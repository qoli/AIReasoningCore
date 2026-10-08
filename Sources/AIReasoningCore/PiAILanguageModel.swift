import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

/// Usage reported by one provider request, before a Session combines Tool rounds.
public struct PiAIRequestUsage: Sendable, Equatable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int

  public init(
    inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, reasoningTokens: Int
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
  }
}

public struct PiAILanguageModel: LanguageModel {
  public typealias UnavailableReason = Never

  public struct CustomGenerationOptions: AnyLanguageModel.CustomGenerationOptions {
    public var reasoningEffort: ProviderReasoningEffort?
    public var providerOptions: [String: PiAIProviderRuntime.JSONValue]
    /// Optional caller-owned safety policy for compatibility Tool continuations.
    /// `nil` preserves the Foundation Models contract and does not impose an
    /// arbitrary round limit.
    public var maximumToolIterations: Int?
    public var outputModality: ProviderOutputModality
    public var sessionID: String?
    public var cacheRetention: ProviderCacheRetention
    public var serviceTier: String?
    public var toolChoice: PiAIProviderRuntime.JSONValue?

    public init(
      reasoningEffort: ProviderReasoningEffort? = nil,
      providerOptions: [String: PiAIProviderRuntime.JSONValue] = [:],
      maximumToolIterations: Int? = nil,
      outputModality: ProviderOutputModality = .text,
      sessionID: String? = nil,
      cacheRetention: ProviderCacheRetention = .short,
      serviceTier: String? = nil,
      toolChoice: PiAIProviderRuntime.JSONValue? = nil
    ) {
      self.reasoningEffort = reasoningEffort
      self.providerOptions = providerOptions
      self.maximumToolIterations = maximumToolIterations
      self.outputModality = outputModality
      self.sessionID = sessionID
      self.cacheRetention = cacheRetention
      self.serviceTier = serviceTier
      self.toolChoice = toolChoice
    }
  }

  private let compatibilityDriver: SessionCompatibilityDriver
  let providerAdapter: PiAIProviderAdapter
  let executorID: UUID
  let providerCapabilities: ProviderCapabilities?

  public init(
    runtime: any ProviderRuntime,
    providerID: String,
    modelID: String,
    capabilities: ProviderCapabilities? = nil,
    onAsset: (@Sendable (ProviderAsset) async throws -> Void)? = nil,
    onRequestUsage: (@Sendable (PiAIRequestUsage) -> Void)? = nil
  ) {
    let executorID = UUID()
    let adapter = PiAIProviderAdapter(
      runtime: runtime,
      providerID: providerID,
      modelID: modelID,
      executorID: executorID,
      onAsset: onAsset,
      onRequestUsage: onRequestUsage
    )
    compatibilityDriver = SessionCompatibilityDriver()
    providerAdapter = adapter
    self.executorID = executorID
    providerCapabilities = capabilities
  }

  public func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    try await compatibilityDriver.respond(
      within: session,
      generating: type,
      options: options
    )
  }

  public func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    compatibilityDriver.streamResponse(
      within: session,
      generating: type,
      options: options
    )
  }
}
