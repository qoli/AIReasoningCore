@_spi(Compatibility) import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

/// Temporary orchestration required by AnyLanguageModel's Foundation Models 26-style
/// `LanguageModel` contract. This type should disappear when the upstream contract
/// supplies a Foundation Models 27-style executor seam.
struct SessionCompatibilityDriver: Sendable {
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
    if let maximumToolIterations = custom.maximumToolIterations,
      maximumToolIterations <= 0
    {
      throw AIReasoningCoreError(
        .toolIterationLimitExceeded,
        "maximumToolIterations must be greater than zero"
      )
    }
    var transcriptEntries: [Transcript.Entry] = []
    var providerContinuation = PiAIProviderContinuation()
    var continuationIdentity: PiAIProviderAdapter.Identity?
    var completedUsage = PiAIGenerationUsage.zero
    var toolIterations = 0

    while true {
      if onSnapshot != nil { try Task.checkCancellation() }
      let context = try await session.resolvedRequestContext(
        including: transcriptEntries,
        options: options
      )
      guard let selectedModel = context.model as? PiAILanguageModel else {
        throw AIReasoningCoreError(
          .unsupportedOperation,
          "a compatibility Tool continuation cannot switch from PiAILanguageModel to another model type"
        )
      }
      let roundAdapter = selectedModel.providerAdapter
      if let continuationIdentity, continuationIdentity != roundAdapter.identity {
        providerContinuation = PiAIProviderContinuation()
      }
      let roundCustom = context.options[custom: PiAILanguageModel.self] ?? custom
      let generationOptions = try roundAdapter.generationOptions(
        for: type,
        options: context.options,
        contextOptions: context.contextOptions,
        custom: roundCustom
      )
      providerContinuation = roundAdapter.normalizedContinuation(
        providerContinuation,
        for: context.transcript,
        currentRoundEntries: transcriptEntries
      )
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

      let result = try await roundAdapter.generateRound(
        transcript: context.transcript,
        tools: context.tools,
        currentRoundEntries: transcriptEntries,
        continuation: providerContinuation,
        options: generationOptions,
        onUpdate: updateHandler
      )
      completedUsage.accumulate(result.usage)

      if !result.toolCalls.isEmpty {
        if let maximumToolIterations = custom.maximumToolIterations {
          guard toolIterations < maximumToolIterations else {
            throw AIReasoningCoreError(
              .toolIterationLimitExceeded,
              "provider exceeded the configured tool iteration limit"
            )
          }
        }
        toolIterations += 1
        transcriptEntries.append(contentsOf: result.entries)
        try await session.profileDidProduceEntries(
          result.entries,
          requestContext: context,
          currentRoundEntries: transcriptEntries
        )
        try emit("", entries: transcriptEntries, usage: completedUsage)

        let resolution = try await resolve(
          result.toolCalls,
          in: session,
          using: context.tools,
          requestContext: context,
          currentRoundEntries: transcriptEntries
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
        try roundAdapter.continueAfterToolRound(
          result,
          outputs: resolution.outputs,
          continuation: &providerContinuation
        )
        continuationIdentity = roundAdapter.identity
        continue
      }

      let raw = try SessionOutputMapper.generatedContent(result.text, for: type)
      let content = try SessionOutputMapper.content(type, from: raw)
      try await session.profileDidProduceEntries(
        result.reasoningEntries,
        requestContext: context,
        currentRoundEntries: transcriptEntries + result.reasoningEntries
      )
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
    requestContext: LanguageModelSession.RequestContext,
    currentRoundEntries: [Transcript.Entry],
    onOutput: ((Transcript.ToolOutput) async throws -> Void)? = nil
  ) async throws -> ToolResolution {
    if let delegate = session.toolExecutionDelegate {
      await delegate.didGenerateToolCalls(calls, in: session)
    }

    var decisions: [ToolExecutionDecision] = []
    decisions.reserveCapacity(calls.count)
    for call in calls {
      try await session.profileWillExecuteToolCall(
        call,
        requestContext: requestContext,
        currentRoundEntries: currentRoundEntries
      )
      let decision =
        await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session) ?? .execute
      if case .stop = decision {
        return ToolResolution(outputs: [], stopped: true)
      }
      decisions.append(decision)
    }

    var outputs: [Transcript.ToolOutput] = []
    var completedOutputEntries: [Transcript.Entry] = []
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
        completedOutputEntries.append(.toolOutput(output))
        try await onOutput?(output)
        try await session.profileDidProduceToolOutput(
          for: call,
          output: output,
          requestContext: requestContext,
          currentRoundEntries: currentRoundEntries + completedOutputEntries
        )
        if let delegate = session.toolExecutionDelegate {
          await delegate.didExecuteToolCall(call, output: output, in: session)
        }
      case .execute:
        guard let tool = tools.first(where: { $0.name == call.toolName }) else {
          throw AIReasoningCoreError(.unknownTool, "unknown tool: \(call.toolName)")
        }
        let segments: [Transcript.Segment]
        do {
          segments = try await session.withProfileToolExecution(
            requestContext: requestContext,
            currentRoundEntries: currentRoundEntries + completedOutputEntries
          ) {
            try await execute(tool, arguments: call.arguments)
          }
        } catch {
          if let delegate = session.toolExecutionDelegate {
            await delegate.didFailToolCall(call, error: error, in: session)
          }
          throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
        }
        let output = Transcript.ToolOutput(
          id: call.id,
          toolName: call.toolName,
          segments: segments
        )
        outputs.append(output)
        completedOutputEntries.append(.toolOutput(output))
        try await onOutput?(output)
        try await session.profileDidProduceToolOutput(
          for: call,
          output: output,
          requestContext: requestContext,
          currentRoundEntries: currentRoundEntries + completedOutputEntries
        )
        if let delegate = session.toolExecutionDelegate {
          await delegate.didExecuteToolCall(call, output: output, in: session)
        }
      }
    }
    return ToolResolution(outputs: outputs, stopped: false)
  }

  private func execute<T: Tool>(
    _ tool: T,
    arguments: GeneratedContent
  ) async throws -> [Transcript.Segment] {
    try await tool.makeOutputSegments(from: arguments)
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
