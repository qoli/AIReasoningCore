import AIReasoningCore
import AIReasoningiSHRuntime
import Foundation

public enum ISHProcessExecutorUnavailableReason: Error, Sendable, Equatable {
    case runtimeNotLinked
    case incompatibleShellExecutorAPI
}

public struct ISHShellExecutorProcessExecutor: AgentProcessExecuting, Sendable {
    public init() {}

    public var unavailableReason: ISHProcessExecutorUnavailableReason? {
        if !ARISHExecutorClassIsLinked() {
            return .runtimeNotLinked
        }
        return ARISHExecutorIsAvailable() ? nil : .incompatibleShellExecutorAPI
    }

    public func isExecutableAvailable(at url: URL) -> Bool {
        url.isFileURL && ARISHExecutorIsAvailable()
    }

    public func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession {
        guard ARISHExecutorIsAvailable() else {
            throw AgentProcessExecutionError.launchFailed(
                "ISHShellExecutor is not linked or lacks the interactive stdin API"
            )
        }
        let session = ISHAgentProcessSession(timeout: request.timeout)
        let arguments = [
            "-c",
            "cd -- \"$1\" && shift && exec \"$@\"",
            "ai-reasoning-ish",
            request.workingDirectoryURL.path,
            request.executableURL.path,
        ] + request.arguments
        try session.start(
            executable: "/bin/sh",
            arguments: arguments,
            environment: request.environment
        )
        return session
    }
}

private final class ISHAgentProcessSession: AgentProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentProcessEvent, any Error>

    private let lock = NSLock()
    private let timeout: Duration
    private var continuation: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
    private var pid: Int32 = -1
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration) {
        self.timeout = timeout
        var captured: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
        self.events = AsyncThrowingStream { captured = $0 }
        self.continuation = captured
    }

    func start(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let argumentsData = try JSONEncoder().encode(arguments)
        let environmentData = try JSONEncoder().encode(environment)
        let context = Unmanaged.passRetained(self).toOpaque()
        let startedPID = executable.withCString { executablePointer in
            argumentsData.withUnsafeBytes { argumentsBytes in
                environmentData.withUnsafeBytes { environmentBytes in
                    ARISHStart(
                        executablePointer,
                        argumentsBytes.bindMemory(to: UInt8.self).baseAddress,
                        argumentsBytes.count,
                        environmentBytes.bindMemory(to: UInt8.self).baseAddress,
                        environmentBytes.count,
                        ishLineCallback,
                        ishCompletionCallback,
                        context
                    )
                }
            }
        }
        guard startedPID > 0 else {
            Unmanaged<ISHAgentProcessSession>.fromOpaque(context).release()
            throw AgentProcessExecutionError.launchFailed(
                "ISHShellExecutor returned \(startedPID)"
            )
        }
        lock.lock()
        pid = startedPID
        lock.unlock()
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
        let pid = currentPID()
        guard pid > 0 else {
            throw AgentProcessExecutionError.standardInputClosed
        }
        let success = data.withUnsafeBytes {
            ARISHWriteStandardInput(
                pid,
                $0.bindMemory(to: UInt8.self).baseAddress,
                $0.count
            )
        }
        guard success else {
            throw AgentProcessExecutionError.standardInputWriteFailed(
                "ISHShellExecutor rejected the write"
            )
        }
    }

    func closeStandardInput() async throws {
        let pid = currentPID()
        guard pid > 0, ARISHCloseStandardInput(pid) else {
            throw AgentProcessExecutionError.standardInputClosed
        }
    }

    func interrupt() async {
        let pid = currentPID()
        if pid > 0 {
            _ = ARISHKillProcessGroup(pid, 2)
        }
    }

    func terminate() async {
        let pid = currentPID()
        guard pid > 0 else { return }
        _ = ARISHKillProcessGroup(pid, 15)
        await agentWaitIgnoringCancellation(for: .milliseconds(500))
        let stillRunning = lock.withLock { !finished }
        if stillRunning {
            _ = ARISHKillProcessGroup(pid, 9)
        }
    }

    fileprivate func receive(line: String, standardError: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        continuation.yield(
            standardError ? .standardErrorLine(line) : .standardOutputLine(line)
        )
        lock.unlock()
    }

    fileprivate func complete(
        pid: Int32,
        exitCode: Int32,
        executionError: Int32,
        standardError: String
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        timeoutTask?.cancel()
        if executionError == 0 {
            continuation.yield(.terminated(exitCode: exitCode))
            continuation.finish()
        } else {
            continuation.finish(
                throwing: AgentProcessExecutionError.terminatedBeforeCompletion(
                    exitCode: exitCode,
                    standardError: standardError
                )
            )
        }
        lock.unlock()
    }

    private func currentPID() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return finished ? -1 : pid
    }

    private func timeoutExpired() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        continuation.finish(
            throwing: AgentProcessExecutionError.timedOut(
                seconds: timeout.secondsValue
            )
        )
        let pid = self.pid
        lock.unlock()
        if pid > 0 {
            _ = ARISHKillProcessGroup(pid, 9)
        }
    }
}

private let ishLineCallback: @convention(c) (
    UnsafePointer<CChar>?,
    Bool,
    UnsafeMutableRawPointer?
) -> Void = { line, standardError, context in
    guard let line, let context else { return }
    let session = Unmanaged<ISHAgentProcessSession>
        .fromOpaque(context).takeUnretainedValue()
    session.receive(line: String(cString: line), standardError: standardError)
}

private let ishCompletionCallback: @convention(c) (
    Int32,
    Int32,
    Int32,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { pid, exitCode, executionError, standardError, context in
    guard let context else { return }
    let session = Unmanaged<ISHAgentProcessSession>
        .fromOpaque(context).takeRetainedValue()
    session.complete(
        pid: pid,
        exitCode: exitCode,
        executionError: executionError,
        standardError: standardError.map(String.init(cString:)) ?? ""
    )
}

private extension Duration {
    var secondsValue: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
