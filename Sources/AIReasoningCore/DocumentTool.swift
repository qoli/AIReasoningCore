import AnyLanguageModel
import Foundation

public struct DocumentTool: Tool {
  @Generable
  public struct Arguments {
    public let operation: String
    public let path: String
    public let content: String?
  }

  public let name = "document"
  public let description =
    "Read, write, or list UTF-8 documents inside the configured document root."

  private let root: URL
  private let maximumReadBytes: Int

  public init(root: URL, maximumReadBytes: Int = 2_000_000) throws {
    guard root.isFileURL else {
      throw AIReasoningCoreError(.invalidDocumentPath, "document root must be a file URL")
    }
    guard maximumReadBytes >= 0 else {
      throw AIReasoningCoreError(.unsupportedOperation, "maximumReadBytes must be nonnegative")
    }
    let standardizedRoot = root.standardizedFileURL
    try FileManager.default.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)
    self.root = standardizedRoot.resolvingSymlinksInPath()
    self.maximumReadBytes = maximumReadBytes
  }

  public func call(arguments: Arguments) async throws -> String {
    switch arguments.operation {
    case "read":
      let url = try resolve(arguments.path)
      let data = try readDocument(at: url)
      guard let value = String(data: data, encoding: .utf8) else {
        throw AIReasoningCoreError(.invalidProviderResponse, "document is not UTF-8")
      }
      return value
    case "write":
      guard let content = arguments.content else {
        throw AIReasoningCoreError(.invalidProviderResponse, "write requires content")
      }
      let url = try resolve(arguments.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard let data = content.data(using: .utf8) else {
        throw AIReasoningCoreError(.invalidProviderResponse, "document content is not UTF-8")
      }
      try data.write(to: url, options: .atomic)
      return "written: \(arguments.path)"
    case "list":
      let url = try resolve(arguments.path)
      return try FileManager.default.contentsOfDirectory(atPath: url.path)
        .sorted()
        .joined(separator: "\n")
    default:
      throw AIReasoningCoreError(
        .unsupportedOperation,
        "unsupported document operation: \(arguments.operation)"
      )
    }
  }

  private func readDocument(at url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while true {
      try Task.checkCancellation()
      // Read at most one byte past the limit, including when the limit is zero.
      let remaining = maximumReadBytes - data.count
      let chunkSize = remaining >= 65_536 ? 65_536 : remaining + 1
      guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
        return data
      }
      guard chunk.count <= remaining else {
        throw AIReasoningCoreError(
          .responseTooLarge,
          "document exceeded \(maximumReadBytes) bytes"
        )
      }
      data.append(chunk)
    }
  }

  private func resolve(_ relativePath: String) throws -> URL {
    guard !relativePath.hasPrefix("/") else {
      throw AIReasoningCoreError(.invalidDocumentPath, "document path must be relative")
    }
    let resolved = root.appendingPathComponent(relativePath).standardizedFileURL
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
      throw AIReasoningCoreError(.invalidDocumentPath, "document path escapes the configured root")
    }
    let existingTarget = resolved.resolvingSymlinksInPath()
    let existingPath = existingTarget.path
    guard existingPath == root.path || existingPath.hasPrefix(rootPath) else {
      throw AIReasoningCoreError(
        .invalidDocumentPath, "document path resolves outside the configured root")
    }
    return resolved
  }
}
