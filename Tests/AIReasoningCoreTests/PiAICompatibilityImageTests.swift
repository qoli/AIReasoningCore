#if canImport(CoreGraphics) && canImport(ImageIO)
  import AnyLanguageModel
  import CoreGraphics
  import Foundation
  import ImageIO
  import PiAIProviderRuntime
  import XCTest

  @testable import AIReasoningCore

  final class PiAICompatibilityImageTests: XCTestCase {
    func testNormalImageToolStreamAndNonstreamSurviveContinuationAndRestore() async throws {
      for streaming in [false, true] {
        let model = PiAILanguageModel(
          runtime: CompatibilityImageRuntime(), providerID: "image", modelID: "model")
        let session = LanguageModelSession(model: model, tools: [CompatibilityImageTool()])
        if streaming {
          var final: String?
          for try await snapshot in session.streamResponse(to: "Read synthetic image") {
            final = snapshot.content
          }
          XCTAssertEqual(final, "image received")
        } else {
          let response = try await session.respond(to: "Read synthetic image")
          XCTAssertEqual(response.content, "image received")
        }
        let images = session.transcript.flatMap { entry -> [Transcript.Segment] in
          if case .toolOutput(let value) = entry { return value.segments }
          return []
        }.compactMap { if case .image(let value) = $0 { value } else { nil } }
        XCTAssertEqual(images.count, 1)
        guard case .data(let bytes, let mime) = images.first?.source else {
          return XCTFail("Missing ordinary image Tool output")
        }
        XCTAssertEqual(mime, "image/png")
        XCTAssertNotNil(CGImageSourceCreateWithData(bytes as CFData, nil))
        let transcript = try JSONDecoder().decode(
          Transcript.self, from: JSONEncoder().encode(session.transcript))
        XCTAssertEqual(transcript, session.transcript)
        let restored = LanguageModelSession(
          model: model, tools: [CompatibilityImageTool()], transcript: transcript)
        let response = try await restored.respond(to: "Continue")
        XCTAssertEqual(response.content, "image received")
      }
    }
  }

  private struct CompatibilityImageTool: Tool {
    @Generable struct Arguments {}
    let name = "read_image"
    let description = "Return a synthetic image"
    func call(arguments: Arguments) async throws -> Prompt {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      return try Prompt {
        "Image result"
        Attachment(try XCTUnwrap(context.makeImage()))
      }
    }
  }

  private struct CompatibilityImageRuntime: ProviderRuntime {
    func catalog() async throws -> ProviderCatalog { .init(revision: "fixture", providers: []) }
    func authorize(
      _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction
    ) async throws -> AuthorizationState {
      throw AIReasoningCoreError(.unsupportedOperation, "Synthetic fixture has no authorization")
    }
    func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
      AsyncThrowingStream { continuation in
        continuation.yield(
          .responseStarted(
            .init(
              responseID: nil, providerID: request.providerID, modelID: request.modelID,
              providerMetadata: [:])))
        let hasImage = request.messages.contains { message in
          if case .toolResult(let result) = message {
            return result.content.contains { if case .image = $0 { true } else { false } }
          }
          return false
        }
        let content: [ProviderResponseContent]
        let finish: ProviderFinishReason
        if hasImage {
          continuation.yield(.textDelta("image received"))
          content = [.text(.init(text: "image received", signature: nil))]
          finish = .stop
        } else {
          let call = ProviderToolCall(id: "read-image", name: "read_image", arguments: .object([:]))
          continuation.yield(.toolCallStarted(id: call.id, name: call.name))
          continuation.yield(.toolCallCompleted(call))
          content = [.toolCall(call)]
          finish = .toolCalls
        }
        continuation.yield(
          .responseSnapshot(
            .init(
              responseID: nil, providerID: request.providerID, protocolID: "fixture",
              modelID: request.modelID,
              responseModelID: nil, content: content,
              usage: .init(
                inputTokens: 1, outputTokens: 1, reasoningTokens: nil, cachedInputTokens: nil,
                providerMetadata: [:]),
              finishReason: finish, rawFinishReason: nil, timestampMilliseconds: 0,
              providerMetadata: [:])))
        continuation.yield(.completed(finish))
        continuation.finish()
      }
    }
  }

#endif
