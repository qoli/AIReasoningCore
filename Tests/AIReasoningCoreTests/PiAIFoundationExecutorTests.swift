#if canImport(FoundationModels)
  import CoreGraphics
  import Foundation
  import FoundationModels
  import ImageIO
  import PiAIProviderRuntime
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
