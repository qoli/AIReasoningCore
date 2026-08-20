// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import CryptoKit
import Foundation

/// The concrete minimal-agent sandbox: Bash runs in iSH while editor calls
/// operate on the host side of the same workspace bind mount.
public actor ISHMinimalAgentSandbox: MinimalAgentSandbox {
    private let executor: ISHEmbeddedProcessExecutor
    private let workspace: ISHWorkspaceMountConfiguration
    private let hostRoot: URL

    public init(runtime: ISHEmbeddedRuntime = .shared) throws {
        guard runtime.isBooted else {
            throw ISHEmbeddedRuntimeError.notBooted
        }
        guard let workspace = runtime.workspaceMount else {
            throw ISHEmbeddedRuntimeError.invalidWorkspace(
                "the runtime was booted without a workspace mount"
            )
        }
        self.executor = ISHEmbeddedProcessExecutor(runtime: runtime)
        self.workspace = workspace
        self.hostRoot = workspace.hostDirectoryURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    public func runBash(_ request: SandboxBashRequest) async throws -> SandboxBashResult {
        guard request.maximumOutputCharacters >= 0 else {
            throw MinimalAgentSandboxError.invalidRequest(
                "maximumOutputCharacters must be nonnegative"
            )
        }
        let workingDirectory = try resolveGuestPath(request.workingDirectory, mustExist: true)
        guard workingDirectory.isDirectory else {
            throw MinimalAgentSandboxError.invalidRequest(
                "bash working directory is not a directory: \(request.workingDirectory)"
            )
        }
        let session = try await executor.start(.init(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-lc", request.command],
            environment: [
                "HOME": "/root",
                "LANG": "C.UTF-8",
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            ],
            workingDirectoryURL: URL(fileURLWithPath: request.workingDirectory),
            timeout: request.timeout
        ))

        return try await withTaskCancellationHandler {
            var stdout = ""
            var stderr = ""
            var exitCode: Int32?
            var remaining = max(0, request.maximumOutputCharacters)
            var truncated = false
            for try await event in session.events {
                switch event {
                case .standardOutputLine(let line):
                    append(line: line, to: &stdout, remaining: &remaining, truncated: &truncated)
                case .standardErrorLine(let line):
                    append(line: line, to: &stderr, remaining: &remaining, truncated: &truncated)
                case .terminated(let code):
                    exitCode = code
                }
            }
            guard let exitCode else {
                throw MinimalAgentSandboxError.operationFailed(
                    operation: "bash",
                    path: request.workingDirectory,
                    message: "iSH ended without an exit status"
                )
            }
            return SandboxBashResult(
                exitCode: exitCode,
                standardOutput: stdout,
                standardError: stderr,
                outputWasTruncated: truncated
            )
        } onCancel: {
            Task { await session.terminate() }
        }
    }

    public func fileInfo(at path: String) async throws -> SandboxFileInfo? {
        let url = try resolveGuestPath(path, mustExist: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return SandboxFileInfo(kind: .directory)
        }
        guard url.isRegularFile else {
            throw MinimalAgentSandboxError.unsupportedFileType(path)
        }
        return SandboxFileInfo(kind: .file, version: try version(of: url, guestPath: path))
    }

    public func readTextFile(at path: String) async throws -> SandboxTextFile {
        let url = try resolveGuestPath(path, mustExist: true)
        guard url.isRegularFile else {
            throw MinimalAgentSandboxError.unsupportedFileType(path)
        }
        let data = try readData(url, operation: "read", guestPath: path)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw MinimalAgentSandboxError.notTextFile(path)
        }
        return SandboxTextFile(contents: contents, version: digest(data))
    }

    public func listDirectory(
        at path: String,
        maximumDepth: Int
    ) async throws -> [SandboxDirectoryEntry] {
        guard maximumDepth >= 0 else {
            throw MinimalAgentSandboxError.invalidRequest("maximumDepth must be nonnegative")
        }
        let root = try resolveGuestPath(path, mustExist: true)
        guard root.isDirectory else {
            throw MinimalAgentSandboxError.unsupportedFileType(path)
        }
        var entries: [SandboxDirectoryEntry] = []
        try collectEntries(
            hostDirectory: root,
            guestDirectory: normalizedGuestPath(path),
            remainingDepth: maximumDepth,
            entries: &entries
        )
        return entries.sorted { $0.path < $1.path }
    }

    public func createTextFile(at path: String, contents: String) async throws {
        try requireWritable(path)
        let url = try resolveGuestPath(path, mustExist: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MinimalAgentSandboxError.fileAlreadyExists(path)
        }
        guard url.deletingLastPathComponent().isDirectory else {
            throw MinimalAgentSandboxError.operationFailed(
                operation: "create",
                path: path,
                message: "parent directory does not exist"
            )
        }
        do {
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            throw MinimalAgentSandboxError.operationFailed(
                operation: "create",
                path: path,
                message: error.localizedDescription
            )
        }
    }

    public func replaceTextFile(
        at path: String,
        expectedVersion: String,
        contents: String
    ) async throws {
        try requireWritable(path)
        let url = try resolveGuestPath(path, mustExist: true)
        guard url.isRegularFile else {
            throw MinimalAgentSandboxError.unsupportedFileType(path)
        }
        let current = try readData(url, operation: "read", guestPath: path)
        guard digest(current) == expectedVersion else {
            throw MinimalAgentSandboxError.concurrentModification(path)
        }
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
        } catch {
            throw MinimalAgentSandboxError.operationFailed(
                operation: "replace",
                path: path,
                message: error.localizedDescription
            )
        }
    }

    private func resolveGuestPath(_ path: String, mustExist: Bool) throws -> URL {
        let normalized = normalizedGuestPath(path)
        let guestRoot = workspace.guestDirectoryPath
        guard normalized == guestRoot || normalized.hasPrefix(guestRoot + "/") else {
            throw MinimalAgentSandboxError.pathOutsideWorkspace(path)
        }
        let relative = String(normalized.dropFirst(guestRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = relative.isEmpty
            ? hostRoot
            : hostRoot.appendingPathComponent(relative)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == hostRoot.path || resolved.path.hasPrefix(hostRoot.path + "/") else {
            throw MinimalAgentSandboxError.pathOutsideWorkspace(path)
        }
        if mustExist, !FileManager.default.fileExists(atPath: resolved.path) {
            throw MinimalAgentSandboxError.fileNotFound(path)
        }
        return resolved
    }

    private func normalizedGuestPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func requireWritable(_ path: String) throws {
        if workspace.isReadOnly {
            throw MinimalAgentSandboxError.operationFailed(
                operation: "write",
                path: path,
                message: "workspace is mounted read-only"
            )
        }
    }

    private func collectEntries(
        hostDirectory: URL,
        guestDirectory: String,
        remainingDepth: Int,
        entries: inout [SandboxDirectoryEntry]
    ) throws {
        guard remainingDepth > 0 else { return }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: hostDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw MinimalAgentSandboxError.operationFailed(
                operation: "list",
                path: guestDirectory,
                message: error.localizedDescription
            )
        }
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let guestPath = guestDirectory + "/" + child.lastPathComponent
            if values.isSymbolicLink == true {
                let resolved = child.resolvingSymlinksInPath()
                guard resolved.path == hostRoot.path || resolved.path.hasPrefix(hostRoot.path + "/") else {
                    throw MinimalAgentSandboxError.pathOutsideWorkspace(guestPath)
                }
            }
            if values.isDirectory == true {
                entries.append(.init(path: guestPath, kind: .directory))
                try collectEntries(
                    hostDirectory: child.resolvingSymlinksInPath(),
                    guestDirectory: guestPath,
                    remainingDepth: remainingDepth - 1,
                    entries: &entries
                )
            } else if values.isRegularFile == true {
                entries.append(.init(path: guestPath, kind: .file))
            } else {
                throw MinimalAgentSandboxError.unsupportedFileType(guestPath)
            }
        }
    }

    private func readData(_ url: URL, operation: String, guestPath: String) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw MinimalAgentSandboxError.operationFailed(
                operation: operation,
                path: guestPath,
                message: error.localizedDescription
            )
        }
    }

    private func version(of url: URL, guestPath: String) throws -> String {
        digest(try readData(url, operation: "version", guestPath: guestPath))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func append(
        line: String,
        to output: inout String,
        remaining: inout Int,
        truncated: inout Bool
    ) {
        guard remaining > 0 else {
            truncated = true
            return
        }
        let rendered = line + "\n"
        if rendered.count <= remaining {
            output += rendered
            remaining -= rendered.count
        } else {
            let end = rendered.index(rendered.startIndex, offsetBy: remaining)
            output += rendered[..<end]
            remaining = 0
            truncated = true
        }
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var isRegularFile: Bool {
        (try? resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
