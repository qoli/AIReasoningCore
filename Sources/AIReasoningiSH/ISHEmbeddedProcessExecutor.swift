// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AIReasoningiSHRuntime
import Foundation

public enum ISHEmbeddedRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case hostRuntimeNotLinked
    case hostRuntimeAlreadyRegistered
    case invalidRootFileSystem(String)
    case invalidSupervisor(String)
    case alreadyBooted
    case notBooted
    case bootFailed(code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .hostRuntimeNotLinked:
            "The OpenMinis iSH host runtime is not linked into this application"
        case .hostRuntimeAlreadyRegistered:
            "An iSH host runtime was already registered in this process"
        case .invalidRootFileSystem(let path):
            "The writable iSH root filesystem is invalid: \(path)"
        case .invalidSupervisor(let path):
            "The iSH guest supervisor is invalid: \(path)"
        case .alreadyBooted:
            "The embedded iSH runtime is already booted"
        case .notBooted:
            "The embedded iSH runtime has not been booted"
        case .bootFailed(let code, let message):
            "Embedded iSH boot failed (\(code)): \(message)"
        case .operationFailed(let operation, let code, let message):
            "Embedded iSH \(operation) failed (\(code)): \(message)"
        }
    }
}

public enum ISHProcessExecutorUnavailableReason: Error, Sendable, Equatable {
    case runtimeNotLinked
    case runtimeNotBooted
}

public struct ISHEmbeddedRuntimeConfiguration: Sendable, Equatable {
    public let rootFileSystemURL: URL
    public let supervisorExecutableURL: URL
    public let initialWorkingDirectory: String
    public let supervisorGuestPath: String

    public init(
        rootFileSystemURL: URL,
        supervisorExecutableURL: URL,
        initialWorkingDirectory: String = "/",
        supervisorGuestPath: String = "/sbin/ishsv"
    ) {
        self.rootFileSystemURL = rootFileSystemURL
        self.supervisorExecutableURL = supervisorExecutableURL
        self.initialWorkingDirectory = initialWorkingDirectory
        self.supervisorGuestPath = supervisorGuestPath
    }
}

/// Owns the single process-global iSH instance permitted by the embedded ABI.
/// Registration and boot are intentionally explicit; this type never loads a
/// framework or substitutes another process executor.
public final class ISHEmbeddedRuntime: @unchecked Sendable {
    public static let shared = ISHEmbeddedRuntime()

    private let lock = NSLock()
    private var instance: OpaquePointer?

    public init() {}

    public static var isHostRuntimeRegistered: Bool {
        ARISHHostRuntimeIsRegistered()
    }

    public static func registerLinkedOpenMinisHost() throws {
        guard !ARISHHostRuntimeIsRegistered() else {
            throw ISHEmbeddedRuntimeError.hostRuntimeAlreadyRegistered
        }
        guard ARISHRegisterLinkedOpenMinisHostRuntime() else {
            throw ISHEmbeddedRuntimeError.hostRuntimeNotLinked
        }
    }

    public static func register(
        hostRuntime: UnsafePointer<ARISHHostRuntimeV1>
    ) throws {
        guard !ARISHHostRuntimeIsRegistered() else {
            throw ISHEmbeddedRuntimeError.hostRuntimeAlreadyRegistered
        }
        guard ARISHRegisterHostRuntimeV1(hostRuntime) else {
            throw ISHEmbeddedRuntimeError.hostRuntimeNotLinked
        }
    }

    public var isBooted: Bool {
        lock.withLock { instance != nil }
    }

    public func boot(_ configuration: ISHEmbeddedRuntimeConfiguration) throws {
        guard Self.isHostRuntimeRegistered else {
            throw ISHEmbeddedRuntimeError.hostRuntimeNotLinked
        }
        guard lock.withLock({ instance == nil }) else {
            throw ISHEmbeddedRuntimeError.alreadyBooted
        }
        let rootPath = configuration.rootFileSystemURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: configuration.rootFileSystemURL.appendingPathComponent("data").path),
              FileManager.default.fileExists(atPath: configuration.rootFileSystemURL.appendingPathComponent("meta.db").path)
        else {
            throw ISHEmbeddedRuntimeError.invalidRootFileSystem(rootPath)
        }

        let supervisorPath = configuration.supervisorExecutableURL.path
        guard let supervisor = try? Data(contentsOf: configuration.supervisorExecutableURL),
              !supervisor.isEmpty
        else {
            throw ISHEmbeddedRuntimeError.invalidSupervisor(supervisorPath)
        }

        var booted: OpaquePointer?
        let status: Int32 = rootPath.withCString { root in
            configuration.initialWorkingDirectory.withCString { workdir in
                configuration.supervisorGuestPath.withCString { guestPath in
                    supervisor.withUnsafeBytes { bytes in
                        var options = ish_embed_boot_opts_t()
                        options.rootfs_path = root
                        options.workdir = workdir
                        options.supervisor_guest_path = guestPath
                        options.supervisor_bytes = bytes.bindMemory(to: UInt8.self).baseAddress
                        options.supervisor_length = bytes.count
                        options.kernel_log_fd = -1
                        return ARISHRuntimeBoot(&options, &booted)
                    }
                }
            }
        }
        guard status == Int32(ISH_OK.rawValue), let booted else {
            throw ISHEmbeddedRuntimeError.bootFailed(
                code: status,
                message: runtimeErrorString(status)
            )
        }
        lock.withLock { instance = booted }
    }

    public func shutdown(gracePeriod: Duration = .seconds(2)) throws {
        guard let current = lock.withLock({ instance }) else {
            throw ISHEmbeddedRuntimeError.notBooted
        }
        let status = ARISHRuntimeShutdown(current, gracePeriod.millisecondsClamped)
        guard status == Int32(ISH_OK.rawValue) else {
            throw ISHEmbeddedRuntimeError.operationFailed(
                operation: "shutdown",
                code: status,
                message: runtimeErrorString(status)
            )
        }
        lock.withLock { instance = nil }
    }

    fileprivate func requireInstance() throws -> OpaquePointer {
        guard let instance = lock.withLock({ instance }) else {
            throw ISHEmbeddedRuntimeError.notBooted
        }
        return instance
    }
}

public struct ISHEmbeddedProcessExecutor: AgentProcessExecuting, Sendable {
    public let runtime: ISHEmbeddedRuntime

    public init(runtime: ISHEmbeddedRuntime = .shared) {
        self.runtime = runtime
    }

    public var unavailableReason: ISHProcessExecutorUnavailableReason? {
        guard ISHEmbeddedRuntime.isHostRuntimeRegistered else {
            return .runtimeNotLinked
        }
        return runtime.isBooted ? nil : .runtimeNotBooted
    }

    public func isExecutableAvailable(at url: URL) -> Bool {
        runtime.isBooted && url.isFileURL && url.path.hasPrefix("/")
    }

    public func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession {
        guard isExecutableAvailable(at: request.executableURL) else {
            throw AgentProcessExecutionError.executableUnavailable(request.executableURL.path)
        }
        let instance = try runtime.requireInstance()
        return try ISHEmbeddedAgentProcessSession(instance: instance, request: request)
    }
}

@available(*, deprecated, renamed: "ISHEmbeddedProcessExecutor")
public typealias ISHShellExecutorProcessExecutor = ISHEmbeddedProcessExecutor

private final class ISHEmbeddedAgentProcessSession: AgentProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentProcessEvent, any Error>

    private let lock = NSLock()
    private let timeout: Duration
    private var continuation: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
    private var session: OpaquePointer?
    private var finished = false
    private var timeoutExpired = false
    private var timeoutTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(instance: OpaquePointer, request: AgentProcessRequest) throws {
        timeout = request.timeout
        var captured: AsyncThrowingStream<AgentProcessEvent, any Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured

        let argv = [request.executableURL.path] + request.arguments
        let environment = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var spawned: OpaquePointer?
        let status = request.workingDirectoryURL.path.withCString { cwd in
            withCStringArray(argv) { argvPointer in
                withCStringArray(environment) { environmentPointer in
                    var options = ish_embed_spawn_opts_t()
                    options.argv = argvPointer
                    options.cwd = cwd
                    options.envp = environmentPointer
                    options.allocate_tty = 0
                    options.merge_stderr_into_stdout = 0
                    return ARISHRuntimeSpawn(instance, &options, &spawned)
                }
            }
        }
        guard status == Int32(ISH_OK.rawValue), let spawned else {
            throw AgentProcessExecutionError.launchFailed(
                "embedded iSH spawn failed (\(status)): \(runtimeErrorString(status))"
            )
        }
        session = spawned
        startReader()
        startTimeout()
    }

    func writeStandardInput(_ data: Data) async throws {
        guard let session = activeSession() else {
            throw AgentProcessExecutionError.standardInputClosed
        }
        let status = data.withUnsafeBytes { bytes in
            ARISHRuntimeWrite(
                session,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        guard status == Int32(ISH_OK.rawValue) else {
            throw AgentProcessExecutionError.standardInputWriteFailed(
                "embedded iSH write failed (\(status)): \(runtimeErrorString(status))"
            )
        }
    }

    func closeStandardInput() async throws {
        guard let session = activeSession() else {
            throw AgentProcessExecutionError.standardInputClosed
        }
        let status = ARISHRuntimeCloseStandardInput(session)
        if status == Int32(ISH_ERR_BROKEN_PIPE.rawValue) {
            throw AgentProcessExecutionError.standardInputClosed
        }
        guard status == Int32(ISH_OK.rawValue) else {
            throw AgentProcessExecutionError.standardInputWriteFailed(
                "embedded iSH close stdin failed (\(status)): \(runtimeErrorString(status))"
            )
        }
    }

    func interrupt() async {
        guard let session = activeSession() else { return }
        _ = ARISHRuntimeSignal(session, 2)
    }

    func terminate() async {
        guard let session = activeSession() else { return }
        _ = ARISHRuntimeTerminate(session, 500)
    }

    private func activeSession() -> OpaquePointer? {
        lock.withLock { finished ? nil : session }
    }

    private func startReader() {
        readerTask = Task.detached { [weak self] in
            self?.readLoop()
        }
    }

    private func startTimeout() {
        timeoutTask = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self else { return }
            lock.withLock { timeoutExpired = true }
            if let session = activeSession() {
                _ = ARISHRuntimeTerminate(session, 500)
            }
        }
    }

    private func readLoop() {
        guard let session = activeSession() else { return }
        while true {
            var buffer: UnsafeMutablePointer<UInt8>?
            var length = 0
            var kind: Int32 = 0
            var sequence: UInt64 = 0
            var exitCode: Int32 = 0
            var signalNumber: Int32 = 0
            let status = ARISHRuntimeRead(
                session,
                100,
                &buffer,
                &length,
                &kind,
                &sequence,
                &exitCode,
                &signalNumber
            )
            if status == Int32(ISH_ERR_TIMEOUT.rawValue) { continue }
            guard status == Int32(ISH_OK.rawValue) else {
                finish(throwing: AgentProcessExecutionError.terminatedBeforeCompletion(
                    exitCode: -1,
                    standardError: "embedded iSH read failed (\(status)): \(runtimeErrorString(status))"
                ))
                ARISHRuntimeCloseSession(session)
                return
            }
            if let buffer, length > 0 {
                let data = Data(bytes: buffer, count: length)
                ARISHRuntimeFree(buffer)
                receive(data, standardError: kind == 2)
            }
            if kind == 3 {
                flushRemainingLines()
                let didTimeOut = lock.withLock { timeoutExpired }
                if didTimeOut {
                    finish(throwing: AgentProcessExecutionError.timedOut(
                        seconds: timeout.secondsValue
                    ))
                } else {
                    finish(exitCode: signalNumber == 0 ? exitCode : 128 + signalNumber)
                }
                ARISHRuntimeCloseSession(session)
                return
            }
        }
    }

    private func receive(_ data: Data, standardError: Bool) {
        lock.withLock {
            guard !finished else { return }
            if standardError {
                stderrBuffer.append(data)
                emitCompleteLines(from: &stderrBuffer, standardError: true)
            } else {
                stdoutBuffer.append(data)
                emitCompleteLines(from: &stdoutBuffer, standardError: false)
            }
        }
    }

    private func emitCompleteLines(from buffer: inout Data, standardError: Bool) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else {
                continuation.finish(
                    throwing: AgentProcessExecutionError.invalidUTF8Output(
                        stream: standardError ? "stderr" : "stdout"
                    )
                )
                finished = true
                return
            }
            continuation.yield(
                standardError ? .standardErrorLine(line) : .standardOutputLine(line)
            )
        }
    }

    private func flushRemainingLines() {
        lock.withLock {
            guard !finished else { return }
            for (buffer, standardError) in [(stdoutBuffer, false), (stderrBuffer, true)]
            where !buffer.isEmpty {
                guard let line = String(data: buffer, encoding: .utf8) else {
                    continuation.finish(
                        throwing: AgentProcessExecutionError.invalidUTF8Output(
                            stream: standardError ? "stderr" : "stdout"
                        )
                    )
                    finished = true
                    return
                }
                continuation.yield(
                    standardError ? .standardErrorLine(line) : .standardOutputLine(line)
                )
            }
            stdoutBuffer.removeAll()
            stderrBuffer.removeAll()
        }
    }

    private func finish(exitCode: Int32) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            session = nil
            continuation.yield(.terminated(exitCode: exitCode))
            continuation.finish()
        }
    }

    private func finish(throwing error: any Error) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            session = nil
            continuation.finish(throwing: error)
        }
    }
}

private func runtimeErrorString(_ status: Int32) -> String {
    guard let message = ARISHRuntimeErrorString(status) else {
        return "unknown error"
    }
    return String(cString: message)
}

private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?) throws -> Result
) rethrows -> Result {
    if strings.isEmpty {
        return try body(nil)
    }
    let storage: [UnsafeMutablePointer<CChar>?] = strings.map { string in
        string.withCString { strdup($0) }
    }
    defer { storage.forEach { free($0) } }
    var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
        pointer.map { UnsafePointer<CChar>($0) }
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress)
    }
}

private extension Duration {
    var millisecondsClamped: UInt32 {
        let value = max(0, secondsValue * 1_000)
        return UInt32(min(value, Double(UInt32.max)))
    }

    var secondsValue: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
