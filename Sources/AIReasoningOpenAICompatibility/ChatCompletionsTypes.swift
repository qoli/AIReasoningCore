// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import Foundation

public enum ChatCompletionsBackend: String, Sendable {
    case openai
    case codex
    case claude
    case opencode
}

public struct ChatCompletionsExecutionConfiguration: Sendable {
    public let backend: ChatCompletionsBackend
    public let executableURL: URL?
    public let baseURL: URL?
    public let workingDirectoryURL: URL
    public let timeoutSeconds: Double
    public let environment: [String: String]
    public let openCodeProvider: OpenCodeLanguageModel.ProviderConfiguration?

    public init(
        backend: ChatCompletionsBackend,
        executableURL: URL?,
        baseURL: URL?,
        workingDirectoryURL: URL,
        timeoutSeconds: Double,
        environment: [String: String],
        openCodeProvider: OpenCodeLanguageModel.ProviderConfiguration? = nil
    ) {
        self.backend = backend
        self.executableURL = executableURL
        self.baseURL = baseURL
        self.workingDirectoryURL = workingDirectoryURL
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
        self.openCodeProvider = openCodeProvider
    }
}

package enum ChatCompletionsFailureKind: Sendable {
    case invalidRequest
    case unavailable
    case backend
}

package struct ChatCompletionsFailure: Error, LocalizedError, Sendable {
    package let kind: ChatCompletionsFailureKind
    package let message: String
    package let parameter: String?
    package let code: String

    package init(
        _ kind: ChatCompletionsFailureKind,
        message: String,
        parameter: String? = nil,
        code: String
    ) {
        self.kind = kind
        self.message = message
        self.parameter = parameter
        self.code = code
    }

    package var errorDescription: String? { message }

    package var envelope: PackageJSONValue {
        var error: [String: PackageJSONValue] = [
            "message": .string(message),
            "type": .string(
                kind == .invalidRequest ? "invalid_request_error" : "api_error"
            ),
            "code": .string(code),
        ]
        error["param"] = parameter.map(PackageJSONValue.string) ?? .null
        return .object(["error": .object(error)])
    }
}
