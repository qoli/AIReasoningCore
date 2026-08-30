import AnyLanguageModel
import Foundation
import XCTest

@testable import AIReasoningCore

final class StoresAndToolsTests: XCTestCase {
  func testConversationRoundTrip() async throws {
    let directory = temporaryDirectory("conversations")
    let store = try ConversationStore(directory: directory)
    let id = UUID()
    let record = ConversationRecord(
      id: id,
      providerID: "provider",
      modelID: "model",
      transcript: Transcript(entries: [
        .prompt(Transcript.Prompt(segments: [.text(.init(content: "hello"))]))
      ]),
      providerState: Data([7, 8, 9])
    )

    try await store.save(record)
    let restored = try await store.load(id: id)

    XCTAssertEqual(restored.id, record.id)
    XCTAssertEqual(restored.providerID, record.providerID)
    XCTAssertEqual(restored.modelID, record.modelID)
    XCTAssertEqual(restored.transcript, record.transcript)
    XCTAssertEqual(restored.providerState, record.providerState)
    XCTAssertEqual(
      restored.updatedAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970, accuracy: 1)
  }

  func testAssetStoreRoundTrip() async throws {
    let store = try AssetStore(directory: temporaryDirectory("assets"))

    let saved = try await store.save(
      id: "image-1",
      kind: .image,
      mimeType: "image/png",
      data: Data([1, 2, 3])
    )

    XCTAssertEqual(saved.id, "image-1")
    let restoredData = try await store.data(id: "image-1")
    let assetIDs = try await store.list().map(\.id)
    XCTAssertEqual(restoredData, Data([1, 2, 3]))
    XCTAssertEqual(assetIDs, ["image-1"])
  }

  func testHTTPToolEnforcesHostPolicy() async throws {
    let client = HTTPClient { _ in
      HTTPResponse(
        statusCode: 200,
        headers: [:],
        body: Data("ok".utf8),
        finalURL: URL(string: "https://example.com/data")!
      )
    }
    let tool = HTTPTool(
      client: client,
      policy: HTTPAccessPolicy(allowedSchemes: ["https"], allowedHosts: ["example.com"])
    )
    let allowed = try HTTPTool.Arguments(
      GeneratedContent(
        properties: [
          "method": "GET",
          "url": "https://example.com/data",
          "headersJSON": nil as String?,
          "body": nil as String?,
        ]
      )
    )

    let output = try await tool.call(arguments: allowed)
    XCTAssertTrue(output.contains("\"status\":200"))

    let denied = try HTTPTool.Arguments(
      GeneratedContent(
        properties: [
          "method": "GET",
          "url": "https://blocked.example/data",
          "headersJSON": nil as String?,
          "body": nil as String?,
        ]
      )
    )
    do {
      _ = try await tool.call(arguments: denied)
      XCTFail("expected policy failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .disallowedURL)
    }
  }

  func testWebReadRemovesScriptsAndMarkup() {
    let text = WebReadTool.visibleText(
      from: "<html><style>.x{}</style><script>bad()</script><body>Hello &amp; goodbye</body></html>"
    )
    XCTAssertEqual(text, "Hello & goodbye")
  }

  func testDocumentToolRejectsTraversalAndReadsWrittenContent() async throws {
    let tool = try DocumentTool(root: temporaryDirectory("documents"))
    let write = try DocumentTool.Arguments(
      GeneratedContent(
        properties: [
          "operation": "write",
          "path": "notes/a.txt",
          "content": "hello",
        ]
      )
    )
    _ = try await tool.call(arguments: write)
    let read = try DocumentTool.Arguments(
      GeneratedContent(
        properties: [
          "operation": "read",
          "path": "notes/a.txt",
          "content": nil as String?,
        ]
      )
    )
    let restored = try await tool.call(arguments: read)
    XCTAssertEqual(restored, "hello")

    let traversal = try DocumentTool.Arguments(
      GeneratedContent(
        properties: [
          "operation": "read",
          "path": "../outside.txt",
          "content": nil as String?,
        ]
      )
    )
    do {
      _ = try await tool.call(arguments: traversal)
      XCTFail("expected traversal failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidDocumentPath)
    }
  }

  func testBrowserSnapshotBecomesManagedAsset() async throws {
    let assets = try AssetStore(directory: temporaryDirectory("browser-assets"))
    let browser = BrowserOperator { command in
      XCTAssertEqual(command.action, .snapshot)
      return BrowserResult(
        text: "snapshot complete",
        snapshot: GeneratedImage(data: Data([4, 5]), mimeType: "image/png")
      )
    }
    let tool = BrowserTool(browser: browser, assets: assets)
    let arguments = try BrowserTool.Arguments(
      GeneratedContent(
        properties: [
          "action": "snapshot",
          "target": nil as String?,
          "value": nil as String?,
        ]
      )
    )

    let output = try await tool.call(arguments: arguments)
    let assetCount = try await assets.list().count

    XCTAssertTrue(output.contains("asset://"))
    XCTAssertEqual(assetCount, 1)
  }

  func testImageGenerationAndAssetManagementToolsShareAssetStore() async throws {
    let assets = try AssetStore(directory: temporaryDirectory("generated-assets"))
    let generation = ImageGenerationTool(
      generator: ImageGenerator { prompt in
        XCTAssertEqual(prompt, "a blue square")
        return GeneratedImage(data: Data([9, 9]), mimeType: "image/png")
      },
      assets: assets
    )
    let generateArguments = try ImageGenerationTool.Arguments(
      GeneratedContent(properties: ["prompt": "a blue square"])
    )

    let reference = try await generation.call(arguments: generateArguments)
    let assetID = String(reference.dropFirst("asset://".count))
    let management = AssetManagementTool(assets: assets)
    let metadataArguments = try AssetManagementTool.Arguments(
      GeneratedContent(
        properties: [
          "operation": "metadata",
          "assetID": assetID,
        ]
      )
    )

    let metadata = try await management.call(arguments: metadataArguments)
    let decodedMetadata = try JSONDecoder().decode(ManagedAsset.self, from: Data(metadata.utf8))

    XCTAssertTrue(reference.hasPrefix("asset://"))
    XCTAssertEqual(decodedMetadata.id, assetID)
    XCTAssertEqual(decodedMetadata.mimeType, "image/png")
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("AIReasoningCoreTests")
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent(name)
  }
}
