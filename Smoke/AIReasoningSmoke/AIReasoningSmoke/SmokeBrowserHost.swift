// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import SwiftUI
import WebKit

@MainActor
final class SmokeBrowserHost: NSObject, WKNavigationDelegate {
  let webView: WKWebView

  private var navigationContinuation: CheckedContinuation<Void, any Error>?

  override init() {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    webView = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 300), configuration: configuration)
    super.init()
    webView.navigationDelegate = self
  }

  nonisolated var operatorAdapter: BrowserOperator {
    BrowserOperator { [weak self] command in
      guard let self else {
        throw SmokeFailure("browser host was released")
      }
      return try await self.perform(command)
    }
  }

  func perform(_ command: BrowserCommand) async throws -> BrowserResult {
    switch command.action {
    case .open:
      guard command.target == "smoke://interactive" else {
        throw SmokeFailure("smoke browser only accepts smoke://interactive")
      }
      try await loadFixture()
      return BrowserResult(text: "opened smoke://interactive")
    case .read:
      let selector = command.target ?? "body"
      let script = "document.querySelector(\(try javaScriptLiteral(selector)))?.innerText ?? ''"
      let value = try await webView.callAsyncJavaScript(
        "return \(script)", arguments: [:], in: nil, contentWorld: .page
      )
      return BrowserResult(text: value as? String ?? "")
    case .type:
      guard let selector = command.target, let value = command.value else {
        throw SmokeFailure("type requires a selector and value")
      }
      let script = """
        const element = document.querySelector(\(try javaScriptLiteral(selector)));
        if (!element) { return false; }
        element.value = \(try javaScriptLiteral(value));
        element.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
        """
      let result = try await webView.callAsyncJavaScript(
        script, arguments: [:], in: nil, contentWorld: .page
      )
      guard result as? Bool == true else { throw SmokeFailure("type target was not found") }
      return BrowserResult(text: "typed \(selector)")
    case .click:
      guard let selector = command.target else {
        throw SmokeFailure("click requires a selector")
      }
      let script = """
        const element = document.querySelector(\(try javaScriptLiteral(selector)));
        if (!element) { return false; }
        element.click();
        return true;
        """
      let result = try await webView.callAsyncJavaScript(
        script, arguments: [:], in: nil, contentWorld: .page
      )
      guard result as? Bool == true else { throw SmokeFailure("click target was not found") }
      return BrowserResult(text: "clicked \(selector)")
    case .snapshot:
      let image = try await webView.takeSnapshot(configuration: nil)
      guard let data = image.pngData() else {
        throw SmokeFailure("WebKit snapshot could not be encoded as PNG")
      }
      return BrowserResult(
        text: "snapshot complete",
        snapshot: GeneratedImage(data: data, mimeType: "image/png")
      )
    case .waitForNavigation:
      if webView.isLoading {
        try await awaitNavigation()
      }
      return BrowserResult(text: "navigation complete")
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigationContinuation?.resume()
    navigationContinuation = nil
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    navigationContinuation?.resume(throwing: error)
    navigationContinuation = nil
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    navigationContinuation?.resume(throwing: error)
    navigationContinuation = nil
  }

  private func loadFixture() async throws {
    let html = """
      <!doctype html>
      <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body { font: 17px -apple-system; padding: 20px; background: #f4f7fb; }
            input, button { font: inherit; padding: 10px; margin: 5px 0; }
            #result { margin-top: 14px; font-weight: 700; color: #14532d; }
          </style>
        </head>
        <body>
          <h1>Interactive Tool Fixture</h1>
          <p id="status">READY</p>
          <input id="name" aria-label="Name" value="">
          <button id="apply" onclick="document.getElementById('result').textContent = 'Hello ' + document.getElementById('name').value">Apply</button>
          <div id="result">Waiting</div>
        </body>
      </html>
      """
    webView.loadHTMLString(html, baseURL: URL(string: "https://smoke.local/interactive")!)
    try await awaitNavigation()
  }

  private func awaitNavigation() async throws {
    guard navigationContinuation == nil else {
      throw SmokeFailure("a navigation wait is already active")
    }
    try await withCheckedThrowingContinuation { continuation in
      navigationContinuation = continuation
    }
  }

  private func javaScriptLiteral(_ value: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [value])
    guard var encoded = String(data: data, encoding: .utf8) else {
      throw SmokeFailure("failed to encode JavaScript string")
    }
    encoded.removeFirst()
    encoded.removeLast()
    return encoded
  }
}

struct SmokeBrowserView: UIViewRepresentable {
  let host: SmokeBrowserHost

  func makeUIView(context: Context) -> WKWebView {
    host.webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}
}
