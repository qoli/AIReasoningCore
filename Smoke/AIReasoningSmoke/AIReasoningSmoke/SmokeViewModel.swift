// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AnyLanguageModel
import Foundation
import PiAIProviderRuntime
import SwiftUI
import UIKit

struct SmokeFailure: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

struct SmokeCheck: Identifiable, Codable, Sendable {
  enum Status: String, Codable, Sendable {
    case pending
    case running
    case passed
    case failed
  }

  let id: String
  let capability: String
  let name: String
  var status: Status
  var detail: String
  var durationMilliseconds: Int?
}

private struct SmokeReport: Codable {
  let schemaVersion: Int
  let finishedAt: Date
  let passed: Bool
  let checks: [SmokeCheck]
}

@MainActor
final class SmokeViewModel: ObservableObject {
  @Published private(set) var checks: [SmokeCheck] = SmokeViewModel.initialChecks
  @Published private(set) var isRunning = false
  @Published private(set) var assetPreview: UIImage?
  @Published private(set) var reportURL: URL?

  private let browserHost: SmokeBrowserHost
  private var hasRun = false
  private var assets: AssetStore?
  private var generatedAssetID: String?
  private var browserAssetID: String?

  init(browserHost: SmokeBrowserHost) {
    self.browserHost = browserHost
  }

  var summary: String {
    if isRunning {
      return "Running \(checks.filter { $0.status == .passed }.count)/\(checks.count)"
    }
    if checks.allSatisfy({ $0.status == .passed }) { return "All \(checks.count) checks passed" }
    if checks.contains(where: { $0.status == .failed }) { return "Smoke suite failed" }
    return "Not run"
  }

  var summaryIcon: String {
    if isRunning { return "progress.indicator" }
    if checks.allSatisfy({ $0.status == .passed }) { return "checkmark.seal.fill" }
    if checks.contains(where: { $0.status == .failed }) { return "xmark.octagon.fill" }
    return "circle.dashed"
  }

  var summaryColor: Color {
    if isRunning { return .blue }
    if checks.allSatisfy({ $0.status == .passed }) { return .green }
    if checks.contains(where: { $0.status == .failed }) { return .red }
    return .secondary
  }

  func runIfNeeded() async {
    guard !hasRun else { return }
    run()
  }

  func run() {
    guard !isRunning else { return }
    hasRun = true
    Task { await executeSuite() }
  }

  private func executeSuite() async {
    isRunning = true
    checks = Self.initialChecks
    assetPreview = nil
    generatedAssetID = nil
    browserAssetID = nil

    do {
      let root = try resetSmokeRoot()
      let store = try AssetStore(
        directory: root.appendingPathComponent("Assets", isDirectory: true))
      assets = store

      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [SmokeHTTPProtocol.self]
      let client = HTTPClient.urlSession(URLSession(configuration: configuration))

      await runCheck(id: "http", capability: "Native") {
        let tool = HTTPTool(client: client)
        let arguments = try HTTPTool.Arguments(
          GeneratedContent(
            properties: [
              "method": "POST",
              "url": "https://smoke.local/api",
              "headersJSON": #"{"X-Smoke":"true"}"#,
              "body": "ping",
            ]
          )
        )
        let output = try await tool.call(arguments: arguments)
        guard
          let envelope = try JSONSerialization.jsonObject(with: Data(output.utf8))
            as? [String: Any],
          envelope["status"] as? Int == 201,
          let responseBody = envelope["body"] as? String,
          let echoed = try JSONSerialization.jsonObject(with: Data(responseBody.utf8))
            as? [String: String],
          echoed["method"] == "POST",
          echoed["body"] == "ping"
        else {
          throw SmokeFailure("unexpected HTTP output: \(output)")
        }
        return "URLSession adapter returned status 201 and echoed request body"
      }

      await runCheck(id: "session-tool-loop", capability: "Core") {
        let output = try await runSessionToolProbe(
          tool: HTTPTool(client: client),
          toolName: "http_request",
          arguments: .object([
            "method": .string("POST"),
            "url": .string("https://smoke.local/api"),
            "headersJSON": .string(#"{"X-Smoke":"session"}"#),
            "body": .string("session-ping"),
          ]),
          expectedToolOutput: "session-ping"
        )
        return "ProviderRuntime → PiAILanguageModel → Session → HTTPTool → \(output)"
      }

      await runCheck(id: "web-read", capability: "Native") {
        let tool = WebReadTool(client: client)
        let arguments = try WebReadTool.Arguments(
          GeneratedContent(properties: ["url": "https://smoke.local/page"])
        )
        let output = try await tool.call(arguments: arguments)
        guard output == "Smoke Web Native web read works & is visible." else {
          throw SmokeFailure("unexpected visible text: \(output)")
        }
        return output
      }

      await runCheck(id: "document", capability: "Native") {
        let tool = try DocumentTool(
          root: root.appendingPathComponent("Documents", isDirectory: true))
        _ = try await tool.call(
          arguments: DocumentTool.Arguments(
            GeneratedContent(
              properties: [
                "operation": "write",
                "path": "notes/smoke.txt",
                "content": "document round trip",
              ]
            )
          )
        )
        let list = try await tool.call(
          arguments: DocumentTool.Arguments(
            GeneratedContent(
              properties: [
                "operation": "list",
                "path": "notes",
                "content": nil as String?,
              ]
            )
          )
        )
        let read = try await tool.call(
          arguments: DocumentTool.Arguments(
            GeneratedContent(
              properties: [
                "operation": "read",
                "path": "notes/smoke.txt",
                "content": nil as String?,
              ]
            )
          )
        )
        guard list == "smoke.txt", read == "document round trip" else {
          throw SmokeFailure("document write/list/read mismatch")
        }
        return "wrote, listed, and read notes/smoke.txt in the iOS sandbox"
      }

      await runCheck(id: "image-generation", capability: "Native") {
        let png = try Self.makeFixturePNG()
        let tool = ImageGenerationTool(
          generator: ImageGenerator { prompt in
            guard prompt == "blue smoke square" else {
              throw SmokeFailure("unexpected image prompt")
            }
            return GeneratedImage(data: png, mimeType: "image/png")
          },
          assets: store
        )
        let reference = try await tool.call(
          arguments: ImageGenerationTool.Arguments(
            GeneratedContent(properties: ["prompt": "blue smoke square"])
          )
        )
        guard reference.hasPrefix("asset://") else {
          throw SmokeFailure("image tool did not return an asset reference")
        }
        let id = String(reference.dropFirst("asset://".count))
        let stored = try await store.data(id: id)
        guard let image = UIImage(data: stored) else {
          throw SmokeFailure("stored generated image is not a decodable PNG")
        }
        generatedAssetID = id
        assetPreview = image
        return "generated and decoded \(stored.count)-byte PNG at asset://\(id)"
      }

      let browserTool = BrowserTool(browser: browserHost.operatorAdapter, assets: store)
      await runCheck(id: "browser-operation", capability: "Interactive") {
        _ = try await browserTool.call(
          arguments: try Self.browserArguments(action: "open", target: "smoke://interactive")
        )
        _ = try await browserTool.call(
          arguments: try Self.browserArguments(action: "waitForNavigation")
        )
        let ready = try await browserTool.call(
          arguments: try Self.browserArguments(action: "read", target: "#status")
        )
        _ = try await browserTool.call(
          arguments: try Self.browserArguments(
            action: "type", target: "#name", value: "AIReasoningCore")
        )
        _ = try await browserTool.call(
          arguments: try Self.browserArguments(action: "click", target: "#apply")
        )
        let result = try await browserTool.call(
          arguments: try Self.browserArguments(action: "read", target: "#result")
        )
        guard ready == "READY", result == "Hello AIReasoningCore" else {
          throw SmokeFailure("WebKit interaction mismatch: \(ready) / \(result)")
        }
        return "WKWebView open/read/type/click produced: \(result)"
      }

      await runCheck(id: "browser-snapshot", capability: "Interactive") {
        let reference = try await browserTool.call(
          arguments: try Self.browserArguments(action: "snapshot")
        )
        guard let marker = reference.range(of: "asset://") else {
          throw SmokeFailure("browser snapshot did not return an asset reference")
        }
        let id = String(reference[marker.upperBound...])
        let stored = try await store.data(id: id)
        guard UIImage(data: stored) != nil else {
          throw SmokeFailure("stored WebKit snapshot is not a decodable PNG")
        }
        browserAssetID = id
        return "captured and decoded \(stored.count)-byte WebKit snapshot"
      }

      await runCheck(id: "asset-management", capability: "Interactive") {
        guard let generatedAssetID, let browserAssetID else {
          throw SmokeFailure("expected generated-image and browser-snapshot assets")
        }
        let tool = AssetManagementTool(assets: store)
        let listJSON = try await tool.call(
          arguments: AssetManagementTool.Arguments(
            GeneratedContent(
              properties: [
                "operation": "list",
                "assetID": nil as String?,
              ]
            )
          )
        )
        let listed = try JSONDecoder().decode([ManagedAsset].self, from: Data(listJSON.utf8))
        let expectedIDs = Set([generatedAssetID, browserAssetID])
        guard Set(listed.map(\.id)) == expectedIDs else {
          throw SmokeFailure("asset list did not contain both managed images")
        }
        for id in expectedIDs {
          let metadataJSON = try await tool.call(
            arguments: AssetManagementTool.Arguments(
              GeneratedContent(properties: ["operation": "metadata", "assetID": id])
            )
          )
          let metadata = try JSONDecoder().decode(ManagedAsset.self, from: Data(metadataJSON.utf8))
          guard metadata.kind == .image, metadata.mimeType == "image/png", metadata.byteCount > 0
          else {
            throw SmokeFailure("invalid metadata for \(id)")
          }
        }
        return "listed and read metadata for two renderable managed assets"
      }
    } catch {
      markPendingChecksFailed(after: error)
    }

    isRunning = false
    do {
      reportURL = try writeReport()
    } catch {
      if let index = checks.indices.last {
        checks[index].status = .failed
        checks[index].detail += " | report write failed: \(error.localizedDescription)"
      }
    }
  }

  private func runCheck(
    id: String,
    capability: String,
    operation: () async throws -> String
  ) async {
    guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
    checks[index].status = .running
    let clock = ContinuousClock()
    let start = clock.now
    do {
      let detail = try await operation()
      checks[index].status = .passed
      checks[index].detail = detail
    } catch {
      checks[index].status = .failed
      checks[index].detail = error.localizedDescription
    }
    let elapsed = start.duration(to: clock.now)
    checks[index].durationMilliseconds =
      Int(elapsed.components.seconds * 1_000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  private func resetSmokeRoot() throws -> URL {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw SmokeFailure("Application Support directory is unavailable")
    }
    let root = applicationSupport.appendingPathComponent("AIReasoningSmoke", isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func writeReport() throws -> URL {
    guard
      let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first
    else {
      throw SmokeFailure("Documents directory is unavailable")
    }
    let report = SmokeReport(
      schemaVersion: 1,
      finishedAt: Date(),
      passed: checks.allSatisfy { $0.status == .passed },
      checks: checks
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = documents.appendingPathComponent("SmokeReport.json")
    try encoder.encode(report).write(to: url, options: .atomic)
    return url
  }

  private func markPendingChecksFailed(after error: any Error) {
    for index in checks.indices where checks[index].status == .pending {
      checks[index].status = .failed
      checks[index].detail = "suite setup failed: \(error.localizedDescription)"
    }
  }

  private static func browserArguments(
    action: String,
    target: String? = nil,
    value: String? = nil
  ) throws -> BrowserTool.Arguments {
    try BrowserTool.Arguments(
      GeneratedContent(
        properties: [
          "action": action,
          "target": target,
          "value": value,
        ]
      )
    )
  }

  private static func makeFixturePNG() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
    let image = renderer.image { context in
      UIColor.systemBlue.setFill()
      context.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      UIColor.white.setFill()
      context.cgContext.fill(CGRect(x: 20, y: 20, width: 24, height: 24))
    }
    guard let data = image.pngData() else {
      throw SmokeFailure("fixture PNG encoding failed")
    }
    return data
  }

  private static let initialChecks: [SmokeCheck] = [
    SmokeCheck(id: "http", capability: "Native", name: "HTTP/API", status: .pending, detail: ""),
    SmokeCheck(
      id: "session-tool-loop", capability: "Core", name: "Agent Tool Loop", status: .pending,
      detail: ""),
    SmokeCheck(
      id: "web-read", capability: "Native", name: "Web Read", status: .pending, detail: ""),
    SmokeCheck(
      id: "document", capability: "Native", name: "Document Read/Write", status: .pending,
      detail: ""),
    SmokeCheck(
      id: "image-generation", capability: "Native", name: "Image Generation", status: .pending,
      detail: ""),
    SmokeCheck(
      id: "browser-operation", capability: "Interactive", name: "Browser Operation",
      status: .pending, detail: ""),
    SmokeCheck(
      id: "browser-snapshot", capability: "Interactive", name: "Browser Snapshot", status: .pending,
      detail: ""),
    SmokeCheck(
      id: "asset-management", capability: "Interactive", name: "Asset Management", status: .pending,
      detail: ""),
  ]
}
