import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

/// Temporary orchestration required by AnyLanguageModel's Foundation Models 26-style
/// `LanguageModel` contract. This type should disappear when the upstream contract
/// supplies a Foundation Models 27-style executor seam.
struct SessionCompatibilityDriver: Sendable {
  private let adapter: PiAIProviderAdapter

  init(adapter: PiAIProviderAdapter) {
    self.adapter = adapter
  }

  func respond<Content>(
    within session: LanguageModelSession,
    generating type: Content.Type,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    guard
      let response = try await run(
        within: session,
        generating: type,
        options: options,
        onSnapshot: nil
      )
    else {
      preconditionFailure("non-streaming compatibility run must produce a terminal response")
    }
    return response
  }

  func streamResponse<Content>(
    within session: LanguageModelSession,
    generating type: Content.Type,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    let upstream = AsyncThrowingStream<
      LanguageModelSession.ResponseStream<Content>.Snapshot, any Error
    > { continuation in
      let task = Task { @Sendable in
        do {
          _ = try await run(
            within: session,
            generating: type,
            options: options
          ) { snapshot in
            continuation.yield(snapshot)
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

  private func run<Content>(
    within session: LanguageModelSession,
    generating type: Content.Type,
    options: GenerationOptions,
    onSnapshot: ((LanguageModelSession.ResponseStream<Content>.Snapshot) -> Void)?
  ) async throws -> LanguageModelSession.Response<Content>? where Content: Generable {
    let custom = options[custom: PiAILanguageModel.self] ?? .init()
    guard custom.maximumToolIterations > 0 else {
      throw AIReasoningCoreError(
        .toolIterationLimitExceeded,
        "maximumToolIterations must be greater than zero"
      )
    }
    let generationOptions = try adapter.generationOptions(
      for: type,
      options: options,
      custom: custom
    )

    var transcriptEntries: [Transcript.Entry] = []
    var providerContinuation = PiAIProviderContinuation()
    var completedUsage = PiAIGenerationUsage.zero
    var toolIterations = 0

    while true {
      if onSnapshot != nil { try Task.checkCancellation() }
      let context = session.resolvedRequestContext()
      var lastSnapshot: LanguageModelSession.ResponseStream<Content>.Snapshot?

      func emit(
        _ text: String,
        entries: [Transcript.Entry],
        usage: PiAIGenerationUsage
      ) throws {
        guard let onSnapshot,
          let snapshot = try SessionOutputMapper.snapshot(
            text,
            for: type,
            transcriptEntries: entries,
            usage: usage.sessionUsage
          )
        else { return }
        onSnapshot(snapshot)
        lastSnapshot = snapshot
      }

      let updateHandler: ((PiAIProviderRoundUpdate) async throws -> Void)?
      if onSnapshot == nil {
        updateHandler = nil
      } else {
        updateHandler = { update in
          try emit(
            update.text,
            entries: transcriptEntries + update.reasoningEntries,
            usage: completedUsage.adding(update.usage)
          )
        }
      }

      let result = try await adapter.generateRound(
        transcript: context.transcript,
        tools: context.tools,
        continuation: providerContinuation,
        options: generationOptions,
        onUpdate: updateHandler
      )
      completedUsage.accumulate(result.usage)

      if !result.toolCalls.isEmpty {
        guard toolIterations < custom.maximumToolIterations else {
          throw AIReasoningCoreError(
            .toolIterationLimitExceeded,
            "provider exceeded the configured tool iteration limit"
          )
        }
        toolIterations += 1
        transcriptEntries.append(contentsOf: result.entries)
        try emit("", entries: transcriptEntries, usage: completedUsage)

        let resolution = try await resolve(
          result.toolCalls,
          in: session,
          using: context.tools
        ) { output in
          transcriptEntries.append(.toolOutput(output))
          try emit("", entries: transcriptEntries, usage: completedUsage)
        }
        if onSnapshot != nil { try Task.checkCancellation() }
        if resolution.stopped {
          if onSnapshot != nil { return nil }
          let empty = try emptyContent(for: type)
          return LanguageModelSession.Response(
            content: empty.content,
            rawContent: empty.raw,
            transcriptEntries: ArraySlice(transcriptEntries),
            usage: completedUsage.sessionUsage
          )
        }
        try adapter.continueAfterToolRound(
          result,
          outputs: resolution.outputs,
          continuation: &providerContinuation
        )
        continue
      }

      let raw = try SessionOutputMapper.generatedContent(result.text, for: type)
      let content = try SessionOutputMapper.content(type, from: raw)
      transcriptEntries.append(contentsOf: result.reasoningEntries)
      let sessionUsage = completedUsage.sessionUsage
      if lastSnapshot.map({ Array($0.transcriptEntries) }) != transcriptEntries
        || lastSnapshot?.usage != sessionUsage
      {
        try emit(result.text, entries: transcriptEntries, usage: completedUsage)
      }
      return LanguageModelSession.Response(
        content: content,
        rawContent: raw,
        transcriptEntries: ArraySlice(transcriptEntries),
        usage: sessionUsage
      )
    }
  }

  private func resolve(
    _ calls: [Transcript.ToolCall],
    in session: LanguageModelSession,
    using tools: [any Tool],
    onOutput: ((Transcript.ToolOutput) throws -> Void)? = nil
  ) async throws -> ToolResolution {
    if let delegate = session.toolExecutionDelegate {
      await delegate.didGenerateToolCalls(calls, in: session)
    }

    var decisions: [ToolExecutionDecision] = []
    decisions.reserveCapacity(calls.count)
    for call in calls {
      let decision =
        await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session) ?? .execute
      if case .stop = decision {
        return ToolResolution(outputs: [], stopped: true)
      }
      decisions.append(decision)
    }

    var outputs: [Transcript.ToolOutput] = []
    for (call, decision) in zip(calls, decisions) {
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
        guard let tool = tools.first(where: { $0.name == call.toolName }) else {
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

private struct ToolResolution: Sendable {
  let outputs: [Transcript.ToolOutput]
  let stopped: Bool
}

private enum SessionOutputMapper {
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
    transcriptEntries: [Transcript.Entry],
    usage: LanguageModelSession.Usage
  ) throws -> LanguageModelSession.ResponseStream<Content>.Snapshot? {
    if type == String.self {
      let raw = GeneratedContent(text)
      return .init(
        content: (text as! Content).asPartiallyGenerated(),
        rawContent: raw,
        transcriptEntries: ArraySlice(transcriptEntries),
        usage: usage
      )
    }
    let raw: GeneratedContent
    do {
      // An empty object represents not-yet-generated fields for usage, reasoning, or Tool
      // checkpoints. Scalar partial types defer the snapshot until content is representable.
      raw = text.isEmpty ? GeneratedContent(properties: [:]) : try GeneratedContent(json: text)
    } catch {
      throw AIReasoningCoreError(
        .invalidStructuredOutput,
        "provider returned invalid structured output: \(error)"
      )
    }
    guard let partial = try? Content.PartiallyGenerated(raw) else { return nil }
    return .init(
      content: partial,
      rawContent: raw,
      transcriptEntries: ArraySlice(transcriptEntries),
      usage: usage
    )
  }
}

extension PiAIGenerationUsage {
  fileprivate var sessionUsage: LanguageModelSession.Usage {
    .init(
      input: .init(
        totalTokenCount: inputTotal,
        cachedTokenCount: cachedInput
      ),
      output: .init(
        totalTokenCount: outputTotal,
        reasoningTokenCount: reasoningOutput
      )
    )
  }
}
