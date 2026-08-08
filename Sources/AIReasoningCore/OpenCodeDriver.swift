import Foundation

package struct OpenCodeDriver: AgentTextStreamingDriver {
    package let name = "opencode"

    private let executor: any AgentProcessExecuting
    private let configuration: AgentDriverConfiguration
    private let provider: OpenCodeLanguageModel.ProviderConfiguration?

    package init(
        executor: any AgentProcessExecuting, configuration: AgentDriverConfiguration,
        provider: OpenCodeLanguageModel.ProviderConfiguration? = nil
    ) {
        self.executor = executor
        self.configuration = configuration
        self.provider = provider
    }

    package func stream(_ request: AgentGenerationRequest) async throws -> AsyncThrowingStream<String, any Error> {
        guard request.outputSchema == nil else {
            throw AgentLanguageModelError.unsupportedStructuredOutput(driver: name)
        }
        guard configuration.environment["OPENCODE_CONFIG_CONTENT"] == nil else {
            throw AgentLanguageModelError.protocolFailure(
                driver: name, message: "OPENCODE_CONFIG_CONTENT is owned by OpenCodeLanguageModel")
        }
        try Self.validate(provider: provider, model: configuration.model, environment: configuration.environment)
        try await AgentDriverSupport.validateVersion(
            driverName: name, minimumVersion: "1.18.15", versionArguments: ["--version"], executor: executor,
            configuration: configuration)
        let images = try await request.prompt.images.asyncMap { image in
            try await AgentImageResolver.resolve(image, maximumBytes: configuration.maximumImageBytes)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var processSession: (any AgentProcessSession)?
                var sessionID: String?
                do {
                    var environment = configuration.environment
                    environment["OPENCODE_CONFIG_CONTENT"] = try Self.configurationContent(
                        model: configuration.model, provider: provider)
                    let processRequest = AgentProcessRequest(
                        executableURL: configuration.executableURL,
                        arguments: ["acp", "--pure", "--cwd", configuration.workingDirectoryURL.path],
                        environment: environment, workingDirectoryURL: configuration.workingDirectoryURL,
                        timeout: configuration.timeout)
                    let session = try await executor.start(processRequest)
                    processSession = session
                    try await session.writeStandardInput(AgentDriverSupport.encodeLine(Self.initializeRequest))

                    var stderr: [String] = []
                    var completed = false
                    eventLoop: for try await event in session.events {
                        try Task.checkCancellation()
                        switch event {
                        case .standardErrorLine(let line): stderr.append(line)
                        case .terminated(let exitCode):
                            guard completed else {
                                throw AgentProcessExecutionError.terminatedBeforeCompletion(
                                    exitCode: exitCode, standardError: stderr.joined(separator: "\n"))
                            }
                        case .standardOutputLine(let line):
                            let object = try Self.protocolObject(line)
                            if let error = object["error"] {
                                throw AgentLanguageModelError.protocolFailure(
                                    driver: name, message: (try? error.jsonString) ?? String(describing: error))
                            }

                            if let id = object["id"]?.integerValue {
                                switch id {
                                case 1:
                                    try await session.writeStandardInput(
                                        AgentDriverSupport.encodeLine(
                                            Self.newSessionRequest(cwd: configuration.workingDirectoryURL.path)))
                                case 2:
                                    guard let foundSessionID = object["result"]?.objectValue?["sessionId"]?.stringValue
                                    else {
                                        throw AgentLanguageModelError.malformedProtocolMessage(
                                            driver: name, message: "session/new response missing result.sessionId")
                                    }
                                    sessionID = foundSessionID
                                    try await session.writeStandardInput(
                                        AgentDriverSupport.encodeLine(
                                            Self.promptRequest(
                                                sessionID: foundSessionID, request: request, images: images)))
                                case 3:
                                    guard let stopReason = object["result"]?.objectValue?["stopReason"]?.stringValue
                                    else {
                                        throw AgentLanguageModelError.malformedProtocolMessage(
                                            driver: name, message: "session/prompt response missing result.stopReason")
                                    }
                                    guard stopReason == "end_turn" else {
                                        throw AgentLanguageModelError.protocolFailure(
                                            driver: name, message: "session/prompt stopped with \(stopReason)")
                                    }
                                    completed = true
                                    break eventLoop
                                default:
                                    throw AgentLanguageModelError.protocolFailure(
                                        driver: name, message: "unexpected JSON-RPC response id \(id)")
                                }
                                continue
                            }

                            guard object["method"]?.stringValue == "session/update" else { continue }
                            guard let update = object["params"]?.objectValue?["update"]?.objectValue else {
                                throw AgentLanguageModelError.malformedProtocolMessage(
                                    driver: name, message: "session/update missing params.update")
                            }
                            guard update["sessionUpdate"]?.stringValue == "agent_message_chunk" else { continue }
                            guard let content = update["content"]?.objectValue, content["type"]?.stringValue == "text",
                                let delta = content["text"]?.stringValue
                            else {
                                throw AgentLanguageModelError.malformedProtocolMessage(
                                    driver: name, message: "agent_message_chunk missing text content")
                            }
                            continuation.yield(delta)
                        }
                    }

                    guard completed else { throw AgentLanguageModelError.missingProtocolResult(driver: name) }
                    try await session.closeStandardInput()
                    await session.terminate()
                    continuation.finish()
                } catch is CancellationError {
                    if let processSession {
                        if let sessionID {
                            try? await processSession.writeStandardInput(
                                AgentDriverSupport.encodeLine(Self.cancelNotification(sessionID: sessionID)))
                            await agentWaitIgnoringCancellation(for: configuration.interruptGracePeriod)
                        }
                        await processSession.terminate()
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if let processSession { await processSession.terminate() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func protocolObject(_ line: String) throws -> [String: PackageJSONValue] {
        do {
            let value = try PackageJSONValue.decode(line)
            guard let object = value.objectValue else { throw CocoaError(.coderReadCorrupt) }
            return object
        } catch { throw AgentLanguageModelError.malformedProtocolMessage(driver: "opencode", message: line) }
    }

    private static func configurationContent(
        model: String, provider: OpenCodeLanguageModel.ProviderConfiguration?
    ) throws -> String {
        var configuration: [String: PackageJSONValue] = [
            "model": .string(model), "autoupdate": .bool(false), "formatter": .bool(false), "lsp": .bool(false),
            "permission": .object(["*": .string("deny")]),
        ]
        if let provider {
            let modelID = String(model.dropFirst(provider.id.count + 1))
            configuration["enabled_providers"] = .array([.string(provider.id)])
            configuration["provider"] = .object([
                provider.id: .object([
                    "npm": .string("@ai-sdk/openai-compatible"),
                    "name": .string(provider.id),
                    "options": .object([
                        "baseURL": .string(provider.baseURL.absoluteString),
                        "apiKey": .string("{env:\(provider.apiKeyEnvironmentVariable)}"),
                    ]),
                    "models": .object([modelID: .object(["name": .string(modelID)])]),
                ])
            ])
        }
        return try PackageJSONValue.object(configuration).jsonString
    }

    private static func validate(
        provider: OpenCodeLanguageModel.ProviderConfiguration?, model: String, environment: [String: String]
    ) throws {
        guard let provider else { return }
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !provider.id.isEmpty, provider.id.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            throw AgentLanguageModelError.protocolFailure(driver: "opencode", message: "invalid provider id")
        }
        guard model.hasPrefix("\(provider.id)/"), model.count > provider.id.count + 1 else {
            throw AgentLanguageModelError.protocolFailure(
                driver: "opencode", message: "model must use provider prefix \(provider.id)/")
        }
        guard let components = URLComponents(url: provider.baseURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            components.host != nil, components.user == nil, components.password == nil
        else {
            throw AgentLanguageModelError.protocolFailure(driver: "opencode", message: "invalid provider base URL")
        }
        let environmentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !provider.apiKeyEnvironmentVariable.isEmpty,
            provider.apiKeyEnvironmentVariable.unicodeScalars.allSatisfy(environmentCharacters.contains)
        else {
            throw AgentLanguageModelError.protocolFailure(
                driver: "opencode", message: "invalid provider API-key environment variable")
        }
        guard let apiKey = environment[provider.apiKeyEnvironmentVariable], !apiKey.isEmpty else {
            throw AgentLanguageModelError.protocolFailure(
                driver: "opencode", message: "missing provider API key environment variable")
        }
    }

    private static let initializeRequest: PackageJSONValue = .object([
        "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
        "params": .object([
            "protocolVersion": .number(1), "clientCapabilities": .object([:]),
            "clientInfo": .object(["name": .string("AIReasoningCore"), "version": .string("1.0.0")]),
        ]),
    ])

    private static func newSessionRequest(cwd: String) -> PackageJSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .number(2), "method": .string("session/new"),
            "params": .object(["cwd": .string(cwd), "mcpServers": .array([])]),
        ])
    }

    private static func promptRequest(sessionID: String, request: AgentGenerationRequest, images: [ResolvedImage])
        -> PackageJSONValue
    {
        var prompt: [PackageJSONValue] = [
            .object(["type": .string("text"), "text": .string(request.prompt.transcriptText)])
        ]
        prompt.append(
            contentsOf: images.map { image in
                .object([
                    "type": .string("image"), "mimeType": .string(image.mimeType),
                    "data": .string(image.data.base64EncodedString()),
                ])
            })
        return .object([
            "jsonrpc": .string("2.0"), "id": .number(3), "method": .string("session/prompt"),
            "params": .object(["sessionId": .string(sessionID), "prompt": .array(prompt)]),
        ])
    }

    private static func cancelNotification(sessionID: String) -> PackageJSONValue {
        .object([
            "jsonrpc": .string("2.0"), "method": .string("session/cancel"),
            "params": .object(["sessionId": .string(sessionID)]),
        ])
    }
}

extension Array {
    fileprivate func asyncMap<T: Sendable>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
