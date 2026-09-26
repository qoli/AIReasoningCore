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
  private let onAsset: @Sendable (ProviderAsset) async throws -> Void

  public init(
    runtime: any ProviderRuntime,
    providerID: String,
    modelID: String,
    onAsset: (@Sendable (ProviderAsset) async throws -> Void)? = nil
  ) {
    self.runtime = runtime
    self.providerID = providerID
    self.modelID = modelID
    self.onAsset =
      onAsset ?? { _ in
        throw AIReasoningCoreError(
          .unhandledProviderAsset,
          "provider emitted an asset but no asset handler was configured"
        )
      }
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
        transcriptEntries.append(contentsOf: result.entries)
        if resolution.stopped {
          let empty = try emptyContent(for: type)
          return LanguageModelSession.Response(
            content: empty.content,
            rawContent: empty.raw,
            transcriptEntries: ArraySlice(transcriptEntries)
          )
        }
        transcriptEntries.append(contentsOf: resolution.outputs.map(Transcript.Entry.toolOutput))
        guard let assistantMessage = result.assistantMessage else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider tool response is missing replayable terminal state"
          )
        }
        messages.append(.assistantMessage(assistantMessage))
        messages.append(contentsOf: try resolution.outputs.map(ProviderMapper.toolResult))
        continue
      }

      transcriptEntries.append(contentsOf: result.reasoningEntries)
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
          guard custom.maximumToolIterations > 0 else {
            throw AIReasoningCoreError(
              .toolIterationLimitExceeded,
              "maximumToolIterations must be greater than zero"
            )
          }
          var messages = try ProviderMapper.messages(from: session.transcript)
          let tools = try ProviderMapper.tools(from: session.tools)
          let generationOptions = try ProviderMapper.options(
            for: type, options: options, custom: custom)
          var transcriptEntries: [Transcript.Entry] = []
          var toolIterations = 0
          while true {
            try Task.checkCancellation()
            let request = ProviderRequest(
              id: UUID().uuidString,
              providerID: providerID,
              modelID: modelID,
              messages: messages,
              tools: tools,
              options: generationOptions
            )
            var lastSnapshot: LanguageModelSession.ResponseStream<Content>.Snapshot?
            func emit(_ text: String, entries: [Transcript.Entry]) throws {
              if let snapshot = try ProviderMapper.snapshot(
                text, for: type, transcriptEntries: entries)
              {
                continuation.yield(snapshot)
                lastSnapshot = snapshot
              }
            }
            let result = try await collect(runtime.stream(request)) { text, reasoningEntries in
              try emit(text, entries: transcriptEntries + reasoningEntries)
            }
            if !result.toolCalls.isEmpty {
              guard toolIterations < custom.maximumToolIterations else {
                throw AIReasoningCoreError(
                  .toolIterationLimitExceeded,
                  "provider exceeded the configured tool iteration limit"
                )
              }
              toolIterations += 1
              transcriptEntries.append(contentsOf: result.entries)
              try emit("", entries: transcriptEntries)
              let resolution = try await resolve(result.toolCalls, in: session) { output in
                transcriptEntries.append(.toolOutput(output))
                try emit("", entries: transcriptEntries)
              }
              try Task.checkCancellation()
              if resolution.stopped { break }
              guard let assistantMessage = result.assistantMessage else {
                throw AIReasoningCoreError(
                  .invalidProviderResponse,
                  "provider tool response is missing replayable terminal state"
                )
              }
              messages.append(.assistantMessage(assistantMessage))
              messages.append(contentsOf: try resolution.outputs.map(ProviderMapper.toolResult))
              continue
            }
            let raw = try ProviderMapper.generatedContent(result.text, for: type)
            _ = try ProviderMapper.content(type, from: raw)
            transcriptEntries.append(contentsOf: result.reasoningEntries)
            // Terminal signatures/metadata can complete a reasoning entry without new answer text.
            if lastSnapshot.map({ Array($0.transcriptEntries) }) != transcriptEntries {
              try emit(result.text, entries: transcriptEntries)
            }
            break
          }
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
    _ stream: AsyncThrowingStream<ProviderEvent, any Error>,
    onUpdate: ((String, [Transcript.Entry]) throws -> Void)? = nil
  ) async throws -> CollectedResponse {
    var text = ""
    let roundID = UUID().uuidString
    var reasoningIndex: Int?
    var content: [ProviderAssistantContent] = []
    var callIndices: [String: Int] = [:]
    var openCalls: [String: String] = [:]
    var completedCallIDs = Set<String>()
    var completed = false
    var started = false
    var finishReason: ProviderFinishReason?
    var terminalSnapshot: ProviderResponseSnapshot?
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
      if terminalSnapshot != nil {
        guard case .completed = event else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider emitted an event after the terminal response snapshot"
          )
        }
      }
      switch event {
      case .responseStarted:
        throw AIReasoningCoreError(
          .invalidProviderResponse,
          "provider emitted responseStarted more than once"
        )
      case .textDelta(let delta):
        text += delta
        if case .text(let previous) = content.last {
          content[content.count - 1] = .text(previous + delta)
        } else {
          content.append(.text(delta))
        }
        reasoningIndex = nil
        try onUpdate?(text, ProviderMapper.reasoningEntries(from: content, roundID: roundID))
      case .toolCallStarted(let id, let name):
        guard openCalls[id] == nil, !completedCallIDs.contains(id) else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider started duplicate tool call: \(id)"
          )
        }
        reasoningIndex = nil
        openCalls[id] = name
        callIndices[id] = content.count
        content.append(.toolCall(ProviderToolCall(id: id, name: name, arguments: .object([:]))))
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
        guard let index = callIndices.removeValue(forKey: call.id) else {
          throw AIReasoningCoreError(.invalidProviderResponse, "missing tool call content position")
        }
        content[index] = .toolCall(call)
      case .asset(let asset):
        try await onAsset(asset)
      case .reasoningDelta(let delta):
        guard !delta.isEmpty else { continue }
        if let index = reasoningIndex, case .reasoning(let previous) = content[index] {
          content[index] = .reasoning(
            .init(
              text: previous.text + delta, signature: previous.signature,
              isRedacted: previous.isRedacted, providerMetadata: previous.providerMetadata))
        } else {
          reasoningIndex = content.count
          content.append(.reasoning(.init(text: delta, signature: nil, providerMetadata: [:])))
        }
        try onUpdate?(text, ProviderMapper.reasoningEntries(from: content, roundID: roundID))
      case .reasoningSignatureDelta:
        // Provider signatures are opaque: only the authoritative terminal content is replayable.
        // Some protocols emit fragments, others emit a replacement token; never concatenate here.
        break
      case .usage:
        break
      case .responseSnapshot(let snapshot):
        try validate(snapshot)
        terminalSnapshot = snapshot
      case .completed(let reason):
        try ProviderMapper.validateFinish(reason)
        guard terminalSnapshot != nil else {
          throw AIReasoningCoreError(
            .invalidProviderResponse,
            "provider completed without a terminal response snapshot"
          )
        }
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
    let calls = content.compactMap { item -> ProviderToolCall? in
      if case .toolCall(let call) = item { return call }
      return nil
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
    guard let terminalSnapshot, let finishReason else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider stream is missing terminal response state"
      )
    }
    try validate(
      terminalSnapshot,
      finishReason: finishReason,
      text: text,
      toolCalls: calls
    )
    let assistantMessage = calls.isEmpty ? nil : try terminalSnapshot.replayAssistantMessage()
    let terminalContent: [ProviderAssistantContent] = terminalSnapshot.content.compactMap {
      switch $0 {
      case .text(let value): return .signedText(value)
      case .reasoning(let value): return .reasoning(value)
      case .toolCall(let value): return .toolCall(value)
      case .asset: return nil
      }
    }
    return CollectedResponse(
      text: text,
      toolCalls: calls,
      entries: try ProviderMapper.entries(from: terminalContent, roundID: roundID),
      reasoningEntries: try ProviderMapper.reasoningEntries(
        from: terminalContent, roundID: roundID),
      assistantMessage: assistantMessage
    )
  }

  private func validate(_ metadata: ProviderResponseMetadata) throws {
    guard metadata.providerID == providerID, metadata.modelID == modelID else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider response identity does not match the requested provider and model"
      )
    }
  }

  private func validate(_ snapshot: ProviderResponseSnapshot) throws {
    guard snapshot.providerID == providerID, snapshot.modelID == modelID else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider response snapshot identity does not match the requested provider and model"
      )
    }
  }

  private func validate(
    _ snapshot: ProviderResponseSnapshot,
    finishReason: ProviderFinishReason,
    text: String,
    toolCalls: [ProviderToolCall]
  ) throws {
    guard snapshot.finishReason == finishReason else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider response snapshot finish reason does not match completion"
      )
    }
    let snapshotText = snapshot.content.compactMap { item -> String? in
      guard case .text(let value) = item else { return nil }
      return value.text
    }.joined()
    let snapshotToolCalls = snapshot.content.compactMap { item -> ProviderToolCall? in
      guard case .toolCall(let call) = item else { return nil }
      return call
    }
    guard snapshotText == text, snapshotToolCalls == toolCalls else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider response snapshot does not match streamed content"
      )
    }
  }

  private func resolve(
    _ calls: [ProviderToolCall],
    in session: LanguageModelSession,
    onOutput: ((Transcript.ToolOutput) throws -> Void)? = nil
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
        return ToolResolution(outputs: [], stopped: true)
      }
      decisions.append(decision)
    }

    var outputs: [Transcript.ToolOutput] = []
    for (call, decision) in zip(transcriptCalls, decisions) {
      try Task.checkCancellation()
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
        outputs.append(output)
        try onOutput?(output)
        if let delegate = session.toolExecutionDelegate {
          await delegate.didExecuteToolCall(call, output: output, in: session)
        }
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
          outputs.append(output)
          try onOutput?(output)
          if let delegate = session.toolExecutionDelegate {
            await delegate.didExecuteToolCall(call, output: output, in: session)
          }
        } catch {
          if let delegate = session.toolExecutionDelegate {
            await delegate.didFailToolCall(call, error: error, in: session)
          }
          throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
        }
      }
    }
    return ToolResolution(outputs: outputs, stopped: false)
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
  let entries: [Transcript.Entry]
  let reasoningEntries: [Transcript.Entry]
  let assistantMessage: ProviderAssistantMessage?
}

private struct ToolResolution: Sendable {
  let outputs: [Transcript.ToolOutput]
  let stopped: Bool
}

private enum ProviderMapper {
  static func messages(from transcript: Transcript) throws -> [ProviderMessage] {
    var messages: [ProviderMessage] = []
    for entry in transcript {
      let message: ProviderMessage
      switch entry {
      case .instructions(let instructions):
        message = .system(try text(from: instructions.segments))
      case .prompt(let prompt):
        message = .user(try prompt.segments.map(userContent))
      case .response(let response):
        message = .assistant(try response.segments.map(assistantContent))
      case .toolCalls(let calls):
        message = .assistant(
          try calls.map { call in
            .toolCall(
              ProviderToolCall(
                id: call.id,
                name: call.toolName,
                arguments: try jsonValue(call.arguments)
              )
            )
          })
      case .reasoning(let reasoning):
        message = .assistant([.reasoning(try providerReasoning(reasoning))])
      case .toolOutput(let output):
        message = try toolResult(output)
      }
      // A mixed assistant turn is stored as adjacent reasoning/response/toolCalls entries.
      // A tool output, prompt or instructions entry terminates that turn.
      if case .assistant(let content) = message,
        case .assistant(let previous) = messages.last
      {
        messages[messages.count - 1] = .assistant(previous + content)
      } else {
        messages.append(message)
      }
    }
    return messages
  }

  static func entries(from content: [ProviderAssistantContent], roundID: String = UUID().uuidString)
    throws -> [Transcript.Entry]
  {
    var entries: [Transcript.Entry] = []
    var reasoningOrdinal = 0
    for item in content {
      switch item {
      case .text(let text):
        entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: text))])))
      case .signedText(let text):
        entries.append(
          .response(.init(assetIDs: [], segments: [.text(.init(content: text.text))])))
      case .reasoning(let value):
        entries.append(
          .reasoning(try reasoningEntry(value, id: "\(roundID):reasoning:\(reasoningOrdinal)")))
        reasoningOrdinal += 1
      case .toolCall(let call):
        let mapped = try transcriptToolCall(call)
        if case .toolCalls(let previous) = entries.last {
          entries[entries.count - 1] = .toolCalls(
            .init(id: previous.id, Array(previous) + [mapped]))
        } else {
          entries.append(.toolCalls(.init([mapped])))
        }
      }
    }
    return entries
  }

  static func reasoningEntries(from content: [ProviderAssistantContent], roundID: String) throws
    -> [Transcript.Entry]
  {
    try entries(
      from: content.filter { if case .reasoning = $0 { true } else { false } }, roundID: roundID)
  }

  private static func reasoningEntry(_ value: ProviderReasoningContent, id: String) throws
    -> Transcript.Reasoning
  {
    var metadata: [String: GeneratedContent] = [
      "pi-ai-swift.providerMetadata": try generatedContent(.object(value.providerMetadata))
    ]
    if let redacted = value.isRedacted {
      metadata["pi-ai-swift.isRedacted"] = GeneratedContent(redacted)
    }
    if value.isRedacted == true {
      metadata["pi-ai-swift.redactedText"] = GeneratedContent(value.text)
    }
    return .init(
      id: id, metadata: metadata,
      segments: value.isRedacted == true || value.text.isEmpty
        ? [] : [.text(.init(id: "\(id):text", content: value.text))],
      signature: value.signature.map { Data($0.utf8) })
  }

  private static func providerReasoning(_ value: Transcript.Reasoning) throws
    -> ProviderReasoningContent
  {
    let redacted: Bool?
    if let flag = value.metadata["pi-ai-swift.isRedacted"] {
      redacted = try Bool(flag)
    } else {
      redacted = nil
    }
    let display = try text(from: value.segments)
    let originalText =
      redacted == true
      ? try value.metadata["pi-ai-swift.redactedText"].map(String.init) ?? "" : display
    let signature: String?
    if let bytes = value.signature {
      guard let decoded = String(data: bytes, encoding: .utf8) else {
        throw AIReasoningCoreError(.invalidTranscript, "pi-ai reasoning signature is not UTF-8")
      }
      signature = decoded
    } else {
      signature = nil
    }
    var metadata: [String: PiAIProviderRuntime.JSONValue] = [:]
    if let raw = value.metadata["pi-ai-swift.providerMetadata"] {
      guard case .object(let object) = try jsonValue(raw) else {
        throw AIReasoningCoreError(.invalidTranscript, "pi-ai reasoning metadata must be an object")
      }
      metadata = object
    }
    return .init(
      text: originalText, signature: signature, isRedacted: redacted, providerMetadata: metadata)
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
        inputSchema: try toolInputSchema(tool.parameters)
      )
    }
  }

  private static func toolInputSchema(_ schema: GenerationSchema) throws
    -> PiAIProviderRuntime.JSONValue
  {
    guard case .object(var root) = try encodedJSONValue(schema) else {
      throw AIReasoningCoreError(.unsupportedOperation, "tool input schema must be an object")
    }
    let definitions = root["$defs"]
    var visited: Set<String> = []
    while let reference = root["$ref"] {
      guard case .string(let path) = reference, path.hasPrefix("#/$defs/"),
        visited.insert(path).inserted,
        case .object(let entries) = definitions,
        case .object(let resolved) = entries[String(path.dropFirst("#/$defs/".count))]
      else {
        throw AIReasoningCoreError(
          .unsupportedOperation, "tool input schema has an unsupported or unresolved root reference"
        )
      }
      root = resolved
    }
    guard root["type"] == .string("object") else {
      throw AIReasoningCoreError(
        .unsupportedOperation, "tool input schema root must have type object")
    }
    if let definitions { root["$defs"] = definitions }
    return .object(root)
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
      // GeneratedContent intentionally repairs partial JSON for streaming snapshots.
      // Final output must first be valid, complete JSON without that repair.
      _ = try JSONDecoder().decode(PiAIProviderRuntime.JSONValue.self, from: Data(text.utf8))
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
    for type: Content.Type,
    transcriptEntries: [Transcript.Entry] = []
  ) throws -> LanguageModelSession.ResponseStream<Content>.Snapshot? {
    if type == String.self {
      let raw = GeneratedContent(text)
      return .init(
        content: (text as! Content).asPartiallyGenerated(), rawContent: raw,
        transcriptEntries: ArraySlice(transcriptEntries)
      )
    }
    let raw: GeneratedContent
    do {
      // An empty object represents not-yet-generated fields, not reasoning JSON.
      raw =
        text.isEmpty
          && transcriptEntries.contains { if case .reasoning = $0 { true } else { false } }
        ? GeneratedContent(properties: [:]) : try GeneratedContent(json: text)
    } catch {
      throw AIReasoningCoreError(
        .invalidStructuredOutput,
        "provider returned invalid structured output: \(error)"
      )
    }
    guard let partial = try? partiallyGenerated(type, from: raw) else { return nil }
    return .init(
      content: partial, rawContent: raw, transcriptEntries: ArraySlice(transcriptEntries)
    )
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
