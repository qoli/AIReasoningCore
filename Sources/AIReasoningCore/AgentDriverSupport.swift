import AnyLanguageModel
import Foundation

package struct AgentDriverConfiguration: Sendable {
    package let executableURL: URL
    package let model: String
    package let workingDirectoryURL: URL
    package let environment: [String: String]
    package let timeout: Duration
    package let interruptGracePeriod: Duration
    package let maximumImageBytes: Int

    package init(
        executableURL: URL,
        model: String,
        workingDirectoryURL: URL,
        environment: [String: String],
        timeout: Duration,
        interruptGracePeriod: Duration,
        maximumImageBytes: Int
    ) {
        self.executableURL = executableURL
        self.model = model
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
        self.timeout = timeout
        self.interruptGracePeriod = interruptGracePeriod
        self.maximumImageBytes = maximumImageBytes
    }
}

package struct AgentGenerationRequest: Sendable {
    package let prompt: AgentPromptContext
    package let outputSchema: PackageJSONValue?
}

package protocol AgentTextStreamingDriver: Sendable {
    var name: String { get }

    func stream(
        _ request: AgentGenerationRequest
    ) async throws -> AsyncThrowingStream<String, any Error>
}

package enum AgentDriverSupport {
    package static func validateVersion(
        driverName: String,
        minimumVersion: String,
        versionArguments: [String],
        executor: any AgentProcessExecuting,
        configuration: AgentDriverConfiguration
    ) async throws {
        let request = AgentProcessRequest(
            executableURL: configuration.executableURL,
            arguments: versionArguments,
            environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL,
            timeout: configuration.timeout
        )
        let session = try await executor.start(request)
        try await session.closeStandardInput()

        var stdout: [String] = []
        var stderr: [String] = []
        var exitCode: Int32?
        for try await event in session.events {
            switch event {
            case .standardOutputLine(let line):
                stdout.append(line)
            case .standardErrorLine(let line):
                stderr.append(line)
            case .terminated(let code):
                exitCode = code
            }
        }

        guard exitCode == 0 else {
            throw AgentLanguageModelError.protocolFailure(
                driver: driverName,
                message: "version command failed: \(stderr.joined(separator: "\n"))"
            )
        }
        let output = (stdout + stderr).joined(separator: "\n")
        guard let found = SemanticVersion(output),
              let minimum = SemanticVersion(minimumVersion)
        else {
            throw AgentLanguageModelError.malformedProtocolMessage(
                driver: driverName,
                message: "could not parse executable version from '\(output)'"
            )
        }
        guard found >= minimum else {
            throw AgentLanguageModelError.incompatibleExecutableVersion(
                executable: configuration.executableURL.path,
                found: found.description,
                minimum: minimum.description
            )
        }
    }

    package static func encodeLine(_ value: PackageJSONValue) throws -> Data {
        var data = try value.jsonData
        data.append(0x0A)
        return data
    }

    package static func schema<Content: Generable>(
        for type: Content.Type
    ) throws -> PackageJSONValue? {
        if type == String.self {
            return nil
        }
        let data = try JSONEncoder().encode(Content.generationSchema)
        return try PackageJSONValue.decode(data)
    }

    package static func response<Content: Generable>(
        from text: String,
        as type: Content.Type
    ) throws -> LanguageModelSession.Response<Content> {
        if type == String.self {
            let content = text as! Content
            return .init(
                content: content,
                rawContent: GeneratedContent(text),
                transcriptEntries: []
            )
        }

        do {
            let raw = try GeneratedContent(json: text)
            let content = try Content(raw)
            return .init(content: content, rawContent: raw, transcriptEntries: [])
        } catch {
            throw AgentLanguageModelError.structuredOutputDecodingFailed(
                String(describing: error)
            )
        }
    }

    package static func snapshot<Content: Generable>(
        accumulatedText: String,
        as type: Content.Type
    ) throws -> LanguageModelSession.ResponseStream<Content>.Snapshot {
        if type == String.self {
            let raw = GeneratedContent(accumulatedText)
            return .init(
                content: (accumulatedText as! Content).asPartiallyGenerated(),
                rawContent: raw
            )
        }
        let raw = try GeneratedContent(json: accumulatedText)
        let partial = try Content.PartiallyGenerated(raw)
        return .init(content: partial, rawContent: raw)
    }
}

package final class AgentLanguageModelEngine: Sendable {
    private let driver: any AgentTextStreamingDriver
    private let maximumImageBytes: Int

    package init(driver: any AgentTextStreamingDriver, maximumImageBytes: Int) {
        self.driver = driver
        self.maximumImageBytes = maximumImageBytes
    }

    package func respond<Content: Generable>(
        within session: LanguageModelSession,
        generating type: Content.Type,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        guard options == GenerationOptions() else {
            throw AgentLanguageModelError.unsupportedGenerationOptions
        }
        let context = try AgentPromptContext(
            session: session,
            maximumImageBytes: maximumImageBytes
        )
        let schema = try AgentDriverSupport.schema(for: type)
        let stream = try await driver.stream(
            .init(prompt: context, outputSchema: schema)
        )
        var accumulated = ""
        for try await delta in stream {
            accumulated += delta
        }
        guard !accumulated.isEmpty else {
            throw AgentLanguageModelError.missingProtocolResult(
                driver: driver.name
            )
        }
        return try AgentDriverSupport.response(from: accumulated, as: type)
    }

    package func streamResponse<Content: Generable>(
        within session: LanguageModelSession,
        generating type: Content.Type,
        options: GenerationOptions
    ) -> LanguageModelSession.ResponseStream<Content> {
        let stream = AsyncThrowingStream<
            LanguageModelSession.ResponseStream<Content>.Snapshot,
            any Error
        > { continuation in
            let task = Task {
                do {
                    guard options == GenerationOptions() else {
                        throw AgentLanguageModelError.unsupportedGenerationOptions
                    }
                    let context = try AgentPromptContext(
                        session: session,
                        maximumImageBytes: maximumImageBytes
                    )
                    let schema = try AgentDriverSupport.schema(for: type)
                    let deltas = try await driver.stream(
                        .init(prompt: context, outputSchema: schema)
                    )
                    var accumulated = ""
                    var yielded = false
                    for try await delta in deltas {
                        try Task.checkCancellation()
                        accumulated += delta
                        do {
                            let snapshot = try AgentDriverSupport.snapshot(
                                accumulatedText: accumulated,
                                as: type
                            )
                            continuation.yield(snapshot)
                            yielded = true
                        } catch where type != String.self {
                            // A structured snapshot is emitted only after its partial
                            // GeneratedContent can be decoded. Final validation remains strict.
                        }
                    }
                    guard !accumulated.isEmpty, yielded else {
                        throw AgentLanguageModelError.missingProtocolResult(
                            driver: driver.name
                        )
                    }
                    if type != String.self {
                        _ = try AgentDriverSupport.response(from: accumulated, as: type)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(stream: stream)
    }
}
