import AnyLanguageModel
import Foundation

public struct ConversationRecord: Sendable, Equatable, Codable, Identifiable {
  public let schemaVersion: Int
  public let id: UUID
  public let providerID: String
  public let modelID: String
  public let transcript: Transcript
  public let providerState: Data?
  public let updatedAt: Date

  public init(
    id: UUID,
    providerID: String,
    modelID: String,
    transcript: Transcript,
    providerState: Data? = nil,
    updatedAt: Date = Date()
  ) {
    self.schemaVersion = 1
    self.id = id
    self.providerID = providerID
    self.modelID = modelID
    self.transcript = transcript
    self.providerState = providerState
    self.updatedAt = updatedAt
  }
}

public actor ConversationStore {
  private let directory: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(directory: URL) throws {
    guard directory.isFileURL else {
      throw AIReasoningCoreError(.persistenceFailure, "conversation directory must be a file URL")
    }
    self.directory = directory.standardizedFileURL
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: self.directory,
      withIntermediateDirectories: true
    )
  }

  public func save(_ record: ConversationRecord) throws {
    guard record.schemaVersion == 1 else {
      throw AIReasoningCoreError(
        .persistenceFailure,
        "unsupported conversation schema version: \(record.schemaVersion)"
      )
    }
    try encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
  }

  public func load(id: UUID) throws -> ConversationRecord {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIReasoningCoreError(.persistenceFailure, "conversation not found: \(id)")
    }
    let record = try decoder.decode(ConversationRecord.self, from: Data(contentsOf: url))
    guard record.schemaVersion == 1 else {
      throw AIReasoningCoreError(
        .persistenceFailure,
        "unsupported conversation schema version: \(record.schemaVersion)"
      )
    }
    return record
  }

  public func list() throws -> [ConversationRecord] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "conversation" }
    .map { try decoder.decode(ConversationRecord.self, from: Data(contentsOf: $0)) }
    .sorted { $0.updatedAt > $1.updatedAt }
  }

  public func delete(id: UUID) throws {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AIReasoningCoreError(.persistenceFailure, "conversation not found: \(id)")
    }
    try FileManager.default.removeItem(at: url)
  }

  private func fileURL(for id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString).appendingPathExtension("conversation")
  }
}
