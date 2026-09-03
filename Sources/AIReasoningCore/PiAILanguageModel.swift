import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

public struct PiAILanguageModel: LanguageModel {
  public typealias UnavailableReason = Never

  public struct CustomGenerationOptions: AnyLanguageModel.CustomGenerationOptions {
    public var reasoningEffort: ProviderReasoningEffort?
    public var providerOptions: [String: PiAIProviderRuntime.JSONValue]
    public var maximumToolIterations: Int
    public var outputModality: ProviderOutputModality
    public var sessionID: String?
    public var cacheRetention: ProviderCacheRetention
    public var serviceTier: String?
    public var toolChoice: PiAIProviderRuntime.JSONValue?

    public init(
      reasoningEffort: ProviderReasoningEffort? = nil,
      providerOptions: [String: PiAIProviderRuntime.JSONValue] = [:],
      maximumToolIterations: Int = 8,
      outputModality: ProviderOutputModality = .text,
      sessionID: String? = nil,
      cacheRetention: ProviderCacheRetention = .short,
      serviceTier: String? = nil,
      toolChoice: PiAIProviderRuntime.JSONValue? = nil
    ) {
      self.reasoningEffort = reasoningEffort
      self.providerOptions = providerOptions
      self.maximumToolIterations = maximumToolIterations
      self.outputModality = outputModality
      self.sessionID = sessionID
      self.cacheRetention = cacheRetention
      self.serviceTier = serviceTier
      self.toolChoice = toolChoice
    }
  }

  private let runtime: any ProviderRuntime
  private let providerID: String
  private let modelID: String
  private let assets: AssetStore?

  public init(
    runtime: any ProviderRuntime,
    providerID: String,
    modelID: String,
    assets: AssetStore? = nil
  ) {
    self.runtime = runtime
    self.providerID = providerID
    self.modelID = modelID
    self.assets = assets
  }

  public func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    var messages = try ProviderMapper.messages(from: session.transcript)
    let tools = try ProviderMapper.tools(from: session.tools)
    let providerOptions = options[custom: Self.self] ?? CustomGenerationOptions()
    guard providerOptions.maximumToolIterations > 0 else {
      throw AIReasoningCoreError(
        .toolIterationLimitExceeded,
        "maximumToolIterations must be greater than zero"
      )
    }
    let generationOptions = try ProviderMapper.options(
      for: type,
      options: options,
      custom: providerOptions
    )
    var transcriptEntries: [Transcript.Entry] = []

    var toolIterations = 0
    while true {
      let request = ProviderRequest(
        id: UUID().uuidString,
        providerID: providerID,
        modelID: modelID,
        messages: messages,
        tools: tools,
        options: generationOptions
      )
      let result = try await collect(runtime.stream(request))

      if !result.toolCalls.isEmpty {
        guard result.text.isEmpty else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider returned mixed text and tool calls in one turn"
          )
        }
        guard toolIterations < providerOptions.maximumToolIterations else {
          throw AIReasoningCoreError(
            .toolIterationLimitExceeded,
            "provider exceeded the configured tool iteration limit"
          )
        }
        toolIterations += 1
        let resolution = try await resolve(
          result.toolCalls,
          in: session
        )
        transcriptEntries.append(.toolCalls(Transcript.ToolCalls(resolution.calls)))
        if resolution.stopped {
          let empty = try emptyContent(for: type)
          return LanguageModelSession.Response(
            content: empty.content,
            rawContent: empty.raw,
            transcriptEntries: ArraySlice(transcriptEntries)
          )
        }
        transcriptEntries.append(contentsOf: resolution.outputs.map(Transcript.Entry.toolOutput))
        messages.append(
          .assistant(result.toolCalls.map(ProviderAssistantContent.toolCall))
        )
        messages.append(contentsOf: try resolution.outputs.map(ProviderMapper.toolResult))
        continue
      }

      let raw = try ProviderMapper.generatedContent(result.text, for: type)
      return LanguageModelSession.Response(
        content: try ProviderMapper.content(type, from: raw),
        rawContent: raw,
        transcriptEntries: ArraySlice(transcriptEntries)
      )
    }
  }

  public func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    let upstream = AsyncThrowingStream<
      LanguageModelSession.ResponseStream<Content>.Snapshot, any Error
    > {
      continuation in
      let task = Task { @Sendable in
        do {
          let custom = options[custom: Self.self] ?? CustomGenerationOptions()
          let request = ProviderRequest(
            id: UUID().uuidString,
            providerID: providerID,
            modelID: modelID,
            messages: try ProviderMapper.messages(from: session.transcript),
            tools: try ProviderMapper.tools(from: session.tools),
            options: try ProviderMapper.options(for: type, options: options, custom: custom)
          )
          var accumulated = ""
          var completed = false
          var started = false
          for try await event in runtime.stream(request) {
            try Task.checkCancellation()
            guard !completed else {
              throw AIReasoningCoreError(
                .invalidProviderResponse,
                "provider emitted an event after completion"
              )
            }
            if !started {
              guard case .responseStarted(let metadata) = event else {
                throw AIReasoningCoreError(
                  .invalidProviderResponse,
                  "the first provider event must be responseStarted"
                )
              }
              try validate(metadata)
              started = true
              continue
            }
            switch event {
            case .textDelta(let delta):
              accumulated += delta
              if let snapshot = try ProviderMapper.snapshot(
                accumulated,
                for: type
              ) {
                continuation.yield(snapshot)
              }
            case .toolCallStarted, .toolInputDelta, .toolCallCompleted:
              throw AIReasoningCoreError(
                .unsupportedStreamingToolCalls,
                "AnyLanguageModel 0.9.0 cannot persist streaming tool calls"
              )
            case .asset(let asset):
              guard let assets else {
                throw AIReasoningCoreError(
                  .missingAssetStore,
                  "provider emitted an asset without an AssetStore"
                )
              }
              _ = try await assets.save(asset)
            case .completed(let reason):
              try ProviderMapper.validateFinish(reason)
              completed = true
            case .responseStarted:
              throw AIReasoningCoreError(
                .invalidProviderResponse,
                "provider emitted responseStarted more than once"
              )
            case .reasoningDelta, .reasoningSignatureDelta, .usage:
              break
            }
          }
          guard completed else {
            throw AIReasoningCoreError(
              .invalidProviderResponse,
              "provider stream ended without a completed event"
            )
          }
          let raw = try ProviderMapper.generatedContent(accumulated, for: type)
          _ = try ProviderMapper.content(type, from: raw)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return LanguageModelSession.ResponseStream(stream: upstream)
  }

  private func collect(
    _ stream: AsyncThrowingStream<ProviderEvent, any Error>
  ) async throws -> CollectedResponse {
    var text = ""
    var calls: [ProviderToolCall] = []
    var openCalls: [String: String] = [:]
    var completedCallIDs = Set<String>()
    var completed = false
    var started = false
    var finishReason: ProviderFinishReason?
    for try await event in stream {
      try Task.checkCancellation()
      guard !completed else {
        throw AIReasoningCoreError(
          .invalidProviderResponse,
          "provider emitted an event after completion"
        )
      }
      if !started {
        guard case .responseStarted(let metadata) = event else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "the first provider event must be responseStarted"
          )
        }
        try validate(metadata)
        started = true
        continue
      }
      switch event {
      case .responseStarted:
        throw AIReasoningCoreError(
          .invalidProviderResponse,
          "provider emitted responseStarted more than once"
        )
      case .textDelta(let delta):
        text += delta
      case .toolCallStarted(let id, let name):
        guard openCalls[id] == nil, !completedCallIDs.contains(id) else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider started duplicate tool call: \(id)"
          )
        }
        openCalls[id] = name
      case .toolInputDelta(let id, _):
        guard openCalls[id] != nil else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider emitted input for unknown tool call: \(id)"
          )
        }
      case .toolCallCompleted(let call):
        guard let startedName = openCalls.removeValue(forKey: call.id) else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider completed unknown tool call: \(call.id)"
          )
        }
        guard startedName == call.name else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider changed tool name for call: \(call.id)"
          )
        }
        completedCallIDs.insert(call.id)
        calls.append(call)
      case .asset(let asset):
        guard let assets else {
          throw AIReasoningCoreError(
            .missingAssetStore,
            "provider emitted an asset without an AssetStore"
          )
        }
        _ = try await assets.save(asset)
      case .usage, .reasoningDelta, .reasoningSignatureDelta:
        break
      case .completed(let reason):
        try ProviderMapper.validateFinish(reason)
        completed = true
        finishReason = reason
      }
    }
    guard completed else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider stream ended without a completed event"
      )
    }
    guard openCalls.isEmpty else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider stream ended with incomplete tool calls"
      )
    }
    guard !text.isEmpty || !calls.isEmpty else {
      throw AIReasoningCoreError(.invalidProviderResponse, "provider returned no content")
    }
    if calls.isEmpty, finishReason == .toolCalls {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider reported toolCalls without completed tool calls"
      )
    }
    if !calls.isEmpty, finishReason != .toolCalls {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider completed tool calls without a toolCalls finish reason"
      )
    }
    return CollectedResponse(text: text, toolCalls: calls)
  }

  private func validate(_ metadata: ProviderResponseMetadata) throws {
    guard metadata.providerID == providerID, metadata.modelID == modelID else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider response identity does not match the requested provider and model"
      )
    }
  }

  private func resolve(
    _ calls: [ProviderToolCall],
    in session: LanguageModelSession
  ) async throws -> ToolResolution {
    let transcriptCalls = try calls.map(ProviderMapper.transcriptToolCall)
    if let delegate = session.toolExecutionDelegate {
      await delegate.didGenerateToolCalls(transcriptCalls, in: session)
    }

    var decisions: [ToolExecutionDecision] = []
    decisions.reserveCapacity(transcriptCalls.count)
    for call in transcriptCalls {
      let decision =
        await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session) ?? .execute
      if case .stop = decision {
        return ToolResolution(calls: transcriptCalls, outputs: [], stopped: true)
      }
      decisions.append(decision)
    }

    var outputs: [Transcript.ToolOutput] = []
    for (call, decision) in zip(transcriptCalls, decisions) {
      switch decision {
      case .stop:
        throw AIReasoningCoreError(
          .invalidProviderResponse,
          "internal tool decision state became inconsistent"
        )
      case .provideOutput(let segments):
        let output = Transcript.ToolOutput(
          id: call.id,
          toolName: call.toolName,
          segments: segments
        )
        if let delegate = session.toolExecutionDelegate {
          await delegate.didExecuteToolCall(call, output: output, in: session)
        }
        outputs.append(output)
      case .execute:
        guard let tool = session.tools.first(where: { $0.name == call.toolName }) else {
          throw AIReasoningCoreError(.unknownTool, "unknown tool: \(call.toolName)")
        }
        do {
          let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: try await execute(tool, arguments: call.arguments)
          )
          if let delegate = session.toolExecutionDelegate {
            await delegate.didExecuteToolCall(call, output: output, in: session)
          }
          outputs.append(output)
        } catch {
          if let delegate = session.toolExecutionDelegate {
            await delegate.didFailToolCall(call, error: error, in: session)
          }
          throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
        }
      }
    }
    return ToolResolution(calls: transcriptCalls, outputs: outputs, stopped: false)
  }

  private func execute<T: Tool>(
    _ tool: T,
    arguments: GeneratedContent
  ) async throws -> [Transcript.Segment] {
    let typedArguments = try T.Arguments(arguments)
    let output = try await tool.call(arguments: typedArguments)
    if let structured = output as? any ConvertibleToGeneratedContent {
      return [.structure(.init(source: tool.name, content: structured.generatedContent))]
    }
    if let text = output as? String {
      return [.text(.init(content: text))]
    }
    return [.text(.init(content: output.promptRepresentation.description))]
  }

  private func emptyContent<Content: Generable>(
    for type: Content.Type
  ) throws -> (content: Content, raw: GeneratedContent) {
    if type == String.self {
      return ("" as! Content, GeneratedContent(""))
    }
    throw AIReasoningCoreError(
      .invalidStructuredOutput,
      "a stopped tool call cannot produce structured content"
    )
  }
}

private struct CollectedResponse: Sendable {
  let text: String
  let toolCalls: [ProviderToolCall]
}

private struct ToolResolution: Sendable {
  let calls: [Transcript.ToolCall]
  let outputs: [Transcript.ToolOutput]
  let stopped: Bool
}

private enum ProviderMapper {
  static func messages(from transcript: Transcript) throws -> [ProviderMessage] {
    try transcript.map { entry in
      switch entry {
      case .instructions(let instructions):
        return .system(try text(from: instructions.segments))
      case .prompt(let prompt):
        return .user(try prompt.segments.map(userContent))
      case .response(let response):
        return .assistant(try response.segments.map(assistantContent))
      case .toolCalls(let calls):
        return .assistant(
          try calls.map { call in
            .toolCall(
              ProviderToolCall(
                id: call.id,
                name: call.toolName,
                arguments: try jsonValue(call.arguments)
              )
            )
          })
      case .toolOutput(let output):
        return try toolResult(output)
      }
    }
  }

  static func tools(from tools: [any Tool]) throws -> [ProviderToolDefinition] {
    let names = tools.map(\.name)
    guard Set(names).count == names.count else {
      throw AIReasoningCoreError(
        .invalidTranscript,
        "tool names must be unique within a LanguageModelSession"
      )
    }
    return try tools.map { tool in
      ProviderToolDefinition(
        name: tool.name,
        description: tool.description,
        inputSchema: try encodedJSONValue(tool.parameters)
      )
    }
  }

  static func options<Content: Generable>(
    for type: Content.Type,
    options: GenerationOptions,
    custom: PiAILanguageModel.CustomGenerationOptions
  ) throws -> ProviderGenerationOptions {
    guard options.sampling == nil else {
      throw AIReasoningCoreError(
        .unsupportedOperation,
        "pi-ai-swift cannot represent AnyLanguageModel sampling options"
      )
    }
    return ProviderGenerationOptions(
      maximumOutputTokens: options.maximumResponseTokens,
      temperature: options.temperature,
      reasoningEffort: custom.reasoningEffort,
      responseSchema: type == String.self ? nil : try encodedJSONValue(type.generationSchema),
      providerOptions: custom.providerOptions,
      outputModality: custom.outputModality,
      sessionID: custom.sessionID,
      cacheRetention: custom.cacheRetention,
      serviceTier: custom.serviceTier,
      toolChoice: custom.toolChoice
    )
  }

  static func generatedContent<Content: Generable>(
    _ text: String,
    for type: Content.Type
  ) throws -> GeneratedContent {
    if type == String.self { return GeneratedContent(text) }
    do {
      return try GeneratedContent(json: text)
    } catch {
      throw AIReasoningCoreError(
        .invalidStructuredOutput,
        "provider returned invalid structured output: \(error)"
      )
    }
  }

  static func content<Content: Generable>(
    _ type: Content.Type,
    from raw: GeneratedContent
  ) throws -> Content {
    if type == String.self, case .string(let value) = raw.kind {
      return value as! Content
    }
    do {
      return try type.init(raw)
    } catch {
      throw AIReasoningCoreError(
        .invalidStructuredOutput,
        "structured output does not match the requested type: \(error)"
      )
    }
  }

  static func snapshot<Content: Generable>(
    _ text: String,
    for type: Content.Type
  ) throws -> LanguageModelSession.ResponseStream<Content>.Snapshot? {
    if type == String.self {
      let raw = GeneratedContent(text)
      return .init(content: (text as! Content).asPartiallyGenerated(), rawContent: raw)
    }
    let raw = try GeneratedContent(json: text)
    guard let partial = try? partiallyGenerated(type, from: raw) else { return nil }
    return .init(content: partial, rawContent: raw)
  }

  private static func partiallyGenerated<Content: Generable>(
    _ type: Content.Type,
    from raw: GeneratedContent
  ) throws -> Content.PartiallyGenerated {
    try Content.PartiallyGenerated(raw)
  }

  static func transcriptToolCall(_ call: ProviderToolCall) throws -> Transcript.ToolCall {
    Transcript.ToolCall(
      id: call.id,
      toolName: call.name,
      arguments: try generatedContent(call.arguments)
    )
  }

  static func toolResult(_ output: Transcript.ToolOutput) throws -> ProviderMessage {
    .toolResult(
      ProviderToolResult(
        toolCallID: output.id,
        toolName: output.toolName,
        content: output.segments.map { segment in
          switch segment {
          case .text(let text): return .text(text.content)
          case .structure(let structure): return .text(structure.content.jsonString)
          case .image(let image): return .image(providerImage(image))
          }
        },
        isError: false
      )
    )
  }

  static func validateFinish(_ reason: ProviderFinishReason) throws {
    switch reason {
    case .stop, .length, .toolCalls:
      return
    case .contentFilter:
      throw AIReasoningCoreError(
        .invalidProviderResponse, "provider stopped because of content filtering")
    case .cancelled:
      throw CancellationError()
    }
  }

  private static func userContent(_ segment: Transcript.Segment) throws -> ProviderUserContent {
    switch segment {
    case .text(let text): return .text(text.content)
    case .structure(let structure): return .text(structure.content.jsonString)
    case .image(let image): return .image(providerImage(image))
    }
  }

  private static func assistantContent(_ segment: Transcript.Segment) throws
    -> ProviderAssistantContent
  {
    switch segment {
    case .text(let text): return .text(text.content)
    case .structure(let structure): return .text(structure.content.jsonString)
    case .image:
      throw AIReasoningCoreError(
        .invalidTranscript,
        "pi-ai-swift cannot represent an assistant image transcript segment"
      )
    }
  }

  private static func text(from segments: [Transcript.Segment]) throws -> String {
    try segments.map { segment in
      switch segment {
      case .text(let text): return text.content
      case .structure(let structure): return structure.content.jsonString
      case .image:
        throw AIReasoningCoreError(
          .invalidTranscript,
          "instructions cannot contain image segments"
        )
      }
    }.joined(separator: "\n")
  }

  private static func providerImage(_ image: Transcript.ImageSegment) -> ProviderImage {
    switch image.source {
    case .data(let data, let mimeType): return .data(data, mimeType: mimeType)
    case .url(let url): return .remoteURL(url, mimeType: nil)
    }
  }

  private static func jsonValue(_ content: GeneratedContent) throws -> PiAIProviderRuntime.JSONValue
  {
    guard let data = content.jsonString.data(using: .utf8) else {
      throw AIReasoningCoreError(.invalidStructuredOutput, "generated content is not UTF-8")
    }
    return try JSONDecoder().decode(PiAIProviderRuntime.JSONValue.self, from: data)
  }

  private static func generatedContent(
    _ value: PiAIProviderRuntime.JSONValue
  ) throws -> GeneratedContent {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw AIReasoningCoreError(.invalidStructuredOutput, "tool arguments are not UTF-8")
    }
    return try GeneratedContent(json: json)
  }

  private static func encodedJSONValue<T: Encodable>(
    _ value: T
  ) throws -> PiAIProviderRuntime.JSONValue {
    try JSONDecoder().decode(
      PiAIProviderRuntime.JSONValue.self,
      from: JSONEncoder().encode(value)
    )
  }
}
