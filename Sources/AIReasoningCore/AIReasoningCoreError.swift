import Foundation

public struct AIReasoningCoreError: Error, Sendable, Equatable, LocalizedError {
  public enum Code: String, Sendable, Equatable, Codable {
    case invalidTranscript
    case invalidProviderResponse
    case invalidStructuredOutput
    case unknownTool
    case toolIterationLimitExceeded
    case unhandledProviderAsset
    case unsupportedOperation
  }

  public let code: Code
  public let message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }

  public var errorDescription: String? { message }
}
