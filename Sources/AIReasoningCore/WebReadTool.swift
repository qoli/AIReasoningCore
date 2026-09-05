import AnyLanguageModel
import Foundation

public struct WebReadTool: Tool {
  @Generable
  public struct Arguments {
    public let url: String
  }

  public let name = "web_read"
  public let description =
    "Read a public web page and return visible text without running page scripts."

  private let client: HTTPClient
  private let policy: HTTPAccessPolicy
  private let maximumResponseBytes: Int
  private let maximumTextCharacters: Int

  public init(
    client: HTTPClient = .urlSession(),
    policy: HTTPAccessPolicy = .publicHTTPS,
    maximumResponseBytes: Int = 2_000_000,
    maximumTextCharacters: Int = 100_000
  ) {
    self.client = client
    self.policy = policy
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumTextCharacters = maximumTextCharacters
  }

  public func call(arguments: Arguments) async throws -> String {
    guard let url = URL(string: arguments.url) else {
      throw AIReasoningCoreError(.invalidURL, "invalid URL: \(arguments.url)")
    }
    try policy.validate(url)
    let response = try await client.send(
      HTTPRequest(
        method: "GET",
        url: url,
        headers: ["Accept": "text/html,text/plain,application/xhtml+xml"],
        maximumResponseBytes: maximumResponseBytes
      )
    )
    try policy.validate(response.finalURL)
    guard response.body.count <= maximumResponseBytes else {
      throw AIReasoningCoreError(
        .responseTooLarge,
        "web response exceeded \(maximumResponseBytes) bytes"
      )
    }
    guard let source = String(data: response.body, encoding: .utf8) else {
      throw AIReasoningCoreError(.invalidProviderResponse, "web response is not UTF-8")
    }
    let text = Self.visibleText(from: source)
    guard text.count <= maximumTextCharacters else {
      throw AIReasoningCoreError(
        .responseTooLarge,
        "extracted web text exceeded \(maximumTextCharacters) characters"
      )
    }
    return text
  }

  static func visibleText(from html: String) -> String {
    var value = html
    let patterns = [
      "(?is)<script\\b[^>]*>.*?</script>",
      "(?is)<style\\b[^>]*>.*?</style>",
      "(?is)<[^>]+>",
    ]
    for pattern in patterns {
      value = value.replacingOccurrences(
        of: pattern,
        with: " ",
        options: .regularExpression
      )
    }
    let entities = [
      "&nbsp;": " ",
      "&amp;": "&",
      "&lt;": "<",
      "&gt;": ">",
      "&quot;": "\"",
      "&#39;": "'",
    ]
    for (entity, replacement) in entities {
      value = value.replacingOccurrences(of: entity, with: replacement)
    }
    return
      value
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
  }
}
