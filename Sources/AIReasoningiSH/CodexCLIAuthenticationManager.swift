// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import Foundation

public struct CodexCLIAuthenticationConfiguration: Sendable, Equatable {
    public let executableURL: URL
    public let workingDirectoryURL: URL
    public let environment: [String: String]
    public let timeout: Duration
    public let cancellationGracePeriod: Duration

    public init(
        executableURL: URL,
        workingDirectoryURL: URL,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(120),
        cancellationGracePeriod: Duration = .milliseconds(500)
    ) {
        self.executableURL = executableURL
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.timeout = timeout
        self.cancellationGracePeriod = cancellationGracePeriod
    }
}

public enum CodexCLIAuthenticationStatus: Sendable, Equatable {
    case authenticated(description: String)
    case notAuthenticated

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

public enum CodexCLIAuthenticationOperation: String, Sendable, Equatable {
    case status
    case deviceLogin
    case apiKeyLogin
    case accessTokenLogin
    case logout
}

public enum CodexCLIAuthenticationOutputStream: Sendable, Equatable {
    case standardOutput
    case standardError
}

public struct CodexCLIAuthenticationOutput: Sendable, Equatable {
    public let stream: CodexCLIAuthenticationOutputStream
    public let line: String

    public init(stream: CodexCLIAuthenticationOutputStream, line: String) {
        self.stream = stream
        self.line = line
    }
}

public enum CodexCLIAuthenticationError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable(String)
    case emptyCredential
    case invalidStatusOutput(exitCode: Int32, output: String)
    case commandFailed(
        operation: CodexCLIAuthenticationOperation,
        exitCode: Int32,
        standardError: String
    )
    case missingProcessTermination(CodexCLIAuthenticationOperation)
    case logoutDidNotClearAuthentication

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            "Codex executable is unavailable: \(path)"
        case .emptyCredential:
            "The Codex login credential is empty."
        case .invalidStatusOutput(let exitCode, let output):
            "Codex login status returned an unrecognized result (exit \(exitCode)): \(output)"
        case .commandFailed(let operation, let exitCode, let standardError):
            "Codex authentication operation \(operation.rawValue) failed (exit \(exitCode)): \(standardError)"
        case .missingProcessTermination(let operation):
            "Codex authentication operation \(operation.rawValue) ended without a process termination event."
        case .logoutDidNotClearAuthentication:
            "Codex logout completed but authentication is still active."
        }
    }
}

public struct CodexCLIAuthenticationManager: Sendable {
    public typealias OutputHandler = @Sendable (CodexCLIAuthenticationOutput) async -> Void

    private let configuration: CodexCLIAuthenticationConfiguration
    private let executor: any AgentProcessExecuting

    public init(
        configuration: CodexCLIAuthenticationConfiguration,
        executor: any AgentProcessExecuting
    ) {
        self.configuration = configuration
        self.executor = executor
    }

    public func status() async throws -> CodexCLIAuthenticationStatus {
        let result = try await execute(
            operation: .status,
            arguments: ["login", "status"]
        )
        let standardOutput = result.standardOutput
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standardError = result.standardError
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.exitCode == 0,
           standardOutput.hasPrefix("Logged in "),
           standardError.isEmpty
        {
            return .authenticated(description: standardOutput)
        }
        if result.exitCode == 1,
           standardOutput == "Not logged in",
           standardError.isEmpty
        {
            return .notAuthenticated
        }
        let diagnostic = [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw CodexCLIAuthenticationError.invalidStatusOutput(
            exitCode: result.exitCode,
            output: diagnostic
        )
    }

    public func loginWithDeviceCode(
        outputHandler: OutputHandler? = nil
    ) async throws -> CodexCLIAuthenticationStatus {
        let result = try await execute(
            operation: .deviceLogin,
            arguments: ["login", "--device-auth"],
            outputHandler: outputHandler
        )
        try requireSuccess(result, operation: .deviceLogin)
        return try await requireAuthenticatedStatus()
    }

    public func loginWithAPIKey(
        _ apiKey: String,
        outputHandler: OutputHandler? = nil
    ) async throws -> CodexCLIAuthenticationStatus {
        try await loginWithCredential(
            apiKey,
            operation: .apiKeyLogin,
            option: "--with-api-key",
            outputHandler: outputHandler
        )
    }

    public func loginWithAccessToken(
        _ accessToken: String,
        outputHandler: OutputHandler? = nil
    ) async throws -> CodexCLIAuthenticationStatus {
        try await loginWithCredential(
            accessToken,
            operation: .accessTokenLogin,
            option: "--with-access-token",
            outputHandler: outputHandler
        )
    }

    public func logout(
        outputHandler: OutputHandler? = nil
    ) async throws {
        let result = try await execute(
            operation: .logout,
            arguments: ["logout"],
            outputHandler: outputHandler
        )
        try requireSuccess(result, operation: .logout)
        guard try await status() == .notAuthenticated else {
            throw CodexCLIAuthenticationError.logoutDidNotClearAuthentication
        }
    }

    private func loginWithCredential(
        _ credential: String,
        operation: CodexCLIAuthenticationOperation,
        option: String,
        outputHandler: OutputHandler?
    ) async throws -> CodexCLIAuthenticationStatus {
        guard !credential.isEmpty else {
            throw CodexCLIAuthenticationError.emptyCredential
        }
        let result = try await execute(
            operation: operation,
            arguments: ["login", option],
            standardInput: Data((credential + "\n").utf8),
            outputHandler: outputHandler
        )
        try requireSuccess(result, operation: operation)
        return try await requireAuthenticatedStatus()
    }

    private func requireAuthenticatedStatus() async throws -> CodexCLIAuthenticationStatus {
        let currentStatus = try await status()
        guard currentStatus.isAuthenticated else {
            throw CodexCLIAuthenticationError.invalidStatusOutput(
                exitCode: 1,
                output: "Not logged in after successful login command"
            )
        }
        return currentStatus
    }

    private func requireSuccess(
        _ result: ProcessResult,
        operation: CodexCLIAuthenticationOperation
    ) throws {
        guard result.exitCode == 0 else {
            let diagnostic = (result.standardError + result.standardOutput)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexCLIAuthenticationError.commandFailed(
                operation: operation,
                exitCode: result.exitCode,
                standardError: diagnostic
            )
        }
    }

    private func execute(
        operation: CodexCLIAuthenticationOperation,
        arguments: [String],
        standardInput: Data? = nil,
        outputHandler: OutputHandler? = nil
    ) async throws -> ProcessResult {
        guard executor.isExecutableAvailable(at: configuration.executableURL) else {
            throw CodexCLIAuthenticationError.executableUnavailable(
                configuration.executableURL.path
            )
        }
        let session = try await executor.start(
            .init(
                executableURL: configuration.executableURL,
                arguments: arguments,
                environment: configuration.environment,
                workingDirectoryURL: configuration.workingDirectoryURL,
                timeout: configuration.timeout
            )
        )
        if let standardInput {
            try await session.writeStandardInput(standardInput)
        }
        try await session.closeStandardInput()

        return try await withTaskCancellationHandler {
            var standardOutput: [String] = []
            var standardError: [String] = []
            var exitCode: Int32?
            for try await event in session.events {
                try Task.checkCancellation()
                switch event {
                case .standardOutputLine(let line):
                    standardOutput.append(line)
                    await outputHandler?(.init(stream: .standardOutput, line: line))
                case .standardErrorLine(let line):
                    standardError.append(line)
                    await outputHandler?(.init(stream: .standardError, line: line))
                case .terminated(let code):
                    exitCode = code
                }
            }
            try Task.checkCancellation()
            guard let exitCode else {
                throw CodexCLIAuthenticationError.missingProcessTermination(operation)
            }
            return .init(
                exitCode: exitCode,
                standardOutput: standardOutput,
                standardError: standardError
            )
        } onCancel: {
            let gracePeriod = configuration.cancellationGracePeriod
            Task {
                await session.interrupt()
                try? await Task.sleep(for: gracePeriod)
                await session.terminate()
            }
        }
    }
}

private struct ProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: [String]
    let standardError: [String]
}
