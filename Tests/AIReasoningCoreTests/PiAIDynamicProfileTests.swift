import AnyLanguageModel
import Foundation
import PiAIProviderRuntime
import XCTest

@testable import AIReasoningCore

extension SessionPropertyValues {
  @SessionPropertyEntry fileprivate var coreProfileRevision = 0
}

final class PiAIDynamicProfileTests: XCTestCase {
  func testProfileToolContinuationKeepsOpaqueReplayAndCanonicalHistoryInBothModes() async throws {
    for streaming in [false, true] {
      let state = ProfileTestState()
      let firstCall = ProviderToolCall(
        id: "call-a-1",
        name: "tool-a-1",
        arguments: .object(["value": .string("one")]),
        thoughtSignature: "tool-signature-1",
        namespace: "functions"
      )
      let secondCall = ProviderToolCall(
        id: "call-a-2",
        name: "tool-a-2",
        arguments: .object(["value": .string("two")]),
        thoughtSignature: "tool-signature-2",
        namespace: "functions"
      )
      let firstReasoning = ProviderReasoningContent(
        text: "plan",
        signature: "reasoning-signature",
        providerMetadata: ["opaque": .string("state")]
      )
      let runtime = ProfileFakeRuntime { request in
        let results = request.messages.compactMap { message -> ProviderToolResult? in
          guard case .toolResult(let result) = message else { return nil }
          return result
        }
        if results.isEmpty {
          XCTAssertEqual(request.options.temperature, 0.2)
          XCTAssertEqual(request.options.maximumOutputTokens, 64)
          XCTAssertEqual(request.options.reasoningEffort, .low)
          XCTAssertEqual(request.options.toolChoice, .string("required"))
          XCTAssertEqual(request.tools.map(\.name), ["tool-a-1", "tool-a-2"])
          XCTAssertEqual(request.messages.count, 2)
          guard case .system(let instructions) = request.messages[0],
            case .user(let prompt) = request.messages[1]
          else { throw ProfileTestError.invalidRequest }
          XCTAssertEqual(instructions, "Profile A revision 0")
          XCTAssertEqual(prompt, [.text("Current question")])
          state.selectSecond()
          return [
            .responseStarted(profileMetadata(for: request)),
            .reasoningDelta(firstReasoning.text),
            .reasoningSignatureDelta(firstReasoning.signature!),
            .toolCallStarted(id: firstCall.id, name: firstCall.name),
            .toolCallStarted(id: secondCall.id, name: secondCall.name),
            .toolCallCompleted(secondCall),
            .toolCallCompleted(firstCall),
            .responseSnapshot(
              profileResponseSnapshot(
                for: request,
                content: [
                  .reasoning(firstReasoning),
                  .toolCall(firstCall),
                  .toolCall(secondCall),
                ],
                finishReason: .toolCalls
              )),
            .completed(.toolCalls),
          ]
        }

        XCTAssertEqual(request.options.temperature, 0.8)
        XCTAssertEqual(request.options.maximumOutputTokens, 128)
        XCTAssertEqual(request.options.reasoningEffort, .high)
        XCTAssertEqual(request.options.toolChoice, .string("none"))
        XCTAssertEqual(request.tools.map(\.name), ["tool-b-1", "tool-b-2"])
        XCTAssertEqual(request.messages.count, 5)
        guard case .system(let instructions) = request.messages[0],
          case .user(let prompt) = request.messages[1],
          case .assistantMessage(let replay) = request.messages[2],
          case .toolResult(let firstOutput) = request.messages[3],
          case .toolResult(let secondOutput) = request.messages[4]
        else { throw ProfileTestError.invalidRequest }
        XCTAssertEqual(instructions, "Profile B revision 2")
        XCTAssertEqual(prompt, [.text("Current question")])
        XCTAssertEqual(
          replay.content,
          [.reasoning(firstReasoning), .toolCall(firstCall), .toolCall(secondCall)]
        )
        XCTAssertEqual(firstOutput.toolCallID, firstCall.id)
        XCTAssertEqual(firstOutput.content, [.text(#""tool-a-1:one""#)])
        XCTAssertEqual(secondOutput.toolCallID, secondCall.id)
        XCTAssertEqual(secondOutput.content, [.text(#""tool-a-2:two""#)])
        return [
          .responseStarted(profileMetadata(for: request)),
          .reasoningDelta("finish"),
          .textDelta("done"),
          .responseSnapshot(
            profileResponseSnapshot(
              for: request,
              content: [
                .reasoning(
                  .init(text: "finish", signature: nil, providerMetadata: [:])
                ),
                .text("done"),
              ],
              finishReason: .stop
            )),
          .completed(.stop),
        ]
      }
      let model = PiAILanguageModel(
        runtime: runtime,
        providerID: "provider",
        modelID: "model"
      )
      let oldHistory = profileOldHistory()
      state.filteredHistoryIDs = Set(oldHistory.map(\.id))
      let session = LanguageModelSession(
        profile: ProfileFixture(
          state: state,
          firstModel: model,
          secondModel: model
        ),
        history: oldHistory
      )

      let response =
        try await streaming
        ? session.streamResponse(to: "Current question").collect()
        : session.respond(to: "Current question")

      XCTAssertEqual(response.content, "done")
      XCTAssertEqual(Array(session.transcript.prefix(oldHistory.count)), oldHistory)
      XCTAssertFalse(
        session.transcript.contains { if case .instructions = $0 { true } else { false } }
      )
      XCTAssertEqual(session.properties.coreProfileRevision, 2)
      XCTAssertEqual(state.executions, ["tool-a-1:one", "tool-a-2:two"])
      XCTAssertEqual(state.transformedOutputCounts, [0, 2])
      XCTAssertEqual(
        state.events,
        [
          "activate:A", "prompt:A", "reasoning:A", "call:A:call-a-1",
          "call:A:call-a-2", "execute:tool-a-1", "output:A:call-a-1",
          "execute:tool-a-2", "output:A:call-a-2", "deactivate:A", "activate:B",
          "reasoning:B", "response:B",
        ]
      )
    }
  }

  func testProfileCanSwitchPiModelOnlyByStartingANewProviderConversation() async throws {
    for streaming in [false, true] {
      let state = ProfileTestState()
      let call = ProviderToolCall(
        id: "switch-call",
        name: "tool-a-1",
        arguments: .object(["value": .string("switch")]),
        thoughtSignature: "must-not-cross-models",
        namespace: "functions"
      )
      let firstRuntime = ProfileFakeRuntime { request in
        XCTAssertEqual(request.providerID, "provider-a")
        state.selectSecond()
        return profileToolEvents(for: request, calls: [call])
      }
      let secondRuntime = ProfileFakeRuntime { request in
        XCTAssertEqual(request.providerID, "provider-b")
        XCTAssertEqual(request.modelID, "model-b")
        XCTAssertFalse(
          request.messages.contains { if case .assistantMessage = $0 { true } else { false } }
        )
        guard
          let assistant = request.messages.compactMap({ message -> [ProviderAssistantContent]? in
            guard case .assistant(let content) = message else { return nil }
            return content
          }).last,
          let mappedCall = assistant.compactMap({ content -> ProviderToolCall? in
            guard case .toolCall(let call) = content else { return nil }
            return call
          }).last
        else { throw ProfileTestError.invalidRequest }
        XCTAssertEqual(mappedCall.id, call.id)
        XCTAssertEqual(mappedCall.name, call.name)
        XCTAssertNil(mappedCall.thoughtSignature)
        XCTAssertNil(mappedCall.namespace)
        return profileTextEvents(for: request, text: "switched")
      }
      let firstModel = PiAILanguageModel(
        runtime: firstRuntime,
        providerID: "provider-a",
        modelID: "model-a"
      )
      let secondModel = PiAILanguageModel(
        runtime: secondRuntime,
        providerID: "provider-b",
        modelID: "model-b"
      )
      let session = LanguageModelSession(
        profile: ProfileFixture(
          state: state,
          firstModel: firstModel,
          secondModel: secondModel
        )
      )

      let response =
        try await streaming
        ? session.streamResponse(to: "Switch").collect()
        : session.respond(to: "Switch")

      XCTAssertEqual(response.content, "switched")
      XCTAssertEqual(state.executions, ["tool-a-1:switch"])
    }
  }

  func testProfileSwitchWithMatchingProviderAndModelIDsStillClearsOpaqueReplay() async throws {
    for streaming in [false, true] {
      let state = ProfileTestState()
      let call = ProviderToolCall(
        id: "same-label-switch",
        name: "tool-a-1",
        arguments: .object(["value": .string("switch")]),
        thoughtSignature: "must-not-cross-executors",
        namespace: "functions"
      )
      let firstRuntime = ProfileFakeRuntime { request in
        state.selectSecond()
        return profileToolEvents(for: request, calls: [call])
      }
      let secondRuntime = ProfileFakeRuntime { request in
        XCTAssertEqual(request.providerID, "provider")
        XCTAssertEqual(request.modelID, "model")
        XCTAssertFalse(
          request.messages.contains { if case .assistantMessage = $0 { true } else { false } }
        )
        guard
          let mappedCall = request.messages.compactMap({ message -> [ProviderAssistantContent]? in
            guard case .assistant(let content) = message else { return nil }
            return content
          }).joined().compactMap({ content -> ProviderToolCall? in
            guard case .toolCall(let call) = content else { return nil }
            return call
          }).last
        else { throw ProfileTestError.invalidRequest }
        XCTAssertEqual(mappedCall.id, call.id)
        XCTAssertNil(mappedCall.thoughtSignature)
        XCTAssertNil(mappedCall.namespace)
        return profileTextEvents(for: request, text: "switched")
      }
      let firstModel = PiAILanguageModel(
        runtime: firstRuntime,
        providerID: "provider",
        modelID: "model"
      )
      let secondModel = PiAILanguageModel(
        runtime: secondRuntime,
        providerID: "provider",
        modelID: "model"
      )
      let session = LanguageModelSession(
        profile: ProfileFixture(
          state: state,
          firstModel: firstModel,
          secondModel: secondModel
        )
      )

      let response =
        try await streaming
        ? session.streamResponse(to: "Switch").collect()
        : session.respond(to: "Switch")

      XCTAssertEqual(response.content, "switched")
      XCTAssertEqual(state.executions, ["tool-a-1:switch"])
    }
  }

  func testHistoryTransformMayDropCurrentToolRoundAndResetsOpaqueReplay() async throws {
    for streaming in [false, true] {
      let state = ProfileTestState()
      state.dropToolRound = true
      let requestCount = LockedCounter()
      let call = ProviderToolCall(
        id: "dropped-call",
        name: "tool-a-1",
        arguments: .object(["value": .string("drop")]),
        thoughtSignature: "dropped-signature",
        namespace: "functions"
      )
      let runtime = ProfileFakeRuntime { request in
        requestCount.increment()
        if requestCount.value == 1 {
          state.selectSecond()
          return profileToolEvents(for: request, calls: [call])
        }
        XCTAssertFalse(
          request.messages.contains { message in
            switch message {
            case .assistant, .assistantMessage, .toolResult: return true
            default: return false
            }
          }
        )
        return profileTextEvents(for: request, text: "projected")
      }
      let model = PiAILanguageModel(
        runtime: runtime,
        providerID: "provider",
        modelID: "model"
      )
      let session = LanguageModelSession(
        profile: ProfileFixture(state: state, firstModel: model, secondModel: model)
      )

      let response =
        try await streaming
        ? session.streamResponse(to: "Project").collect()
        : session.respond(to: "Project")

      XCTAssertEqual(response.content, "projected")
      XCTAssertEqual(requestCount.value, 2)
      XCTAssertTrue(session.transcript.contains { if case .toolCalls = $0 { true } else { false } })
      XCTAssertTrue(
        session.transcript.contains { if case .toolOutput = $0 { true } else { false } })
    }
  }

  func testToolOutputCallbackErrorStopsContinuationInBothModes() async throws {
    for streaming in [false, true] {
      let state = ProfileTestState()
      let requestCount = LockedCounter()
      let call = ProviderToolCall(
        id: "rejected-call",
        name: "tool-a-1",
        arguments: .object(["value": .string("reject")])
      )
      let runtime = ProfileFakeRuntime { request in
        requestCount.increment()
        return profileToolEvents(for: request, calls: [call])
      }
      let model = PiAILanguageModel(
        runtime: runtime,
        providerID: "provider",
        modelID: "model"
      )
      let session = LanguageModelSession(
        profile: ThrowingToolOutputProfile(state: state, model: model)
      )

      do {
        if streaming {
          _ = try await session.streamResponse(to: "Reject").collect()
        } else {
          _ = try await session.respond(to: "Reject")
        }
        XCTFail("expected Tool-output callback failure")
      } catch ProfileTestError.outputRejected {
        // Expected.
      }

      XCTAssertEqual(requestCount.value, 1)
      XCTAssertEqual(state.executions, ["tool-a-1:reject"])
      XCTAssertEqual(
        state.events.suffix(3),
        ["call:A:rejected-call", "execute:tool-a-1", "reject-output"]
      )
      XCTAssertEqual(session.transcript.count, 1)
      XCTAssertTrue(session.transcript.allSatisfy { if case .prompt = $0 { true } else { false } })
    }
  }

  func testStopDecisionRunsProducingCallbackWithoutExecutingToolInBothModes() async throws {
    for streaming in [false, true] {
      let state = ProfileTestState()
      let requestCount = LockedCounter()
      let call = ProviderToolCall(
        id: "stopped-call",
        name: "tool-a-1",
        arguments: .object(["value": .string("stop")])
      )
      let runtime = ProfileFakeRuntime { request in
        requestCount.increment()
        return profileToolEvents(for: request, calls: [call])
      }
      let model = PiAILanguageModel(
        runtime: runtime,
        providerID: "provider",
        modelID: "model"
      )
      let session = LanguageModelSession(
        profile: ProfileFixture(state: state, firstModel: model, secondModel: model)
      )
      session.toolExecutionDelegate = StopProfileTools()

      let response =
        try await streaming
        ? session.streamResponse(to: "Stop").collect()
        : session.respond(to: "Stop")

      XCTAssertEqual(response.content, "")
      XCTAssertEqual(requestCount.value, 1)
      XCTAssertTrue(state.executions.isEmpty)
      XCTAssertTrue(state.events.contains("call:A:stopped-call"))
      XCTAssertFalse(state.events.contains { $0.hasPrefix("output:") })
      XCTAssertTrue(state.events.contains("response:A"))
      XCTAssertEqual(session.transcript.count, 3)
    }
  }

  func testCancellationPreservesCheckpointWithoutDispatchingTerminalCallbacks() async throws {
    let state = ProfileTestState()
    let received = expectation(description: "received reasoning checkpoint")
    let stopped = expectation(description: "provider stream stopped")
    let runtime = ProfileHangingRuntime(providerStopped: stopped)
    let model = PiAILanguageModel(
      runtime: runtime,
      providerID: "provider",
      modelID: "model"
    )
    let session = LanguageModelSession(
      profile: ProfileFixture(state: state, firstModel: model, secondModel: model)
    )
    session.transcriptErrorHandlingPolicy = .preserveTranscript
    let consumer = Task {
      for try await snapshot in session.streamResponse(to: "Cancel") {
        if profileVisibleReasoning(snapshot.transcriptEntries) == "working" {
          received.fulfill()
        }
      }
    }

    await fulfillment(of: [received], timeout: 2)
    consumer.cancel()
    _ = await consumer.result
    await fulfillment(of: [stopped], timeout: 2)
    await session.waitForResponseCompletion()

    XCTAssertFalse(session.isResponding)
    XCTAssertEqual(profileVisibleReasoning(session.transcript), "working")
    XCTAssertEqual(state.events, ["activate:A", "prompt:A"])
    XCTAssertFalse(
      session.transcript.contains { if case .response = $0 { true } else { false } }
    )
  }
}

private struct ProfileFixture: LanguageModelSession.DynamicProfile, @unchecked Sendable {
  let state: ProfileTestState
  let firstModel: PiAILanguageModel
  let secondModel: PiAILanguageModel
  @SessionProperty(\.coreProfileRevision) private var revision

  var body: some LanguageModelSession.DynamicProfile {
    if state.usesSecond {
      profile(label: "B", model: secondModel, temperature: 0.8, maximumTokens: 128)
        .reasoningLevel(.deep)
        .toolCallingMode(.disallowed)
    } else {
      profile(label: "A", model: firstModel, temperature: 0.2, maximumTokens: 64)
        .reasoningLevel(.light)
        .toolCallingMode(.required)
    }
  }

  private func profile(
    label: String,
    model: PiAILanguageModel,
    temperature: Double,
    maximumTokens: Int
  ) -> some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Profile \(label) revision \(revision)")
      ProfileRecordingTool(name: "tool-\(label.lowercased())-1", state: state)
      ProfileRecordingTool(name: "tool-\(label.lowercased())-2", state: state)
    }
    .model(model)
    .temperature(temperature)
    .maximumResponseTokens(maximumTokens)
    .historyTransform { entries in state.transform(entries, label: label) }
    .onActivate { state.record("activate:\(label)") }
    .onDeactivate { state.record("deactivate:\(label)") }
    .onPrompt { _ in state.record("prompt:\(label)") }
    .onReasoning { _ in state.record("reasoning:\(label)") }
    .onToolCall { call in state.record("call:\(label):\(call.id)") }
    .onToolOutput { _, output in state.record("output:\(label):\(output.id)") }
    .onResponse { _ in state.record("response:\(label)") }
  }
}

private struct ThrowingToolOutputProfile: LanguageModelSession.DynamicProfile, @unchecked Sendable {
  let state: ProfileTestState
  let model: PiAILanguageModel

  var body: some LanguageModelSession.DynamicProfile {
    LanguageModelSession.Profile {
      Instructions("Reject Tool output")
      ProfileRecordingTool(name: "tool-a-1", state: state)
    }
    .model(model)
    .onToolCall { call in state.record("call:A:\(call.id)") }
    .onToolOutput { _, _ in
      state.record("reject-output")
      throw ProfileTestError.outputRejected
    }
  }
}

private struct ProfileRecordingTool: Tool, @unchecked Sendable {
  @Generable
  struct Arguments {
    let value: String
  }

  let name: String
  let description = "Records the producing profile's Tool"
  let state: ProfileTestState
  @SessionProperty(\.coreProfileRevision) private var revision

  func call(arguments: Arguments) async throws -> String {
    revision += 1
    state.record("execute:\(name)")
    state.recordExecution("\(name):\(arguments.value)")
    return "\(name):\(arguments.value)"
  }
}

private final class ProfileTestState: @unchecked Sendable {
  private struct Storage {
    var usesSecond = false
    var dropToolRound = false
    var filteredHistoryIDs: Set<String> = []
    var transformedOutputCounts: [Int] = []
    var events: [String] = []
    var executions: [String] = []
  }

  private let lock = NSLock()
  private var storage = Storage()

  var usesSecond: Bool { withLock { $0.usesSecond } }
  var transformedOutputCounts: [Int] { withLock { $0.transformedOutputCounts } }
  var events: [String] { withLock { $0.events } }
  var executions: [String] { withLock { $0.executions } }

  var dropToolRound: Bool {
    get { withLock { $0.dropToolRound } }
    set { withLock { $0.dropToolRound = newValue } }
  }

  var filteredHistoryIDs: Set<String> {
    get { withLock { $0.filteredHistoryIDs } }
    set { withLock { $0.filteredHistoryIDs = newValue } }
  }

  func selectSecond() {
    withLock { $0.usesSecond = true }
  }

  func record(_ event: String) {
    withLock { $0.events.append(event) }
  }

  func recordExecution(_ execution: String) {
    withLock { $0.executions.append(execution) }
  }

  func transform(_ entries: [Transcript.Entry], label: String) -> [Transcript.Entry] {
    withLock { storage in
      storage.transformedOutputCounts.append(
        entries.count { if case .toolOutput = $0 { true } else { false } }
      )
      return entries.filter { entry in
        guard !storage.filteredHistoryIDs.contains(entry.id) else { return false }
        guard storage.dropToolRound else { return true }
        switch entry {
        case .toolCalls, .toolOutput: return false
        default: return true
        }
      }
    }
  }

  private func withLock<Result>(_ body: (inout Storage) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }
}

private enum ProfileTestError: Error {
  case invalidRequest
  case outputRejected
}

private struct StopProfileTools: ToolExecutionDelegate {
  func toolCallDecision(
    for toolCall: Transcript.ToolCall,
    in session: LanguageModelSession
  ) async -> ToolExecutionDecision {
    .stop
  }
}

private struct ProfileFakeRuntime: ProviderRuntime {
  let handler: @Sendable (ProviderRequest) throws -> [ProviderEvent]

  init(handler: @escaping @Sendable (ProviderRequest) throws -> [ProviderEvent]) {
    self.handler = handler
  }

  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "test", providers: [])
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    switch operation {
    case .login(let providerID, _), .logout(let providerID):
      return .disconnected(providerID: providerID)
    }
  }

  func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      do {
        for event in try handler(request) { continuation.yield(event) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }
}

private struct ProfileHangingRuntime: ProviderRuntime {
  let providerStopped: XCTestExpectation

  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "test", providers: [])
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    switch operation {
    case .login(let providerID, _), .logout(let providerID):
      return .disconnected(providerID: providerID)
    }
  }

  func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.responseStarted(profileMetadata(for: request)))
      continuation.yield(.reasoningDelta("working"))
      continuation.onTermination = { _ in providerStopped.fulfill() }
    }
  }
}

private func profileOldHistory() -> [Transcript.Entry] {
  [
    .prompt(
      .init(
        id: "old-prompt",
        segments: [.text(.init(id: "old-question", content: "Old question"))]
      )),
    .response(
      .init(
        id: "old-response",
        assetIDs: [],
        segments: [.text(.init(id: "old-answer", content: "Old answer"))]
      )),
  ]
}

private func profileToolEvents(
  for request: ProviderRequest,
  calls: [ProviderToolCall]
) -> [ProviderEvent] {
  var events: [ProviderEvent] = [.responseStarted(profileMetadata(for: request))]
  events += calls.map { .toolCallStarted(id: $0.id, name: $0.name) }
  events += calls.reversed().map(ProviderEvent.toolCallCompleted)
  events += [
    .responseSnapshot(
      profileResponseSnapshot(
        for: request,
        content: calls.map(ProviderAssistantContent.toolCall),
        finishReason: .toolCalls
      )),
    .completed(.toolCalls),
  ]
  return events
}

private func profileTextEvents(for request: ProviderRequest, text: String) -> [ProviderEvent] {
  [
    .responseStarted(profileMetadata(for: request)),
    .textDelta(text),
    .responseSnapshot(
      profileResponseSnapshot(for: request, content: [.text(text)], finishReason: .stop)
    ),
    .completed(.stop),
  ]
}

private func profileMetadata(for request: ProviderRequest) -> ProviderResponseMetadata {
  ProviderResponseMetadata(
    responseID: "response",
    providerID: request.providerID,
    modelID: request.modelID,
    providerMetadata: [:]
  )
}

private func profileResponseSnapshot(
  for request: ProviderRequest,
  content: [ProviderAssistantContent],
  finishReason: ProviderFinishReason
) -> ProviderResponseSnapshot {
  ProviderResponseSnapshot(
    responseID: "response",
    providerID: request.providerID,
    protocolID: "test-protocol",
    modelID: request.modelID,
    responseModelID: nil,
    content: content.map { item in
      switch item {
      case .text(let text):
        return .text(.init(text: text, signature: nil))
      case .signedText(let text):
        return .text(text)
      case .reasoning(let reasoning):
        return .reasoning(reasoning)
      case .toolCall(let call):
        return .toolCall(call)
      }
    },
    usage: .init(
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      cachedInputTokens: 0,
      cacheWriteTokens: 0,
      totalTokens: 0,
      providerMetadata: [:]
    ),
    finishReason: finishReason,
    rawFinishReason: finishReason.rawValue,
    timestampMilliseconds: 0
  )
}

private func profileVisibleReasoning<S: Sequence>(_ entries: S) -> String?
where S.Element == Transcript.Entry {
  let text = entries.compactMap { entry -> Transcript.Reasoning? in
    guard case .reasoning(let reasoning) = entry else { return nil }
    return reasoning
  }.flatMap(\.segments).compactMap { segment -> String? in
    guard case .text(let text) = segment else { return nil }
    return text.content
  }.joined()
  return text.isEmpty ? nil : text
}
