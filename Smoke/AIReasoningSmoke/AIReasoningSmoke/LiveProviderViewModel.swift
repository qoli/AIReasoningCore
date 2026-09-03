// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AnyLanguageModel
import Foundation
import PhotosUI
import PiAIProviderRuntime
import SwiftUI
import UIKit

@MainActor
final class LiveProviderViewModel: ObservableObject {
  @Published private(set) var providers: [ProviderDescriptor] = []
  @Published var selectedProviderID = "" {
    didSet { if selectedProviderID != oldValue { reasoningEffort = nil } }
  }
  @Published var selectedModelID = "" {
    didSet { if selectedModelID != oldValue { reasoningEffort = nil } }
  }
  @Published var selectedAuthorizationMethodID = ""

  @Published var apiKey = ""
  @Published var baseURL = ""
  @Published var credentialMetadataJSON = "{}"
  @Published var providerOptionsJSON = "{}"
  @Published var toolChoiceJSON = ""
  @Published var prompt = "Reply with a short greeting."
  @Published var imagePrompt = "A small blue robot reading Swift code, clean icon style."
  @Published var maximumOutputTokens = "256"
  @Published var temperatureEnabled = false
  @Published var temperature = "0"
  @Published var reasoningEffort: ProviderReasoningEffort?
  @Published var sessionID = ""
  @Published var serviceTier = ""
  @Published var cacheRetention: ProviderCacheRetention = .short

  @Published private(set) var credentialStatus = "Not connected"
  @Published private(set) var authorizationStatus = ""
  @Published private(set) var authorizationPresentation: LiveAuthorizationPresentation?
  @Published var authorizationInput = ""
  @Published private(set) var isLoadingCatalog = false
  @Published private(set) var isAuthorizing = false
  @Published private(set) var runningTask: LiveProviderTask?
  @Published private(set) var results: [LiveProviderResult] = []
  @Published private(set) var selectedImage: UIImage?
  @Published private(set) var selectedImageData: Data?
  @Published private(set) var selectedImageMIMEType: String?
  @Published private(set) var generatedImage: UIImage?

  private var credentialStore: KeychainProviderCredentialStore?
  private var runtime: BuiltinProviderRuntime?
  private var assets: AssetStore?
  private var authorizationTask: Task<Void, Never>?
  private var challengeContinuation: CheckedContinuation<AuthorizationResponse, any Error>?
  private var authorizationSecret: String?

  var selectedProvider: ProviderDescriptor? {
    providers.first { $0.id == selectedProviderID }
  }

  var availableModels: [ProviderModel] {
    selectedProvider?.models ?? []
  }

  var selectedModel: ProviderModel? {
    availableModels.first { $0.id == selectedModelID }
  }

  var supportedReasoningEfforts: [ProviderReasoningEffort] {
    selectedModel?.supportedReasoningEfforts ?? []
  }

  var authorizationMethods: [AuthorizationMethodDescriptor] {
    selectedProvider?.authorizationMethods ?? []
  }

  var selectedAuthorizationMethod: AuthorizationMethodDescriptor? {
    authorizationMethods.first { $0.id == selectedAuthorizationMethodID }
  }

  var isBusy: Bool {
    isLoadingCatalog || isAuthorizing || runningTask != nil
  }

  func loadCatalog() {
    guard !isLoadingCatalog else { return }
    Task { await performLoadCatalog() }
  }

  func selectProvider(_ providerID: String) {
    selectedProviderID = providerID
    guard let provider = selectedProvider else {
      selectedModelID = ""
      selectedAuthorizationMethodID = ""
      credentialStatus = "Not connected"
      return
    }
    if !provider.models.contains(where: { $0.id == selectedModelID }) {
      selectedModelID = provider.models.first?.id ?? ""
    }
    if !provider.authorizationMethods.contains(where: {
      $0.id == selectedAuthorizationMethodID
    }) {
      selectedAuthorizationMethodID = provider.authorizationMethods.first?.id ?? ""
    }
    Task { await refreshCredentialStatus() }
  }

  func selectAuthorizationMethod(_ methodID: String) {
    selectedAuthorizationMethodID = methodID
  }

  func connect() {
    guard authorizationTask == nil else { return }
    authorizationTask = Task { [weak self] in
      await self?.performConnect()
    }
  }

  func logout() {
    guard authorizationTask == nil else { return }
    authorizationTask = Task { [weak self] in
      await self?.performLogout()
    }
  }

  func cancelAuthorization() {
    authorizationTask?.cancel()
    authorizationTask = nil
    finishChallenge(throwing: CancellationError())
    authorizationPresentation = nil
    authorizationStatus = "Authorization cancelled"
    isAuthorizing = false
  }

  func submitAuthorizationInput() {
    guard let presentation = authorizationPresentation else { return }
    let input = authorizationInput.trimmingCharacters(in: .whitespacesAndNewlines)
    switch presentation.responseKind {
    case .value:
      guard !input.isEmpty else {
        authorizationStatus = "A response value is required"
        return
      }
      finishChallenge(returning: .value(input))
    case .callbackURL:
      guard let url = URL(string: input), url.scheme != nil else {
        authorizationStatus = "A complete callback URL is required"
        return
      }
      finishChallenge(returning: .callbackURL(url))
    case .information:
      return
    }
    authorizationInput = ""
    authorizationPresentation = nil
  }

  func receiveOAuthCallback(_ url: URL) {
    guard authorizationPresentation?.responseKind == .callbackURL else { return }
    finishChallenge(returning: .callbackURL(url))
    authorizationInput = ""
    authorizationPresentation = nil
  }

  func loadPhoto(_ item: PhotosPickerItem?) {
    guard let item else {
      selectedImage = nil
      selectedImageData = nil
      selectedImageMIMEType = nil
      return
    }
    Task {
      do {
        guard let data = try await item.loadTransferable(type: Data.self),
          let image = UIImage(data: data)
        else {
          throw LiveSmokeFailure("The selected photo is not a decodable image")
        }
        selectedImageData = data
        selectedImage = image
        selectedImageMIMEType = Self.detectMIMEType(data)
      } catch {
        authorizationStatus = safeDescription(error)
      }
    }
  }

  func createFixtureImage() {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
    let image = renderer.image { context in
      UIColor.systemIndigo.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
      UIColor.systemYellow.setFill()
      context.cgContext.fillEllipse(in: CGRect(x: 64, y: 64, width: 128, height: 128))
    }
    guard let data = image.pngData() else {
      authorizationStatus = "Could not encode the explicit fixture image"
      return
    }
    selectedImage = image
    selectedImageData = data
    selectedImageMIMEType = "image/png"
  }

  func run(_ task: LiveProviderTask) {
    guard runningTask == nil else { return }
    Task { await perform(task) }
  }

  func clearResults() {
    results = []
    generatedImage = nil
  }

  private func configureIfNeeded() throws {
    if runtime != nil, credentialStore != nil, assets != nil { return }
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw LiveSmokeFailure("Application Support directory is unavailable")
    }
    let root = applicationSupport.appendingPathComponent(
      "AIReasoningSmokeLive",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try KeychainProviderCredentialStore(
      service: "org.aireasoningcore.smoke.providers"
    )
    credentialStore = store
    runtime = try BuiltinProviderRuntime(
      credentialStore: store,
      radiusCatalogPersistenceURL: root.appendingPathComponent("RadiusCatalog.json")
    )
    assets = try AssetStore(
      directory: root.appendingPathComponent("Assets", isDirectory: true)
    )
  }

  private func performLoadCatalog() async {
    isLoadingCatalog = true
    defer { isLoadingCatalog = false }
    do {
      try configureIfNeeded()
      guard let runtime else { throw LiveSmokeFailure("Provider runtime is unavailable") }
      providers = try await runtime.catalog().providers
      if selectedProviderID.isEmpty {
        selectedProviderID = providers.first?.id ?? ""
      }
      selectProvider(selectedProviderID)
      authorizationStatus = "Loaded \(providers.count) providers"
    } catch {
      authorizationStatus = safeDescription(error)
    }
  }

  private func performConnect() async {
    isAuthorizing = true
    defer {
      isAuthorizing = false
      authorizationTask = nil
      authorizationSecret = nil
    }
    do {
      try configureIfNeeded()
      guard let runtime, let credentialStore else {
        throw LiveSmokeFailure("Provider runtime is unavailable")
      }
      guard let provider = selectedProvider else {
        throw LiveSmokeFailure("Select a provider before connecting")
      }
      guard let method = selectedAuthorizationMethod else {
        throw LiveSmokeFailure("Select an authorization method before connecting")
      }
      if method.kind == .apiKey {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
          throw LiveSmokeFailure("API key is required")
        }
        authorizationSecret = normalized
      }
      authorizationStatus = "Connecting \(provider.name)…"
      let state = try await runtime.authorize(
        .login(providerID: provider.id, methodID: method.id),
        interaction: { [weak self] challenge in
          guard let self else { throw CancellationError() }
          return try await self.respond(to: challenge)
        }
      )
      if method.kind == .apiKey {
        let metadata = try credentialMetadata()
        if !metadata.isEmpty {
          _ = try await credentialStore.modify(providerID: provider.id) { current in
            guard case .apiKey(let credential) = current else {
              throw LiveSmokeFailure("API-key authorization did not persist an API key")
            }
            return .apiKey(APIKeyCredential(key: credential.key, metadata: metadata))
          }
        }
        apiKey = ""
      }
      guard case .connected = state else {
        throw LiveSmokeFailure("Authorization did not reach connected state")
      }
      authorizationPresentation = nil
      authorizationStatus = "Connected to \(provider.name)"
      await refreshCredentialStatus()
      providers = try await runtime.catalog().providers
      selectProvider(provider.id)
    } catch is CancellationError {
      authorizationStatus = "Authorization cancelled"
    } catch {
      authorizationStatus = safeDescription(error)
    }
  }

  private func performLogout() async {
    isAuthorizing = true
    defer {
      isAuthorizing = false
      authorizationTask = nil
    }
    do {
      try configureIfNeeded()
      guard let runtime, let provider = selectedProvider else {
        throw LiveSmokeFailure("Select a provider before logging out")
      }
      _ = try await runtime.authorize(
        .logout(providerID: provider.id),
        interaction: { _ in .acknowledged }
      )
      authorizationStatus = "Disconnected from \(provider.name)"
      authorizationPresentation = nil
      await refreshCredentialStatus()
    } catch {
      authorizationStatus = safeDescription(error)
    }
  }

  private func respond(to challenge: AuthorizationChallenge) async throws
    -> AuthorizationResponse
  {
    try Task.checkCancellation()
    switch challenge {
    case .progress(_, let message):
      authorizationStatus = message
      return .acknowledged
    case .deviceCode(let providerID, let userCode, let url, _, _):
      authorizationPresentation = LiveAuthorizationPresentation(
        providerID: providerID,
        title: "Device authorization",
        message: "Enter this code in the opened provider page.",
        responseKind: .information,
        url: url,
        userCode: userCode
      )
      authorizationStatus = "Waiting for device authorization"
      _ = await UIApplication.shared.open(url)
      return .acknowledged
    case .openURL(let providerID, let url, _):
      authorizationPresentation = LiveAuthorizationPresentation(
        providerID: providerID,
        title: "Browser authorization",
        message:
          "Complete sign-in, then return through the app callback or paste the callback URL.",
        responseKind: .callbackURL,
        url: url,
        userCode: nil
      )
      authorizationStatus = "Waiting for browser callback"
      _ = await UIApplication.shared.open(url)
      return try await awaitChallengeResponse()
    case .prompt(let providerID, _, let message, let kind):
      if kind == .secret, let authorizationSecret {
        return .value(authorizationSecret)
      }
      authorizationPresentation = LiveAuthorizationPresentation(
        providerID: providerID,
        title: "Provider input",
        message: message,
        responseKind: .value(kind),
        url: nil,
        userCode: nil
      )
      authorizationStatus = "Provider input required"
      return try await awaitChallengeResponse()
    }
  }

  private func awaitChallengeResponse() async throws -> AuthorizationResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard challengeContinuation == nil else {
          continuation.resume(
            throwing: LiveSmokeFailure("An authorization challenge is already pending")
          )
          return
        }
        challengeContinuation = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finishChallenge(throwing: CancellationError())
      }
    }
  }

  private func finishChallenge(returning response: AuthorizationResponse) {
    let continuation = challengeContinuation
    challengeContinuation = nil
    continuation?.resume(returning: response)
  }

  private func finishChallenge(throwing error: any Error) {
    let continuation = challengeContinuation
    challengeContinuation = nil
    continuation?.resume(throwing: error)
  }

  private func refreshCredentialStatus() async {
    guard let credentialStore, !selectedProviderID.isEmpty else {
      credentialStatus = "Not connected"
      return
    }
    do {
      switch try await credentialStore.read(providerID: selectedProviderID) {
      case .apiKey:
        credentialStatus = "API key stored in Keychain"
      case .oauth(let credential):
        credentialStatus =
          "OAuth stored in Keychain · expires \(credential.expiresAt.formatted())"
      case nil:
        credentialStatus = "Not connected"
      }
    } catch {
      credentialStatus = safeDescription(error)
    }
  }

  private func perform(_ task: LiveProviderTask) async {
    runningTask = task
    generatedImage = nil
    var result = LiveProviderResult(
      id: UUID(),
      task: task,
      providerID: selectedProviderID,
      modelID: selectedModelID,
      startedAt: Date(),
      finishedAt: nil,
      status: .running,
      detail: "Running"
    )
    results.insert(result, at: 0)
    defer { runningTask = nil }

    do {
      try configureIfNeeded()
      guard let runtime, let model = selectedModel, let assets else {
        throw LiveSmokeFailure("Select a provider and model before running a task")
      }
      let detail: String
      switch task {
      case .textStream:
        detail = try await runTextStream(runtime: runtime, model: model, assets: assets)
      case .structuredOutput:
        detail = try await runStructuredOutput(runtime: runtime, model: model, assets: assets)
      case .functionCall:
        detail = try await runFunctionCall(runtime: runtime, model: model, assets: assets)
      case .imageInput:
        detail = try await runImageInput(runtime: runtime, model: model, assets: assets)
      case .imageGeneration:
        detail = try await runImageGeneration(runtime: runtime, model: model, assets: assets)
      }
      result.status = .passed
      result.detail = detail
    } catch {
      result.status = .failed
      result.detail = safeDescription(error)
    }
    result.finishedAt = Date()
    if let index = results.firstIndex(where: { $0.id == result.id }) {
      results[index] = result
    }
  }

  private func runTextStream(
    runtime: BuiltinProviderRuntime,
    model: ProviderModel,
    assets: AssetStore
  ) async throws -> String {
    guard model.capabilities.textInput else {
      throw LiveSmokeFailure("Selected model does not support text input")
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(
        runtime: runtime,
        providerID: model.providerID,
        modelID: model.id,
        assets: assets
      )
    )
    var snapshots = 0
    var final = ""
    for try await snapshot in session.streamResponse(
      to: prompt,
      options: try generationOptions(outputModality: .text)
    ) {
      snapshots += 1
      final = snapshot.content
    }
    guard snapshots > 0, !final.isEmpty else {
      throw LiveSmokeFailure("Text stream completed without visible content")
    }
    return "\(snapshots) snapshots · \(Self.limit(final))"
  }

  private func runFunctionCall(
    runtime: BuiltinProviderRuntime,
    model: ProviderModel,
    assets: AssetStore
  ) async throws -> String {
    guard model.capabilities.toolCalling else {
      throw LiveSmokeFailure("Selected model does not support tool calling")
    }
    let recorder = LiveEchoRecorder()
    let session = LanguageModelSession(
      model: PiAILanguageModel(
        runtime: runtime,
        providerID: model.providerID,
        modelID: model.id,
        assets: assets
      ),
      tools: [LiveEchoTool(recorder: recorder)]
    )
    let response = try await session.respond(
      to: "Call the echo tool exactly once with value live-ok, then confirm completion.",
      options: try generationOptions(outputModality: .text)
    )
    let values = await recorder.values
    guard values == ["live-ok"] else {
      throw LiveSmokeFailure("Provider did not execute echo exactly once with live-ok")
    }
    guard session.transcript.contains(where: { if case .toolCalls = $0 { true } else { false } }),
      session.transcript.contains(where: { if case .toolOutput = $0 { true } else { false } })
    else {
      throw LiveSmokeFailure("Session transcript did not preserve the tool loop")
    }
    return "echo(live-ok) → \(Self.limit(response.content))"
  }

  private func runStructuredOutput(
    runtime: BuiltinProviderRuntime,
    model: ProviderModel,
    assets: AssetStore
  ) async throws -> String {
    guard model.capabilities.structuredOutput else {
      throw LiveSmokeFailure("Selected model does not support structured output")
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(
        runtime: runtime,
        providerID: model.providerID,
        modelID: model.id,
        assets: assets
      )
    )
    let response = try await session.respond(
      to: "Return status exactly live-ok and count exactly 1.",
      generating: LiveStructuredAnswer.self,
      options: try generationOptions(outputModality: .text)
    )
    guard response.content.status == "live-ok", response.content.count == 1 else {
      throw LiveSmokeFailure(
        "Structured response did not contain status live-ok and count 1"
      )
    }
    return "{\"status\":\"live-ok\",\"count\":1}"
  }

  private func runImageInput(
    runtime: BuiltinProviderRuntime,
    model: ProviderModel,
    assets: AssetStore
  ) async throws -> String {
    guard model.capabilities.imageInput else {
      throw LiveSmokeFailure("Selected model does not support image input")
    }
    guard let selectedImageData, let selectedImageMIMEType else {
      throw LiveSmokeFailure("Select or explicitly create an input image first")
    }
    let transcript = Transcript(entries: [
      .prompt(
        Transcript.Prompt(segments: [
          .text(.init(content: prompt)),
          .image(.init(data: selectedImageData, mimeType: selectedImageMIMEType)),
        ])
      )
    ])
    let session = LanguageModelSession(
      model: PiAILanguageModel(
        runtime: runtime,
        providerID: model.providerID,
        modelID: model.id,
        assets: assets
      ),
      transcript: transcript
    )
    let response = try await session.respond(
      to: "Describe the supplied image briefly.",
      options: try generationOptions(outputModality: .text)
    )
    guard !response.content.isEmpty else {
      throw LiveSmokeFailure("Image-input response contained no text")
    }
    return Self.limit(response.content)
  }

  private func runImageGeneration(
    runtime: BuiltinProviderRuntime,
    model: ProviderModel,
    assets: AssetStore
  ) async throws -> String {
    guard model.capabilities.imageGeneration else {
      throw LiveSmokeFailure("Selected model does not support image generation")
    }
    let options = try providerOptions(
      outputModality: .image,
      toolChoice: nil
    )
    let generator = ImageGenerator { [providerID = model.providerID, modelID = model.id] prompt in
      let request = ProviderRequest(
        id: UUID().uuidString,
        providerID: providerID,
        modelID: modelID,
        messages: [.user([.text(prompt)])],
        tools: [],
        options: options
      )
      var started = false
      var completed = false
      var images: [ProviderAsset] = []
      for try await event in runtime.stream(request) {
        switch event {
        case .responseStarted: started = true
        case .asset(let asset) where asset.kind == .image: images.append(asset)
        case .completed: completed = true
        default: break
        }
      }
      guard started, completed, images.count == 1 else {
        throw LiveSmokeFailure(
          "Image provider must emit exactly one image between start and completion"
        )
      }
      return GeneratedImage(data: images[0].data, mimeType: images[0].mimeType)
    }
    let tool = ImageGenerationTool(generator: generator, assets: assets)
    let reference = try await tool.call(
      arguments: try ImageGenerationTool.Arguments(
        GeneratedContent(properties: ["prompt": imagePrompt])
      )
    )
    guard reference.hasPrefix("asset://") else {
      throw LiveSmokeFailure("Image tool did not return an asset reference")
    }
    let assetID = String(reference.dropFirst("asset://".count))
    let data = try await assets.data(id: assetID)
    guard let image = UIImage(data: data) else {
      throw LiveSmokeFailure("Generated provider asset is not a decodable image")
    }
    generatedImage = image
    return "\(data.count) bytes · asset://\(assetID)"
  }

  private func generationOptions(
    outputModality: ProviderOutputModality
  ) throws -> GenerationOptions {
    let providerOptions = try providerOptions(
      outputModality: outputModality,
      toolChoice: try optionalJSONValue(toolChoiceJSON)
    )
    var options = GenerationOptions(
      temperature: try parsedTemperature(),
      maximumResponseTokens: try parsedMaximumTokens()
    )
    options[custom: PiAILanguageModel.self] = .init(
      reasoningEffort: reasoningEffort,
      providerOptions: try parsedJSONObject(providerOptionsJSON, field: "Provider options"),
      outputModality: providerOptions.outputModality,
      sessionID: sessionID.nilIfEmpty,
      cacheRetention: cacheRetention,
      serviceTier: serviceTier.nilIfEmpty,
      toolChoice: providerOptions.toolChoice
    )
    return options
  }

  private func providerOptions(
    outputModality: ProviderOutputModality,
    toolChoice: PiAIProviderRuntime.JSONValue?
  ) throws -> ProviderGenerationOptions {
    ProviderGenerationOptions(
      maximumOutputTokens: try parsedMaximumTokens(),
      temperature: try parsedTemperature(),
      reasoningEffort: reasoningEffort,
      responseSchema: nil,
      providerOptions: try parsedJSONObject(providerOptionsJSON, field: "Provider options"),
      outputModality: outputModality,
      sessionID: sessionID.nilIfEmpty,
      cacheRetention: cacheRetention,
      serviceTier: serviceTier.nilIfEmpty,
      toolChoice: toolChoice
    )
  }

  private func parsedMaximumTokens() throws -> Int? {
    let raw = maximumOutputTokens.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    guard let value = Int(raw), value > 0 else {
      throw LiveSmokeFailure("Maximum output tokens must be a positive integer")
    }
    return value
  }

  private func parsedTemperature() throws -> Double? {
    guard temperatureEnabled else { return nil }
    let raw = temperature.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Double(raw), (0...1).contains(value) else {
      throw LiveSmokeFailure("Temperature must be between 0 and 1")
    }
    return value
  }

  private func credentialMetadata() throws -> [String: String] {
    let raw = credentialMetadataJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    let data = Data(raw.utf8)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LiveSmokeFailure("Credential metadata must be a JSON object")
    }
    var result: [String: String] = [:]
    for (key, value) in object {
      guard let value = value as? String else {
        throw LiveSmokeFailure("Credential metadata values must all be strings")
      }
      result[key] = value
    }
    if let baseURL = baseURL.nilIfEmpty {
      guard let url = URL(string: baseURL),
        let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        url.host != nil
      else {
        throw LiveSmokeFailure("Base URL must be a complete HTTP or HTTPS URL")
      }
      result["baseURL"] = baseURL
    }
    return result
  }

  private func parsedJSONObject(
    _ raw: String,
    field: String
  ) throws -> [String: PiAIProviderRuntime.JSONValue] {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [:] }
    let value = try JSONDecoder().decode(
      PiAIProviderRuntime.JSONValue.self,
      from: Data(normalized.utf8)
    )
    guard case .object(let object) = value else {
      throw LiveSmokeFailure("\(field) must be a JSON object")
    }
    return object
  }

  private func optionalJSONValue(
    _ raw: String
  ) throws -> PiAIProviderRuntime.JSONValue? {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return try JSONDecoder().decode(
      PiAIProviderRuntime.JSONValue.self,
      from: Data(normalized.utf8)
    )
  }

  private func safeDescription(_ error: any Error) -> String {
    if let failure = error as? ProviderRuntimeFailure {
      let operation = failure.operation.map { " · \($0)" } ?? ""
      return "\(failure.code.rawValue)\(operation): \(failure.message)"
    }
    if let failure = error as? AIReasoningCoreError {
      return "\(failure.code.rawValue): \(failure.message)"
    }
    if error is CancellationError { return "Cancelled" }
    return error.localizedDescription
  }

  private static func limit(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.count > 2_000 ? String(normalized.prefix(2_000)) + "…" : normalized
  }

  private static func detectMIMEType(_ data: Data) -> String {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if data.starts(with: Array("GIF8".utf8)) { return "image/gif" }
    return "image/webp"
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}
