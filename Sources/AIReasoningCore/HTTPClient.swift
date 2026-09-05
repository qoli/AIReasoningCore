import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data?
  /// Transports must stop reading when the response body exceeds this limit.
  public let maximumResponseBytes: Int?

  public init(
    method: String,
    url: URL,
    headers: [String: String] = [:],
    body: Data? = nil,
    maximumResponseBytes: Int? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.maximumResponseBytes = maximumResponseBytes
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
    if let limit = request.maximumResponseBytes, limit < 0 {
      throw AIReasoningCoreError(.unsupportedOperation, "maximumResponseBytes must be nonnegative")
    }
    let response = try await sendImplementation(request)
    if let limit = request.maximumResponseBytes, response.body.count > limit {
      throw AIReasoningCoreError(.responseTooLarge, "HTTP response exceeded \(limit) bytes")
    }
    return response
  }

  public static func urlSession(_ session: URLSession = .shared) -> HTTPClient {
    HTTPClient { request in
      var urlRequest = URLRequest(url: request.url)
      urlRequest.httpMethod = request.method
      urlRequest.httpBody = request.body
      for (name, value) in request.headers {
        urlRequest.setValue(value, forHTTPHeaderField: name)
      }
      let (bytes, response) = try await session.bytes(for: urlRequest)
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse else {
        throw AIReasoningCoreError(
          .invalidProviderResponse, "HTTP response was not an HTTPURLResponse")
      }
      guard let finalURL = http.url else {
        throw AIReasoningCoreError(.invalidProviderResponse, "HTTP response has no final URL")
      }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        if let limit = request.maximumResponseBytes, data.count >= limit {
          throw AIReasoningCoreError(.responseTooLarge, "HTTP response exceeded \(limit) bytes")
        }
        data.append(byte)
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

  public init(allowedSchemes: Set<String>) {
    self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
  }

  public static let publicHTTPS = HTTPAccessPolicy(allowedSchemes: ["https"])

  public func validate(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
      throw AIReasoningCoreError(.disallowedURL, "URL scheme is not allowed: \(url.absoluteString)")
    }
  }
}
