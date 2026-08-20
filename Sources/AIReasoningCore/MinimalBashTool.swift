// SPDX-License-Identifier: GPL-3.0-or-later

import AnyLanguageModel
import Foundation

public struct MinimalBashTool: Tool, Sendable {
    @Generable
    public struct Arguments {
        @Guide(description: "The Bash command to run inside the isolated iSH environment.")
        public var command: String

    }

    public let name = "bash"
    public let description: String

    private let sandbox: any MinimalAgentSandbox
    private let workingDirectory: String
    private let timeout: Duration
    private let maximumOutputCharacters: Int

    public init(
        sandbox: any MinimalAgentSandbox,
        workingDirectory: String = "/workspace",
        timeout: Duration = .seconds(300),
        maximumOutputCharacters: Int = 16_000,
        description: String = "Run a command in the isolated iSH Bash environment. Network access is available."
    ) {
        self.sandbox = sandbox
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.maximumOutputCharacters = max(0, maximumOutputCharacters)
        self.description = description
    }

    public func call(arguments: Arguments) async throws -> String {
        guard !arguments.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MinimalAgentSandboxError.invalidRequest("bash command must not be empty")
        }
        let result = try await sandbox.runBash(.init(
            command: arguments.command,
            workingDirectory: workingDirectory,
            timeout: timeout,
            maximumOutputCharacters: maximumOutputCharacters
        ))
        var sections: [String] = []
        if !result.standardOutput.isEmpty {
            sections.append(result.standardOutput)
        }
        if !result.standardError.isEmpty {
            sections.append("stderr:\n\(result.standardError)")
        }
        if result.outputWasTruncated {
            sections.append("<response clipped>")
        }
        if result.exitCode != 0 {
            sections.append("Process exited with code \(result.exitCode).")
        }
        return sections.isEmpty ? "Process exited with code 0." : sections.joined(separator: "\n")
    }
}
