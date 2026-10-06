#if canImport(FoundationModels)
  import CoreGraphics
  import Foundation
  import FoundationModels
  import ImageIO
  import PiAIProviderRuntime
  import Observation
  import XCTest

  @testable import AIReasoningCore

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  final class PiAIFoundationExecutorTests: XCTestCase {
    private let capabilities = ProviderCapabilities(
      textInput: true, imageInput: true, toolCalling: true,
      reasoning: true, structuredOutput: true, imageGeneration: false)

    func testCanonicalSessionExecutesImageToolAndPersistsProviderContinuation() async throws {
      let runtime = FoundationFixtureRuntime { request in
        if case .toolResult(let result) = request.messages.last {
          XCTAssertEqual(result.toolCallID, "image-call")
          XCTAssertEqual(result.toolName, "read_image")
          XCTAssertEqual(result.content.count, 2)
          guard case .image(.data(let bytes, let mime)) = result.content.last else {
            throw FoundationFixtureFailure()
          }
          XCTAssertEqual(mime, "image/png")
          let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
          let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
          XCTAssertEqual(image.width, 2)
          XCTAssertEqual(image.height, 1)
          guard case .assistantMessage(let replay) = request.messages.dropLast().last else {
            throw FoundationFixtureFailure()
          }
          XCTAssertEqual(replay.responseID, "native-response")
          XCTAssertEqual(replay.providerMetadata, ["opaque": .string("preserved")])
          return fixtureEvents(request, [.text(.init(text: "image received", signature: nil))])
        }
        if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
          return fixtureEvents(request, [.text(.init(text: "restored image", signature: nil))])
        }
        return fixtureEvents(
          request,
          [
            .toolCall(
              .init(
                id: "image-call", name: "read_image", arguments: .object([:]),
                thoughtSignature: "tool-signature", namespace: "host",
                providerMetadata: ["field": .bool(true)]))
          ])
      }
      let model = PiAILanguageModel(
        runtime: runtime, providerID: "test", modelID: "model",
        capabilities: capabilities)
      let session = FoundationModels.LanguageModelSession(model: model, tools: [FixtureImageTool()])
      let response = try await session.respond(to: "Read the image")
      XCTAssertEqual(response.content, "image received")
      XCTAssertEqual(Set(session.transcript.map(\.id)).count, session.transcript.count)
      XCTAssertTrue(
        session.transcript.contains { entry in
          if case .toolOutput(let output) = entry {
            return output.segments.contains { if case .attachment = $0 { true } else { false } }
          }
          return false
        })
      let restored = try JSONDecoder().decode(
        FoundationModels.Transcript.self,
        from: JSONEncoder().encode(session.transcript))
      let reconstructed = FoundationModels.LanguageModelSession(
        model: model, tools: [FixtureImageTool()], transcript: restored)
      let continued = try await reconstructed.respond(to: "Continue")
      XCTAssertEqual(continued.content, "restored image")
    }

    func testSignedMixedTurnMetadataSurvivesCanonicalExecutionAndCodable() async throws {
      let runtime = FoundationFixtureRuntime { request in
        if case .toolResult = request.messages.last {
          guard case .assistantMessage(let replay) = request.messages.dropLast().last else {
            throw FoundationFixtureFailure()
          }
          XCTAssertEqual(
            replay.content,
            [
              .reasoning(
                .init(
                  text: "plan", signature: "reasoning-signature",
                  providerMetadata: ["r": .bool(true)])),
              .signedText(
                .init(
                  text: "before", signature: "text-signature", providerMetadata: ["t": .bool(true)])
              ),
              .toolCall(
                .init(
                  id: "echo-call", name: "echo",
                  arguments: .object(["value": .string("\u{FEFF}value")]),
                  thoughtSignature: "tool-signature", namespace: "host",
                  providerMetadata: ["c": .bool(true)])),
              .signedText(.init(text: "after", signature: nil)),
            ])
          return fixtureEvents(request, [.text(.init(text: "done", signature: nil))])
        }
        return fixtureEvents(
          request,
          [
            .reasoning(
              .init(
                text: "plan", signature: "reasoning-signature", providerMetadata: ["r": .bool(true)]
              )),
            .text(
              .init(
                text: "before", signature: "text-signature", providerMetadata: ["t": .bool(true)])),
            .toolCall(
              .init(
                id: "echo-call", name: "echo",
                arguments: .object(["value": .string("\u{FEFF}value")]),
                thoughtSignature: "tool-signature", namespace: "host",
                providerMetadata: ["c": .bool(true)])),
            .text(.init(text: "after", signature: nil)),
          ])
      }
      let model = PiAILanguageModel(
        runtime: runtime, providerID: "test", modelID: "model",
        capabilities: capabilities)
      let session = FoundationModels.LanguageModelSession(model: model, tools: [FixtureEchoTool()])
      let response = try await session.respond(to: "Use echo")
      XCTAssertEqual(response.content, "done")
      let restored = try JSONDecoder().decode(
        FoundationModels.Transcript.self,
        from: JSONEncoder().encode(session.transcript))
      let mapped = try FoundationProviderMapper.messages(restored)
      guard case .toolResult(let output) = mapped.dropLast().last else {
        return XCTFail("Missing restored tool output")
      }
      XCTAssertEqual(output.content, [.text("\u{FEFF}value")])
    }

    func testCanonicalRequestMapsEnabledSchemaReasoningAndUsage() async throws {
      let runtime = FoundationFixtureRuntime { request in
        XCTAssertEqual(request.tools.map(\.name), ["echo"])
        guard case .object(let schema) = request.tools[0].inputSchema,
          case .object(let properties) = schema["properties"]
        else {
          throw FoundationFixtureFailure()
        }
        XCTAssertNotNil(properties["value"])
        XCTAssertEqual(request.options.reasoningEffort, .max)
        XCTAssertEqual(request.options.maximumOutputTokens, 64)
        return fixtureEvents(
          request, [.text(.init(text: "answer", signature: nil))],
          usage: .init(
            inputTokens: 10, outputTokens: 3, reasoningTokens: 1,
            cachedInputTokens: 2, cacheWriteTokens: 1, totalTokens: 16, providerMetadata: [:]))
      }
      let model = PiAILanguageModel(
        runtime: runtime, providerID: "test", modelID: "model",
        capabilities: capabilities)
      let session = FoundationModels.LanguageModelSession(model: model, tools: [FixtureEchoTool()])
      let response = try await session.respond(
        to: "hello",
        options: .init(maximumResponseTokens: 64),
        contextOptions: .init(reasoningLevel: .custom("max")))
      XCTAssertEqual(response.content, "answer")
      XCTAssertEqual(response.usage.input.totalTokenCount, 13)
      XCTAssertEqual(response.usage.input.cachedTokenCount, 2)
      XCTAssertEqual(response.usage.output.totalTokenCount, 3)
      XCTAssertEqual(response.usage.output.reasoningTokenCount, 1)
    }

    func testCanonicalStreamAndTerminalIdentityValidation() async throws {
      let runtime = FoundationFixtureRuntime { request in
        fixtureEvents(request, [.text(.init(text: "Hello", signature: nil))], splitText: true)
      }
      let session = FoundationModels.LanguageModelSession(
        model: PiAILanguageModel(
          runtime: runtime, providerID: "test", modelID: "model", capabilities: capabilities))
      var values: [String] = []
      for try await snapshot in session.streamResponse(to: "Hello") {
        values.append(snapshot.content)
      }
      XCTAssertEqual(values.last, "Hello")
      XCTAssertFalse(values.isEmpty)
      let invalid = FoundationFixtureRuntime { request in
        [
          .responseStarted(
            .init(
              responseID: nil, providerID: "wrong", modelID: request.modelID, providerMetadata: [:])
          )
        ]
      }
      let rejected = FoundationModels.LanguageModelSession(
        model: PiAILanguageModel(
          runtime: invalid, providerID: "test", modelID: "model", capabilities: capabilities))
      do {
        _ = try await rejected.respond(to: "Hello")
        XCTFail("Expected identity failure")
      } catch {
        XCTAssertTrue(String(describing: error).contains("identity"))
      }
    }

    func testDirectFoundationExecutorMutatesCanonicalTranscriptBeforeReturning() async throws {
      let sent = expectation(description: "Direct native channel sends awaited")
      let gate = DirectFoundationGate(sent: sent)
      let session = FoundationModels.LanguageModelSession(model: DirectFoundationModel(gate: gate))
      let consumer = Task { () throws -> (String, Int, Int) in
        var content = ""
        var beforeReturn = 0
        var afterReturn = 0
        for try await snapshot in session.streamResponse(to: "Direct executor probe") {
          content = snapshot.content
          if await gate.released { afterReturn += 1 } else { beforeReturn += 1 }
        }
        return (content, beforeReturn, afterReturn)
      }
      await fulfillment(of: [sent], timeout: 2)
      let schemaPresent = await gate.schemaPresent
      let released = await gate.released
      XCTAssertFalse(released)
      Self.logDirectCheckpoint(session, phase: "afterSend", schemaPresent: schemaPresent)
      XCTAssertTrue(Self.hasLiveTextAndReasoning(session.transcript))
      XCTAssertTrue(session.isResponding)
      let preterminalIDs = session.transcript.map(\.id)
      await gate.release()
      let (final, beforeReturn, afterReturn) = try await consumer.value
      XCTAssertEqual(final, "Hello")
      XCTAssertGreaterThan(afterReturn, 0)
      XCTAssertFalse(session.isResponding)
      XCTAssertEqual(session.transcript.map(\.id), preterminalIDs)
      // Installed Xcode 27A266a buffers ResponseStream snapshots until the executor returns,
      // even though canonical Transcript mutations above are already visible. Record the
      // distinction; do not promise unavailable preterminal snapshots or invent token counts.
      print(
        "Direct native snapshot summary beforeReturn=\(beforeReturn) afterReturn=\(afterReturn)")
      Self.logDirectCheckpoint(session, phase: "afterReturn", schemaPresent: schemaPresent)
    }

    private static func hasLiveTextAndReasoning(_ transcript: FoundationModels.Transcript) -> Bool {
      let reasoning = transcript.contains { entry in
        guard case .reasoning(let value) = entry else { return false }
        return value.segments.contains {
          if case .text(let text) = $0 { text.content == "Thinking" } else { false }
        }
      }
      let response = transcript.contains { entry in
        guard case .response(let value) = entry else { return false }
        return value.segments.contains {
          if case .text(let text) = $0 { text.content == "Hello" } else { false }
        }
      }
      return reasoning && response
    }

    private static func observeLiveTranscript(
      _ session: FoundationModels.LanguageModelSession,
      visible: XCTestExpectation
    ) -> Task<[String], Never> {
      Task {
        let observations = Observations { session.transcript }
        for await transcript in observations {
          if Self.hasLiveTextAndReasoning(transcript) {
            visible.fulfill()
            return transcript.map(\.id)
          }
        }
        return []
      }
    }

    private static func logDirectCheckpoint(
      _ session: FoundationModels.LanguageModelSession,
      phase: String, schemaPresent: Bool
    ) {
      let shape = session.transcript.map { entry -> String in
        switch entry {
        case .instructions: return "instructions"
        case .prompt: return "prompt"
        case .response(let value): return "response(segments=\(value.segments.count))"
        case .reasoning(let value): return "reasoning(segments=\(value.segments.count))"
        case .toolCalls: return "toolCalls"
        case .toolOutput: return "toolOutput"
        @unknown default: return "unknown"
        }
      }
      print(
        "Direct native checkpoint phase=\(phase) schemaPresent=\(schemaPresent) responding=\(session.isResponding) shape=\(shape.joined(separator: ",")) ids=\(session.transcript.map(\.id).joined(separator: ","))"
      )
    }

    func testCanonicalStreamObservesTextAndReasoningBeforeProviderTerminal() async throws {
      let visible = expectation(description: "Canonical transcript observation before terminal")
      let stopped = expectation(description: "Provider stream finished")
      let gate = FoundationStreamGate(stopped: stopped)
      let session = FoundationModels.LanguageModelSession(
        model: PiAILanguageModel(
          runtime: FoundationGatedRuntime(gate: gate),
          providerID: "test", modelID: "model", capabilities: capabilities))
      let observer = Self.observeLiveTranscript(session, visible: visible)
      let consumer = Task { () throws -> (String, Int) in
        var content = ""
        var snapshots = 0
        for try await snapshot in session.streamResponse(to: "Stream while provider is gated") {
          content = snapshot.content
          snapshots += 1
        }
        return (content, snapshots)
      }
      // Transcript observation is the SDK-supported continuous projection. The separate
      // direct native baseline records this SDK's buffering of public ResponseStream snapshots.
      await fulfillment(of: [visible], timeout: 2)
      observer.cancel()
      let liveIDs = await observer.value
      XCTAssertFalse(liveIDs.isEmpty)
      let terminalReleased = await gate.terminalReleased
      XCTAssertFalse(terminalReleased)
      XCTAssertTrue(session.isResponding)
      await gate.finish()
      let (finalContent, snapshots) = try await consumer.value
      XCTAssertEqual(finalContent, "Hello world")
      XCTAssertGreaterThan(snapshots, 0)
      await fulfillment(of: [stopped], timeout: 2)
      XCTAssertFalse(session.isResponding)
      XCTAssertEqual(session.transcript.map(\.id), liveIDs)
      XCTAssertEqual(session.usage.output.totalTokenCount, 2)
    }

    func testCanonicalStreamCancellationAfterObservedLiveTranscriptDrainsProvider() async throws {
      let visible = expectation(description: "Canonical live transcript before cancellation")
      let stopped = expectation(description: "Provider stream cancelled")
      let gate = FoundationStreamGate(stopped: stopped)
      let session = FoundationModels.LanguageModelSession(
        model: PiAILanguageModel(
          runtime: FoundationGatedRuntime(gate: gate),
          providerID: "test", modelID: "model", capabilities: capabilities))
      session.transcriptErrorHandlingPolicy = .preserveTranscript
      let observer = Self.observeLiveTranscript(session, visible: visible)
      let consumer = Task {
        for try await _ in session.streamResponse(to: "Cancel a live response") {}
      }
      await fulfillment(of: [visible], timeout: 2)
      observer.cancel()
      let liveIDs = await observer.value
      XCTAssertFalse(liveIDs.isEmpty)
      consumer.cancel()
      do { try await consumer.value } catch { XCTAssertTrue(error is CancellationError) }
      await fulfillment(of: [stopped], timeout: 2)
      XCTAssertFalse(session.isResponding)
      XCTAssertEqual(session.transcript.map(\.id), liveIDs)
      let terminalReleased = await gate.terminalReleased
      XCTAssertFalse(terminalReleased)
      await gate.finish()
    }

    func testInvalidTerminalToolSnapshotCannotExecuteHostSideEffects() async throws {
      let observed = FoundationToolObservation()
      let runtime = FoundationFixtureRuntime { request in
        let call = ProviderToolCall(
          id: "rejected-call", name: "echo", arguments: .object(["value": .string("value")]))
        return [
          .responseStarted(
            .init(
              responseID: nil, providerID: request.providerID,
              modelID: request.modelID, providerMetadata: [:])),
          .toolCallStarted(id: call.id, name: call.name), .toolCallCompleted(call),
          .responseSnapshot(
            .init(
              responseID: nil, providerID: "wrong", protocolID: "test",
              modelID: request.modelID, responseModelID: nil, content: [.toolCall(call)],
              usage: nil, finishReason: .toolCalls, rawFinishReason: nil, timestampMilliseconds: 1
            )),
          .completed(.toolCalls),
        ]
      }
      let tool = FixtureEchoTool { value in
        await observed.record()
        return value
      }
      let session = FoundationModels.LanguageModelSession(
        model: PiAILanguageModel(
          runtime: runtime, providerID: "test", modelID: "model", capabilities: capabilities),
        tools: [tool])
      do {
        _ = try await session.respond(to: "Use echo")
        XCTFail("Expected terminal identity rejection")
      } catch { XCTAssertTrue(String(describing: error).contains("identity")) }
      let calls = await observed.calls
      XCTAssertEqual(calls, 0)
    }

    func testCanonicalCancellationDrainsProviderStream() async throws {
      let started = expectation(description: "Provider stream started")
      let stopped = expectation(description: "Provider stream terminated")
      let runtime = FoundationHangingRuntime(started: started, stopped: stopped)
      let session = FoundationModels.LanguageModelSession(
        model: PiAILanguageModel(
          runtime: runtime, providerID: "test", modelID: "model", capabilities: capabilities))
      let task = Task { try await session.respond(to: "Wait") }
      await fulfillment(of: [started], timeout: 2)
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
      await fulfillment(of: [stopped], timeout: 2)
      XCTAssertFalse(session.isResponding)
    }
  }

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  private struct DirectFoundationModel: FoundationModels.LanguageModel {
    typealias Executor = DirectFoundationExecutor
    let gate: DirectFoundationGate
    var executorConfiguration: String { "direct-native-fixture" }
    var capabilities: FoundationModels.LanguageModelCapabilities { .init([.reasoning]) }
  }

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  private struct DirectFoundationExecutor: FoundationModels.LanguageModelExecutor {
    init(configuration: String) {}
    func respond(
      to request: FoundationModels.LanguageModelExecutorGenerationRequest,
      model: DirectFoundationModel,
      streamingInto channel: FoundationModels.LanguageModelExecutorGenerationChannel
    ) async throws {
      await channel.send(.response(action: .updateMetadata(["fixture": "direct-native"])))
      await channel.send(
        .response(
          action: .updateUsage(
            input: .init(totalTokenCount: 1, cachedTokenCount: 0),
            output: .init(totalTokenCount: 0, reasoningTokenCount: 0))))
      await channel.send(.reasoning(action: .appendText("Thinking", tokenCount: 1)))
      await channel.send(.response(action: .appendText("Hello", tokenCount: 1)))
      await model.gate.pauseAfterSends(schemaPresent: request.schema != nil)
      try Task.checkCancellation()
    }
  }

  private actor DirectFoundationGate {
    let sent: XCTestExpectation
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var released = false
    private(set) var schemaPresent = false
    init(sent: XCTestExpectation) { self.sent = sent }
    func pauseAfterSends(schemaPresent: Bool) async {
      self.schemaPresent = schemaPresent
      sent.fulfill()
      if released { return }
      await withCheckedContinuation { waiter = $0 }
    }
    func release() {
      released = true
      waiter?.resume()
      waiter = nil
    }
  }

  private struct FoundationFixtureFailure: Error {}

  private actor FoundationToolObservation {
    var calls = 0
    func record() { calls += 1 }
  }

  private struct FoundationHangingRuntime: ProviderRuntime {
    let started: XCTestExpectation
    let stopped: XCTestExpectation
    func catalog() async throws -> ProviderCatalog { .init(revision: "test", providers: []) }
    func authorize(
      _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction
    ) async throws -> AuthorizationState {
      throw FoundationFixtureFailure()
    }
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
      AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in stopped.fulfill() }
        continuation.yield(
          .responseStarted(
            .init(
              responseID: nil, providerID: request.providerID,
              modelID: request.modelID, providerMetadata: [:])))
        started.fulfill()
      }
    }
  }

  private struct FoundationGatedRuntime: ProviderRuntime {
    let gate: FoundationStreamGate
    func catalog() async throws -> ProviderCatalog { .init(revision: "test", providers: []) }
    func authorize(
      _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction
    ) async throws -> AuthorizationState {
      throw FoundationFixtureFailure()
    }
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
      AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in gate.stopped.fulfill() }
        Task { await gate.start(request, continuation: continuation) }
      }
    }
  }

  private actor FoundationStreamGate {
    nonisolated let stopped: XCTestExpectation
    private var request: ProviderRequest?
    private var continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation?
    private(set) var terminalReleased = false
    init(stopped: XCTestExpectation) { self.stopped = stopped }
    func start(
      _ request: ProviderRequest,
      continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) {
      self.request = request
      self.continuation = continuation
      continuation.yield(
        .responseStarted(
          .init(
            responseID: "gated-response", providerID: request.providerID,
            modelID: request.modelID, providerMetadata: [:])))
      continuation.yield(.reasoningDelta("Thinking"))
      continuation.yield(.textDelta("Hello"))
    }
    func finish() {
      guard let request, let continuation else { return }
      terminalReleased = true
      continuation.yield(.textDelta(" world"))
      continuation.yield(
        .responseSnapshot(
          .init(
            responseID: "gated-response", providerID: request.providerID,
            protocolID: "test", modelID: request.modelID, responseModelID: nil,
            content: [
              .reasoning(.init(text: "Thinking", signature: nil, providerMetadata: [:])),
              .text(.init(text: "Hello world", signature: nil)),
            ],
            usage: .init(
              inputTokens: 1, outputTokens: 2, reasoningTokens: nil, cachedInputTokens: nil,
              providerMetadata: [:]),
            finishReason: .stop, rawFinishReason: nil, timestampMilliseconds: 1)))
      continuation.yield(.completed(.stop))
      continuation.finish()
      self.continuation = nil
    }
  }

  private struct FoundationFixtureRuntime: ProviderRuntime {
    let handler: @Sendable (ProviderRequest) throws -> [ProviderEvent]
    func catalog() async throws -> ProviderCatalog { .init(revision: "test", providers: []) }
    func authorize(
      _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction
    ) async throws -> AuthorizationState {
      throw FoundationFixtureFailure()
    }
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
      // Synthetic fixture diagnostics: types/call IDs only, no payload contents.
      let shape = request.messages.map { message in
        switch message {
        case .system: return "instructions"
        case .user, .userMessage: return "prompt"
        case .assistant: return "assistant"
        case .assistantMessage(let value):
          return
            "replay(\(value.content.compactMap { if case .toolCall(let call) = $0 { call.id } else { nil } }.joined(separator: ",")))"
        case .toolResult(let value): return "output(\(value.toolCallID))"
        }
      }
      print("Canonical fixture request: \(shape.joined(separator: " → "))")
      return AsyncThrowingStream { continuation in
        do {
          for event in try handler(request) { continuation.yield(event) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
    }
  }

  private func fixtureEvents(
    _ request: ProviderRequest, _ content: [ProviderResponseContent],
    usage: ProviderUsage = .init(
      inputTokens: 1, outputTokens: 1, reasoningTokens: nil,
      cachedInputTokens: nil, providerMetadata: [:]), splitText: Bool = false
  ) -> [ProviderEvent] {
    let hasCalls = content.contains { if case .toolCall = $0 { true } else { false } }
    let finish: ProviderFinishReason = hasCalls ? .toolCalls : .stop
    var events: [ProviderEvent] = [
      .responseStarted(
        .init(
          responseID: "native-response",
          providerID: request.providerID, modelID: request.modelID, providerMetadata: [:]))
    ]
    for item in content {
      switch item {
      case .text(let value):
        if splitText {
          events += [.textDelta("Hel"), .textDelta("lo")]
        } else {
          events.append(.textDelta(value.text))
        }
      case .reasoning(let value): events.append(.reasoningDelta(value.text))
      case .toolCall(let value):
        events += [.toolCallStarted(id: value.id, name: value.name), .toolCallCompleted(value)]
      case .asset: break
      }
    }
    events += [
      .responseSnapshot(
        .init(
          responseID: "native-response", providerID: request.providerID, protocolID: "test",
          modelID: request.modelID, responseModelID: "wire-model", content: content,
          usage: usage, finishReason: finish, rawFinishReason: nil, timestampMilliseconds: 1,
          providerMetadata: ["opaque": .string("preserved")])), .completed(finish),
    ]
    return events
  }

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  private struct FixtureEchoTool: FoundationModels.Tool {
    @Generable struct Arguments { var value: String }
    let name = "echo"
    let description = "Return the argument"
    let body: @Sendable (String) async throws -> String
    init(body: @escaping @Sendable (String) async throws -> String = { $0 }) { self.body = body }
    func call(arguments: Arguments) async throws -> String { try await body(arguments.value) }
  }

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  private struct FixtureImageTool: FoundationModels.Tool {
    @Generable struct Arguments {}
    let name = "read_image"
    let description = "Return a synthetic image attachment"
    func call(arguments: Arguments) async throws -> FoundationModels.Prompt {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 2, height: 1, bitsPerComponent: 8,
          bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      let image = try XCTUnwrap(context.makeImage())
      return FoundationModels.Prompt {
        "image result"
        Attachment(image)
      }
    }
  }
#endif
