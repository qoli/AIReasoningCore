// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AIReasoningiSH
import AIReasoningiSHTestSupport
import Foundation
import Testing

@Suite
struct ISHEmbeddedProcessExecutorTests {
    @Test
    func runtimeBridgeIsExplicitWhenUnlinkedAndSupportsInteractiveLifecycle() async throws {
        let runtime = ISHEmbeddedRuntime()
        let executor = ISHEmbeddedProcessExecutor(runtime: runtime)

        #expect(throws: ISHEmbeddedRuntimeError.notBooted) {
            try ISHMinimalAgentSandbox(runtime: runtime)
        }

        #expect(
            !executor.isExecutableAvailable(
                at: URL(fileURLWithPath: "/usr/local/bin/codex")
            )
        )

        #expect(ARISHFixtureInstall())
        let fixture = try makeBootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try runtime.boot(.init(
            rootFileSystemURL: fixture.root,
            supervisorExecutableURL: fixture.supervisor,
            workspaceMount: .init(hostDirectoryURL: workspace)
        ))
        #expect(String(cString: ARISHFixtureWorkspaceHostPath()) == workspace.path)
        #expect(String(cString: ARISHFixtureWorkspaceGuestPath()) == "/workspace")
        #expect(ARISHFixtureWorkspaceReadOnly() == 0)
        #expect(executor.isExecutableAvailable(at: URL(fileURLWithPath: "/usr/local/bin/codex")))

        let sandbox = try ISHMinimalAgentSandbox(runtime: runtime)
        try await sandbox.createTextFile(at: "/workspace/shared.txt", contents: "before")
        let before = try await sandbox.readTextFile(at: "/workspace/shared.txt")
        #expect(before.contents == "before")
        #expect(try String(contentsOf: workspace.appendingPathComponent("shared.txt")) == "before")
        try await sandbox.replaceTextFile(
            at: "/workspace/shared.txt",
            expectedVersion: before.version,
            contents: "after"
        )
        #expect(try String(contentsOf: workspace.appendingPathComponent("shared.txt")) == "after")
        let stale = try await sandbox.readTextFile(at: "/workspace/shared.txt")
        try "external change".write(
            to: workspace.appendingPathComponent("shared.txt"),
            atomically: true,
            encoding: .utf8
        )
        await #expect(throws: MinimalAgentSandboxError.concurrentModification("/workspace/shared.txt")) {
            try await sandbox.replaceTextFile(
                at: "/workspace/shared.txt",
                expectedVersion: stale.version,
                contents: "must not win"
            )
        }
        await #expect(throws: MinimalAgentSandboxError.pathOutsideWorkspace("/workspace/../escape")) {
            _ = try await sandbox.fileInfo(at: "/workspace/../escape")
        }

        let session = try await executor.start(request())
        let binary = Data((0..<131_072).map { UInt8($0 % 251) })
        try await session.writeStandardInput(binary)
        #expect(ARISHFixtureWrittenByteCount() == binary.count)
        #expect(
            ARISHFixtureCountOfByte(0)
                == binary.filter { $0 == 0 }.count
        )
        try await session.closeStandardInput()
        await #expect(throws: AgentProcessExecutionError.standardInputClosed) {
            try await session.closeStandardInput()
        }
        ARISHFixtureComplete(0)
        var events: [AgentProcessEvent] = []
        for try await event in session.events {
            events.append(event)
        }
        #expect(events == [.terminated(exitCode: 0)])

        let concurrentSession = try await executor.start(request())
        await withTaskGroup(of: Void.self) { group in
            for byte in UInt8(1)...UInt8(8) {
                group.addTask {
                    try? await concurrentSession.writeStandardInput(
                        Data(repeating: byte, count: 8_192)
                    )
                }
            }
        }
        #expect(ARISHFixtureWrittenByteCount() == 65_536)
        for byte in UInt8(1)...UInt8(8) {
            #expect(ARISHFixtureCountOfByte(byte) == 8_192)
        }

        await concurrentSession.interrupt()
        #expect(ARISHFixtureSignalAtIndex(0) == 2)
        await concurrentSession.terminate()
        #expect(ARISHFixtureSignalCount() == 3)
        #expect(ARISHFixtureSignalAtIndex(1) == 15)
        #expect(ARISHFixtureSignalAtIndex(2) == 9)
        ARISHFixtureComplete(130)
    }

    private func makeBootFixture() throws -> (root: URL, supervisor: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("meta.db").path,
            contents: Data("fixture".utf8)
        )
        let supervisor = root.appendingPathComponent("ishsv")
        FileManager.default.createFile(atPath: supervisor.path, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        return (root, supervisor)
    }

    private func request() -> AgentProcessRequest {
        .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/codex"),
            arguments: ["app-server"],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: .seconds(5)
        )
    }
}
