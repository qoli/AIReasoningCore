// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

func runTextStreamingProbe() async throws -> String {
  let runtime = ProbeRuntime { request in
    responseEvents(for: request, textParts: ["stream", " complete"])
  }
  let session = probeSession(runtime: runtime)
  var snapshots: [String] = []
  for try await snapshot in session.streamResponse(to: "Stream") {
    snapshots.append(snapshot.content)
  }
  guard snapshots == ["stream", "stream complete"] else {
    throw SmokeFailure("unexpected text snapshots: \(snapshots)")
  }
  return "ProviderRuntime → PiAILanguageModel → LanguageModelSession"
}

func runStructuredOutputProbe() async throws -> String {
  let json = #"{"status":"ok","count":1}"#
  let runtime = ProbeRuntime { request in
    responseEvents(for: request, textParts: [json])
  }
  let response = try await probeSession(runtime: runtime).respond(
    to: "Structure",
    generating: SmokeStructuredAnswer.self
  )
  guard response.content.status == "ok", response.content.count == 1 else {
    throw SmokeFailure("structured response did not round-trip")
  }
  return json
}

func runReasoningReplayProbe() async throws -> String {
  let reasoning = ProviderReasoningContent(
    text: "plan",
    signature: "opaque-signature",
    providerMetadata: ["cache": .string("fixture")]
  )
  let runtime = ProbeRuntime { request in
    if request.messages.contains(where: { message in
      if case .assistant(let content) = message { return content.contains(.reasoning(reasoning)) }
      return false
    }) {
      return responseEvents(for: request, textParts: ["replayed"])
    }
    return [
      .responseStarted(metadata(for: request)),
      .reasoningDelta(reasoning.text),
      .reasoningSignatureDelta(reasoning.signature!),
      .textDelta("answer"),
      .responseSnapshot(
        responseSnapshot(
          for: request,
          content: [.reasoning(reasoning), .text("answer")],
          finishReason: .stop
        )
      ),
      .completed(.stop),
    ]
  }
  let first = probeSession(runtime: runtime)
  _ = try await first.respond(to: "Reason")
  let restored = try JSONDecoder().decode(
    Transcript.self,
    from: JSONEncoder().encode(first.transcript)
  )
  let replay = LanguageModelSession(
    model: PiAILanguageModel(runtime: runtime, providerID: "smoke", modelID: "deterministic"),
    transcript: restored
  )
  let response = try await replay.respond(to: "Continue")
  guard response.content == "replayed" else {
    throw SmokeFailure("provider reasoning metadata did not replay")
  }
  return "opaque reasoning signature and metadata survived Codable replay"
}

func runToolContinuationProbe() async throws -> String {
  let call = ProviderToolCall(
    id: "smoke-call",
    name: "echo",
    arguments: .object(["value": .string("tool-output")])
  )
  let runtime = ProbeRuntime { request in
    if let result = request.messages.compactMap({ message -> ProviderToolResult? in
      if case .toolResult(let value) = message { return value }
      return nil
    }).last {
      let text = result.content.compactMap { item -> String? in
        if case .text(let value) = item { return value }
        return nil
      }.joined()
      guard text.contains("tool-output") else {
        throw SmokeFailure("provider continuation received wrong tool output")
      }
      return responseEvents(for: request, textParts: ["tool loop complete"])
    }
    return [
      .responseStarted(metadata(for: request)),
      .toolCallStarted(id: call.id, name: call.name),
      .toolCallCompleted(call),
      .responseSnapshot(
        responseSnapshot(for: request, content: [.toolCall(call)], finishReason: .toolCalls)
      ),
      .completed(.toolCalls),
    ]
  }
  let session = LanguageModelSession(
    model: PiAILanguageModel(
      runtime: runtime,
      providerID: "smoke",
      modelID: "deterministic"
    ),
    tools: [SmokeEchoTool()]
  )
  let response = try await session.respond(to: "Use the supplied echo Tool")
  guard response.content == "tool loop complete",
    session.transcript.contains(where: { if case .toolCalls = $0 { true } else { false } }),
    session.transcript.contains(where: { if case .toolOutput = $0 { true } else { false } })
  else {
    throw SmokeFailure("tool continuation transcript was incomplete")
  }
  return "deterministic external echo Tool completed one provider round"
}

func runCancellationCheckpointProbe() async throws -> String {
  let runtime = HangingReasoningRuntime()
  let session = probeSession(runtime: runtime)
  session.transcriptErrorHandlingPolicy = .preserveTranscript
  let consumer = Task {
    for try await snapshot in session.streamResponse(to: "Wait") {
      if snapshot.transcriptEntries.contains(where: {
        if case .reasoning = $0 { true } else { false }
      }) {
        return
      }
    }
  }
  try await consumer.value
  await session.waitForResponseCompletion()
  guard session.transcript.contains(where: { if case .reasoning = $0 { true } else { false } }),
    !session.transcript.contains(where: { if case .response = $0 { true } else { false } })
  else {
    throw SmokeFailure("cancellation did not preserve only the reasoning checkpoint")
  }
  return "consumer cancellation preserved reasoning without a completed response"
}

func runAssetDeliveryProbe() async throws -> String {
  let asset = ProviderAsset(
    id: "smoke-asset",
    kind: .image,
    mimeType: "image/png",
    data: Data([1, 2, 3]),
    providerMetadata: ["source": .string("deterministic")]
  )
  let recorder = SmokeAssetRecorder()
  let runtime = ProbeRuntime { request in
    [
      .responseStarted(metadata(for: request)),
      .asset(asset),
      .textDelta("delivered"),
      .responseSnapshot(
        ProviderResponseSnapshot(
          responseID: "smoke-response",
          providerID: request.providerID,
          protocolID: "smoke",
          modelID: request.modelID,
          responseModelID: nil,
          content: [
            .asset(asset),
            .text(ProviderTextContent(text: "delivered", signature: nil)),
          ],
          usage: usage,
          finishReason: .stop,
          rawFinishReason: "stop",
          timestampMilliseconds: 0
        )
      ),
      .completed(.stop),
    ]
  }
  let session = LanguageModelSession(
    model: PiAILanguageModel(
      runtime: runtime,
      providerID: "smoke",
      modelID: "deterministic",
      onAsset: { value in await recorder.record(value) }
    )
  )
  let response = try await session.respond(to: "Deliver")
  let recordedAssets = await recorder.assets
  guard response.content == "delivered", recordedAssets == [asset] else {
    throw SmokeFailure("provider asset was not delivered exactly once")
  }
  return "provider asset delivered unchanged to the Host callback"
}

@Generable
private struct SmokeStructuredAnswer {
  let status: String
  let count: Int
}

private struct SmokeEchoTool: Tool {
  @Generable
  struct Arguments {
    let value: String
  }

  let name = "echo"
  let description = "Echo a deterministic smoke-test value."

  func call(arguments: Arguments) async throws -> String {
    arguments.value
  }
}

private actor SmokeAssetRecorder {
  private(set) var assets: [ProviderAsset] = []

  func record(_ asset: ProviderAsset) {
    assets.append(asset)
  }
}

private struct ProbeRuntime: ProviderRuntime {
  let handler: @Sendable (ProviderRequest) throws -> [ProviderEvent]

  init(_ handler: @escaping @Sendable (ProviderRequest) throws -> [ProviderEvent]) {
    self.handler = handler
  }

  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "smoke", providers: [])
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

private struct HangingReasoningRuntime: ProviderRuntime {
  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "smoke", providers: [])
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
      continuation.yield(.responseStarted(metadata(for: request)))
      continuation.yield(.reasoningDelta("checkpoint"))
    }
  }
}

private func probeSession(runtime: any ProviderRuntime) -> LanguageModelSession {
  LanguageModelSession(
    model: PiAILanguageModel(
      runtime: runtime,
      providerID: "smoke",
      modelID: "deterministic"
    )
  )
}

private func metadata(for request: ProviderRequest) -> ProviderResponseMetadata {
  ProviderResponseMetadata(
    responseID: "smoke-response",
    providerID: request.providerID,
    modelID: request.modelID,
    providerMetadata: [:]
  )
}

private let usage = ProviderUsage(
  inputTokens: 1,
  outputTokens: 1,
  reasoningTokens: 0,
  cachedInputTokens: 0,
  totalTokens: 2,
  providerMetadata: [:]
)

private func responseEvents(
  for request: ProviderRequest,
  textParts: [String]
) -> [ProviderEvent] {
  let text = textParts.joined()
  var events: [ProviderEvent] = [.responseStarted(metadata(for: request))]
  events.append(contentsOf: textParts.map(ProviderEvent.textDelta))
  events.append(contentsOf: [
    .responseSnapshot(
      responseSnapshot(for: request, content: [.text(text)], finishReason: .stop)
    ),
    .completed(.stop),
  ])
  return events
}

private func responseSnapshot(
  for request: ProviderRequest,
  content: [ProviderAssistantContent],
  finishReason: ProviderFinishReason
) -> ProviderResponseSnapshot {
  ProviderResponseSnapshot(
    responseID: "smoke-response",
    providerID: request.providerID,
    protocolID: "smoke",
    modelID: request.modelID,
    responseModelID: nil,
    content: content.map { item in
      switch item {
      case .text(let text):
        return .text(ProviderTextContent(text: text, signature: nil))
      case .signedText(let text):
        return .text(text)
      case .reasoning(let reasoning):
        return .reasoning(reasoning)
      case .toolCall(let call):
        return .toolCall(call)
      }
    },
    usage: usage,
    finishReason: finishReason,
    rawFinishReason: finishReason.rawValue,
    timestampMilliseconds: 0
  )
}
