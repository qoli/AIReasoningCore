// SPDX-License-Identifier: GPL-3.0-or-later

import AnyLanguageModel
import AIReasoningCore
import AIReasoningiSH
import Combine
import Foundation

@Generable
struct SmokeStructuredOutput {
    var summary: String
    var confidence: Int
}

struct SmokeImageAttachment {
    let data: Data
    let mimeType: String
    let name: String
}

enum SmokeRunState: Equatable {
    case idle
    case running
    case succeeded
    case cancelled
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .running:
            "Running"
        case .succeeded:
            "Succeeded"
        case .cancelled:
            "Cancelled"
        case .failed:
            "Failed"
        }
    }

    var detail: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

enum SmokeCodexAuthenticationState: Equatable {
    case unchecked
    case checking
    case authenticated(String)
    case notAuthenticated
    case failed(String)

    var title: String {
        switch self {
        case .unchecked:
            "Unchecked"
        case .checking:
            "Working"
        case .authenticated:
            "Authenticated"
        case .notAuthenticated:
            "Not authenticated"
        case .failed:
            "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .authenticated(let description), .failed(let description):
            description
        case .unchecked, .checking, .notAuthenticated:
            nil
        }
    }
}

@MainActor
final class SmokeViewModel: ObservableObject {
    @Published var backend: SmokeBackend = .anyLanguageModelOpenAI
    @Published var mode: SmokeMode = .stream
    @Published var model = ""
    @Published var executablePath = ""
    @Published var workingDirectoryPath = ""
    @Published var baseURL = ""
    @Published var apiKey = ""
    @Published var codexLoginCredential = ""
    @Published var reasoningEffort: SmokeReasoningEffort = .providerDefault
    @Published var maximumResponseTokens = 2048
    @Published var timeoutSeconds = 120.0
    @Published var prompt = ""
    @Published private(set) var attachment: SmokeImageAttachment?
    @Published private(set) var output = ""
    @Published private(set) var state: SmokeRunState = .idle
    @Published private(set) var codexAuthenticationState: SmokeCodexAuthenticationState = .unchecked
    @Published private(set) var codexAuthenticationOutput = ""

    private let processExecutor: any AgentProcessExecuting
    private var runTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?

    init(
        initialBackend: SmokeBackend = .anyLanguageModelOpenAI,
        processExecutor: any AgentProcessExecuting = ISHEmbeddedProcessExecutor()
    ) {
        self.processExecutor = processExecutor
        backend = initialBackend
        applyBackendDefaults()
    }

    var isRunning: Bool {
        runTask != nil
    }

    var isAuthenticating: Bool {
        authenticationTask != nil
    }

    var backendStatus: String {
        guard backend.requiresISH else {
            return "Native HTTP model. Configuration is validated when Run is pressed."
        }
        if let error = ISHHostBootstrap.registrationError ?? ISHHostBootstrap.bootError {
            return "Unavailable: \(error)"
        }
        switch ISHEmbeddedProcessExecutor().unavailableReason {
        case nil:
            return "iSH interactive runtime is linked."
        case .runtimeNotLinked:
            return "Unavailable: iSH runtime is not linked to this app target."
        case .runtimeNotBooted:
            return "Unavailable: iSH is linked but its writable rootfs has not been booted."
        }
    }

    func run() {
        guard runTask == nil else {
            state = .failed("A smoke request is already running.")
            return
        }
        guard authenticationTask == nil else {
            state = .failed("A Codex authentication operation is still running.")
            return
        }
        let configuration = SmokeConfiguration(
            backend: backend,
            model: model,
            executablePath: executablePath,
            workingDirectoryPath: workingDirectoryPath,
            baseURL: baseURL,
            apiKey: apiKey,
            reasoningEffort: reasoningEffort,
            maximumResponseTokens: maximumResponseTokens,
            timeoutSeconds: timeoutSeconds
        )
        let requestMode = mode
        let requestPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestAttachment = attachment

        output = ""
        state = .running
        runTask = Task { [weak self] in
            guard let self else { return }
            await execute(
                configuration: configuration,
                mode: requestMode,
                prompt: requestPrompt,
                attachment: requestAttachment
            )
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func backendDidChange() {
        authenticationTask?.cancel()
        codexLoginCredential = ""
        codexAuthenticationOutput = ""
        codexAuthenticationState = .unchecked
        applyBackendDefaults()
    }

    private func applyBackendDefaults() {
        if backend == .codex {
            if executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                executablePath = "/usr/local/bin/codex"
            }
            if workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                workingDirectoryPath = "/root"
            }
        } else if backend == .openCode {
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model = "deepseek/deepseek-v4-flash"
            }
            if executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                executablePath = "/usr/local/bin/opencode"
            }
            if workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                workingDirectoryPath = "/root"
            }
            if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                baseURL = "https://api.deepseek.com/v1"
            }
        }
    }

    func refreshCodexAuthentication() {
        startCodexAuthenticationOperation(clearOutput: true) { manager in
            try await manager.status()
        }
    }

    func loginCodexWithDeviceCode() {
        let outputHandler = authenticationOutputHandler()
        startCodexAuthenticationOperation(clearOutput: true) { manager in
            try await manager.loginWithDeviceCode(outputHandler: outputHandler)
        }
    }

    func loginCodexWithAPIKey() {
        let credential = codexLoginCredential
        codexLoginCredential = ""
        let outputHandler = authenticationOutputHandler()
        startCodexAuthenticationOperation(clearOutput: true) { manager in
            try await manager.loginWithAPIKey(
                credential,
                outputHandler: outputHandler
            )
        }
    }

    func logoutCodex() {
        let outputHandler = authenticationOutputHandler()
        startCodexAuthenticationOperation(clearOutput: true) { manager in
            try await manager.logout(outputHandler: outputHandler)
            return .notAuthenticated
        }
    }

    func cancelCodexAuthentication() {
        authenticationTask?.cancel()
    }

    func setAttachment(data: Data, mimeType: String, name: String) {
        attachment = nil
        guard !data.isEmpty else {
            state = .failed("Selected image contains no data.")
            return
        }
        guard mimeType.hasPrefix("image/") else {
            state = .failed("Selected attachment is not an image: \(mimeType).")
            return
        }
        attachment = .init(data: data, mimeType: mimeType, name: name)
    }

    func clearAttachment() {
        attachment = nil
    }

    func reportAttachmentFailure(_ error: any Error) {
        attachment = nil
        state = .failed("Image loading failed: \(error.localizedDescription)")
    }

    private func execute(
        configuration: SmokeConfiguration,
        mode: SmokeMode,
        prompt: String,
        attachment: SmokeImageAttachment?
    ) async {
        defer { runTask = nil }
        do {
            guard !prompt.isEmpty else {
                throw SmokeRequestError.missingPrompt
            }
            try Task.checkCancellation()
            if configuration.backend == .codex {
                let manager = try configuration.makeCodexAuthenticationManager(
                    executor: processExecutor
                )
                let authenticationStatus = try await manager.status()
                guard authenticationStatus.isAuthenticated else {
                    codexAuthenticationState = .notAuthenticated
                    throw SmokeRequestError.codexAuthenticationRequired
                }
                updateAuthenticationState(authenticationStatus)
            }
            let model = try configuration.makeLanguageModel(
                executor: processExecutor
            )
            let generationOptions = try configuration.makeGenerationOptions()
            let session = LanguageModelSession(model: model)
            let images = attachment.map {
                [Transcript.ImageSegment(data: $0.data, mimeType: $0.mimeType)]
            } ?? []

            switch mode {
            case .oneShot:
                let response = if images.isEmpty {
                    try await session.respond(to: prompt, options: generationOptions)
                } else {
                    try await session.respond(
                        to: prompt,
                        images: images,
                        options: generationOptions
                    )
                }
                output = response.content

            case .stream:
                let stream = if images.isEmpty {
                    session.streamResponse(to: prompt, options: generationOptions)
                } else {
                    session.streamResponse(
                        to: prompt,
                        images: images,
                        options: generationOptions
                    )
                }
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    output = snapshot.content
                }

            case .structured:
                let response = if images.isEmpty {
                    try await session.respond(
                        to: prompt,
                        generating: SmokeStructuredOutput.self,
                        options: generationOptions
                    )
                } else {
                    try await session.respond(
                        to: prompt,
                        images: images,
                        generating: SmokeStructuredOutput.self,
                        options: generationOptions
                    )
                }
                output = """
                summary: \(response.content.summary)
                confidence: \(response.content.confidence)
                """
            }
            try Task.checkCancellation()
            state = .succeeded
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startCodexAuthenticationOperation(
        clearOutput: Bool,
        operation: @escaping @Sendable (
            CodexCLIAuthenticationManager
        ) async throws -> CodexCLIAuthenticationStatus
    ) {
        guard authenticationTask == nil else {
            codexAuthenticationState = .failed(
                "A Codex authentication operation is already running."
            )
            return
        }
        guard runTask == nil else {
            codexAuthenticationState = .failed(
                "Cancel the active smoke request before changing Codex authentication."
            )
            return
        }
        let configuration = currentConfiguration()
        if clearOutput {
            codexAuthenticationOutput = ""
        }
        codexAuthenticationState = .checking
        authenticationTask = Task { [weak self] in
            guard let self else { return }
            defer { authenticationTask = nil }
            do {
                let manager = try configuration.makeCodexAuthenticationManager(
                    executor: processExecutor
                )
                let status = try await operation(manager)
                try Task.checkCancellation()
                updateAuthenticationState(status)
            } catch is CancellationError {
                codexAuthenticationState = .unchecked
            } catch {
                codexAuthenticationState = .failed(error.localizedDescription)
            }
        }
    }

    private func currentConfiguration() -> SmokeConfiguration {
        SmokeConfiguration(
            backend: backend,
            model: model,
            executablePath: executablePath,
            workingDirectoryPath: workingDirectoryPath,
            baseURL: baseURL,
            apiKey: apiKey,
            reasoningEffort: reasoningEffort,
            maximumResponseTokens: maximumResponseTokens,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func updateAuthenticationState(
        _ status: CodexCLIAuthenticationStatus
    ) {
        switch status {
        case .authenticated(let description):
            codexAuthenticationState = .authenticated(description)
        case .notAuthenticated:
            codexAuthenticationState = .notAuthenticated
        }
    }

    private func appendAuthenticationOutput(
        _ output: CodexCLIAuthenticationOutput
    ) {
        let prefix = output.stream == .standardError ? "stderr" : "stdout"
        let line = "[\(prefix)] \(output.line)"
        if codexAuthenticationOutput.isEmpty {
            codexAuthenticationOutput = line
        } else {
            codexAuthenticationOutput += "\n\(line)"
        }
    }

    private func authenticationOutputHandler() -> CodexCLIAuthenticationManager.OutputHandler {
        { [self] output in
            await appendAuthenticationOutput(output)
        }
    }
}

enum SmokeRequestError: Error, LocalizedError {
    case missingPrompt
    case codexAuthenticationRequired

    var errorDescription: String? {
        switch self {
        case .missingPrompt:
            "Prompt is required."
        case .codexAuthenticationRequired:
            "Codex CLI is not authenticated in this app's iSH root filesystem. Sign in before running the request."
        }
    }
}
