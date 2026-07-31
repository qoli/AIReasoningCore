@testable import AIReasoningOpenAICompatibility
import Foundation
import OpenAI
import Testing

@Suite
struct ChatCompletionsGoldenTests {
    @Test
    func requestFixtureDecodesAsMacPawChatQuery() throws {
        let data = try fixture("text-request")
        let query = try JSONDecoder().decode(ChatQuery.self, from: data)
        #expect(query.model == "fixture-model")
        #expect(query.messages.count == 1)
    }

    @Test
    func responseFixtureDecodesAsMacPawChatResult() throws {
        let data = try fixture("text-response")
        let result = try JSONDecoder().decode(ChatResult.self, from: data)
        #expect(result.choices.first?.message.content == "Hello")
    }

    @Test
    func everyStreamFixtureLineDecodesAsMacPawChatStreamResult() throws {
        let data = try fixture("text-stream", extension: "jsonl")
        let text = try #require(String(data: data, encoding: .utf8))
        let chunks = try text.split(separator: "\n").map {
            try JSONDecoder().decode(ChatStreamResult.self, from: Data($0.utf8))
        }

        #expect(chunks.count == 3)
        #expect(chunks[1].choices.first?.delta.content == "Hello")
        #expect(chunks[2].choices.first?.finishReason != nil)
    }

    @Test
    func imageDataURLIsAcceptedWithoutChangingItsBytes() throws {
        let request = """
        {
          "model":"fixture-model",
          "messages":[{
            "role":"user",
            "content":[
              {"type":"text","text":"Describe"},
              {"type":"image_url","image_url":{"url":"data:image/png;base64,AQI="}}
            ]
          }]
        }
        """
        let parsed = try ChatCompletionsRequestParser.parse(Data(request.utf8))
        #expect(parsed.images.count == 1)
    }

    @Test
    func jsonSchemaRequestPreservesTheStandardSchema() throws {
        let request = """
        {
          "model":"fixture-model",
          "messages":[{"role":"user","content":"Return JSON"}],
          "stream":false,
          "response_format":{
            "type":"json_schema",
            "json_schema":{
              "name":"answer",
              "strict":true,
              "schema":{
                "type":"object",
                "properties":{"answer":{"type":"string"}},
                "required":["answer"],
                "additionalProperties":false
              }
            }
          }
        }
        """

        let parsed = try ChatCompletionsRequestParser.parse(Data(request.utf8))
        #expect(
            parsed.outputSchema?.objectValue?["properties"]?
                .objectValue?["answer"]?.objectValue?["type"]?.stringValue
                == "string"
        )
    }

    @Test
    func nestedUnsupportedMessageFieldFailsExplicitly() {
        let request = """
        {
          "model":"fixture-model",
          "messages":[{
            "role":"user",
            "content":"Hello",
            "provider_extension":true
          }],
          "stream":false
        }
        """

        #expect(throws: ChatCompletionsFailure.self) {
            _ = try ChatCompletionsRequestParser.parse(Data(request.utf8))
        }
    }

    @Test
    func streamUsageFailsExplicitly() {
        let request = """
        {
          "model":"fixture-model",
          "messages":[{"role":"user","content":"Hello"}],
          "stream":true,
          "stream_options":{"include_usage":true}
        }
        """

        #expect(throws: ChatCompletionsFailure.self) {
            _ = try ChatCompletionsRequestParser.parse(Data(request.utf8))
        }
    }

    @Test
    func streamWithToolsFailsExplicitly() throws {
        let request = """
        {
          "model":"fixture-model",
          "messages":[{"role":"user","content":"Hello"}],
          "stream":true,
          "tools":[{
            "type":"function",
            "function":{
              "name":"lookup",
              "parameters":{"type":"object","properties":{}}
            }
          }]
        }
        """

        #expect(throws: ChatCompletionsFailure.self) {
            _ = try ChatCompletionsRequestParser.parse(Data(request.utf8))
        }
    }

    @Test
    func unsupportedFieldFailsExplicitly() throws {
        let request = """
        {
          "model":"fixture-model",
          "messages":[{"role":"user","content":"Hello"}],
          "seed":42
        }
        """

        #expect(throws: ChatCompletionsFailure.self) {
            _ = try ChatCompletionsRequestParser.parse(Data(request.utf8))
        }
    }

    private func fixture(_ name: String, extension: String = "json") throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: `extension`,
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }
}
