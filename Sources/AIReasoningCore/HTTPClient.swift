import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data?

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data
  public let finalURL: URL

  public init(statusCode: Int, headers: [String: String], body: Data, finalURL: URL) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.finalURL = finalURL
  }
}

public struct HTTPClient: Sendable {
  private let sendImplementation: @Sendable (HTTPRequest) async throws -> HTTPResponse

  public init(
    send: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
  ) {
    self.sendImplementation = send
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await sendImplementation(request)
  }

  public static func urlSession(_ session: URLSession = .shared) -> HTTPClient {
    HTTPClient { request in
      var urlRequest = URLRequest(url: request.url)
      urlRequest.httpMethod = request.method
      urlRequest.httpBody = request.body
      for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
      let (data, response) = try await session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse else {
        throw AIReasoningCoreError(
          .invalidProviderResponse, "HTTP response was not an HTTPURLResponse")
      }
      guard let finalURL = http.url else {
        throw AIReasoningCoreError(.invalidProviderResponse, "HTTP response has no final URL")
      }
      var headers: [String: String] = [:]
      for (name, value) in http.allHeaderFields {
        headers[String(describing: name)] = String(describing: value)
      }
      return HTTPResponse(
        statusCode: http.statusCode,
        headers: headers,
        body: data,
        finalURL: finalURL
      )
    }
  }
}

public struct HTTPAccessPolicy: Sendable, Equatable {
  public let allowedSchemes: Set<String>
  public let allowedHosts: Set<String>?

  public init(allowedSchemes: Set<String>, allowedHosts: Set<String>? = nil) {
    self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
    self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
  }

  public static let publicHTTPS = HTTPAccessPolicy(allowedSchemes: ["https"])

  public func validate(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
      throw AIReasoningCoreError(.disallowedURL, "URL scheme is not allowed: \(url.absoluteString)")
    }
    if let allowedHosts {
      guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
        throw AIReasoningCoreError(.disallowedURL, "URL host is not allowed: \(url.absoluteString)")
      }
    }
  }
}
