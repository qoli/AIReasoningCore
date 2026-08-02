import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = SmokeViewModel()
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                configurationSection
                if viewModel.backend == .codex {
                    codexAuthenticationSection
                }
                requestSection
                executionSection
                resultSection
            }
            .navigationTitle("AIReasoning Smoke")
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                await loadPhoto(newValue)
            }
        }
        .onChange(of: viewModel.backend) { _, _ in
            viewModel.backendDidChange()
        }
    }

    private var backendSection: some View {
        Section("Reasoner") {
            Picker("Backend", selection: $viewModel.backend) {
                ForEach(SmokeBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            Text(viewModel.backendStatus)
                .font(.footnote)
                .foregroundStyle(viewModel.backend.requiresISH ? .orange : .secondary)
        }
    }

    private var codexAuthenticationSection: some View {
        Section("Codex authentication") {
            LabeledContent(
                "Status",
                value: viewModel.codexAuthenticationState.title
            )
            if let detail = viewModel.codexAuthenticationState.detail {
                Text(detail)
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Button("Refresh status") {
                viewModel.refreshCodexAuthentication()
            }
            .disabled(viewModel.isAuthenticating || viewModel.isRunning)

            Button("Sign in with device code") {
                viewModel.loginCodexWithDeviceCode()
            }
            .disabled(viewModel.isAuthenticating || viewModel.isRunning)

            SecureField(
                "OpenAI API key (sent to Codex stdin)",
                text: $viewModel.codexLoginCredential
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(viewModel.isAuthenticating || viewModel.isRunning)

            Button("Sign in with API key") {
                viewModel.loginCodexWithAPIKey()
            }
            .disabled(
                viewModel.codexLoginCredential.isEmpty
                    || viewModel.isAuthenticating
                    || viewModel.isRunning
            )

            HStack {
                Button("Sign out", role: .destructive) {
                    viewModel.logoutCodex()
                }
                .disabled(viewModel.isAuthenticating || viewModel.isRunning)
                Spacer()
                Button("Cancel authentication", role: .destructive) {
                    viewModel.cancelCodexAuthentication()
                }
                .disabled(!viewModel.isAuthenticating)
            }

            if !viewModel.codexAuthenticationOutput.isEmpty {
                ScrollView(.horizontal) {
                    Text(viewModel.codexAuthenticationOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(minHeight: 80)
            }

            Text(
                "Authentication is stored by Codex inside this app's iSH root filesystem. A standalone iSH app login is not shared."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var configurationSection: some View {
        Section("Configuration") {
            TextField("Model (required)", text: $viewModel.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if viewModel.backend.requiresISH {
                TextField(
                    "Guest executable, e.g. /usr/bin/codex",
                    text: $viewModel.executablePath
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    "Guest working directory, e.g. /root",
                    text: $viewModel.workingDirectoryPath
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } else {
                TextField(
                    "Base URL, e.g. https://api.openai.com/v1/",
                    text: $viewModel.baseURL
                )
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()

                SecureField("API key (memory only)", text: $viewModel.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Reasoning effort", selection: $viewModel.reasoningEffort) {
                    ForEach(SmokeReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }
                Text("High and Max explicitly enable provider thinking mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(
                    "Maximum response tokens",
                    value: $viewModel.maximumResponseTokens,
                    format: .number
                )
                .keyboardType(.numberPad)
            }

            TextField(
                "Timeout seconds",
                value: $viewModel.timeoutSeconds,
                format: .number
            )
            .keyboardType(.decimalPad)
        }
    }

    private var requestSection: some View {
        Section("Request") {
            Picker("Mode", selection: $viewModel.mode) {
                ForEach(SmokeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextEditor(text: $viewModel.prompt)
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if viewModel.prompt.isEmpty {
                        Text("Prompt (required)")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Choose image", systemImage: "photo")
            }

            if let attachment = viewModel.attachment {
                HStack {
                    VStack(alignment: .leading) {
                        Text(attachment.name)
                        Text("\(attachment.mimeType) · \(attachment.data.count) bytes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        selectedPhoto = nil
                        viewModel.clearAttachment()
                    }
                }
            }
        }
    }

    private var executionSection: some View {
        Section {
            HStack {
                Button {
                    viewModel.run()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(viewModel.isRunning || viewModel.isAuthenticating)

                Spacer()

                Button(role: .destructive) {
                    viewModel.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isRunning)
            }

            LabeledContent("State", value: viewModel.state.title)
            if let detail = viewModel.state.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var resultSection: some View {
        Section("Result") {
            ScrollView(.horizontal) {
                Text(viewModel.output.isEmpty ? "No output." : viewModel.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let contentType = item.supportedContentTypes.first(
                where: { $0.conforms(to: .image) }
            ), let mimeType = contentType.preferredMIMEType else {
                throw SmokeImageLoadingError.missingImageMIMEType
            }
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SmokeImageLoadingError.missingImageData
            }
            viewModel.setAttachment(
                data: data,
                mimeType: mimeType,
                name: item.itemIdentifier ?? "Photos image"
            )
        } catch {
            viewModel.reportAttachmentFailure(error)
        }
    }
}

private enum SmokeImageLoadingError: Error, LocalizedError {
    case missingImageMIMEType
    case missingImageData

    var errorDescription: String? {
        switch self {
        case .missingImageMIMEType:
            "The selected Photos item does not expose an image MIME type."
        case .missingImageData:
            "The selected Photos item contains no transferable image data."
        }
    }
}
