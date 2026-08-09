// SPDX-License-Identifier: GPL-3.0-or-later

#if os(macOS)
import Darwin
import Foundation

public struct MacOSAgentProcessExecutor: AgentProcessExecuting {
    public init() {}

    public func isExecutableAvailable(at url: URL) -> Bool {
        url.isFileURL && FileManager.default.isExecutableFile(atPath: url.path)
    }

    public func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession {
        guard isExecutableAvailable(at: request.executableURL) else {
            throw AgentProcessExecutionError.executableUnavailable(request.executableURL.path)
        }
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectoryURL
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        var environment = ProcessInfo.processInfo.environment
        environment.merge(request.environment) { _, configured in configured }
        process.environment = environment

        let session = MacOSAgentProcessSession(
            process: process,
            standardInput: standardInput.fileHandleForWriting,
            standardOutput: standardOutput.fileHandleForReading,
            standardError: standardError.fileHandleForReading,
            timeout: request.timeout
        )

        do {
            try process.run()
        } catch {
            throw AgentProcessExecutionError.launchFailed(String(describing: error))
        }

        if setpgid(process.processIdentifier, process.processIdentifier) != 0,
           getpgid(process.processIdentifier) != process.processIdentifier
        {
            process.terminate()
            throw AgentProcessExecutionError.launchFailed(
                "Could not isolate subprocess process group: \(String(cString: strerror(errno)))"
            )
        }
        session.didLaunch()
        if let initialStandardInput = request.initialStandardInput {
            try await session.writeStandardInput(initialStandardInput)
        }
        return session
    }
}

private final class MacOSAgentProcessSession: AgentProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentProcessEvent, any Error>

    private let process: Process
    private let standardInput: FileHandle
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let timeout: Duration
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdinClosed = false
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    init(
        process: Process,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle,
        timeout: Duration
    ) {
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timeout = timeout

        var captured: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
        self.events = AsyncThrowingStream { captured = $0 }
        self.continuation = captured
    }

    func didLaunch() {
        standardOutput.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, standardError: false)
        }
        standardError.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, standardError: true)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(exitCode: process.terminationStatus)
        }

        timeoutTask = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.timeoutExpired()
        }
    }

    func writeStandardInput(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let canWrite = lock.withLock { !stdinClosed && !finished }
        guard canWrite else {
            throw AgentProcessExecutionError.standardInputClosed
        }

        do {
            try standardInput.write(contentsOf: data)
        } catch {
            throw AgentProcessExecutionError.standardInputWriteFailed(String(describing: error))
        }
    }

    func closeStandardInput() async throws {
        let shouldClose = lock.withLock {
            guard !stdinClosed else { return false }
            stdinClosed = true
            return true
        }
        guard shouldClose else { return }
        do {
            try standardInput.close()
        } catch {
            throw AgentProcessExecutionError.standardInputWriteFailed(String(describing: error))
        }
    }

    func interrupt() async {
        guard process.isRunning else { return }
        _ = kill(-process.processIdentifier, SIGINT)
    }

    func terminate() async {
        guard process.isRunning else { return }
        _ = kill(-process.processIdentifier, SIGTERM)
        await agentWaitIgnoringCancellation(for: .milliseconds(500))
        if process.isRunning {
            _ = kill(-process.processIdentifier, SIGKILL)
        }
    }

    private func receive(_ data: Data, standardError: Bool) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if standardError {
            stderrBuffer.append(data)
            emitCompleteLines(from: &stderrBuffer, event: AgentProcessEvent.standardErrorLine)
        } else {
            stdoutBuffer.append(data)
            emitCompleteLines(from: &stdoutBuffer, event: AgentProcessEvent.standardOutputLine)
        }
        lock.unlock()
    }

    private func emitCompleteLines(
        from buffer: inout Data,
        event: (String) -> AgentProcessEvent
    ) {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[..<newlineIndex]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                finishLocked(
                    throwing: AgentProcessExecutionError.invalidUTF8Output(
                        stream: event("") == .standardErrorLine("") ? "stderr" : "stdout"
                    )
                )
                return
            }
            continuation.yield(event(line))
            buffer.removeSubrange(...newlineIndex)
        }
    }

    private func processDidTerminate(exitCode: Int32) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }

        flushRemainder(&stdoutBuffer, event: AgentProcessEvent.standardOutputLine)
        flushRemainder(&stderrBuffer, event: AgentProcessEvent.standardErrorLine)
        continuation.yield(.terminated(exitCode: exitCode))
        finishLocked()
        lock.unlock()
    }

    private func flushRemainder(
        _ buffer: inout Data,
        event: (String) -> AgentProcessEvent
    ) {
        guard !buffer.isEmpty else { return }
        if let line = String(data: buffer, encoding: .utf8) {
            continuation.yield(event(line))
        } else {
            finishLocked(
                throwing: AgentProcessExecutionError.invalidUTF8Output(stream: "process output")
            )
        }
        buffer.removeAll(keepingCapacity: false)
    }

    private func timeoutExpired() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finishLocked(
            throwing: AgentProcessExecutionError.timedOut(seconds: timeout.secondsValue)
        )
        lock.unlock()
        Task { await terminate() }
    }

    private func finishLocked(throwing error: (any Error)? = nil) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

private extension Duration {
    var secondsValue: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
#endif
