import AnyLanguageModel
@testable import AIReasoningCore
import Foundation
import Testing

@Generable
private struct StructuredGreeting {
    var word: String
}

private struct FixtureTool: Tool {
    let name = "fixture"
    let description = "Fixture tool that must not be invoked"

    @Generable
    struct Arguments {
        var value: String
    }

    func call(arguments: Arguments) async throws -> String {
        arguments.value
    }
}

@Suite
struct AgentLanguageModelTests {
    @Test
    func codexProducesTrueCumulativeTextStream() async throws {
        let executor = MockAgentProcessExecutor(
            sessions: [
                .lines([
                    .standardOutputLine("codex-cli 0.146.0"),
                    .terminated(exitCode: 0),
                ]),
                .lines([
                    .standardOutputLine(
                        #"[{"name":"z-server"},{"name":"a.server"}]"#
                    ),
                    .terminated(exitCode: 0),
                ]),
                try .fixture("codex-text"),
            ]
        )
        let model = CodexLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/codex"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let session = LanguageModelSession(model: model)

        var snapshots: [String] = []
        for try await snapshot in session.streamResponse(to: "Hello") {
            snapshots.append(snapshot.content)
        }

        #expect(snapshots == ["Hello", "Hello world"])
        #expect(executor.startedRequestCount == 3)
        let appServerRequest = try #require(executor.request(at: 2))
        #expect(appServerRequest.arguments.contains("tools.web_search=false"))
        #expect(
            appServerRequest.arguments.contains(
                #"mcp_servers."a.server".enabled=false"#
            )
        )
        #expect(
            appServerRequest.arguments.contains(
                #"mcp_servers."z-server".enabled=false"#
            )
        )
    }

    @Test
    func claudeProducesOneShotText() async throws {
        let executor = MockAgentProcessExecutor(
            sessions: [
                .lines([
                    .standardOutputLine("2.1.85"),
                    .terminated(exitCode: 0),
                ]),
                try .fixture("claude-text"),
            ]
        )
        let model = ClaudeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/claude"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let response = try await LanguageModelSession(model: model)
            .respond(to: "Hello")

        #expect(response.content == "Hello world")
    }

    @Test
    func openCodeProducesTrueACPTextStreamAndDisablesCapabilities() async throws {
        let generation = try MockAgentProcessSession.fixture("opencode-text")
        let executor = MockAgentProcessExecutor(
            sessions: [
                .lines([
                    .standardOutputLine("1.18.15"),
                    .terminated(exitCode: 0),
                ]),
                generation,
            ]
        )
        let model = OpenCodeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/opencode"),
                model: "deepseek/deepseek-v4-flash",
                workingDirectoryURL: URL(fileURLWithPath: "/root"),
                environment: ["DEEPSEEK_API_KEY": "fixture-key"],
                provider: .init(
                    id: "deepseek", baseURL: URL(string: "https://api.deepseek.com/v1")!,
                    apiKeyEnvironmentVariable: "DEEPSEEK_API_KEY")
            ),
            executor: executor
        )

        var snapshots: [String] = []
        for try await snapshot in LanguageModelSession(model: model)
            .streamResponse(
                to: "Hello",
                images: [
                    Transcript.ImageSegment(
                        data: validPNG,
                        mimeType: "image/png"
                    )
                ]
            )
        {
            snapshots.append(snapshot.content)
        }

        #expect(snapshots == ["Hello", "Hello world"])
        let request = try #require(executor.request(at: 1))
        #expect(request.arguments == ["acp", "--pure", "--cwd", "/root"])
        let configText = try #require(request.environment["OPENCODE_CONFIG_CONTENT"])
        let config = try #require(
            JSONSerialization.jsonObject(with: Data(configText.utf8)) as? [String: Any]
        )
        #expect(config["model"] as? String == "deepseek/deepseek-v4-flash")
        #expect(config["autoupdate"] as? Bool == false)
        #expect((config["permission"] as? [String: String])?["*"] == "deny")
        #expect(config["enabled_providers"] as? [String] == ["deepseek"])
        let providers = try #require(config["provider"] as? [String: Any])
        let deepSeek = try #require(providers["deepseek"] as? [String: Any])
        let options = try #require(deepSeek["options"] as? [String: String])
        #expect(options["baseURL"] == "https://api.deepseek.com/v1")
        #expect(options["apiKey"] == "{env:DEEPSEEK_API_KEY}")

        let writes = generation.writtenData.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        #expect(writes.compactMap { $0["method"] as? String } == [
            "initialize", "session/new", "session/prompt",
        ])
        let promptParams = try #require(writes.last?["params"] as? [String: Any])
        let prompt = try #require(promptParams["prompt"] as? [[String: Any]])
        #expect(prompt.compactMap { $0["type"] as? String } == ["text", "image"])
        #expect(prompt.last?["mimeType"] as? String == "image/png")
        #expect(prompt.last?["data"] as? String == validPNG.base64EncodedString())
    }

    @Test
    func openCodeCustomProviderMissingKeyFailsBeforeStartingProcess() async {
        let executor = MockAgentProcessExecutor(sessions: [])
        let model = OpenCodeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/opencode"),
                model: "deepseek/deepseek-v4-flash",
                workingDirectoryURL: URL(fileURLWithPath: "/root"),
                provider: .init(
                    id: "deepseek", baseURL: URL(string: "https://api.deepseek.com/v1")!,
                    apiKeyEnvironmentVariable: "DEEPSEEK_API_KEY")
            ),
            executor: executor
        )

        await #expect(
            throws: AgentLanguageModelError.protocolFailure(
                driver: "opencode", message: "missing provider API key environment variable")
        ) {
            _ = try await LanguageModelSession(model: model).respond(to: "Hello")
        }
        #expect(executor.startedRequestCount == 0)
    }

    @Test
    func openCodeStructuredOutputFailsBeforeStartingProcess() async {
        let executor = MockAgentProcessExecutor(sessions: [])
        let model = OpenCodeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/opencode"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/root")
            ),
            executor: executor
        )

        await #expect(
            throws: AgentLanguageModelError.unsupportedStructuredOutput(
                driver: "opencode"
            )
        ) {
            _ = try await LanguageModelSession(model: model).respond(
                to: "Return JSON",
                generating: StructuredGreeting.self
            )
        }
        #expect(executor.startedRequestCount == 0)
    }

    @Test
    func claudeProducesGenerableStructuredOutput() async throws {
        let executor = MockAgentProcessExecutor(
            sessions: [
                .lines([
                    .standardOutputLine("2.1.85"),
                    .terminated(exitCode: 0),
                ]),
                try .fixture("claude-structured"),
            ]
        )
        let model = ClaudeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/claude"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let response = try await LanguageModelSession(model: model).respond(
            to: "Return a greeting",
            generating: StructuredGreeting.self
        )

        #expect(response.content.word == "Hello")
    }

    @Test
    func claudeReceivesMultipleDataImagesAsBase64Blocks() async throws {
        let version = MockAgentProcessSession.lines([
            .standardOutputLine("2.1.85"),
            .terminated(exitCode: 0),
        ])
        let generation = try MockAgentProcessSession.fixture("claude-text")
        let executor = MockAgentProcessExecutor(sessions: [version, generation])
        let model = ClaudeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/claude"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let images = [
            Transcript.ImageSegment(data: validPNG, mimeType: "image/png"),
            Transcript.ImageSegment(data: validPNG, mimeType: "image/png"),
        ]

        _ = try await LanguageModelSession(model: model).respond(
            to: "Describe both",
            images: images
        )

        let input = try #require(generation.writtenData.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: input) as? [String: Any]
        )
        let message = try #require(object["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        let mediaTypes = content.compactMap { part in
            (part["source"] as? [String: Any])?["media_type"] as? String
        }
        let line = try #require(String(data: input, encoding: .utf8))
        #expect(line.contains(validPNG.base64EncodedString()))
        #expect(mediaTypes == ["image/png", "image/png"])
    }

    @Test
    func transcriptIsRebuiltInDeterministicRoleOrder() throws {
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Rules"))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Question"))])),
            .response(.init(assetIDs: [], segments: [.text(.init(content: "Answer"))])),
        ])
        let executor = MockAgentProcessExecutor(sessions: [])
        let model = ClaudeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/claude"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let context = try AgentPromptContext(
            session: LanguageModelSession(model: model, transcript: transcript),
            maximumImageBytes: 100
        )

        #expect(
            context.transcriptText
                == "[instructions]\nRules\n[user]\nQuestion\n[assistant]\nAnswer"
        )
    }

    @Test
    func imageValidationRejectsNonImageMIME() throws {
        let transcript = Transcript(entries: [
            .prompt(
                .init(
                    segments: [
                        .image(.init(data: Data([0x01]), mimeType: "application/octet-stream"))
                    ]
                )
            )
        ])
        let executor = MockAgentProcessExecutor(sessions: [])
        let model = ClaudeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/claude"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let session = LanguageModelSession(model: model, transcript: transcript)

        #expect(throws: AgentLanguageModelError.invalidImageMIMEType("application/octet-stream")) {
            _ = try AgentPromptContext(session: session, maximumImageBytes: 100)
        }
    }

    @Test
    func imageValidationRejectsCorruptData() {
        #expect(
            throws: AgentLanguageModelError.invalidImageData(mimeType: "image/png")
        ) {
            try AgentPromptContext.validateImage(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png",
                maximumBytes: 100
            )
        }
    }

    @Test
    func fileURLImagePreservesValidBytesAndMIME() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("fixture.png")
        try validPNG.write(to: imageURL, options: .withoutOverwriting)

        let resolved = try await AgentImageResolver.resolve(
            .url(imageURL),
            maximumBytes: 1_024
        )

        #expect(resolved.data == validPNG)
        #expect(resolved.mimeType == "image/png")
    }

    @Test
    func swiftToolsFailBeforeStartingAgentProcess() async {
        let executor = MockAgentProcessExecutor(sessions: [])
        let model = CodexLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/codex"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let session = LanguageModelSession(model: model, tools: [FixtureTool()])

        await #expect(throws: AgentLanguageModelError.unsupportedTools) {
            _ = try await session.respond(to: "Use the fixture")
        }
        #expect(executor.startedRequestCount == 0)
    }

    @Test
    func nonDefaultGenerationOptionsFailExplicitly() async {
        let executor = MockAgentProcessExecutor(sessions: [])
        let model = ClaudeLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/claude"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )
        let session = LanguageModelSession(model: model)

        await #expect(throws: AgentLanguageModelError.unsupportedGenerationOptions) {
            _ = try await session.respond(
                to: "Hello",
                options: .init(temperature: 0.5)
            )
        }
        #expect(executor.startedRequestCount == 0)
    }

    @Test
    func oldExecutableVersionFailsExplicitly() async {
        let executor = MockAgentProcessExecutor(
            sessions: [
                .lines([
                    .standardOutputLine("codex-cli 0.145.0"),
                    .terminated(exitCode: 0),
                ])
            ]
        )
        let model = CodexLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/codex"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            executor: executor
        )

        await #expect(throws: AgentLanguageModelError.self) {
            _ = try await LanguageModelSession(model: model).respond(to: "Hello")
        }
    }

    @Test
    func codexCancellationSendsTurnInterruptBeforeTerminating() async throws {
        let generation = MockAgentProcessSession.hangingAfter([
            .standardOutputLine(#"{"id":1,"result":{"userAgent":"fixture"}}"#),
            .standardOutputLine(
                #"{"id":2,"result":{"thread":{"id":"thread-fixture"}}}"#
            ),
            .standardOutputLine(
                #"{"id":3,"result":{"turn":{"id":"turn-fixture"}}}"#
            ),
        ])
        let executor = MockAgentProcessExecutor(
            sessions: [
                .lines([
                    .standardOutputLine("codex-cli 0.146.0"),
                    .terminated(exitCode: 0),
                ]),
                .lines([
                    .standardOutputLine("[]"),
                    .terminated(exitCode: 0),
                ]),
                generation,
            ]
        )
        let model = CodexLanguageModel(
            configuration: .init(
                executableURL: URL(fileURLWithPath: "/fixture/codex"),
                model: "fixture-model",
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                interruptGracePeriod: .milliseconds(10)
            ),
            executor: executor
        )
        let task = Task {
            try await LanguageModelSession(model: model).respond(to: "Wait")
        }
        for _ in 0..<1_000 where generation.writtenData.count < 4 {
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try #require(generation.writtenData.count >= 4)
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation unexpectedly returned a response")
        } catch {}
        for _ in 0..<1_000 where generation.terminateCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try #require(generation.terminateCount > 0)

        let methods = try generation.writtenData.compactMap {
            try PackageJSONValue.decode($0).objectValue?["method"]?.stringValue
        }
        #expect(methods.contains("turn/interrupt"))
        #expect(generation.interruptCount == 0)
        #expect(generation.terminateCount == 1)
    }
}

private let validPNG = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

private final class MockAgentProcessExecutor: AgentProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [MockAgentProcessSession]
    private var requests: [AgentProcessRequest] = []

    init(sessions: [MockAgentProcessSession]) {
        self.sessions = sessions
    }

    var startedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(at index: Int) -> AgentProcessRequest? {
        lock.withLock {
            requests.indices.contains(index) ? requests[index] : nil
        }
    }

    func isExecutableAvailable(at url: URL) -> Bool { true }

    func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession {
        try lock.withLock {
            requests.append(request)
            guard !sessions.isEmpty else {
                throw AgentProcessExecutionError.launchFailed("No mock session remains")
            }
            return sessions.removeFirst()
        }
    }
}

private final class MockAgentProcessSession: AgentProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentProcessEvent, any Error>
    private let lock = NSLock()
    private var writes: [Data] = []
    private var interrupts = 0
    private var terminations = 0

    var writtenData: [Data] {
        lock.withLock { writes }
    }

    var interruptCount: Int {
        lock.withLock { interrupts }
    }

    var terminateCount: Int {
        lock.withLock { terminations }
    }

    init(events: [AgentProcessEvent], finish: Bool = true) {
        self.events = AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            if finish {
                continuation.finish()
            }
        }
    }

    static func lines(_ events: [AgentProcessEvent]) -> MockAgentProcessSession {
        .init(events: events)
    }

    static func hangingAfter(
        _ events: [AgentProcessEvent]
    ) -> MockAgentProcessSession {
        .init(events: events, finish: false)
    }

    static func fixture(_ name: String) throws -> MockAgentProcessSession {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "jsonl",
                subdirectory: "Fixtures"
            )
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let events = text.split(separator: "\n").map {
            AgentProcessEvent.standardOutputLine(String($0))
        } + [.terminated(exitCode: 0)]
        return .init(events: events)
    }

    func writeStandardInput(_ data: Data) async throws {
        lock.withLock { writes.append(data) }
    }

    func closeStandardInput() async throws {}
    func interrupt() async {
        lock.withLock { interrupts += 1 }
    }
    func terminate() async {
        lock.withLock { terminations += 1 }
    }
}
