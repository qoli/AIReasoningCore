import AnyLanguageModel
import Foundation
import PiAIProviderRuntime
import XCTest

@testable import AIReasoningCore

final class ConsumerResponseIdentityTests: XCTestCase {
  func testNativeCompletionsTextAndToolBlocksAreAccepted() async throws {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PI_RESPONSE_EVENT_FIXTURE_PATH"])
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        as? [String: Any])
    let cases = try XCTUnwrap(document["completionBlockLifecycleCases"] as? [String: [String: Any]])
    for name in [
      "text-only", "interleaved-signature-stays-with-first-field", "tool-before-text",
      "no-finish-compatible",
    ] {
      let spec = try XCTUnwrap(cases[name])
      let chunks = try XCTUnwrap(spec["chunks"] as? [[String: Any]])
      let wire =
        try chunks.map {
          "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
            + "\n\n"
        }.joined() + "data: [DONE]\n\n"
      let fixture = IdentityFixture(
        caseID: name, protocolID: "openai-completions", providerID: "openai",
        modelID: "requested-model", baseURL: URL(string: "https://fixture.invalid/v1")!,
        decoderInput: .init(
          status: 200, headers: ["content-type": "text/event-stream"],
          chunksBase64: [Data(wire.utf8).base64EncodedString()]))
      let runtime = try identityRuntime(
        fixture,
        metadata: [
          "compat": .object([
            "supportsFinishReason": .bool(spec["supportsFinishReason"] as? Bool ?? true)
          ])
        ])
      let adapter = PiAIProviderAdapter(
        runtime: runtime, providerID: fixture.providerID, modelID: fixture.modelID,
        protocolID: fixture.protocolID, executorID: UUID(), requiredToolRecoveryToolName: nil,
        onAsset: nil, onRequestUsage: nil)
      var updates: [String] = []
      let round = try await adapter.generateRound(
        messages: [.user([.text("Hello")])],
        tools: [
          .init(
            name: "sample_tool", description: "Fixture tool",
            inputSchema: .object(["type": .string("object")]))
        ],
        options: .init(
          maximumOutputTokens: 64, temperature: nil, reasoningEffort: nil, responseSchema: nil,
          providerOptions: [:]),
        onUpdate: { updates.append($0.text) })
      XCTAssertEqual(
        round.text, name == "interleaved-signature-stays-with-first-field" ? "AB" : "answer", name)
      XCTAssertEqual(round.toolCalls.count, name == "tool-before-text" ? 1 : 0, name)
      XCTAssertEqual(updates.last, round.text, name)
    }
  }

  func testNativeBlockLifecycleWithoutResponseStartedIsAcceptedInBothModes() async throws {
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PI_RESPONSE_EVENT_FIXTURE_PATH"])
    let document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        as? [String: Any])
    let cases = try XCTUnwrap(
      document["responsesBlockLifecycleEvents"] as? [String: [[String: Any]]])
    XCTAssertEqual(cases.count, 5)
    for (name, events) in cases {
      let wire = try events.map { event in
        "data: "
          + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
          + "\n\n"
      }.joined()
      let fixture = IdentityFixture(
        caseID: name, protocolID: "openai-responses", providerID: "openai",
        modelID: "gpt-model", baseURL: URL(string: "https://fixture.invalid/v1")!,
        decoderInput: .init(
          status: 200, headers: ["content-type": "text/event-stream"],
          chunksBase64: [Data(wire.utf8).base64EncodedString()]))
      for streaming in [false, true] {
        let runtime = try identityRuntime(fixture)
        let session = LanguageModelSession(
          model: PiAILanguageModel(
            runtime: runtime, providerID: fixture.providerID,
            modelID: fixture.modelID))
        let response =
          try await streaming
          ? session.streamResponse(to: "Hello").collect() : session.respond(to: "Hello")
        XCTAssertEqual(
          response.content, name == "interleaved-reused-output-index" ? "first" : "answer", name)
      }
    }
  }

  func testWireAliasIsAcceptedByCoreInBothModes() async throws {
    let fixture = try identityFixture()
    for streaming in [false, true] {
      let runtime = try identityRuntime(fixture)
      let session = LanguageModelSession(
        model: PiAILanguageModel(
          runtime: runtime, providerID: fixture.providerID, modelID: fixture.modelID))
      if streaming {
        let response = try await session.streamResponse(to: "Hello").collect()
        XCTAssertEqual(response.content, "OK")
      } else {
        let response = try await session.respond(to: "Hello")
        XCTAssertEqual(response.content, "OK")
      }
    }
  }

  func testCoreStillRejectsWrongNormalizedIdentityInBothModes() async throws {
    let fixture = try identityFixture()
    for streaming in [false, true] {
      let runtime = StartIdentityMutationRuntime(base: try identityRuntime(fixture))
      let session = LanguageModelSession(
        model: PiAILanguageModel(
          runtime: runtime, providerID: fixture.providerID, modelID: fixture.modelID))
      do {
        if streaming {
          _ = try await session.streamResponse(to: "Hello").collect()
        } else {
          _ = try await session.respond(to: "Hello")
        }
        XCTFail("Core accepted a different normalized model identity")
      } catch let error as AIReasoningCoreError {
        XCTAssertEqual(error.code, .invalidProviderResponse)
      }
    }
  }
}

private struct IdentityFixture: Decodable {
  let caseID: String
  let protocolID: String
  let providerID: String
  let modelID: String
  let baseURL: URL
  let decoderInput: DecoderInput

  struct DecoderInput: Decodable {
    let status: Int
    let headers: [String: String]
    let chunksBase64: [String]
  }
}

private func identityFixture() throws -> IdentityFixture {
  let path = try XCTUnwrap(ProcessInfo.processInfo.environment["PI_IDENTITY_FIXTURE_PATH"])
  // Decode only SSE cases: the shared image fixture has a JSON-body driver.
  let document = try XCTUnwrap(
    JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
      as? [String: Any])
  let cases = try XCTUnwrap(document["identityCases"] as? [[String: Any]])
  let selected = try XCTUnwrap(
    cases.first { $0["caseID"] as? String == "completions.identity-alias" })
  return try JSONDecoder().decode(
    IdentityFixture.self, from: JSONSerialization.data(withJSONObject: selected))
}

private func identityRuntime(
  _ fixture: IdentityFixture, metadata: [String: PiAIProviderRuntime.JSONValue] = [:]
) throws -> CustomProviderRuntime {
  let chunks = try fixture.decoderInput.chunksBase64.map { try XCTUnwrap(Data(base64Encoded: $0)) }
  return try CustomProviderRuntime(
    providers: [
      CustomProvider(
        id: fixture.providerID, baseURL: fixture.baseURL, api: fixture.protocolID,
        models: [
          CustomProviderModel(
            id: fixture.modelID,
            capabilities: ProviderCapabilities(
              textInput: true, imageInput: false, toolCalling: true,
              reasoning: false, structuredOutput: false, imageGeneration: false),
            metadata: metadata.merging(
              [
                "cost": .object([
                  "input": .integer(0), "output": .integer(0),
                  "cacheRead": .integer(0), "cacheWrite": .integer(0),
                ])
              ], uniquingKeysWith: { configured, _ in configured }))
        ])
    ],
    credentialStore: InMemoryProviderCredentialStore(credentials: [
      fixture.providerID: .apiKey(APIKeyCredential(key: "fixture-key", metadata: [:]))
    ]),
    streamingTransport: IdentityReplayTransport(
      modelID: fixture.modelID, status: fixture.decoderInput.status,
      headers: fixture.decoderInput.headers, chunks: chunks))
}

private struct IdentityReplayTransport: ProviderHTTPStreamingTransport {
  let modelID: String
  let status: Int
  let headers: [String: String]
  let chunks: [Data]

  func stream(_ request: URLRequest) async throws -> ProviderHTTPStreamingResponse {
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["model"] as? String, modelID)
    return ProviderHTTPStreamingResponse(
      statusCode: status, headers: headers,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}

private struct StartIdentityMutationRuntime: ProviderRuntime {
  let base: CustomProviderRuntime

  func catalog() async throws -> ProviderCatalog { try await base.catalog() }

  func authorize(
    _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    try await base.authorize(operation, interaction: interaction)
  }

  func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await event in base.stream(request) {
            if case .responseStarted(let metadata) = event {
              continuation.yield(
                .responseStarted(
                  ProviderResponseMetadata(
                    responseID: metadata.responseID, providerID: metadata.providerID,
                    modelID: "different-normalized-model",
                    providerMetadata: metadata.providerMetadata)))
            } else {
              continuation.yield(event)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
