import AnyLanguageModel
import Foundation

public struct HTTPTool: Tool {
  @Generable
  public struct Arguments {
    public let method: String
    public let url: String
    public let headersJSON: String?
    public let body: String?
  }

  public let name = "http_request"
  public let description =
    "Send an HTTP request and return its status, headers, and UTF-8 response body."

  private let client: HTTPClient
  private let policy: HTTPAccessPolicy
  private let maximumResponseBytes: Int

  public init(
    client: HTTPClient = .urlSession(),
    policy: HTTPAccessPolicy = .publicHTTPS,
    maximumResponseBytes: Int = 1_000_000
  ) {
    self.client = client
    self.policy = policy
    self.maximumResponseBytes = maximumResponseBytes
  }

  public func call(arguments: Arguments) async throws -> String {
    guard let url = URL(string: arguments.url) else {
      throw AIReasoningCoreError(.invalidURL, "invalid URL: \(arguments.url)")
    }
    try policy.validate(url)
    let headers = try decodeHeaders(arguments.headersJSON)
    let response = try await client.send(
      HTTPRequest(
        method: arguments.method.uppercased(),
        url: url,
        headers: headers,
        body: arguments.body?.data(using: .utf8),
        maximumResponseBytes: maximumResponseBytes
      )
    )
    try policy.validate(response.finalURL)
    guard response.body.count <= maximumResponseBytes else {
      throw AIReasoningCoreError(
        .responseTooLarge,
        "HTTP response exceeded \(maximumResponseBytes) bytes"
      )
    }
    guard let body = String(data: response.body, encoding: .utf8) else {
      throw AIReasoningCoreError(.invalidProviderResponse, "HTTP response body is not UTF-8")
    }
    let result: [String: Any] = [
      "status": response.statusCode,
      "headers": response.headers,
      "body": body,
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw AIReasoningCoreError(.invalidProviderResponse, "failed to encode HTTP response")
    }
    return json
  }

  private func decodeHeaders(_ json: String?) throws -> [String: String] {
    guard let json else { return [:] }
    guard let data = json.data(using: .utf8) else {
      throw AIReasoningCoreError(.invalidProviderResponse, "headersJSON is not UTF-8")
    }
    return try JSONDecoder().decode([String: String].self, from: data)
  }
}
