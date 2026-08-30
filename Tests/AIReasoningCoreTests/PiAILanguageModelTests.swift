import AnyLanguageModel
import Foundation
import PiAIProviderRuntime
import XCTest

@testable import AIReasoningCore

final class PiAILanguageModelTests: XCTestCase {
  func testTextResponseUsesProviderRuntime() async throws {
    let runtime = FakeRuntime { request in
      responseEvents(for: request, text: "Hello from pi")
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    let response = try await session.respond(to: "Hello")

    XCTAssertEqual(response.content, "Hello from pi")
    XCTAssertEqual(session.transcript.count, 2)
  }

  func testStreamingProducesCumulativeSnapshots() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .textDelta("Hel"),
        .textDelta("lo"),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )
    var values: [String] = []

    for try await snapshot in session.streamResponse(to: "Hello") {
      values.append(snapshot.content)
    }

    XCTAssertEqual(values, ["Hel", "Hello"])
  }

  func testStructuredOutputUsesGenerationSchema() async throws {
    let runtime = FakeRuntime { request in
      XCTAssertNotNil(request.options.responseSchema)
      return responseEvents(for: request, text: #"{"answer":"yes"}"#)
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    let response = try await session.respond(to: "Answer", generating: StructuredAnswer.self)

    XCTAssertEqual(response.content.answer, "yes")
  }

  func testStructuredStreamingProducesRequestedType() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .textDelta(#"{"answer":"ye"#),
        .textDelta(#"s"}"#),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    let response = try await session.streamResponse(
      to: "Answer",
      generating: StructuredAnswer.self
    ).collect()

    XCTAssertEqual(response.content.answer, "yes")
  }

  func testToolCallExecutesAndContinuesProviderConversation() async throws {
    let runtime = FakeRuntime { request in
      if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
        return responseEvents(for: request, text: "tool complete")
      }
      return [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "echo"),
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "echo",
            arguments: .object(["value": .string("ping")])
          )
        ),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )

    let response = try await session.respond(to: "Use echo")

    XCTAssertEqual(response.content, "tool complete")
    XCTAssertEqual(session.transcript.count, 4)
    guard case .toolCalls(let calls) = session.transcript[1] else {
      return XCTFail("expected tool calls")
    }
    XCTAssertEqual(calls.first?.toolName, "echo")
    guard case .toolOutput(let output) = session.transcript[2] else {
      return XCTFail("expected tool output")
    }
    XCTAssertEqual(output.toolName, "echo")
  }

  func testOneToolIterationAllowsFollowingFinalResponse() async throws {
    let runtime = FakeRuntime { request in
      if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
        return responseEvents(for: request, text: "done")
      }
      return [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "echo"),
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "echo",
            arguments: .object(["value": .string("ping")])
          )
        ),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )
    var options = GenerationOptions()
    options[custom: PiAILanguageModel.self] = .init(maximumToolIterations: 1)

    let response = try await session.respond(to: "Use echo", options: options)

    XCTAssertEqual(response.content, "done")
  }

  func testImageTranscriptMapsToProviderImage() async throws {
    let recorder = RequestRecorder()
    let runtime = FakeRuntime { request in
      Task { await recorder.record(request) }
      return responseEvents(for: request, text: "seen")
    }
    let image = Transcript.ImageSegment(data: Data([1, 2, 3]), mimeType: "image/png")
    let transcript = Transcript(entries: [
      .prompt(
        Transcript.Prompt(
          segments: [.text(.init(content: "describe")), .image(image)]
        )
      )
    ])
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      transcript: transcript
    )

    _ = try await session.respond(to: "")
    let requests = await recorder.requests

    XCTAssertTrue(
      requests.flatMap(\.messages).contains { message in
        guard case .user(let content) = message else { return false }
        return content.contains { item in
          guard case .image(.data(let data, mimeType: let mimeType)) = item else { return false }
          return data == Data([1, 2, 3]) && mimeType == "image/png"
        }
      })
  }

  func testStreamingToolCallFailsExplicitly() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "echo"),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )

    do {
      for try await _ in session.streamResponse(to: "Use echo") {}
      XCTFail("expected explicit streaming tool failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .unsupportedStreamingToolCalls)
    }
  }

  func testUnknownToolFailsExplicitly() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "missing"),
        .toolCallCompleted(
          ProviderToolCall(id: "call-1", name: "missing", arguments: .object([:]))
        ),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    do {
      _ = try await session.respond(to: "Use missing tool")
      XCTFail("expected unknown tool failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .unknownTool)
    }
  }

  func testProviderAssetRequiresAssetStore() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .asset(
          ProviderAsset(
            id: "asset-1",
            kind: .image,
            mimeType: "image/png",
            data: Data([1]),
            providerMetadata: [:]
          )
        ),
        .textDelta("image"),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    do {
      _ = try await session.respond(to: "Generate")
      XCTFail("expected missing asset store failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .missingAssetStore)
    }
  }

  func testProviderMustStartStreamBeforeContent() async throws {
    let runtime = FakeRuntime { _ in [.textDelta("invalid"), .completed(.stop)] }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    do {
      _ = try await session.respond(to: "Hello")
      XCTFail("expected event ordering failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidProviderResponse)
    }
  }

  func testToolCompletionWithoutStartFailsBeforeExecution() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "echo",
            arguments: .object(["value": .string("ping")])
          )
        ),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )

    do {
      _ = try await session.respond(to: "Use echo")
      XCTFail("expected invalid tool lifecycle failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidProviderResponse)
    }
  }

  func testDuplicateToolNamesFailExplicitly() async throws {
    let runtime = FakeRuntime { request in responseEvents(for: request, text: "unused") }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool(), EchoTool()]
    )

    do {
      _ = try await session.respond(to: "Hello")
      XCTFail("expected duplicate tool failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidTranscript)
    }
  }

  func testUnsupportedSamplingFailsInsteadOfBeingIgnored() async throws {
    let runtime = FakeRuntime { request in responseEvents(for: request, text: "unused") }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )
    let options = GenerationOptions(sampling: .greedy)

    do {
      _ = try await session.respond(to: "Hello", options: options)
      XCTFail("expected unsupported sampling failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .unsupportedOperation)
    }
  }
}

@Generable
private struct StructuredAnswer: Equatable {
  let answer: String
}

private struct EchoTool: Tool {
  @Generable
  struct Arguments {
    let value: String
  }

  let name = "echo"
  let description = "Echo a value"

  func call(arguments: Arguments) async throws -> String {
    arguments.value
  }
}

private struct FakeRuntime: ProviderRuntime {
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

private actor RequestRecorder {
  private(set) var requests: [ProviderRequest] = []

  func record(_ request: ProviderRequest) {
    requests.append(request)
  }
}

private func metadata(for request: ProviderRequest) -> ProviderResponseMetadata {
  ProviderResponseMetadata(
    responseID: "response",
    providerID: request.providerID,
    modelID: request.modelID,
    providerMetadata: [:]
  )
}

private func responseEvents(for request: ProviderRequest, text: String) -> [ProviderEvent] {
  [
    .responseStarted(metadata(for: request)),
    .textDelta(text),
    .completed(.stop),
  ]
}
