import Foundation

package struct CodexDriver: AgentTextStreamingDriver {
    package let name = "codex"

    private let executor: any AgentProcessExecuting
    private let configuration: AgentDriverConfiguration

    package init(
        executor: any AgentProcessExecuting,
        configuration: AgentDriverConfiguration
    ) {
        self.executor = executor
        self.configuration = configuration
    }

    package func stream(
        _ request: AgentGenerationRequest
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await AgentDriverSupport.validateVersion(
            driverName: name,
            minimumVersion: "0.146.0",
            versionArguments: ["--version"],
            executor: executor,
            configuration: configuration
        )
        let mcpDisableArguments = try await disabledMCPServerArguments()

        return AsyncThrowingStream { continuation in
            let task = Task {
                var stagedPaths: [String] = []
                var processSession: (any AgentProcessSession)?
                let cancellation = CodexCancellationState(
                    gracePeriod: configuration.interruptGracePeriod
                )

                do {
                    stagedPaths = try await AgentTemporaryArtifacts.stageImages(
                        request.prompt.images,
                        executor: executor,
                        configuration: configuration
                    )

                    let processRequest = AgentProcessRequest(
                        executableURL: configuration.executableURL,
                        arguments: [
                            "--disable", "shell_tool",
                            "--disable", "multi_agent",
                            "--disable", "multi_agent_v2",
                            "--disable", "standalone_web_search",
                            "--disable", "browser_use",
                            "--disable", "computer_use",
                            "--disable", "apps",
                            "--disable", "plugins",
                            "-c", "project_doc_max_bytes=0",
                            "-c", "tools.web_search=false",
                        ] + mcpDisableArguments + [
                            "app-server",
                            "--listen", "stdio://",
                        ],
                        environment: configuration.environment,
                        workingDirectoryURL: configuration.workingDirectoryURL,
                        timeout: configuration.timeout
                    )
                    let session = try await executor.start(processRequest)
                    processSession = session
                    cancellation.attach(session)

                    try await session.writeStandardInput(
                        AgentDriverSupport.encodeLine(Self.initializeRequest)
                    )

                    var stderr: [String] = []
                    var completed = false

                    eventLoop: for try await event in session.events {
                        try Task.checkCancellation()
                        switch event {
                        case .standardErrorLine(let line):
                            stderr.append(line)
                        case .terminated(let exitCode):
                            guard completed else {
                                throw AgentProcessExecutionError.terminatedBeforeCompletion(
                                    exitCode: exitCode,
                                    standardError: stderr.joined(separator: "\n")
                                )
                            }
                        case .standardOutputLine(let line):
                            let value: PackageJSONValue
                            do {
                                value = try PackageJSONValue.decode(line)
                            } catch {
                                throw AgentLanguageModelError.malformedProtocolMessage(
                                    driver: name,
                                    message: line
                                )
                            }
                            guard let object = value.objectValue else {
                                throw AgentLanguageModelError.malformedProtocolMessage(
                                    driver: name,
                                    message: line
                                )
                            }

                            if let error = object["error"] {
                                throw AgentLanguageModelError.protocolFailure(
                                    driver: name,
                                    message: (try? error.jsonString) ?? String(describing: error)
                                )
                            }

                            if let id = object["id"]?.integerValue {
                                switch id {
                                case 1:
                                    try await session.writeStandardInput(
                                        AgentDriverSupport.encodeLine(Self.initializedNotification)
                                    )
                                    try await session.writeStandardInput(
                                        AgentDriverSupport.encodeLine(
                                            threadStartRequest(configuration: configuration)
                                        )
                                    )
                                case 2:
                                    guard let threadID = object["result"]?.objectValue?["thread"]?
                                        .objectValue?["id"]?.stringValue
                                    else {
                                        throw AgentLanguageModelError.malformedProtocolMessage(
                                            driver: name,
                                            message: "thread/start response missing thread.id"
                                        )
                                    }
                                    cancellation.setThreadID(threadID)
                                    try await session.writeStandardInput(
                                        AgentDriverSupport.encodeLine(
                                            turnStartRequest(
                                                threadID: threadID,
                                                request: request,
                                                stagedPaths: stagedPaths,
                                                configuration: configuration
                                            )
                                        )
                                    )
                                case 3:
                                    guard let turnID = object["result"]?.objectValue?["turn"]?
                                        .objectValue?["id"]?.stringValue
                                    else {
                                        throw AgentLanguageModelError.malformedProtocolMessage(
                                            driver: name,
                                            message: "turn/start response missing turn.id"
                                        )
                                    }
                                    cancellation.setTurnID(turnID)
                                default:
                                    break
                                }
                                continue
                            }

                            guard let method = object["method"]?.stringValue else {
                                continue
                            }
                            switch method {
                            case "item/agentMessage/delta":
                                guard let delta = object["params"]?.objectValue?["delta"]?.stringValue
                                else {
                                    throw AgentLanguageModelError.malformedProtocolMessage(
                                        driver: name,
                                        message: "agent message delta missing params.delta"
                                    )
                                }
                                continuation.yield(delta)
                            case "turn/completed":
                                guard let status = object["params"]?.objectValue?["turn"]?
                                    .objectValue?["status"]?.stringValue
                                else {
                                    throw AgentLanguageModelError.malformedProtocolMessage(
                                        driver: name,
                                        message: "turn/completed missing turn.status"
                                    )
                                }
                                guard status == "completed" else {
                                    throw AgentLanguageModelError.protocolFailure(
                                        driver: name,
                                        message: "turn completed with status \(status)"
                                    )
                                }
                                completed = true
                                break eventLoop
                            default:
                                break
                            }
                        }
                    }

                    try Task.checkCancellation()
                    guard completed else {
                        throw AgentLanguageModelError.missingProtocolResult(driver: name)
                    }
                    await session.terminate()
                    try await AgentTemporaryArtifacts.remove(
                        stagedPaths,
                        executor: executor,
                        configuration: configuration
                    )
                    continuation.finish()
                } catch is CancellationError {
                    await cancellation.cancel()
                    do {
                        try await AgentTemporaryArtifacts.remove(
                            stagedPaths,
                            executor: executor,
                            configuration: configuration
                        )
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    if let processSession {
                        await processSession.terminate()
                    }
                    do {
                        try await AgentTemporaryArtifacts.remove(
                            stagedPaths,
                            executor: executor,
                            configuration: configuration
                        )
                        continuation.finish(throwing: error)
                    } catch let cleanupError {
                        continuation.finish(
                            throwing: AgentLanguageModelError.artifactCleanupFailed(
                                "original error: \(error); cleanup error: \(cleanupError)"
                            )
                        )
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func disabledMCPServerArguments() async throws -> [String] {
        let request = AgentProcessRequest(
            executableURL: configuration.executableURL,
            arguments: ["mcp", "list", "--json"],
            environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL,
            timeout: .seconds(15)
        )
        let session = try await executor.start(request)
        try await session.closeStandardInput()
        var stdout: [String] = []
        var stderr: [String] = []
        var exitCode: Int32?
        for try await event in session.events {
            switch event {
            case .standardOutputLine(let line): stdout.append(line)
            case .standardErrorLine(let line): stderr.append(line)
            case .terminated(let code): exitCode = code
            }
        }
        guard exitCode == 0 else {
            throw AgentLanguageModelError.protocolFailure(
                driver: name,
                message: "mcp list failed: \(stderr.joined(separator: "\n"))"
            )
        }
        let value: PackageJSONValue
        do {
            value = try PackageJSONValue.decode(stdout.joined(separator: "\n"))
        } catch {
            throw AgentLanguageModelError.malformedProtocolMessage(
                driver: name,
                message: "mcp list --json did not return JSON: \(error)"
            )
        }
        guard let servers = value.arrayValue else {
            throw AgentLanguageModelError.malformedProtocolMessage(
                driver: name,
                message: "mcp list --json did not return an array"
            )
        }
        let names = try servers.enumerated().map { index, server -> String in
            guard let name = server.objectValue?["name"]?.stringValue,
                  !name.isEmpty,
                  name.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  })
            else {
                throw AgentLanguageModelError.malformedProtocolMessage(
                    driver: self.name,
                    message: "mcp list entry \(index) has an invalid name"
                )
            }
            return name
        }
        return Set(names).sorted().flatMap { name in
            let escaped = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return [
                "-c",
                "mcp_servers.\"\(escaped)\".enabled=false",
            ]
        }
    }

    private static let initializeRequest: PackageJSONValue = .object([
        "id": .number(1),
        "method": .string("initialize"),
        "params": .object([
            "clientInfo": .object([
                "name": .string("ai_reasoning_core"),
                "title": .string("AIReasoningCore"),
                "version": .string("0.1.0"),
            ])
        ]),
    ])

    private static let initializedNotification: PackageJSONValue = .object([
        "method": .string("initialized"),
        "params": .object([:]),
    ])

    private func threadStartRequest(
        configuration: AgentDriverConfiguration
    ) -> PackageJSONValue {
        .object([
            "id": .number(2),
            "method": .string("thread/start"),
            "params": .object([
                "model": .string(configuration.model),
                "cwd": .string(configuration.workingDirectoryURL.path),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
                "ephemeral": .bool(true),
                "serviceName": .string("ai_reasoning_core"),
            ]),
        ])
    }

    private func turnStartRequest(
        threadID: String,
        request: AgentGenerationRequest,
        stagedPaths: [String],
        configuration: AgentDriverConfiguration
    ) -> PackageJSONValue {
        var inputs: [PackageJSONValue] = [
            .object([
                "type": .string("text"),
                "text": .string(request.prompt.transcriptText),
            ])
        ]
        inputs.append(
            contentsOf: stagedPaths.map {
                .object([
                    "type": .string("localImage"),
                    "path": .string($0),
                ])
            }
        )

        var params: [String: PackageJSONValue] = [
            "threadId": .string(threadID),
            "input": .array(inputs),
            "cwd": .string(configuration.workingDirectoryURL.path),
            "approvalPolicy": .string("never"),
            "sandboxPolicy": .object([
                "type": .string("readOnly"),
                "networkAccess": .bool(false),
            ]),
            "model": .string(configuration.model),
        ]
        if let outputSchema = request.outputSchema {
            params["outputSchema"] = outputSchema
        }
        return .object([
            "id": .number(3),
            "method": .string("turn/start"),
            "params": .object(params),
        ])
    }
}

private final class CodexCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private let gracePeriod: Duration
    private var session: (any AgentProcessSession)?
    private var threadID: String?
    private var turnID: String?

    init(gracePeriod: Duration) {
        self.gracePeriod = gracePeriod
    }

    func attach(_ session: any AgentProcessSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func setThreadID(_ value: String) {
        lock.lock()
        threadID = value
        lock.unlock()
    }

    func setTurnID(_ value: String) {
        lock.lock()
        turnID = value
        lock.unlock()
    }

    func cancel() async {
        let state = lock.withLock {
            (session: self.session, threadID: self.threadID, turnID: self.turnID)
        }

        guard let session = state.session else { return }
        if let threadID = state.threadID, let turnID = state.turnID {
            let request: PackageJSONValue = .object([
                "id": .number(4),
                "method": .string("turn/interrupt"),
                "params": .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                ]),
            ])
            if let data = try? AgentDriverSupport.encodeLine(request) {
                try? await session.writeStandardInput(data)
            }
            await agentWaitIgnoringCancellation(for: gracePeriod)
        }
        await session.terminate()
    }
}
