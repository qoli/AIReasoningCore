import AnyLanguageModel
import Foundation

public struct BrowserCommand: Sendable, Equatable {
  public enum Action: String, Sendable, Equatable {
    case open
    case read
    case click
    case type
    case snapshot
    case waitForNavigation
  }

  public let action: Action
  public let target: String?
  public let value: String?

  public init(action: Action, target: String? = nil, value: String? = nil) {
    self.action = action
    self.target = target
    self.value = value
  }
}

public struct BrowserResult: Sendable, Equatable {
  public let text: String
  public let snapshot: GeneratedImage?

  public init(text: String, snapshot: GeneratedImage? = nil) {
    self.text = text
    self.snapshot = snapshot
  }
}

public struct BrowserOperator: Sendable {
  private let implementation: @Sendable (BrowserCommand) async throws -> BrowserResult

  public init(
    perform: @escaping @Sendable (BrowserCommand) async throws -> BrowserResult
  ) {
    self.implementation = perform
  }

  public func perform(_ command: BrowserCommand) async throws -> BrowserResult {
    try await implementation(command)
  }
}

public struct BrowserTool: Tool {
  @Generable
  public struct Arguments {
    public let action: String
    public let target: String?
    public let value: String?
  }

  public let name = "browser"
  public let description =
    "Operate the app-owned browser: open, read, click, type, snapshot, or wait for navigation."

  private let browser: BrowserOperator
  private let assets: AssetStore

  public init(browser: BrowserOperator, assets: AssetStore) {
    self.browser = browser
    self.assets = assets
  }

  public func call(arguments: Arguments) async throws -> String {
    guard let action = BrowserCommand.Action(rawValue: arguments.action) else {
      throw AIReasoningCoreError(
        .unsupportedOperation,
        "unsupported browser action: \(arguments.action)"
      )
    }
    let result = try await browser.perform(
      BrowserCommand(action: action, target: arguments.target, value: arguments.value)
    )
    guard let snapshot = result.snapshot else { return result.text }
    let asset = try await assets.save(
      kind: .image,
      mimeType: snapshot.mimeType,
      data: snapshot.data
    )
    return result.text + "\nasset://\(asset.id)"
  }
}
