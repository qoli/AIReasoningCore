// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The isolated execution and filesystem surface used by the minimal harness.
/// Paths are absolute guest paths; implementations must reject paths outside
/// their configured workspace.
public protocol MinimalAgentSandbox: Sendable {
    func runBash(_ request: SandboxBashRequest) async throws -> SandboxBashResult
    func fileInfo(at path: String) async throws -> SandboxFileInfo?
    func readTextFile(at path: String) async throws -> SandboxTextFile
    func listDirectory(at path: String, maximumDepth: Int) async throws
        -> [SandboxDirectoryEntry]
    func createTextFile(at path: String, contents: String) async throws
    func replaceTextFile(
        at path: String,
        expectedVersion: String,
        contents: String
    ) async throws
}

public struct SandboxBashRequest: Sendable, Equatable {
    public let command: String
    public let workingDirectory: String
    public let timeout: Duration
    public let maximumOutputCharacters: Int

    public init(
        command: String,
        workingDirectory: String = "/workspace",
        timeout: Duration = .seconds(300),
        maximumOutputCharacters: Int = 16_000
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.maximumOutputCharacters = maximumOutputCharacters
    }
}

public struct SandboxBashResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let outputWasTruncated: Bool

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        outputWasTruncated: Bool
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
    }
}

public enum SandboxFileKind: String, Sendable, Equatable {
    case file
    case directory
}

public struct SandboxFileInfo: Sendable, Equatable {
    public let kind: SandboxFileKind
    public let version: String?

    public init(kind: SandboxFileKind, version: String? = nil) {
        self.kind = kind
        self.version = version
    }
}

public struct SandboxTextFile: Sendable, Equatable {
    public let contents: String
    public let version: String

    public init(contents: String, version: String) {
        self.contents = contents
        self.version = version
    }
}

public struct SandboxDirectoryEntry: Sendable, Equatable {
    public let path: String
    public let kind: SandboxFileKind

    public init(path: String, kind: SandboxFileKind) {
        self.path = path
        self.kind = kind
    }
}

public enum MinimalAgentSandboxError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case pathOutsideWorkspace(String)
    case unsupportedFileType(String)
    case fileNotFound(String)
    case fileAlreadyExists(String)
    case notTextFile(String)
    case concurrentModification(String)
    case operationFailed(operation: String, path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            message
        case .pathOutsideWorkspace(let path):
            "Path is outside the sandbox workspace: \(path)"
        case .unsupportedFileType(let path):
            "Unsupported sandbox file type: \(path)"
        case .fileNotFound(let path):
            "Sandbox path does not exist: \(path)"
        case .fileAlreadyExists(let path):
            "Sandbox path already exists: \(path)"
        case .notTextFile(let path):
            "Sandbox file is not valid UTF-8 text: \(path)"
        case .concurrentModification(let path):
            "Sandbox file changed before the edit could be committed: \(path)"
        case .operationFailed(let operation, let path, let message):
            "Sandbox \(operation) failed for \(path): \(message)"
        }
    }
}
