// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

final class SmokeHTTPProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "smoke.local"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    let statusCode: Int
    let headers: [String: String]
    let body: Data

    switch url.path {
    case "/api":
      statusCode = 201
      headers = ["Content-Type": "application/json; charset=utf-8"]
      let requestBody = String(data: readRequestBody(), encoding: .utf8) ?? ""
      body =
        (try? JSONSerialization.data(
          withJSONObject: [
            "method": request.httpMethod ?? "",
            "body": requestBody,
          ],
          options: [.sortedKeys]
        )) ?? Data()
    case "/page":
      statusCode = 200
      headers = ["Content-Type": "text/html; charset=utf-8"]
      body = Data(
        "<html><head><style>.hidden{display:none}</style><script>bad()</script></head>"
          .appending(
            "<body><h1>Smoke Web</h1><p>Native web read works &amp; is visible.</p></body></html>"
          )
          .utf8
      )
    default:
      statusCode = 404
      headers = ["Content-Type": "text/plain; charset=utf-8"]
      body = Data("not found".utf8)
    }

    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private func readRequestBody() -> Data {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4_096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: bufferSize)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
