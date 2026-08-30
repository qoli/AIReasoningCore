import AnyLanguageModel
import Foundation

public struct GeneratedImage: Sendable, Equatable {
  public let data: Data
  public let mimeType: String

  public init(data: Data, mimeType: String) {
    self.data = data
    self.mimeType = mimeType
  }
}

public struct ImageGenerator: Sendable {
  private let implementation: @Sendable (String) async throws -> GeneratedImage

  public init(
    generate: @escaping @Sendable (String) async throws -> GeneratedImage
  ) {
    self.implementation = generate
  }

  public func generate(prompt: String) async throws -> GeneratedImage {
    try await implementation(prompt)
  }
}

public struct ImageGenerationTool: Tool {
  @Generable
  public struct Arguments {
    public let prompt: String
  }

  public let name = "image_generate"
  public let description = "Generate an image from a text prompt and save it as a managed asset."

  private let generator: ImageGenerator
  private let assets: AssetStore

  public init(generator: ImageGenerator, assets: AssetStore) {
    self.generator = generator
    self.assets = assets
  }

  public func call(arguments: Arguments) async throws -> String {
    let image = try await generator.generate(prompt: arguments.prompt)
    let asset = try await assets.save(
      kind: .image,
      mimeType: image.mimeType,
      data: image.data
    )
    return "asset://\(asset.id)"
  }
}
