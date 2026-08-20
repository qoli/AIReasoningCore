// SPDX-License-Identifier: GPL-3.0-or-later

import AnyLanguageModel
import Foundation

public struct MinimalStrReplaceEditorTool: Tool, Sendable {
    @Generable
    public struct Arguments {
        @Guide(description: "One of: view, create, str_replace, insert.")
        public var command: String
        @Guide(description: "Absolute guest path under /workspace.")
        public var path: String
        @Guide(description: "Required file contents for create.")
        public var file_text: String?
        @Guide(description: "Required one-based line after which insert adds new_str. Use 0 to insert before the first line.")
        public var insert_line: Int?
        @Guide(description: "Replacement text for str_replace, or required inserted text for insert.")
        public var new_str: String?
        @Guide(description: "Required exact, unique source text for str_replace.")
        public var old_str: String?
        @Guide(description: "Optional one-based inclusive [start, end] range for view; end -1 means EOF.")
        public var view_range: [Int]?

    }

    public let name = "str_replace_editor"
    public let description = "View, create, replace exact text in, or insert lines into files in /workspace. Exact replacement text must occur once."

    private let sandbox: any MinimalAgentSandbox
    private let maximumOutputCharacters: Int

    public init(
        sandbox: any MinimalAgentSandbox,
        maximumOutputCharacters: Int = 16_000
    ) {
        self.sandbox = sandbox
        self.maximumOutputCharacters = max(0, maximumOutputCharacters)
    }

    public func call(arguments: Arguments) async throws -> String {
        switch arguments.command {
        case "view":
            return try await view(path: arguments.path, range: arguments.view_range)
        case "create":
            guard let contents = arguments.file_text else {
                throw MinimalAgentSandboxError.invalidRequest("file_text is required for create")
            }
            try await sandbox.createTextFile(at: arguments.path, contents: contents)
            return "The file \(arguments.path) has been created successfully."
        case "str_replace":
            guard let oldValue = arguments.old_str, !oldValue.isEmpty else {
                throw MinimalAgentSandboxError.invalidRequest("old_str is required and must not be empty for str_replace")
            }
            let file = try await sandbox.readTextFile(at: arguments.path)
            let offsets = matchOffsets(of: oldValue, in: file.contents)
            guard !offsets.isEmpty else {
                throw MinimalAgentSandboxError.invalidRequest("old_str did not appear verbatim in \(arguments.path)")
            }
            guard offsets.count == 1, let offset = offsets.first else {
                throw MinimalAgentSandboxError.invalidRequest(
                    "old_str appears multiple times in \(arguments.path); include more context"
                )
            }
            let end = file.contents.index(offset, offsetBy: oldValue.count)
            var updated = file.contents
            updated.replaceSubrange(offset..<end, with: arguments.new_str ?? "")
            try await sandbox.replaceTextFile(
                at: arguments.path,
                expectedVersion: file.version,
                contents: updated
            )
            return "The file \(arguments.path) has been edited successfully."
        case "insert":
            guard let line = arguments.insert_line, line >= 0 else {
                throw MinimalAgentSandboxError.invalidRequest("insert_line is required and must be nonnegative for insert")
            }
            guard let inserted = arguments.new_str else {
                throw MinimalAgentSandboxError.invalidRequest("new_str is required for insert")
            }
            let file = try await sandbox.readTextFile(at: arguments.path)
            let lines = file.contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard line <= lines.count else {
                throw MinimalAgentSandboxError.invalidRequest(
                    "insert_line \(line) exceeds the file's \(lines.count) lines"
                )
            }
            var updatedLines = lines
            updatedLines.insert(
                contentsOf: inserted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                at: line
            )
            try await sandbox.replaceTextFile(
                at: arguments.path,
                expectedVersion: file.version,
                contents: updatedLines.joined(separator: "\n")
            )
            return "The file \(arguments.path) has been edited successfully."
        default:
            throw MinimalAgentSandboxError.invalidRequest(
                "command must be one of view, create, str_replace, insert"
            )
        }
    }

    private func view(path: String, range: [Int]?) async throws -> String {
        guard let info = try await sandbox.fileInfo(at: path) else {
            throw MinimalAgentSandboxError.fileNotFound(path)
        }
        switch info.kind {
        case .directory:
            guard range == nil else {
                throw MinimalAgentSandboxError.invalidRequest("view_range is not valid for a directory")
            }
            let entries = try await sandbox.listDirectory(at: path, maximumDepth: 2)
            let rendered = entries.map { entry in
                "\(entry.kind == .directory ? "directory" : "file")\t\(entry.path)"
            }.joined(separator: "\n")
            return clipped(rendered)
        case .file:
            let file = try await sandbox.readTextFile(at: path)
            let lines = file.contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let selected = try selectedLines(lines, range: range)
            let rendered = selected.map { number, line in
                "\(String(format: "%6d", number))  \(line)"
            }.joined(separator: "\n")
            return clipped(rendered)
        }
    }

    private func selectedLines(
        _ lines: [String],
        range: [Int]?
    ) throws -> [(Int, String)] {
        guard let range else {
            return lines.enumerated().map { ($0.offset + 1, $0.element) }
        }
        guard range.count == 2 else {
            throw MinimalAgentSandboxError.invalidRequest("view_range must contain exactly two integers")
        }
        let start = range[0]
        let requestedEnd = range[1]
        guard start >= 1, start <= lines.count else {
            throw MinimalAgentSandboxError.invalidRequest("view_range start is outside the file")
        }
        let end = requestedEnd == -1 ? lines.count : requestedEnd
        guard end >= start, end <= lines.count else {
            throw MinimalAgentSandboxError.invalidRequest("view_range end is outside the file")
        }
        return (start...end).map { ($0, lines[$0 - 1]) }
    }

    private func matchOffsets(of search: String, in contents: String) -> [String.Index] {
        var offsets: [String.Index] = []
        var cursor = contents.startIndex
        while cursor < contents.endIndex,
              let range = contents.range(of: search, range: cursor..<contents.endIndex)
        {
            offsets.append(range.lowerBound)
            cursor = range.upperBound
        }
        return offsets
    }

    private func clipped(_ value: String) -> String {
        guard value.count > maximumOutputCharacters else { return value }
        let end = value.index(value.startIndex, offsetBy: maximumOutputCharacters)
        return String(value[..<end]) + "<response clipped>"
    }
}
