import AnyLanguageModel
import Foundation
import XCTest

@testable import AIReasoningCore

final class ReadLimitsTests: XCTestCase {
  func testHTTPAndWebToolsCancelOversizedResponseBeforeEOF() async throws {
    for isWeb in [false, true] {
      let url = URL(string: "https://read-limit.test/hanging/\(UUID())")!
      let stopped = expectation(forNotification: Notification.Name(url.absoluteString), object: nil)
      let completed = expectation(description: "tool rejects before response finishes")
      let session = makeSession()
      defer { session.invalidateAndCancel() }
      let client = HTTPClient.urlSession(session)
      let task = Task {
        defer { completed.fulfill() }
        do {
          if isWeb {
            let tool = WebReadTool(client: client, maximumResponseBytes: 8)
            _ = try await tool.call(
              arguments: .init(GeneratedContent(properties: ["url": url.absoluteString])))
          } else {
            let tool = HTTPTool(client: client, maximumResponseBytes: 8)
            _ = try await tool.call(
              arguments: .init(
                GeneratedContent(properties: [
                  "url": url.absoluteString,
                  "method": "GET",
                  "headersJSON": nil as String?,
                  "body": nil as String?,
                ])))
          }
          XCTFail("expected responseTooLarge")
        } catch let error as AIReasoningCoreError {
          XCTAssertEqual(error.code, .responseTooLarge)
        } catch {
          XCTFail("unexpected error: \(error)")
        }
      }
      await fulfillment(of: [completed, stopped], timeout: 5)
      task.cancel()
      await task.value
    }
  }

  func testURLSessionAcceptsExactLimitAndEmptyBody() async throws {
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    for limit in [0, 9] {
      let response = try await HTTPClient.urlSession(session).send(
        HTTPRequest(
          method: "GET",
          url: URL(string: "https://read-limit.test/complete/\(limit)")!,
          maximumResponseBytes: limit))
      XCTAssertEqual(response.body, Data(repeating: 65, count: limit))
      XCTAssertEqual(response.statusCode, 200)
    }
  }

  func testInjectedTransportReceivesLimitAndCannotReturnOversizedBody() async throws {
    let client = HTTPClient { request in
      XCTAssertEqual(request.maximumResponseBytes, 8)
      return HTTPResponse(
        statusCode: 200, headers: [:], body: Data(repeating: 65, count: 9),
        finalURL: request.url)
    }
    do {
      _ = try await client.send(
        HTTPRequest(
          method: "GET", url: URL(string: "https://read-limit.test/")!, maximumResponseBytes: 8))
      XCTFail("expected responseTooLarge")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .responseTooLarge)
    }
  }

  func testDocumentReadByteBoundariesAndLargeSparseFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let tool = try DocumentTool(root: root, maximumReadBytes: 8)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("document.txt")
    let arguments = try DocumentTool.Arguments(
      GeneratedContent(properties: [
        "operation": "read", "path": "document.txt", "content": nil as String?,
      ]))
    // The limit is bytes, not characters. Four of these characters occupy eight bytes.
    try Data("éééé".utf8).write(to: file)
    let text = try await tool.call(arguments: arguments)
    XCTAssertEqual(text, "éééé")
    for count in [9, 1_073_741_824] {
      let handle = try FileHandle(forWritingTo: file)
      try handle.truncate(atOffset: UInt64(count))
      try handle.close()
      do {
        _ = try await tool.call(arguments: arguments)
        XCTFail("expected responseTooLarge for \(count) bytes")
      } catch let error as AIReasoningCoreError {
        XCTAssertEqual(error.code, .responseTooLarge)
      }
    }
    let emptyOnly = try DocumentTool(root: root, maximumReadBytes: 0)
    try Data().write(to: file)
    let empty = try await emptyOnly.call(arguments: arguments)
    XCTAssertEqual(empty, "")
    try Data([65]).write(to: file)
    do {
      _ = try await emptyOnly.call(arguments: arguments)
      XCTFail("a zero limit must reject nonempty content")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .responseTooLarge)
    }
  }

  func testNegativeLimitsFailBeforeIO() async throws {
    let client = HTTPClient { _ in
      XCTFail("invalid limit must be rejected before sending")
      throw URLError(.unknown)
    }
    do {
      _ = try await client.send(
        HTTPRequest(
          method: "GET", url: URL(string: "https://read-limit.test/")!, maximumResponseBytes: -1))
      XCTFail("expected invalid limit failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .unsupportedOperation)
    }
    XCTAssertThrowsError(
      try DocumentTool(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        maximumReadBytes: -1))
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadLimitProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class ReadLimitProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "read-limit.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/plain"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if url.path.hasPrefix("/hanging/") {
      // URLSession buffers small URLProtocol payloads before delivering headers.
      // Supply a full chunk but no Content-Length or EOF: the client must reject
      // the overflow and cancel without waiting for this response to finish.
      client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 65_536))
    } else {
      let count = Int(url.lastPathComponent)!
      if count > 0 {
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: count))
      }
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {
    NotificationCenter.default.post(
      name: Notification.Name(request.url!.absoluteString), object: nil)
  }
}
