// SPDX-License-Identifier: GPL-3.0-or-later

import AnyLanguageModel
import Foundation

/// A two-tool coding harness. The model can call only `bash` and
/// `str_replace_editor`; both act on the same isolated sandbox.
public final class MinimalHarness: @unchecked Sendable {
    public static let toolNames = ["bash", "str_replace_editor"]
    public static let defaultInstructions = "You are a helpful software engineer assistant. Use only the provided Bash and file editor tools when operating on the sandbox."

    private let session: LanguageModelSession

    public init(
        model: any LanguageModel,
        sandbox: any MinimalAgentSandbox,
        instructions: String = MinimalHarness.defaultInstructions
    ) {
        self.session = LanguageModelSession(
            model: model,
            tools: [
                MinimalBashTool(sandbox: sandbox),
                MinimalStrReplaceEditorTool(sandbox: sandbox),
            ],
            instructions: instructions
        )
    }

    public var transcript: Transcript {
        session.transcript
    }

    @discardableResult
    public func respond(
        to prompt: String,
        options: GenerationOptions = GenerationOptions()
    ) async throws
        -> LanguageModelSession.Response<String>
    {
        try await session.respond(to: prompt, options: options)
    }

    public func streamResponse(to prompt: String)
        -> sending LanguageModelSession.ResponseStream<String>
    {
        session.streamResponse(to: prompt)
    }
}
