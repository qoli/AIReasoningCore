// SPDX-License-Identifier: GPL-3.0-or-later

import PhotosUI
import PiAIProviderRuntime
import SwiftUI

struct ContentView: View {
  private enum Tab: Hashable {
    case deterministic
    case liveProvider
  }

  @StateObject private var smokeViewModel: SmokeViewModel
  @StateObject private var liveViewModel = LiveProviderViewModel()
  @State private var selectedTab: Tab
  private let browserHost: SmokeBrowserHost

  init() {
    let browserHost = SmokeBrowserHost()
    self.browserHost = browserHost
    _smokeViewModel = StateObject(wrappedValue: SmokeViewModel(browserHost: browserHost))
    _selectedTab = State(
      initialValue: ProcessInfo.processInfo.arguments.contains("--live-provider")
        ? .liveProvider : .deterministic
    )
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      DeterministicSmokeView(viewModel: smokeViewModel, browserHost: browserHost)
        .tabItem { Label("Deterministic", systemImage: "checkmark.shield") }
        .tag(Tab.deterministic)

      LiveProviderView(viewModel: liveViewModel)
        .tabItem { Label("Live Provider", systemImage: "network") }
        .tag(Tab.liveProvider)
    }
    .onOpenURL { liveViewModel.receiveOAuthCallback($0) }
  }
}

private struct DeterministicSmokeView: View {
  @ObservedObject var viewModel: SmokeViewModel
  let browserHost: SmokeBrowserHost

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Label(viewModel.summary, systemImage: viewModel.summaryIcon)
              .foregroundStyle(viewModel.summaryColor)
            Spacer()
            if viewModel.isRunning { ProgressView() }
          }
          Button("Run complete smoke suite") { viewModel.run() }
            .disabled(viewModel.isRunning)
            .accessibilityIdentifier("run-smoke-suite")
        } header: {
          Text("Native + Interactive Tools")
        } footer: {
          Text("Deterministic fixtures only. No provider credential or paid API is used.")
        }

        Section("Checks") {
          ForEach(viewModel.checks) { check in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Image(systemName: check.status.symbol).foregroundStyle(check.status.color)
                Text(check.name).font(.headline)
                Spacer()
                Text(check.capability).font(.caption).foregroundStyle(.secondary)
              }
              if !check.detail.isEmpty {
                Text(check.detail)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("smoke-check-\(check.id)")
          }
        }

        Section("App-owned browser") {
          SmokeBrowserView(host: browserHost)
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
            .accessibilityIdentifier("smoke-browser")
        }

        if let preview = viewModel.assetPreview {
          Section("Managed image asset") {
            Image(uiImage: preview)
              .resizable().scaledToFit().frame(maxHeight: 180)
              .accessibilityIdentifier("smoke-asset-preview")
          }
        }

        if let reportURL = viewModel.reportURL {
          Section("Automation evidence") {
            Text(reportURL.path).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      .navigationTitle("Deterministic Smoke")
    }
    .task { await viewModel.runIfNeeded() }
  }
}

private struct LiveProviderView: View {
  @ObservedObject var viewModel: LiveProviderViewModel
  @State private var photoItem: PhotosPickerItem?

  var body: some View {
    NavigationStack {
      Form {
        catalogSection
        credentialSection
        if let presentation = viewModel.authorizationPresentation {
          authorizationSection(presentation)
        }
        generationSection
        imageSection
        tasksSection
        resultsSection
      }
      .navigationTitle("Live Provider Console")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: viewModel.loadCatalog) {
            viewModel.isLoadingCatalog
              ? AnyView(ProgressView()) : AnyView(Image(systemName: "arrow.clockwise"))
          }
          .disabled(viewModel.isBusy)
          .accessibilityLabel("Reload provider catalog")
        }
      }
    }
    .task { if viewModel.providers.isEmpty { viewModel.loadCatalog() } }
    .onChange(of: photoItem) { _, item in viewModel.loadPhoto(item) }
  }

  private var catalogSection: some View {
    Section {
      if viewModel.providers.isEmpty {
        Button("Load provider catalog", action: viewModel.loadCatalog)
          .disabled(viewModel.isLoadingCatalog)
      } else {
        Picker(
          "Provider",
          selection: Binding(
            get: { viewModel.selectedProviderID },
            set: { viewModel.selectProvider($0) }
          )
        ) {
          ForEach(viewModel.providers, id: \.id) {
            Text("\($0.name) · \($0.id)").tag($0.id)
          }
        }
        Picker("Model", selection: $viewModel.selectedModelID) {
          ForEach(viewModel.availableModels, id: \.id) {
            Text("\($0.name) · \($0.id)").tag($0.id)
          }
        }
        if let model = viewModel.selectedModel {
          Text(model.protocolID)
            .font(.caption.monospaced()).foregroundStyle(.secondary)
          CapabilityFlow(model: model)
        } else if let provider = viewModel.selectedProvider, provider.models.isEmpty {
          Text("No published models. Connect and reload if this catalog is dynamic.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Provider + Model")
    } footer: {
      Text("Tasks never switch provider, model, protocol, or endpoint after a failure.")
    }
  }

  private var credentialSection: some View {
    Section {
      if !viewModel.authorizationMethods.isEmpty {
        Picker(
          "Authorization",
          selection: Binding(
            get: { viewModel.selectedAuthorizationMethodID },
            set: { viewModel.selectAuthorizationMethod($0) }
          )
        ) {
          ForEach(viewModel.authorizationMethods, id: \.id) { Text($0.label).tag($0.id) }
        }
      }
      if viewModel.selectedAuthorizationMethod?.kind == .apiKey {
        SecureField("API key", text: $viewModel.apiKey)
          .textContentType(.password).privacySensitive()
      }
      TextField("Base URL override (optional)", text: $viewModel.baseURL)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      DisclosureGroup("Credential metadata JSON") {
        TextEditor(text: $viewModel.credentialMetadataJSON)
          .font(.caption.monospaced()).frame(minHeight: 80).privacySensitive()
      }
      HStack {
        Button(viewModel.selectedAuthorizationMethod?.kind == .oauth ? "Sign in" : "Save key") {
          viewModel.connect()
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.selectedAuthorizationMethod == nil || viewModel.isBusy)
        Button("Logout", role: .destructive, action: viewModel.logout)
          .disabled(viewModel.selectedProvider == nil || viewModel.isBusy)
        if viewModel.isAuthorizing { ProgressView() }
      }
      Label(viewModel.credentialStatus, systemImage: "key.fill").font(.caption)
      if !viewModel.authorizationStatus.isEmpty {
        Text(viewModel.authorizationStatus)
          .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }
    } header: {
      Text("Credential")
    } footer: {
      Text("Secrets use this app's device-only Keychain and never enter SmokeReport.json.")
    }
  }

  private func authorizationSection(_ value: LiveAuthorizationPresentation) -> some View {
    Section("Authorization Challenge") {
      Text(value.title).font(.headline)
      Text(value.message).font(.caption)
      if let code = value.userCode {
        Text(code).font(.title2.monospaced().bold()).textSelection(.enabled)
      }
      if let url = value.url {
        Link(destination: url) { Label("Open provider page", systemImage: "safari") }
        Text(url.absoluteString)
          .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      }
      switch value.responseKind {
      case .value(let kind):
        if kind == .secret {
          SecureField("Response", text: $viewModel.authorizationInput)
        } else {
          TextField("Response", text: $viewModel.authorizationInput)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Button("Submit response", action: viewModel.submitAuthorizationInput)
      case .callbackURL:
        TextField("Paste callback URL", text: $viewModel.authorizationInput)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("Submit callback", action: viewModel.submitAuthorizationInput)
      case .information:
        EmptyView()
      }
      Button("Cancel authorization", role: .cancel, action: viewModel.cancelAuthorization)
    }
  }

  private var generationSection: some View {
    Section("Generation Configuration") {
      Text("Prompt").font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $viewModel.prompt).frame(minHeight: 90)
      TextField(
        "Maximum output tokens (empty = provider default)", text: $viewModel.maximumOutputTokens
      )
      .keyboardType(.numberPad)
      Toggle("Send temperature", isOn: $viewModel.temperatureEnabled)
      if viewModel.temperatureEnabled {
        TextField("Temperature 0…1", text: $viewModel.temperature).keyboardType(.decimalPad)
      }
      Picker("Reasoning effort", selection: $viewModel.reasoningEffort) {
        Text("Provider default").tag("")
        ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) {
          Text($0).tag($0)
        }
      }
      Picker("Cache retention", selection: $viewModel.cacheRetention) {
        Text("None").tag(ProviderCacheRetention.none)
        Text("Short").tag(ProviderCacheRetention.short)
        Text("Long").tag(ProviderCacheRetention.long)
      }
      TextField("Session ID (optional)", text: $viewModel.sessionID)
        .textInputAutocapitalization(.never)
      TextField("Service tier (optional)", text: $viewModel.serviceTier)
        .textInputAutocapitalization(.never)
      DisclosureGroup("Provider options JSON") {
        TextEditor(text: $viewModel.providerOptionsJSON)
          .font(.caption.monospaced()).frame(minHeight: 90)
      }
      DisclosureGroup("Tool choice JSON") {
        TextEditor(text: $viewModel.toolChoiceJSON)
          .font(.caption.monospaced()).frame(minHeight: 70)
        Text(
          "Empty uses the selected provider's default. Enter a provider-native JSON value only when the protocol requires an explicit tool policy."
        )
        .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var imageSection: some View {
    Section("Image Tasks") {
      PhotosPicker(selection: $photoItem, matching: .images) {
        Label("Choose input image", systemImage: "photo.on.rectangle")
      }
      Button("Create explicit test image", action: viewModel.createFixtureImage)
      if let image = viewModel.selectedImage {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
      }
      TextField("Image generation prompt", text: $viewModel.imagePrompt, axis: .vertical)
        .lineLimit(2...5)
      if let image = viewModel.generatedImage {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
      }
    }
  }

  private var tasksSection: some View {
    Section {
      ForEach(LiveProviderTask.allCases) { task in
        Button {
          viewModel.run(task)
        } label: {
          HStack {
            Label(task.name, systemImage: task.symbol)
            Spacer()
            if viewModel.runningTask == task { ProgressView() }
          }
        }
        .disabled(viewModel.selectedModel == nil || viewModel.isBusy)
        .accessibilityIdentifier("live-task-\(task.rawValue)")
      }
    } header: {
      Text("Live Tasks")
    } footer: {
      Text(
        "Each task is manual and may consume quota. Evidence contains no credentials or authorization headers."
      )
    }
  }

  private var resultsSection: some View {
    Section {
      if viewModel.results.isEmpty {
        Text("No live task has run.").foregroundStyle(.secondary)
      } else {
        Button("Clear results", role: .destructive, action: viewModel.clearResults)
        ForEach(viewModel.results) { result in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Image(systemName: result.status.symbol).foregroundStyle(result.status.color)
              Text(result.task.name).font(.headline)
              Spacer()
              Text(result.modelID).font(.caption).foregroundStyle(.secondary)
            }
            Text(result.detail)
              .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
      }
    } header: {
      Text("Live Evidence")
    }
  }
}

private struct CapabilityFlow: View {
  let model: ProviderModel

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        badge("Text", model.capabilities.textInput)
        badge("Image input", model.capabilities.imageInput)
        badge("Tools", model.capabilities.toolCalling)
        badge("Reasoning", model.capabilities.reasoning)
        badge("Structured", model.capabilities.structuredOutput)
        badge("Image output", model.capabilities.imageGeneration)
      }
    }
  }

  private func badge(_ name: String, _ enabled: Bool) -> some View {
    Text(name)
      .font(.caption2).padding(.horizontal, 7).padding(.vertical, 4)
      .background(enabled ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
      .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
      .clipShape(Capsule())
  }
}

extension LiveProviderResult.Status {
  fileprivate var symbol: String {
    switch self {
    case .running: "arrow.trianglehead.2.clockwise.rotate.90"
    case .passed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .running: .blue
    case .passed: .green
    case .failed: .red
    }
  }
}

extension SmokeCheck.Status {
  fileprivate var symbol: String {
    switch self {
    case .pending: "circle"
    case .running: "arrow.trianglehead.2.clockwise.rotate.90"
    case .passed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .pending: .secondary
    case .running: .blue
    case .passed: .green
    case .failed: .red
    }
  }
}
