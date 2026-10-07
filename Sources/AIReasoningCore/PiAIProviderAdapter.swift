import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

/// Long-lived AnyLanguageModel-to-pi-ai-swift adapter core.
///
/// This type intentionally has no session dependency. It consumes an already-resolved
/// transcript and Tool snapshot, maps one provider round, validates the normalized event
/// stream, and preserves opaque replay state for a continuation.
struct PiAIProviderAdapter: Sendable {
  struct Identity: Sendable, Equatable {
    let providerID: String
    let modelID: String
    let executorID: UUID
  }

  private let runtime: any ProviderRuntime
  private let providerID: String
  private let modelID: String
  let identity: Identity
  private let onAsset: @Sendable (ProviderAsset) async throws -> Void
  private let onRequestUsage: (@Sendable (PiAIRequestUsage) -> Void)?

  init(
    runtime: any ProviderRuntime,
    providerID: String,
    modelID: String,
    executorID: UUID,
    onAsset: (@Sendable (ProviderAsset) async throws -> Void)?,
    onRequestUsage: (@Sendable (PiAIRequestUsage) -> Void)?
  ) {
    self.runtime = runtime
    self.providerID = providerID
    self.modelID = modelID
    identity = Identity(providerID: providerID, modelID: modelID, executorID: executorID)
    self.onAsset =
      onAsset ?? { _ in
        throw AIReasoningCoreError(
          .unhandledProviderAsset,
          "provider emitted an asset but no asset handler was configured"
        )
      }
    self.onRequestUsage = onRequestUsage
  }

  func generationOptions<Content: Generable>(
    for type: Content.Type,
    options: GenerationOptions,
    contextOptions: ContextOptions = .init(),
    custom: PiAILanguageModel.CustomGenerationOptions
  ) throws -> ProviderGenerationOptions {
    try PiAIProviderMapper.options(
      for: type,
      options: options,
      contextOptions: contextOptions,
      custom: custom
    )
  }

  func generateRound(
    transcript: Transcript,
    tools: [any Tool],
    currentRoundEntries: [Transcript.Entry] = [],
    continuation: PiAIProviderContinuation,
    options: ProviderGenerationOptions,
    onUpdate: ((PiAIProviderRoundUpdate) async throws -> Void)? = nil
  ) async throws -> PiAIProviderRound {
    let messages = try messages(
      from: transcript,
      replacing: currentRoundEntries,
      with: continuation
    )
    return try await generateRound(
      messages: messages, tools: PiAIProviderMapper.tools(from: tools), options: options,
      onUpdate: onUpdate)
  }

  func normalizedContinuation(
    _ continuation: PiAIProviderContinuation,
    for transcript: Transcript,
    currentRoundEntries: [Transcript.Entry]
  ) -> PiAIProviderContinuation {
    guard !continuation.messages.isEmpty, !currentRoundEntries.isEmpty else {
      return PiAIProviderContinuation()
    }
    let projected = Array(transcript)
    let count = currentRoundEntries.count
    let matches = projected.indices.count { start in
      let end = start + count
      return end <= projected.count
        && Array(projected[start..<end]) == currentRoundEntries
    }
    return matches == 1 ? continuation : PiAIProviderContinuation()
  }

  private func messages(
    from transcript: Transcript,
    replacing currentRoundEntries: [Transcript.Entry],
    with continuation: PiAIProviderContinuation
  ) throws -> [ProviderMessage] {
    guard !continuation.messages.isEmpty else {
      return try PiAIProviderMapper.messages(from: transcript)
    }
    guard !currentRoundEntries.isEmpty else {
      return try PiAIProviderMapper.messages(from: transcript)
    }

    let projected = Array(transcript)
    let count = currentRoundEntries.count
    let ranges = projected.indices.compactMap { start -> Range<Int>? in
      let end = start + count
      guard end <= projected.count,
        Array(projected[start..<end]) == currentRoundEntries
      else { return nil }
      return start..<end
    }
    guard ranges.count == 1, let range = ranges.first else {
      return try PiAIProviderMapper.messages(from: transcript)
    }
    return try PiAIProviderMapper.messages(
      from: Transcript(entries: projected[..<range.lowerBound])
    )
      + continuation.messages
      + PiAIProviderMapper.messages(from: Transcript(entries: projected[range.upperBound...]))
  }

  func generateRound(
    messages: [ProviderMessage], tools: [ProviderToolDefinition],
    options: ProviderGenerationOptions,
    onUpdate: ((PiAIProviderRoundUpdate) async throws -> Void)? = nil
  ) async throws -> PiAIProviderRound {
    let request = ProviderRequest(
      id: UUID().uuidString,
      providerID: providerID,
      modelID: modelID,
      messages: messages,
      tools: tools,
      options: options
    )
    let result = try await collect(runtime.stream(request), onUpdate: onUpdate)
    onRequestUsage?(
      PiAIRequestUsage(
        inputTokens: result.usage.inputTotal,
        cachedInputTokens: result.usage.cachedInput,
        outputTokens: result.usage.outputTotal,
        reasoningTokens: result.usage.reasoningOutput
      )
    )
    return result
  }

  func continueAfterToolRound(
    _ round: PiAIProviderRound,
    outputs: [Transcript.ToolOutput],
    continuation: inout PiAIProviderContinuation
  ) throws {
    guard let assistantMessage = round.assistantMessage else {
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider tool response is missing replayable terminal state"
      )
    }
    continuation.messages.append(.assistantMessage(assistantMessage))
    continuation.messages.append(contentsOf: try outputs.map(PiAIProviderMapper.toolResult))
  }

  private func collect(
    _ stream: AsyncThrowingStream<ProviderEvent, any Error>,
    onUpdate: ((PiAIProviderRoundUpdate) async throws -> Void)?
  ) async throws -> PiAIProviderRound {
    var text = ""
    let roundID = UUID().uuidString
    var reasoningIndex: Int?
    var content: [ProviderAssistantContent] = []
    var callIndices: [String: Int] = [:]
    var openCalls: [String: String] = [:]
    var completedCallIDs = Set<String>()
    var completed = false
    var started = false
    var reportedUsage = ProviderUsageAccumulator()
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
        try await onUpdate?(
          PiAIProviderRoundUpdate(
            text: text,
            reasoningEntries: PiAIProviderMapper.reasoningEntries(
              from: content,
              roundID: roundID
            ),
            usage: reportedUsage.value, content: content
          )
        )
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
              text: previous.text + delta,
              signature: previous.signature,
              isRedacted: previous.isRedacted,
              providerMetadata: previous.providerMetadata
            )
          )
        } else {
          reasoningIndex = content.count
          content.append(.reasoning(.init(text: delta, signature: nil, providerMetadata: [:])))
        }
        try await onUpdate?(
          PiAIProviderRoundUpdate(
            text: text,
            reasoningEntries: PiAIProviderMapper.reasoningEntries(
              from: content,
              roundID: roundID
            ),
            usage: reportedUsage.value, content: content
          )
        )
      case .reasoningSignatureDelta:
        // Provider signatures are opaque. Only terminal content is authoritative for replay.
        break
      case .usage(let update):
        let previous = reportedUsage.value
        reportedUsage.merge(update)
        let current = reportedUsage.value
        if current != previous {
          try await onUpdate?(
            PiAIProviderRoundUpdate(
              text: text,
              reasoningEntries: PiAIProviderMapper.reasoningEntries(
                from: content,
                roundID: roundID
              ),
              usage: current, content: content
            )
          )
        }
      case .responseSnapshot(let snapshot):
        try validate(snapshot)
        reportedUsage.merge(snapshot.usage)
        terminalSnapshot = snapshot
      case .completed(let reason):
        try PiAIProviderMapper.validateFinish(reason)
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

    try Task.checkCancellation()
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
    return PiAIProviderRound(
      text: text,
      toolCalls: try calls.map(PiAIProviderMapper.transcriptToolCall),
      entries: try PiAIProviderMapper.entries(from: terminalContent, roundID: roundID),
      reasoningEntries: try PiAIProviderMapper.reasoningEntries(
        from: terminalContent,
        roundID: roundID
      ),
      assistantMessage: assistantMessage,
      usage: reportedUsage.value, snapshot: terminalSnapshot, content: terminalContent
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
}

struct PiAIProviderContinuation: Sendable {
  fileprivate var messages: [ProviderMessage] = []
}

struct PiAIProviderRoundUpdate: Sendable {
  let text: String
  let reasoningEntries: [Transcript.Entry]
  let usage: PiAIGenerationUsage
  let content: [ProviderAssistantContent]
}

struct PiAIProviderRound: Sendable {
  let text: String
  let toolCalls: [Transcript.ToolCall]
  let entries: [Transcript.Entry]
  let reasoningEntries: [Transcript.Entry]
  fileprivate let assistantMessage: ProviderAssistantMessage?
  let usage: PiAIGenerationUsage
  let snapshot: ProviderResponseSnapshot
  let content: [ProviderAssistantContent]
}

struct PiAIGenerationUsage: Sendable, Equatable {
  static let zero = Self(
    inputTotal: 0,
    cachedInput: 0,
    outputTotal: 0,
    reasoningOutput: 0
  )

  var inputTotal: Int
  var cachedInput: Int
  var outputTotal: Int
  var reasoningOutput: Int

  mutating func accumulate(_ usage: Self) {
    inputTotal += usage.inputTotal
    cachedInput += usage.cachedInput
    outputTotal += usage.outputTotal
    reasoningOutput += usage.reasoningOutput
  }

  func adding(_ usage: Self) -> Self {
    var combined = self
    combined.accumulate(usage)
    return combined
  }
}

private struct ProviderUsageAccumulator: Sendable {
  private var inputTokens: Int?
  private var outputTokens: Int?
  private var reasoningTokens: Int?
  private var cachedInputTokens: Int?
  private var cacheWriteTokens: Int?
  private var totalTokens: Int?

  mutating func merge(_ update: ProviderUsage?) {
    guard let update else { return }
    let updatesComponent =
      update.inputTokens != nil || update.outputTokens != nil || update.reasoningTokens != nil
      || update.cachedInputTokens != nil || update.cacheWriteTokens != nil
    if let value = update.inputTokens { inputTokens = value }
    if let value = update.outputTokens { outputTokens = value }
    if let value = update.reasoningTokens { reasoningTokens = value }
    if let value = update.cachedInputTokens { cachedInputTokens = value }
    if let value = update.cacheWriteTokens { cacheWriteTokens = value }
    if let value = update.totalTokens {
      totalTokens = value
    } else if updatesComponent {
      totalTokens = nil
    }
  }

  var value: PiAIGenerationUsage {
    // Foundation Models counts cached input as a subset of total input. pi-ai-swift's
    // provider-normalized buckets are not uniformly inclusive across protocols.
    let inputTotal: Int
    if let totalTokens, let outputTokens, totalTokens >= outputTokens {
      inputTotal = totalTokens - outputTokens
    } else {
      inputTotal = (inputTokens ?? 0) + (cachedInputTokens ?? 0) + (cacheWriteTokens ?? 0)
    }
    return .init(
      inputTotal: inputTotal,
      cachedInput: cachedInputTokens ?? 0,
      outputTotal: outputTokens ?? 0,
      reasoningOutput: reasoningTokens ?? 0
    )
  }
}
