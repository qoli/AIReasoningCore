import Foundation

package struct ClaudeDriver: AgentTextStreamingDriver {
    package let name = "claude"

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
            minimumVersion: "2.1.85",
            versionArguments: ["--version"],
            executor: executor,
            configuration: configuration
        )

        var content: [PackageJSONValue] = [
            .object([
                "type": .string("text"),
                "text": .string(request.prompt.transcriptText),
            ])
        ]
        for image in request.prompt.images {
            let resolved = try await AgentImageResolver.resolve(
                image,
                maximumBytes: configuration.maximumImageBytes
            )
            content.append(
                .object([
                    "type": .string("image"),
                    "source": .object([
                        "type": .string("base64"),
                        "media_type": .string(resolved.mimeType),
                        "data": .string(resolved.data.base64EncodedString()),
                    ]),
                ])
            )
        }

        let input: PackageJSONValue = .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array(content),
            ]),
            "parent_tool_use_id": .null,
        ])

        var arguments = [
            "--print",
            "--bare",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--no-chrome",
            "--tools", "",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", configuration.model,
        ]
        if let outputSchema = request.outputSchema {
            arguments.append(contentsOf: ["--json-schema", try outputSchema.jsonString])
        }

        let processRequest = AgentProcessRequest(
            executableURL: configuration.executableURL,
            arguments: arguments,
            environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL,
            timeout: configuration.timeout
        )
        let session = try await executor.start(processRequest)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await session.writeStandardInput(
                        AgentDriverSupport.encodeLine(input)
                    )
                    try await session.closeStandardInput()

                    var stderr: [String] = []
                    var sawResult = false
                    var structuredOutput: PackageJSONValue?

                    eventLoop: for try await event in session.events {
                        try Task.checkCancellation()
                        switch event {
                        case .standardErrorLine(let line):
                            stderr.append(line)
                        case .terminated(let exitCode):
                            throw AgentProcessExecutionError.terminatedBeforeCompletion(
                                exitCode: exitCode,
                                standardError: stderr.joined(separator: "\n")
                            )
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
                            guard let object = value.objectValue,
                                  let type = object["type"]?.stringValue
                            else {
                                throw AgentLanguageModelError.malformedProtocolMessage(
                                    driver: name,
                                    message: line
                                )
                            }

                            switch type {
                            case "stream_event":
                                guard request.outputSchema == nil else {
                                    continue
                                }
                                guard let eventObject = object["event"]?.objectValue,
                                      eventObject["type"]?.stringValue == "content_block_delta",
                                      let deltaObject = eventObject["delta"]?.objectValue
                                else {
                                    continue
                                }
                                if deltaObject["type"]?.stringValue == "text_delta",
                                   let delta = deltaObject["text"]?.stringValue
                                {
                                    continuation.yield(delta)
                                }
                            case "result":
                                let isError = object["is_error"]?.boolValue ?? false
                                let subtype = object["subtype"]?.stringValue
                                guard !isError, subtype == "success" else {
                                    let message = object["result"]?.stringValue
                                        ?? (try? value.jsonString)
                                        ?? "unknown Claude result error"
                                    throw AgentLanguageModelError.protocolFailure(
                                        driver: name,
                                        message: message
                                    )
                                }
                                structuredOutput = object["structured_output"]
                                sawResult = true
                                break eventLoop
                            case "system", "assistant", "user":
                                break
                            default:
                                break
                            }
                        }
                    }

                    try Task.checkCancellation()
                    guard sawResult else {
                        throw AgentLanguageModelError.missingProtocolResult(driver: name)
                    }
                    if request.outputSchema != nil {
                        guard let structuredOutput else {
                            throw AgentLanguageModelError.missingProtocolResult(driver: name)
                        }
                        continuation.yield(try structuredOutput.jsonString)
                    }
                    await session.terminate()
                    continuation.finish()
                } catch is CancellationError {
                    await session.interrupt()
                    await agentWaitIgnoringCancellation(
                        for: configuration.interruptGracePeriod
                    )
                    await session.terminate()
                    continuation.finish(throwing: CancellationError())
                } catch {
                    await session.terminate()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
