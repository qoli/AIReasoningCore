// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AIReasoningiSH
import AnyLanguageModel
import Foundation

enum SmokeBackend: String, CaseIterable, Identifiable {
    case codex
    case claude
    case openCode
    case anyLanguageModelOpenAI

    var id: Self { self }

    var title: String {
        switch self {
        case .codex:
            "Codex CLI (iSH)"
        case .claude:
            "Claude CLI (iSH)"
        case .openCode:
            "OpenCode (iSH)"
        case .anyLanguageModelOpenAI:
            "AnyLanguageModel / OpenAI"
        }
    }

    var requiresISH: Bool {
        switch self {
        case .codex, .claude, .openCode:
            true
        case .anyLanguageModelOpenAI:
            false
        }
    }
}

enum SmokeMode: String, CaseIterable, Identifiable {
    case oneShot
    case stream
    case structured

    var id: Self { self }

    var title: String {
        switch self {
        case .oneShot:
            "One-shot"
        case .stream:
            "Text stream"
        case .structured:
            "Structured"
        }
    }
}

enum SmokeReasoningEffort: String, CaseIterable, Identifiable {
    case providerDefault
    case high
    case max

    var id: Self { self }

    var title: String {
        switch self {
        case .providerDefault:
            "Provider default"
        case .high:
            "High"
        case .max:
            "Max"
        }
    }

    var apiValue: String? {
        switch self {
        case .providerDefault:
            nil
        case .high:
            "high"
        case .max:
            "max"
        }
    }
}

struct SmokeConfiguration {
    let backend: SmokeBackend
    let model: String
    let executablePath: String
    let workingDirectoryPath: String
    let baseURL: String
    let apiKey: String
    var reasoningEffort: SmokeReasoningEffort = .providerDefault
    let maximumResponseTokens: Int
    let timeoutSeconds: Double

    func makeLanguageModel(
        executor: any AgentProcessExecuting = ISHEmbeddedProcessExecutor()
    ) throws -> any LanguageModel {
        let model = try required(model, named: "model")
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw SmokeConfigurationError.invalidTimeout
        }

        switch backend {
        case .codex, .claude, .openCode:
            let executablePath = try absolutePath(
                executablePath,
                named: "guest executable path"
            )
            let workingDirectoryPath = try absolutePath(
                workingDirectoryPath,
                named: "guest working directory"
            )
            if let ishExecutor = executor as? ISHEmbeddedProcessExecutor,
               let unavailableReason = ishExecutor.unavailableReason
            {
                throw SmokeConfigurationError.iSHUnavailable(unavailableReason)
            }

            let common = (
                executableURL: URL(fileURLWithPath: executablePath),
                model: model,
                workingDirectoryURL: URL(
                    fileURLWithPath: workingDirectoryPath,
                    isDirectory: true
                ),
                environment: guestEnvironment(home: workingDirectoryPath),
                timeout: Duration.seconds(timeoutSeconds)
            )
            switch backend {
            case .codex:
                return CodexLanguageModel(
                    configuration: .init(
                        executableURL: common.executableURL,
                        model: common.model,
                        workingDirectoryURL: common.workingDirectoryURL,
                        environment: common.environment,
                        timeout: common.timeout
                    ),
                    executor: executor
                )
            case .claude:
                return ClaudeLanguageModel(
                    configuration: .init(
                        executableURL: common.executableURL,
                        model: common.model,
                        workingDirectoryURL: common.workingDirectoryURL,
                        environment: common.environment,
                        timeout: common.timeout
                    ),
                    executor: executor
                )
            case .openCode:
                let provider: OpenCodeLanguageModel.ProviderConfiguration?
                var environment = common.environment
                if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    provider = nil
                } else {
                    let apiKey = try required(apiKey, named: "API key")
                    let baseURL = try httpURL(baseURL)
                    guard let separator = model.firstIndex(of: "/"), separator != model.startIndex else {
                        throw SmokeConfigurationError.openCodeProviderModelRequired
                    }
                    let providerID = String(model[..<separator])
                    let environmentVariable = "AIREASONING_OPENCODE_API_KEY"
                    environment[environmentVariable] = apiKey
                    provider = .init(
                        id: providerID, baseURL: baseURL,
                        apiKeyEnvironmentVariable: environmentVariable)
                }
                return OpenCodeLanguageModel(
                    configuration: .init(
                        executableURL: common.executableURL,
                        model: common.model,
                        workingDirectoryURL: common.workingDirectoryURL,
                        environment: environment,
                        timeout: common.timeout,
                        provider: provider
                    ),
                    executor: executor
                )
            case .anyLanguageModelOpenAI:
                throw SmokeConfigurationError.invalidBackendState
            }

        case .anyLanguageModelOpenAI:
            let apiKey = try required(apiKey, named: "API key")
            let baseURL = try httpURL(baseURL)
            return OpenAILanguageModel(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                apiVariant: .chatCompletions
            )
        }
    }

    func makeCodexAuthenticationManager(
        executor: any AgentProcessExecuting = ISHEmbeddedProcessExecutor()
    ) throws -> CodexCLIAuthenticationManager {
        guard backend == .codex else {
            throw SmokeConfigurationError.codexAuthenticationUnsupportedBackend
        }
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw SmokeConfigurationError.invalidTimeout
        }
        let executablePath = try absolutePath(
            executablePath,
            named: "guest executable path"
        )
        let workingDirectoryPath = try absolutePath(
            workingDirectoryPath,
            named: "guest working directory"
        )
        if let ishExecutor = executor as? ISHEmbeddedProcessExecutor,
           let unavailableReason = ishExecutor.unavailableReason
        {
            throw SmokeConfigurationError.iSHUnavailable(unavailableReason)
        }
        return CodexCLIAuthenticationManager(
            configuration: .init(
                executableURL: URL(fileURLWithPath: executablePath),
                workingDirectoryURL: URL(
                    fileURLWithPath: workingDirectoryPath,
                    isDirectory: true
                ),
                environment: guestEnvironment(home: workingDirectoryPath),
                // Codex device codes are valid for 15 minutes. Authentication
                // must not inherit a shorter generation timeout and terminate
                // while the user is completing the browser confirmation.
                timeout: .seconds(max(timeoutSeconds, 900))
            ),
            executor: executor
        )
    }

    func makeGenerationOptions() throws -> GenerationOptions {
        if backend != .anyLanguageModelOpenAI {
            guard reasoningEffort == .providerDefault else {
                throw SmokeConfigurationError.reasoningEffortUnsupported
            }
            return GenerationOptions()
        }
        guard maximumResponseTokens > 0 else {
            throw SmokeConfigurationError.invalidMaximumResponseTokens
        }
        var options = GenerationOptions(
            maximumResponseTokens: maximumResponseTokens
        )
        guard let apiValue = reasoningEffort.apiValue else {
            return options
        }
        options[custom: OpenAILanguageModel.self] = .init(
            extraBody: [
                "reasoning_effort": .string(apiValue),
                "thinking": .object(["type": .string("enabled")]),
            ]
        )
        return options
    }

    private func required(_ value: String, named name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SmokeConfigurationError.missingRequiredValue(name)
        }
        return trimmed
    }

    private func absolutePath(_ value: String, named name: String) throws -> String {
        let path = try required(value, named: name)
        guard path.hasPrefix("/") else {
            throw SmokeConfigurationError.pathMustBeAbsolute(name)
        }
        return path
    }

    private func httpURL(_ value: String) throws -> URL {
        let value = try required(value, named: "base URL")
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            throw SmokeConfigurationError.invalidBaseURL
        }
        return url
    }

    private func guestEnvironment(home: String) -> [String: String] {
        [
            "HOME": home,
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "SSL_CERT_FILE": "/etc/ssl/cert.pem",
        ]
    }
}

enum SmokeConfigurationError: Error, LocalizedError, Equatable {
    case missingRequiredValue(String)
    case pathMustBeAbsolute(String)
    case invalidBaseURL
    case invalidMaximumResponseTokens
    case invalidTimeout
    case invalidBackendState
    case codexAuthenticationUnsupportedBackend
    case reasoningEffortUnsupported
    case openCodeProviderModelRequired
    case iSHUnavailable(ISHProcessExecutorUnavailableReason)

    var errorDescription: String? {
        switch self {
        case .missingRequiredValue(let name):
            "Missing required configuration: \(name)."
        case .pathMustBeAbsolute(let name):
            "\(name) must be an absolute path inside the iSH guest."
        case .invalidBaseURL:
            "Base URL must be an absolute HTTP(S) URL."
        case .invalidMaximumResponseTokens:
            "Maximum response tokens must be greater than zero."
        case .invalidTimeout:
            "Timeout must be a finite number greater than zero."
        case .invalidBackendState:
            "The selected backend does not match its configuration path."
        case .codexAuthenticationUnsupportedBackend:
            "Codex CLI authentication is only available for the Codex backend."
        case .reasoningEffortUnsupported:
            "Reasoning effort is only supported by the native OpenAI-compatible backend."
        case .openCodeProviderModelRequired:
            "OpenCode custom provider models must use provider/model format."
        case .iSHUnavailable(.runtimeNotLinked):
            "iSH runtime is not linked. Codex, Claude, and OpenCode cannot run in this build."
        case .iSHUnavailable(.runtimeNotBooted):
            "The linked iSH runtime has not booted a writable root filesystem."
        }
    }
}
