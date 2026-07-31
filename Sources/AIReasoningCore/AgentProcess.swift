import Foundation

public struct AgentProcessRequest: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL
    public let timeout: Duration

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectoryURL: URL,
        timeout: Duration = .seconds(120)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
    }
}

public enum AgentProcessEvent: Sendable, Equatable {
    case standardOutputLine(String)
    case standardErrorLine(String)
    case terminated(exitCode: Int32)
}

public protocol AgentProcessSession: Sendable {
    var events: AsyncThrowingStream<AgentProcessEvent, any Error> { get }

    func writeStandardInput(_ data: Data) async throws
    func closeStandardInput() async throws
    func interrupt() async
    func terminate() async
}

public protocol AgentProcessExecuting: Sendable {
    func isExecutableAvailable(at url: URL) -> Bool
    func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession
}

public enum AgentProcessExecutionError: Error, LocalizedError, Sendable, Equatable {
    case executableUnavailable(String)
    case launchFailed(String)
    case standardInputClosed
    case standardInputWriteFailed(String)
    case timedOut(seconds: Double)
    case terminatedBeforeCompletion(exitCode: Int32, standardError: String)
    case invalidUTF8Output(stream: String)

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            "Executable is unavailable: \(path)"
        case .launchFailed(let message):
            "Process launch failed: \(message)"
        case .standardInputClosed:
            "Process standard input is closed"
        case .standardInputWriteFailed(let message):
            "Failed to write process standard input: \(message)"
        case .timedOut(let seconds):
            "Process timed out after \(seconds) seconds"
        case .terminatedBeforeCompletion(let exitCode, let standardError):
            "Process terminated before protocol completion (exit \(exitCode)): \(standardError)"
        case .invalidUTF8Output(let stream):
            "Process \(stream) contained invalid UTF-8"
        }
    }
}

package func agentWaitIgnoringCancellation(for duration: Duration) async {
    await Task.detached {
        try? await Task.sleep(for: duration)
    }.value
}
