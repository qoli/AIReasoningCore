@testable import AIReasoningSmokeSupport
import AIReasoningCore
import AnyLanguageModel
import Foundation
import Testing

@Suite
struct SmokeConfigurationTests {
    @Test
    func missingModelFailsBeforeBackendExecution() {
        let configuration = SmokeConfiguration(
            backend: .codex,
            model: "",
            executablePath: "/usr/bin/codex",
            workingDirectoryPath: "/root",
            baseURL: "",
            apiKey: "",
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        #expect(throws: SmokeConfigurationError.missingRequiredValue("model")) {
            _ = try configuration.makeLanguageModel()
        }
    }

    @Test
    func codexRelativeGuestExecutableFailsExplicitly() {
        let configuration = SmokeConfiguration(
            backend: .codex,
            model: "fixture-model",
            executablePath: "usr/bin/codex",
            workingDirectoryPath: "/root",
            baseURL: "",
            apiKey: "",
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        #expect(
            throws: SmokeConfigurationError.pathMustBeAbsolute(
                "guest executable path"
            )
        ) {
            _ = try configuration.makeLanguageModel()
        }
    }

    @Test
    func nativeOpenAIMissingKeyDoesNotContinue() {
        let configuration = SmokeConfiguration(
            backend: .anyLanguageModelOpenAI,
            model: "fixture-model",
            executablePath: "",
            workingDirectoryPath: "",
            baseURL: "https://example.com/v1/",
            apiKey: "",
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        #expect(throws: SmokeConfigurationError.missingRequiredValue("API key")) {
            _ = try configuration.makeLanguageModel()
        }
    }

    @Test
    func nativeOpenAIRejectsNonHTTPBaseURL() {
        let configuration = SmokeConfiguration(
            backend: .anyLanguageModelOpenAI,
            model: "fixture-model",
            executablePath: "",
            workingDirectoryPath: "",
            baseURL: "file:///tmp/fake-endpoint",
            apiKey: "fixture-key",
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        #expect(throws: SmokeConfigurationError.invalidBaseURL) {
            _ = try configuration.makeLanguageModel()
        }
    }

    @Test
    func invalidTimeoutFailsBeforeBackendExecution() {
        let configuration = SmokeConfiguration(
            backend: .anyLanguageModelOpenAI,
            model: "fixture-model",
            executablePath: "",
            workingDirectoryPath: "",
            baseURL: "https://example.com/v1/",
            apiKey: "fixture-key",
            maximumResponseTokens: 2048,
            timeoutSeconds: 0
        )

        #expect(throws: SmokeConfigurationError.invalidTimeout) {
            _ = try configuration.makeLanguageModel()
        }
    }

    @Test
    func maxReasoningUsesOpenAICompatibleVendorBody() throws {
        let configuration = SmokeConfiguration(
            backend: .anyLanguageModelOpenAI,
            model: "deepseek-v4-flash",
            executablePath: "",
            workingDirectoryPath: "",
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "fixture-key",
            reasoningEffort: .max,
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        let options = try configuration.makeGenerationOptions()
        let custom = options[custom: OpenAILanguageModel.self]

        #expect(custom?.extraBody?["reasoning_effort"] == .string("max"))
        #expect(
            custom?.extraBody?["thinking"]
                == .object(["type": .string("enabled")])
        )
        #expect(options.maximumResponseTokens == 2048)
    }

    @Test
    func agentBackendRejectsNativeReasoningEffort() {
        let configuration = SmokeConfiguration(
            backend: .codex,
            model: "fixture-model",
            executablePath: "/usr/bin/codex",
            workingDirectoryPath: "/root",
            baseURL: "",
            apiKey: "",
            reasoningEffort: .max,
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        #expect(throws: SmokeConfigurationError.reasoningEffortUnsupported) {
            _ = try configuration.makeGenerationOptions()
        }
    }

    @Test
    func invalidMaximumResponseTokensFailsExplicitly() {
        let configuration = SmokeConfiguration(
            backend: .anyLanguageModelOpenAI,
            model: "fixture-model",
            executablePath: "",
            workingDirectoryPath: "",
            baseURL: "https://example.com/v1/",
            apiKey: "fixture-key",
            maximumResponseTokens: 0,
            timeoutSeconds: 120
        )

        #expect(throws: SmokeConfigurationError.invalidMaximumResponseTokens) {
            _ = try configuration.makeGenerationOptions()
        }
    }

    @Test
    func codexAuthenticationRejectsAnotherBackend() {
        let configuration = SmokeConfiguration(
            backend: .claude,
            model: "fixture-model",
            executablePath: "/usr/bin/claude",
            workingDirectoryPath: "/root",
            baseURL: "",
            apiKey: "",
            maximumResponseTokens: 2048,
            timeoutSeconds: 120
        )

        #expect(
            throws: SmokeConfigurationError.codexAuthenticationUnsupportedBackend
        ) {
            _ = try configuration.makeCodexAuthenticationManager(
                executor: SmokeFixtureExecutor(events: [])
            )
        }
    }

    @Test @MainActor
    func codexRunStopsAfterUnauthenticatedPreflight() async throws {
        let executor = SmokeFixtureExecutor(events: [
            .standardOutputLine("Not logged in"),
            .terminated(exitCode: 1),
        ])
        let viewModel = SmokeViewModel(processExecutor: executor)
        viewModel.backend = .codex
        viewModel.model = "fixture-model"
        viewModel.executablePath = "/usr/bin/codex"
        viewModel.workingDirectoryPath = "/root"
        viewModel.prompt = "This request must not start."

        viewModel.run()
        while viewModel.isRunning {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(viewModel.codexAuthenticationState == .notAuthenticated)
        #expect(
            viewModel.state == .failed(
                "Codex CLI is not authenticated in this app's iSH root filesystem. Sign in before running the request."
            )
        )
        #expect(executor.requests.map(\.arguments) == [["login", "status"]])
    }

    @Test @MainActor
    func invalidReplacementImageClearsPreviousAttachment() {
        let viewModel = SmokeViewModel()
        viewModel.setAttachment(
            data: Data([0x01]),
            mimeType: "image/png",
            name: "first.png"
        )
        #expect(viewModel.attachment != nil)

        viewModel.setAttachment(
            data: Data(),
            mimeType: "image/png",
            name: "invalid.png"
        )

        #expect(viewModel.attachment == nil)
        #expect(
            viewModel.state
                == .failed("Selected image contains no data.")
        )
    }

    @Test @MainActor
    func imageLoadFailureClearsPreviousAttachment() {
        let viewModel = SmokeViewModel()
        viewModel.setAttachment(
            data: Data([0x01]),
            mimeType: "image/png",
            name: "first.png"
        )

        viewModel.reportAttachmentFailure(SmokeImageFixtureError.failed)

        #expect(viewModel.attachment == nil)
        #expect(
            viewModel.state
                == .failed("Image loading failed: fixture image load failed")
        )
    }
}

private enum SmokeImageFixtureError: Error, LocalizedError {
    case failed

    var errorDescription: String? {
        "fixture image load failed"
    }
}

private final class SmokeFixtureExecutor: AgentProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [AgentProcessEvent]
    private var capturedRequests: [AgentProcessRequest] = []

    init(events: [AgentProcessEvent]) {
        self.events = events
    }

    var requests: [AgentProcessRequest] {
        lock.withLock { capturedRequests }
    }

    func isExecutableAvailable(at url: URL) -> Bool {
        true
    }

    func start(_ request: AgentProcessRequest) async throws -> any AgentProcessSession {
        lock.withLock { capturedRequests.append(request) }
        return SmokeFixtureSession(events: events)
    }
}

private final class SmokeFixtureSession: AgentProcessSession, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentProcessEvent, any Error>

    init(events: [AgentProcessEvent]) {
        self.events = AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func writeStandardInput(_ data: Data) async throws {}
    func closeStandardInput() async throws {}
    func interrupt() async {}
    func terminate() async {}
}
