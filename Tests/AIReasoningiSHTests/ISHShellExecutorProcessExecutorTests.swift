import AIReasoningCore
import AIReasoningiSH
import AIReasoningiSHTestSupport
import Foundation
import Testing

@Suite
struct ISHShellExecutorProcessExecutorTests {
    @Test
    func runtimeBridgeIsExplicitWhenUnlinkedAndSupportsInteractiveLifecycle() async throws {
        let executor = ISHShellExecutorProcessExecutor()

        #expect(executor.unavailableReason == .runtimeNotLinked)
        #expect(
            !executor.isExecutableAvailable(
                at: URL(fileURLWithPath: "/usr/local/bin/codex")
            )
        )

        #expect(ARISHFixtureInstall())
        #expect(executor.unavailableReason == nil)

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

    private func request() -> AgentProcessRequest {
        .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/codex"),
            arguments: ["app-server"],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: .seconds(5)
        )
    }
}
