// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AIReasoningiSH
import Foundation
import Testing

@Suite
struct CodexCLIAuthenticationManagerTests {
    @Test
    func statusDistinguishesAuthenticatedAndNotAuthenticatedFixtures() async throws {
        let authenticatedExecutor = FixtureExecutor(responses: [
            .immediate([
                .standardOutputLine("Logged in using ChatGPT"),
                .terminated(exitCode: 0),
            ]),
        ])
        let authenticatedManager = manager(executor: authenticatedExecutor)
        #expect(
            try await authenticatedManager.status()
                == .authenticated(description: "Logged in using ChatGPT")
        )

        let signedOutExecutor = FixtureExecutor(responses: [
            .immediate([
                .standardOutputLine("Not logged in"),
                .terminated(exitCode: 1),
            ]),
        ])
        #expect(try await manager(executor: signedOutExecutor).status() == .notAuthenticated)
    }

    @Test
    func unrecognizedStatusFailsInsteadOfGuessingAuthentication() async {
        let executor = FixtureExecutor(responses: [
            .immediate([
                .standardErrorLine("guest filesystem unavailable"),
                .terminated(exitCode: 1),
            ]),
        ])

        await #expect(
            throws: CodexCLIAuthenticationError.invalidStatusOutput(
                exitCode: 1,
                output: "guest filesystem unavailable"
            )
        ) {
            try await manager(executor: executor).status()
        }
    }

    @Test
    func successfulExitWithoutLoggedInContractIsNotAuthenticated() async {
        let executor = FixtureExecutor(responses: [
            .immediate([
                .standardOutputLine("Status unavailable"),
                .terminated(exitCode: 0),
            ]),
        ])

        await #expect(
            throws: CodexCLIAuthenticationError.invalidStatusOutput(
                exitCode: 0,
                output: "Status unavailable"
            )
        ) {
            try await manager(executor: executor).status()
        }
    }

    @Test
    func deviceLoginUsesCLIAndStreamsItsOutputVerbatim() async throws {
        let executor = FixtureExecutor(responses: [
            .immediate([
                .standardErrorLine("Open https://auth.openai.com/codex/device"),
                .standardErrorLine("Enter ABCD-EFGH"),
                .terminated(exitCode: 0),
            ]),
            .immediate([
                .standardOutputLine("Logged in using ChatGPT"),
                .terminated(exitCode: 0),
            ]),
        ])
        let collector = OutputCollector()

        let status = try await manager(executor: executor).loginWithDeviceCode {
            await collector.append($0)
        }

        #expect(status == .authenticated(description: "Logged in using ChatGPT"))
        #expect(
            await collector.values == [
                .init(stream: .standardError, line: "Open https://auth.openai.com/codex/device"),
                .init(stream: .standardError, line: "Enter ABCD-EFGH"),
            ]
        )
        let requests = executor.requests
        #expect(requests.map(\.arguments) == [["login", "--device-auth"], ["login", "status"]])
        #expect(executor.sessions[0].standardInputClosed)
        #expect(requests[0].initialStandardInput == nil)
        #expect(executor.sessions[0].standardInput.isEmpty)
    }

    @Test
    func apiKeyUsesStandardInputAndNeverArgumentsOrEnvironment() async throws {
        let executor = FixtureExecutor(responses: [
            .immediate([.terminated(exitCode: 0)]),
            .immediate([
                .standardOutputLine("Logged in using an API key"),
                .terminated(exitCode: 0),
            ]),
        ])
        let secret = "fixture-secret-value"

        _ = try await manager(executor: executor).loginWithAPIKey(secret)

        let requests = executor.requests
        #expect(requests[0].arguments == ["login", "--with-api-key"])
        #expect(!requests[0].arguments.joined().contains(secret))
        #expect(!requests[0].environment.values.joined().contains(secret))
        #expect(executor.sessions[0].standardInput == Data((secret + "\n").utf8))
        #expect(executor.sessions[0].standardInputClosed)
    }

    @Test
    func emptyCredentialFailsBeforeStartingProcess() async {
        let executor = FixtureExecutor(responses: [])

        await #expect(throws: CodexCLIAuthenticationError.emptyCredential) {
            try await manager(executor: executor).loginWithAPIKey("")
        }
        #expect(executor.requests.isEmpty)
    }

    @Test
    func logoutMustBeConfirmedBySignedOutStatus() async throws {
        let executor = FixtureExecutor(responses: [
            .immediate([.terminated(exitCode: 0)]),
            .immediate([
                .standardOutputLine("Not logged in"),
                .terminated(exitCode: 1),
            ]),
        ])

        try await manager(executor: executor).logout()

        #expect(executor.requests.map(\.arguments) == [["logout"], ["login", "status"]])
    }

    @Test
    func failedLoginDoesNotRunStatusOrClaimSuccess() async {
        let executor = FixtureExecutor(responses: [
            .immediate([
                .standardErrorLine("authorization denied"),
                .terminated(exitCode: 1),
            ]),
        ])

        await #expect(
            throws: CodexCLIAuthenticationError.commandFailed(
                operation: .deviceLogin,
                exitCode: 1,
                standardError: "authorization denied"
            )
        ) {
            try await manager(executor: executor).loginWithDeviceCode()
        }
        #expect(executor.requests.count == 1)
    }

    @Test
    func cancellationInterruptsThenTerminatesTheLoginProcess() async throws {
        let executor = FixtureExecutor(responses: [.waitForTermination])
        let authentication = manager(
            executor: executor,
            cancellationGracePeriod: .milliseconds(10)
        )
        let task = Task {
            try await authentication.loginWithDeviceCode()
        }
        while executor.sessions.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(executor.sessions[0].interruptCount == 1)
        #expect(executor.sessions[0].terminateCount == 1)
    }

    @Test
    func unavailableExecutableFailsBeforeStartingProcess() async {
        let executor = FixtureExecutor(responses: [], executableAvailable: false)

        await #expect(
            throws: CodexCLIAuthenticationError.executableUnavailable("/usr/bin/codex")
        ) {
            try await manager(executor: executor).status()
        }
        #expect(executor.requests.isEmpty)
    }

    private func manager(
        executor: FixtureExecutor,
        cancellationGracePeriod: Duration = .milliseconds(1)
    ) -> CodexCLIAuthenticationManager {
        .init(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/codex"),
                workingDirectoryURL: URL(fileURLWithPath: "/root"),
                timeout: .seconds(5),
                cancellationGracePeriod: cancellationGracePeriod
            ),
            executor: executor
        )
    }
}

private actor OutputCollector {
    private(set) var values: [CodexCLIAuthenticationOutput] = []

    func append(_ output: CodexCLIAuthenticationOutput) {
        values.append(output)
    }
}

private enum FixtureResponse: Sendable {
    case immediate([AgentProcessEvent])
    case waitForTermination
}

private final class FixtureExecutor: AgentProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var responseQueue: [FixtureResponse]
    private var capturedRequests: [AgentProcessRequest] = []
    private var capturedSessions: [FixtureSession] = []
    private let executableAvailable: Bool

    init(responses: [FixtureResponse], executableAvailable: Bool = true) {
        self.responseQueue = responses
        self.executableAvailable = executableAvailable
    }

    var requests: [AgentProcessRequest] {
        lock.withLock { capturedRequests }
    }

    var sessions: [FixtureSession] {
        lock.withLock { capturedSessions }
    }

    func isExecutableAvailable(at url: URL) -> Bool {
        executableAvailable
    }

    func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession {
        try lock.withLock {
            guard !responseQueue.isEmpty else {
                throw FixtureError.missingResponse
            }
            let session = FixtureSession(response: responseQueue.removeFirst())
            capturedRequests.append(request)
            capturedSessions.append(session)
            return session
        }
    }
}

private final class FixtureSession: AgentProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentProcessEvent, any Error>

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation
    private var input = Data()
    private var inputClosed = false
    private var interrupts = 0
    private var terminations = 0

    init(response: FixtureResponse) {
        var captured: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured
        if case .immediate(let events) = response {
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    var standardInput: Data { lock.withLock { input } }
    var standardInputClosed: Bool { lock.withLock { inputClosed } }
    var interruptCount: Int { lock.withLock { interrupts } }
    var terminateCount: Int { lock.withLock { terminations } }

    func writeStandardInput(_ data: Data) async throws {
        try lock.withLock {
            guard !inputClosed else {
                throw AgentProcessExecutionError.standardInputClosed
            }
            input.append(data)
        }
    }

    func closeStandardInput() async throws {
        try lock.withLock {
            guard !inputClosed else {
                throw AgentProcessExecutionError.standardInputClosed
            }
            inputClosed = true
        }
    }

    func interrupt() async {
        lock.withLock { interrupts += 1 }
    }

    func terminate() async {
        lock.withLock { terminations += 1 }
        continuation.yield(.terminated(exitCode: 130))
        continuation.finish()
    }
}

private enum FixtureError: Error {
    case missingResponse
}
