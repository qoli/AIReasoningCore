// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import Foundation
import OpenAI

public struct ChatCompletionsRunner: Sendable {
    public init() {}

    public func run(
        input: Data,
        configuration: ChatCompletionsExecutionConfiguration,
        emit: @escaping @Sendable (Data) async throws -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        var streamRequested = false
        let emissionState = ProtocolEmissionState()
        do {
            let request = try ChatCompletionsRequestParser.parse(input)
            streamRequested = request.stream

            switch configuration.backend {
            case .openai:
                try await runOpenAI(
                    request,
                    configuration: configuration,
                    emit: { data in
                        emissionState.markStarted()
                        try await emit(data)
                    }
                )
            case .codex, .claude, .opencode:
                try validateAgentParameters(
                    request,
                    backend: configuration.backend
                )
                try await runAgent(
                    request,
                    configuration: configuration,
                    emit: { data in
                        emissionState.markStarted()
                        try await emit(data)
                    }
                )
            }
            return 0
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            let failure = Self.failure(from: error)
            log(failure.message)
            do {
                let envelope = try failure.envelope.jsonData
                if streamRequested && emissionState.started {
                    try await emit(Self.sseData(envelope))
                } else if !emissionState.started {
                    var output = envelope
                    output.append(0x0A)
                    try await emit(output)
                }
            } catch {
                log("Failed to write protocol error: \(error)")
                return 74
            }
            if wasCancelled {
                return 130
            }
            switch failure.kind {
            case .invalidRequest: return 2
            case .unavailable: return 69
            case .backend: return 70
            }
        }
    }

    private func runOpenAI(
        _ request: PreparedChatCompletionsRequest,
        configuration: ChatCompletionsExecutionConfiguration,
        emit: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard let token = configuration.environment["OPENAI_API_KEY"], !token.isEmpty else {
            throw ChatCompletionsFailure(
                .unavailable,
                message: "OPENAI_API_KEY is required for the openai backend",
                code: "authentication_unavailable"
            )
        }

        let baseURL: URL
        if let configuredBaseURL = configuration.baseURL {
            baseURL = configuredBaseURL
        } else {
            guard let defaultBaseURL = URL(string: "https://api.openai.com/v1") else {
                throw ChatCompletionsFailure(
                    .unavailable,
                    message: "The built-in OpenAI base URL is invalid",
                    code: "configuration_error"
                )
            }
            baseURL = defaultBaseURL
        }
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              ["http", "https"].contains(scheme),
              let host = components.host
        else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "--base-url must be an absolute HTTP(S) URL",
                parameter: "base_url",
                code: "invalid_base_url"
            )
        }
        let basePath = components.path.isEmpty ? "/v1" : components.path
        let openAI = OpenAI(
            configuration: .init(
                token: token,
                host: host,
                port: components.port ?? (scheme == "https" ? 443 : 80),
                scheme: scheme,
                basePath: basePath,
                timeoutInterval: configuration.timeoutSeconds
            )
        )

        if request.stream {
            for try await chunk in openAI.chatsStream(query: request.query) {
                try Task.checkCancellation()
                let data = try JSONEncoder().encode(chunk)
                try await emit(Self.sseData(data))
            }
            try Task.checkCancellation()
            try await emit(Data("data: [DONE]\n\n".utf8))
        } else {
            let result = try await openAI.chats(query: request.query)
            try Task.checkCancellation()
            var data = try JSONEncoder().encode(result)
            data.append(0x0A)
            try await emit(data)
        }
    }

    private func runAgent(
        _ request: PreparedChatCompletionsRequest,
        configuration: ChatCompletionsExecutionConfiguration,
        emit: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard let executableURL = configuration.executableURL else {
            throw ChatCompletionsFailure(
                .unavailable,
                message: "Agent executable could not be resolved",
                code: "executable_unavailable"
            )
        }
        #if os(macOS)
        let timeout = Duration.seconds(configuration.timeoutSeconds)
        let stream: AsyncThrowingStream<String, any Error>
        switch configuration.backend {
        case .codex:
            let model = CodexLanguageModel(
                configuration: .init(
                    executableURL: executableURL,
                    model: request.model,
                    workingDirectoryURL: configuration.workingDirectoryURL,
                    environment: configuration.environment,
                    timeout: timeout
                )
            )
            stream = try await model.rawStream(
                transcriptText: request.transcriptText,
                images: request.images,
                outputSchema: request.outputSchema
            )
        case .claude:
            let model = ClaudeLanguageModel(
                configuration: .init(
                    executableURL: executableURL,
                    model: request.model,
                    workingDirectoryURL: configuration.workingDirectoryURL,
                    environment: configuration.environment,
                    timeout: timeout
                )
            )
            stream = try await model.rawStream(
                transcriptText: request.transcriptText,
                images: request.images,
                outputSchema: request.outputSchema
            )
        case .opencode:
            let model = OpenCodeLanguageModel(
                configuration: .init(
                    executableURL: executableURL,
                    model: request.model,
                    workingDirectoryURL: configuration.workingDirectoryURL,
                    environment: configuration.environment,
                    timeout: timeout,
                    provider: configuration.openCodeProvider
                )
            )
            stream = try await model.rawStream(
                transcriptText: request.transcriptText,
                images: request.images,
                outputSchema: request.outputSchema
            )
        case .openai:
            throw ChatCompletionsFailure(
                .backend,
                message: "OpenAI backend reached the agent subprocess path",
                code: "internal_routing_error"
            )
        }

        let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let created = Int(Date().timeIntervalSince1970)

        if request.stream {
            try await emit(
                Self.sseData(
                    try Self.streamChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        role: "assistant",
                        content: nil,
                        finishReason: nil
                    ).jsonData
                )
            )
            for try await delta in stream {
                try Task.checkCancellation()
                try await emit(
                    Self.sseData(
                        try Self.streamChunk(
                            id: id,
                            created: created,
                            model: request.model,
                            role: nil,
                            content: delta,
                            finishReason: nil
                        ).jsonData
                    )
                )
            }
            try Task.checkCancellation()
            try await emit(
                Self.sseData(
                    try Self.streamChunk(
                        id: id,
                        created: created,
                        model: request.model,
                        role: nil,
                        content: nil,
                        finishReason: "stop"
                    ).jsonData
                )
            )
            try await emit(Data("data: [DONE]\n\n".utf8))
        } else {
            var text = ""
            for try await delta in stream {
                try Task.checkCancellation()
                text += delta
            }
            try Task.checkCancellation()
            let parsed = try Self.message(from: text, toolEnvelope: request.usesToolEnvelope)
            let result: PackageJSONValue = .object([
                "id": .string(id),
                "object": .string("chat.completion"),
                "created": .number(Double(created)),
                "model": .string(request.model),
                "choices": .array([
                    .object([
                        "index": .number(0),
                        "message": parsed.message,
                        "finish_reason": .string(parsed.finishReason),
                        "logprobs": .null,
                    ])
                ]),
            ])
            var data = try result.jsonData
            data.append(0x0A)
            try await emit(data)
        }
        #else
        throw ChatCompletionsFailure(
            .unavailable,
            message: "The CLI agent backends require macOS",
            code: "platform_unavailable"
        )
        #endif
    }

    private func validateAgentParameters(
        _ request: PreparedChatCompletionsRequest,
        backend: ChatCompletionsBackend
    ) throws {
        if backend == .opencode, request.outputSchema != nil {
            let parameter = request.usesToolEnvelope ? "tools" : "response_format"
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "\(parameter) cannot be losslessly mapped by OpenCode ACP v1",
                parameter: parameter,
                code: "unsupported_parameter"
            )
        }
        if request.temperature != nil {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "temperature cannot be losslessly mapped by agent backends",
                parameter: "temperature",
                code: "unsupported_parameter"
            )
        }
        if request.topP != nil {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "top_p cannot be losslessly mapped by agent backends",
                parameter: "top_p",
                code: "unsupported_parameter"
            )
        }
        if request.maximumTokens != nil {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "token limits cannot be losslessly mapped by agent backends",
                parameter: "max_completion_tokens",
                code: "unsupported_parameter"
            )
        }
    }

    private static func message(
        from output: String,
        toolEnvelope: Bool
    ) throws -> (message: PackageJSONValue, finishReason: String) {
        guard toolEnvelope else {
            return (
                .object([
                    "role": .string("assistant"),
                    "content": .string(output),
                ]),
                "stop"
            )
        }

        let value: PackageJSONValue
        do {
            value = try PackageJSONValue.decode(output)
        } catch {
            throw ChatCompletionsFailure(
                .backend,
                message: "Agent returned malformed function-tool envelope: \(error)",
                code: "invalid_backend_response"
            )
        }
        guard let object = value.objectValue,
              let toolCalls = object["tool_calls"]?.arrayValue,
              let content = object["content"]
        else {
            throw ChatCompletionsFailure(
                .backend,
                message: "Agent function-tool envelope is missing content or tool_calls",
                code: "invalid_backend_response"
            )
        }

        var message: [String: PackageJSONValue] = [
            "role": .string("assistant")
        ]
        switch content {
        case .null:
            message["content"] = .null
        case .string(let string):
            message["content"] = .string(string)
        default:
            message["content"] = .string(try content.jsonString)
        }

        if !toolCalls.isEmpty {
            let normalized = try toolCalls.enumerated().map { index, callValue in
                guard let call = callValue.objectValue,
                      let id = call["id"]?.stringValue,
                      let function = call["function"]?.objectValue,
                      let name = function["name"]?.stringValue,
                      let arguments = function["arguments"]
                else {
                    throw ChatCompletionsFailure(
                        .backend,
                        message: "Agent tool_calls[\(index)] is malformed",
                        code: "invalid_backend_response"
                    )
                }
                return PackageJSONValue.object([
                    "id": .string(id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(name),
                        "arguments": .string(try arguments.jsonString),
                    ]),
                ])
            }
            message["tool_calls"] = .array(normalized)
        }
        return (.object(message), toolCalls.isEmpty ? "stop" : "tool_calls")
    }

    private static func streamChunk(
        id: String,
        created: Int,
        model: String,
        role: String?,
        content: String?,
        finishReason: String?
    ) -> PackageJSONValue {
        var delta: [String: PackageJSONValue] = [:]
        if let role { delta["role"] = .string(role) }
        if let content { delta["content"] = .string(content) }
        return .object([
            "id": .string(id),
            "object": .string("chat.completion.chunk"),
            "created": .number(Double(created)),
            "model": .string(model),
            "choices": .array([
                .object([
                    "index": .number(0),
                    "delta": .object(delta),
                    "finish_reason": finishReason.map(PackageJSONValue.string) ?? .null,
                    "logprobs": .null,
                ])
            ]),
        ])
    }

    private static func sseData(_ data: Data) -> Data {
        var result = Data("data: ".utf8)
        result.append(data)
        result.append(Data("\n\n".utf8))
        return result
    }

    private static func failure(from error: any Error) -> ChatCompletionsFailure {
        if let failure = error as? ChatCompletionsFailure {
            return failure
        }
        if let modelError = error as? AgentLanguageModelError {
            switch modelError {
            case .unavailable:
                return .init(
                    .unavailable,
                    message: modelError.localizedDescription,
                    code: "model_unavailable"
                )
            default:
                return .init(
                    .backend,
                    message: modelError.localizedDescription,
                    code: "backend_error"
                )
            }
        }
        if let processError = error as? AgentProcessExecutionError {
            return .init(
                .backend,
                message: processError.localizedDescription,
                code: "process_error"
            )
        }
        if error is CancellationError || Task.isCancelled {
            return .init(
                .backend,
                message: "Request cancelled",
                code: "cancelled"
            )
        }
        return .init(
            .backend,
            message: String(describing: error),
            code: "backend_error"
        )
    }
}

private final class ProtocolEmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var started: Bool {
        lock.withLock { value }
    }

    func markStarted() {
        lock.withLock { value = true }
    }
}
