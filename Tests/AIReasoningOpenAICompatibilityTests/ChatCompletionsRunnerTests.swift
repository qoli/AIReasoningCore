// SPDX-License-Identifier: GPL-3.0-or-later

@testable import AIReasoningOpenAICompatibility
import Foundation
import OpenAI
import Testing

@Suite
struct ChatCompletionsRunnerTests {
    @Test
    func codexStreamEmitsOnlyDecodableSSEChunksAndDone() async throws {
        let fixture = try CodexFixtureExecutable()
        defer { fixture.remove() }
        let output = LockedData()

        let exitCode = await ChatCompletionsRunner().run(
            input: Data(
                """
                {
                  "model":"fixture-model",
                  "messages":[{"role":"user","content":"Hello"}],
                  "stream":true
                }
                """.utf8
            ),
            configuration: fixture.configuration(mode: "text"),
            emit: { output.append($0) },
            log: { _ in }
        )

        #expect(exitCode == 0)
        let events = try sseEvents(output.data)
        #expect(events.last == "[DONE]")
        let chunks = try events.dropLast().map {
            try JSONDecoder().decode(ChatStreamResult.self, from: Data($0.utf8))
        }
        _ = try #require(chunks.count == 4)
        #expect(chunks[1].choices.first?.delta.content == "Hello")
        #expect(chunks[2].choices.first?.delta.content == " world")
        #expect(chunks[3].choices.first?.finishReason != nil)
    }

    @Test
    func codexNonStreamReturnsPassiveFunctionToolCall() async throws {
        let fixture = try CodexFixtureExecutable()
        defer { fixture.remove() }
        let output = LockedData()

        let exitCode = await ChatCompletionsRunner().run(
            input: Data(
                """
                {
                  "model":"fixture-model",
                  "messages":[{"role":"user","content":"Look it up"}],
                  "stream":false,
                  "tools":[{
                    "type":"function",
                    "function":{
                      "name":"lookup",
                      "description":"Lookup a value",
                      "parameters":{
                        "type":"object",
                        "properties":{"q":{"type":"string"}},
                        "required":["q"]
                      }
                    }
                  }]
                }
                """.utf8
            ),
            configuration: fixture.configuration(mode: "tools"),
            emit: { output.append($0) },
            log: { _ in }
        )

        #expect(exitCode == 0)
        let result = try JSONDecoder().decode(ChatResult.self, from: output.data)
        #expect(result.choices.first?.finishReason == "tool_calls")
        #expect(result.choices.first?.message.toolCalls?.first?.function.name == "lookup")
        #expect(
            result.choices.first?.message.toolCalls?.first?.function.arguments
                == #"{"q":"x"}"#
        )
    }

    @Test
    func midStreamBackendFailureEmitsErrorSSEWithoutDone() async throws {
        let fixture = try CodexFixtureExecutable()
        defer { fixture.remove() }
        let output = LockedData()

        let exitCode = await ChatCompletionsRunner().run(
            input: Data(
                """
                {
                  "model":"fixture-model",
                  "messages":[{"role":"user","content":"Hello"}],
                  "stream":true
                }
                """.utf8
            ),
            configuration: fixture.configuration(mode: "failure"),
            emit: { output.append($0) },
            log: { _ in }
        )

        #expect(exitCode != 0)
        let events = try sseEvents(output.data)
        #expect(!events.contains("[DONE]"))
        let final = try #require(events.last)
        let object = try JSONSerialization.jsonObject(
            with: Data(final.utf8)
        ) as? [String: Any]
        #expect(object?["error"] != nil)
    }

    @Test
    func malformedJSONReturnsOpenAIErrorEnvelopeAndNonzeroStatus() async throws {
        let output = LockedData()
        let exitCode = await ChatCompletionsRunner().run(
            input: Data("{".utf8),
            configuration: .init(
                backend: .codex,
                executableURL: URL(fileURLWithPath: "/missing/codex"),
                baseURL: nil,
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeoutSeconds: 1,
                environment: [:]
            ),
            emit: { output.append($0) },
            log: { _ in }
        )

        #expect(exitCode != 0)
        let object = try JSONSerialization.jsonObject(
            with: output.data
        ) as? [String: Any]
        #expect(object?["error"] != nil)
    }

    @Test
    func openCodeStructuredOutputFailsBeforeLaunchingBackend() async throws {
        let output = LockedData()
        let exitCode = await ChatCompletionsRunner().run(
            input: Data(
                """
                {
                  "model":"fixture-model",
                  "messages":[{"role":"user","content":"Hello"}],
                  "response_format":{"type":"json_object"},
                  "stream":false
                }
                """.utf8
            ),
            configuration: .init(
                backend: .opencode,
                executableURL: URL(fileURLWithPath: "/must-not-launch/opencode"),
                baseURL: nil,
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeoutSeconds: 1,
                environment: [:]
            ),
            emit: { output.append($0) },
            log: { _ in }
        )

        #expect(exitCode == 2)
        let object = try #require(
            JSONSerialization.jsonObject(with: output.data) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["param"] as? String == "response_format")
        #expect(error["code"] as? String == "unsupported_parameter")
    }

    private func sseEvents(_ data: Data) throws -> [String] {
        let text = try #require(String(data: data, encoding: .utf8))
        return text
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
            .map { event in
                String(event.dropFirst("data: ".count))
            }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }
}

private struct CodexFixtureExecutable {
    let directoryURL: URL
    let executableURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        executableURL = directoryURL.appendingPathComponent("fixture-codex")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "--version" ]; then
          printf '%s\\n' 'codex-cli 0.146.0'
          exit 0
        fi
        if [ "${1:-}" = "mcp" ]; then
          printf '%s\\n' '[]'
          exit 0
        fi
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\\n' '{"id":1,"result":{"userAgent":"fixture"}}'
              ;;
            *'thread/start'*|*'thread\\/start'*)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fixture"}}}'
              ;;
            *'turn/start'*|*'turn\\/start'*)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fixture"}}}'
              if [ "${AI_REASONING_FIXTURE:-text}" = "tools" ]; then
                printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fixture","turnId":"turn-fixture","itemId":"item-fixture","delta":"{\\"content\\":null,\\"tool_calls\\":[{\\"id\\":\\"call_1\\",\\"function\\":{\\"name\\":\\"lookup\\",\\"arguments\\":{\\"q\\":\\"x\\"}}}]}"}}'
              else
                printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fixture","turnId":"turn-fixture","itemId":"item-fixture","delta":"Hello"}}'
                if [ "${AI_REASONING_FIXTURE:-text}" = "failure" ]; then
                  printf '%s\\n' 'fixture failure' >&2
                  exit 9
                fi
                printf '%s\\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fixture","turnId":"turn-fixture","itemId":"item-fixture","delta":" world"}}'
              fi
              printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-fixture","turn":{"id":"turn-fixture","status":"completed"}}}'
              exit 0
              ;;
          esac
        done
        """
        try Data(script.utf8).write(
            to: executableURL,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func configuration(mode: String) -> ChatCompletionsExecutionConfiguration {
        .init(
            backend: .codex,
            executableURL: executableURL,
            baseURL: nil,
            workingDirectoryURL: directoryURL,
            timeoutSeconds: 5,
            environment: ["AI_REASONING_FIXTURE": mode]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
