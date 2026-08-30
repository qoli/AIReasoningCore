import AnyLanguageModel
import Foundation

public struct AssetManagementTool: Tool {
  @Generable
  public struct Arguments {
    public let operation: String
    public let assetID: String?
  }

  public let name = "asset"
  public let description = "List managed assets or read metadata for one asset."

  private let assets: AssetStore

  public init(assets: AssetStore) {
    self.assets = assets
  }

  public func call(arguments: Arguments) async throws -> String {
    switch arguments.operation {
    case "list":
      let values = try await assets.list()
      let data = try JSONEncoder().encode(values)
      guard let json = String(data: data, encoding: .utf8) else {
        throw AIReasoningCoreError(.invalidProviderResponse, "failed to encode asset list")
      }
      return json
    case "metadata":
      guard let id = arguments.assetID else {
        throw AIReasoningCoreError(.assetNotFound, "metadata requires assetID")
      }
      let value = try await assets.asset(id: id)
      let data = try JSONEncoder().encode(value)
      guard let json = String(data: data, encoding: .utf8) else {
        throw AIReasoningCoreError(.invalidProviderResponse, "failed to encode asset metadata")
      }
      return json
    default:
      throw AIReasoningCoreError(
        .unsupportedOperation,
        "unsupported asset operation: \(arguments.operation)"
      )
    }
  }
}
