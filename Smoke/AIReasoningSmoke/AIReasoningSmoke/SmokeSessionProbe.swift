// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AnyLanguageModel
import PiAIProviderRuntime

func runSessionToolProbe(
  tool: any Tool,
  toolName: String,
  arguments: PiAIProviderRuntime.JSONValue,
  expectedToolOutput: String
) async throws -> String {
  let runtime = SingleToolRuntime(
    toolName: toolName,
    arguments: arguments,
    expectedToolOutput: expectedToolOutput
  )
  let session = LanguageModelSession(
    model: PiAILanguageModel(runtime: runtime, providerID: "smoke", modelID: "deterministic"),
    tools: [tool]
  )

  let response = try await session.respond(to: "Run the deterministic smoke tool")
  guard response.content == "tool loop complete" else {
    throw SmokeFailure("unexpected session response: \(response.content)")
  }
  guard
    session.transcript.contains(where: { entry in
      if case .toolCalls = entry { return true }
      return false
    })
  else {
    throw SmokeFailure("session transcript has no tool call entry")
  }
  guard
    session.transcript.contains(where: { entry in
      if case .toolOutput = entry { return true }
      return false
    })
  else {
    throw SmokeFailure("session transcript has no tool output entry")
  }
  return response.content
}

private struct SingleToolRuntime: ProviderRuntime {
  let toolName: String
  let arguments: PiAIProviderRuntime.JSONValue
  let expectedToolOutput: String

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
    AsyncThrowingStream<ProviderEvent, any Error> { continuation in
      let metadata = ProviderResponseMetadata(
        responseID: "smoke-response",
        providerID: request.providerID,
        modelID: request.modelID,
        providerMetadata: [:]
      )
      continuation.yield(.responseStarted(metadata))

      if let result = request.messages.compactMap({ message -> ProviderToolResult? in
        if case .toolResult(let result) = message { return result }
        return nil
      }).last {
        let text = result.content.compactMap { content -> String? in
          if case .text(let value) = content { return value }
          return nil
        }.joined(separator: "\n")
        guard !result.isError, text.contains(expectedToolOutput) else {
          continuation.finish(
            throwing: SmokeFailure("provider continuation received invalid tool output: \(text)")
          )
          return
        }
        continuation.yield(.textDelta("tool loop complete"))
        continuation.yield(.completed(.stop))
        continuation.finish()
        return
      }

      continuation.yield(.toolCallStarted(id: "smoke-call", name: toolName))
      continuation.yield(
        .toolCallCompleted(
          ProviderToolCall(id: "smoke-call", name: toolName, arguments: arguments)
        )
      )
      continuation.yield(.completed(.toolCalls))
      continuation.finish()
    }
  }
}
