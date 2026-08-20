// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import Foundation
import Testing

@Suite
struct MinimalHarnessToolsTests {
    @Test
    func harnessExposesOnlyBashAndEditor() {
        #expect(MinimalHarness.toolNames == ["bash", "str_replace_editor"])
    }

    @Test
    func editorSchemaUsesTheDSHArgumentContract() throws {
        let data = try JSONEncoder().encode(MinimalStrReplaceEditorTool.Arguments.generationSchema)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let definitions = try #require(object["$defs"] as? [String: Any])
        let argumentDefinition = try #require(
            definitions.values.compactMap { $0 as? [String: Any] }.first {
                $0["properties"] != nil
            }
        )
        let properties = try #require(argumentDefinition["properties"] as? [String: Any])
        #expect(Set(properties.keys) == [
            "command", "path", "file_text", "insert_line", "new_str", "old_str", "view_range",
        ])
    }

    @Test
    func bashReturnsOutputAndNonzeroStatusWithoutApproval() async throws {
        let sandbox = MemorySandbox()
        await sandbox.setBashResult(.init(
            exitCode: 7,
            standardOutput: "out",
            standardError: "bad",
            outputWasTruncated: false
        ))
        let output = try await MinimalBashTool(sandbox: sandbox).call(
            arguments: .init(command: "curl https://example.com")
        )
        #expect(output.contains("out"))
        #expect(output.contains("stderr:\nbad"))
        #expect(output.contains("Process exited with code 7."))
        #expect(await sandbox.lastBashRequest()?.command == "curl https://example.com")
    }

    @Test
    func editorUsesExactUniqueVersionedReplacementAndMultilineInsert() async throws {
        let sandbox = MemorySandbox(files: ["/workspace/a.txt": "one\ntwo\nthree"])
        let editor = MinimalStrReplaceEditorTool(sandbox: sandbox)

        _ = try await editor.call(arguments: .init(
            command: "str_replace",
            path: "/workspace/a.txt",
            file_text: nil,
            insert_line: nil,
            new_str: "TWO",
            old_str: "two",
            view_range: nil
        ))
        _ = try await editor.call(arguments: .init(
            command: "insert",
            path: "/workspace/a.txt",
            file_text: nil,
            insert_line: 1,
            new_str: "alpha\nbeta",
            old_str: nil,
            view_range: nil
        ))
        #expect(try await sandbox.readTextFile(at: "/workspace/a.txt").contents == "one\nalpha\nbeta\nTWO\nthree")
    }

    @Test
    func editorRejectsAmbiguousReplacement() async {
        let sandbox = MemorySandbox(files: ["/workspace/a.txt": "same same"])
        let editor = MinimalStrReplaceEditorTool(sandbox: sandbox)
        await #expect(throws: MinimalAgentSandboxError.self) {
            try await editor.call(arguments: .init(
                command: "str_replace",
                path: "/workspace/a.txt",
                file_text: nil,
                insert_line: nil,
                new_str: "new",
                old_str: "same",
                view_range: nil
            ))
        }
    }
}

private actor MemorySandbox: MinimalAgentSandbox {
    private var files: [String: (contents: String, version: Int)]
    private var bashResult = SandboxBashResult(
        exitCode: 0,
        standardOutput: "",
        standardError: "",
        outputWasTruncated: false
    )
    private var bashRequest: SandboxBashRequest?

    init(files: [String: String] = [:]) {
        self.files = files.mapValues { ($0, 1) }
    }

    func setBashResult(_ result: SandboxBashResult) {
        bashResult = result
    }

    func lastBashRequest() -> SandboxBashRequest? {
        bashRequest
    }

    func runBash(_ request: SandboxBashRequest) async throws -> SandboxBashResult {
        bashRequest = request
        return bashResult
    }

    func fileInfo(at path: String) async throws -> SandboxFileInfo? {
        guard let file = files[path] else { return nil }
        return .init(kind: .file, version: String(file.version))
    }

    func readTextFile(at path: String) async throws -> SandboxTextFile {
        guard let file = files[path] else {
            throw MinimalAgentSandboxError.fileNotFound(path)
        }
        return .init(contents: file.contents, version: String(file.version))
    }

    func listDirectory(at path: String, maximumDepth: Int) async throws -> [SandboxDirectoryEntry] {
        files.keys.sorted().map { .init(path: $0, kind: .file) }
    }

    func createTextFile(at path: String, contents: String) async throws {
        guard files[path] == nil else {
            throw MinimalAgentSandboxError.fileAlreadyExists(path)
        }
        files[path] = (contents, 1)
    }

    func replaceTextFile(
        at path: String,
        expectedVersion: String,
        contents: String
    ) async throws {
        guard let file = files[path] else {
            throw MinimalAgentSandboxError.fileNotFound(path)
        }
        guard expectedVersion == String(file.version) else {
            throw MinimalAgentSandboxError.concurrentModification(path)
        }
        files[path] = (contents, file.version + 1)
    }
}
