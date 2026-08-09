// SPDX-License-Identifier: GPL-3.0-or-later

import AnyLanguageModel
import Foundation

public struct CodexLanguageModel: LanguageModel, Sendable {
    public struct Configuration: Sendable {
        public let executableURL: URL
        public let model: String
        public let workingDirectoryURL: URL
        public let environment: [String: String]
        public let timeout: Duration
        public let interruptGracePeriod: Duration
        public let maximumImageBytes: Int

        public init(
            executableURL: URL,
            model: String,
            workingDirectoryURL: URL,
            environment: [String: String] = [:],
            timeout: Duration = .seconds(120),
            interruptGracePeriod: Duration = .seconds(2),
            maximumImageBytes: Int = 20 * 1_024 * 1_024
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

    public typealias UnavailableReason = AgentLanguageModelUnavailableReason

    public var availability: Availability<UnavailableReason> {
        executor.isExecutableAvailable(at: configuration.executableURL)
            ? .available
            : .unavailable(.executableUnavailable(configuration.executableURL.path))
    }

    private let configuration: Configuration
    private let executor: any AgentProcessExecuting
    private let driver: CodexDriver
    private let engine: AgentLanguageModelEngine

    public init(
        configuration: Configuration,
        executor: any AgentProcessExecuting
    ) {
        self.configuration = configuration
        self.executor = executor
        let driverConfiguration = AgentDriverConfiguration(
            executableURL: configuration.executableURL,
            model: configuration.model,
            workingDirectoryURL: configuration.workingDirectoryURL,
            environment: configuration.environment,
            timeout: configuration.timeout,
            interruptGracePeriod: configuration.interruptGracePeriod,
            maximumImageBytes: configuration.maximumImageBytes
        )
        let driver = CodexDriver(
            executor: executor,
            configuration: driverConfiguration
        )
        self.driver = driver
        self.engine = AgentLanguageModelEngine(
            driver: driver,
            maximumImageBytes: configuration.maximumImageBytes
        )
    }

    #if os(macOS)
    public init(configuration: Configuration) {
        self.init(configuration: configuration, executor: MacOSAgentProcessExecutor())
    }
    #endif

    public func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        try await engine.respond(within: session, generating: type, options: options)
    }

    public func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        engine.streamResponse(within: session, generating: type, options: options)
    }

    package func rawStream(
        transcriptText: String,
        images: [AgentPromptContext.Image],
        outputSchema: PackageJSONValue?
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await driver.stream(
            .init(
                prompt: .init(transcriptText: transcriptText, images: images),
                outputSchema: outputSchema
            )
        )
    }
}
