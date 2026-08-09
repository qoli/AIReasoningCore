// SPDX-License-Identifier: GPL-3.0-or-later

#if os(macOS)
@testable import AIReasoningCore
import Foundation
import Testing

@Suite
struct MacOSAgentProcessExecutorTests {
    @Test
    func emitsStdoutStderrAndExitStatus() async throws {
        let session = try await MacOSAgentProcessExecutor().start(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'out\\n'; printf 'err\\n' >&2; exit 7"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            )
        )
        try await session.closeStandardInput()

        var events: [AgentProcessEvent] = []
        for try await event in session.events {
            events.append(event)
        }

        #expect(events.contains(.standardOutputLine("out")))
        #expect(events.contains(.standardErrorLine("err")))
        #expect(events.contains(.terminated(exitCode: 7)))
    }

    @Test
    func timeoutTerminatesTheIsolatedProcessGroup() async throws {
        let session = try await MacOSAgentProcessExecutor().start(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 5"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: .milliseconds(50)
            )
        )
        try await session.closeStandardInput()

        await #expect(throws: AgentProcessExecutionError.self) {
            for try await _ in session.events {}
        }
    }
}
#endif
