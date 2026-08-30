import Foundation
import PiAIProviderRuntime

public struct ManagedAsset: Sendable, Equatable, Codable, Identifiable {
  public enum Kind: String, Sendable, Equatable, Codable {
    case image
    case file
  }

  public let id: String
  public let kind: Kind
  public let mimeType: String
  public let byteCount: Int
  public let createdAt: Date

  public init(
    id: String,
    kind: Kind,
    mimeType: String,
    byteCount: Int,
    createdAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.createdAt = createdAt
  }
}

public actor AssetStore {
  private struct Envelope: Codable {
    let asset: ManagedAsset
    let data: Data
  }

  private let directory: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(directory: URL) throws {
    guard directory.isFileURL else {
      throw AIReasoningCoreError(.persistenceFailure, "asset directory must be a file URL")
    }
    self.directory = directory.standardizedFileURL
    try FileManager.default.createDirectory(
      at: self.directory,
      withIntermediateDirectories: true
    )
  }

  @discardableResult
  public func save(
    id: String = UUID().uuidString,
    kind: ManagedAsset.Kind,
    mimeType: String,
    data: Data
  ) throws -> ManagedAsset {
    let asset = ManagedAsset(
      id: id,
      kind: kind,
      mimeType: mimeType,
      byteCount: data.count,
      createdAt: Date()
    )
    let encoded = try encoder.encode(Envelope(asset: asset, data: data))
    try encoded.write(to: fileURL(for: id), options: .atomic)
    return asset
  }

  @discardableResult
  public func save(_ providerAsset: ProviderAsset) throws -> ManagedAsset {
    try save(
      id: providerAsset.id,
      kind: providerAsset.kind == .image ? .image : .file,
      mimeType: providerAsset.mimeType,
      data: providerAsset.data
    )
  }

  public func asset(id: String) throws -> ManagedAsset {
    try envelope(id: id).asset
  }

  public func data(id: String) throws -> Data {
    try envelope(id: id).data
  }

  public func list() throws -> [ManagedAsset] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    return
      try urls
      .filter { $0.pathExtension == "asset" }
      .map { try decoder.decode(Envelope.self, from: Data(contentsOf: $0)).asset }
      .sorted { $0.createdAt < $1.createdAt }
  }

  private func envelope(id: String) throws -> Envelope {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIReasoningCoreError(.assetNotFound, "asset not found: \(id)")
    }
    return try decoder.decode(Envelope.self, from: Data(contentsOf: url))
  }

  private func fileURL(for id: String) -> URL {
    let safeID = Data(id.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
    return directory.appendingPathComponent(safeID).appendingPathExtension("asset")
  }
}
