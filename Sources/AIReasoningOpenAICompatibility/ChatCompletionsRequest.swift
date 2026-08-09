// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import Foundation
import OpenAI

package struct PreparedChatCompletionsRequest: Sendable {
    package let query: ChatQuery
    package let model: String
    package let stream: Bool
    package let transcriptText: String
    package let images: [AgentPromptContext.Image]
    package let outputSchema: PackageJSONValue?
    package let usesToolEnvelope: Bool
    package let temperature: Double?
    package let topP: Double?
    package let maximumTokens: Int?
}

package enum ChatCompletionsRequestParser {
    private static let allowedTopLevelFields: Set<String> = [
        "messages",
        "model",
        "temperature",
        "top_p",
        "max_tokens",
        "max_completion_tokens",
        "response_format",
        "tools",
        "tool_choice",
        "stream",
        "stream_options",
        "n",
    ]

    package static func parse(_ data: Data) throws -> PreparedChatCompletionsRequest {
        let raw: PackageJSONValue
        do {
            raw = try PackageJSONValue.decode(data)
        } catch {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Request must be a JSON object",
                code: "invalid_json"
            )
        }
        guard let object = raw.objectValue else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Request must be a JSON object",
                code: "invalid_json"
            )
        }

        // OpenAI makes `stream` optional with a false default, while
        // MacPaw/OpenAI 0.5.1 requires it during ChatQuery decoding.
        var compatibilityObject = object
        if compatibilityObject["stream"] == nil {
            compatibilityObject["stream"] = .bool(false)
        }
        let query: ChatQuery
        do {
            query = try JSONDecoder().decode(
                ChatQuery.self,
                from: try PackageJSONValue.object(compatibilityObject).jsonData
            )
        } catch {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Malformed Chat Completions request: \(error)",
                code: "invalid_json"
            )
        }

        let unsupported = Set(object.keys).subtracting(allowedTopLevelFields)
        if let field = unsupported.sorted().first {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Unsupported Chat Completions parameter: \(field)",
                parameter: field,
                code: "unsupported_parameter"
            )
        }

        guard !query.model.isEmpty else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "model must not be empty",
                parameter: "model",
                code: "missing_required_parameter"
            )
        }
        if let n = object["n"]?.integerValue, n != 1 {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Only n=1 is supported",
                parameter: "n",
                code: "unsupported_parameter"
            )
        }
        if let streamOptions = object["stream_options"]?.objectValue {
            let unknown = Set(streamOptions.keys).subtracting(["include_usage"])
            if let field = unknown.sorted().first {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "Unsupported stream_options parameter: \(field)",
                    parameter: "stream_options.\(field)",
                    code: "unsupported_parameter"
                )
            }
            if streamOptions["include_usage"]?.boolValue == true {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "stream_options.include_usage is unsupported",
                    parameter: "stream_options.include_usage",
                    code: "unsupported_parameter"
                )
            }
        }

        let messages = try parseMessages(object["messages"])
        let responseSchema = try parseResponseSchema(object["response_format"])
        let tools = try parseTools(object["tools"])
        let toolChoice = try parseToolChoice(
            object["tool_choice"],
            tools: tools
        )
        if query.stream, !tools.isEmpty {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "stream with tools is unsupported",
                parameter: "tools",
                code: "unsupported_parameter"
            )
        }

        var transcriptText = messages.text
        var outputSchema = responseSchema
        var usesToolEnvelope = false
        if !tools.isEmpty {
            usesToolEnvelope = true
            transcriptText += "\n[available_functions]\n"
            transcriptText += try PackageJSONValue.array(tools).jsonString
            transcriptText += "\n[tool_choice]\n"
            transcriptText += try toolChoice.jsonString
            transcriptText += """

            [response_contract]
            Return exactly the JSON object required by the supplied output schema. \
            Use tool_calls only when a function should be called. Never execute a function.
            """
            outputSchema = toolEnvelopeSchema(
                tools: tools,
                contentSchema: responseSchema
            )
        }

        let maximumTokens = object["max_completion_tokens"]?.integerValue
            ?? object["max_tokens"]?.integerValue

        return .init(
            query: query,
            model: query.model,
            stream: query.stream,
            transcriptText: transcriptText,
            images: messages.images,
            outputSchema: outputSchema,
            usesToolEnvelope: usesToolEnvelope,
            temperature: object["temperature"].flatMap(number),
            topP: object["top_p"].flatMap(number),
            maximumTokens: maximumTokens
        )
    }

    private static func parseMessages(
        _ value: PackageJSONValue?
    ) throws -> (text: String, images: [AgentPromptContext.Image]) {
        guard let messages = value?.arrayValue, !messages.isEmpty else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "messages must be a non-empty array",
                parameter: "messages",
                code: "missing_required_parameter"
            )
        }

        var lines: [String] = []
        var images: [AgentPromptContext.Image] = []
        var imageIndex = 0

        for (index, messageValue) in messages.enumerated() {
            guard let message = messageValue.objectValue,
                  let role = message["role"]?.stringValue,
                  ["system", "developer", "user", "assistant", "tool"].contains(role)
            else {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "messages[\(index)].role is invalid",
                    parameter: "messages[\(index)].role",
                    code: "invalid_parameter"
                )
            }
            var allowedFields: Set<String> = ["role", "content"]
            switch role {
            case "system", "developer", "user":
                allowedFields.insert("name")
            case "assistant":
                allowedFields.formUnion(["name", "tool_calls"])
            case "tool":
                allowedFields.insert("tool_call_id")
            default:
                break
            }
            try rejectUnknownFields(
                in: message,
                allowed: allowedFields,
                parameter: "messages[\(index)]"
            )
            lines.append("[\(role)]")
            if let name = message["name"]?.stringValue, !name.isEmpty {
                lines.append("[name]")
                lines.append(name)
            } else if message["name"] != nil {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "messages[\(index)].name must be a non-empty string",
                    parameter: "messages[\(index)].name",
                    code: "invalid_parameter"
                )
            }
            if let content = message["content"] {
                try appendContent(
                    content,
                    role: role,
                    messageIndex: index,
                    lines: &lines,
                    images: &images,
                    imageIndex: &imageIndex
                )
            }
            if let toolCalls = message["tool_calls"] {
                guard toolCalls.arrayValue != nil else {
                    throw ChatCompletionsFailure(
                        .invalidRequest,
                        message: "messages[\(index)].tool_calls must be an array",
                        parameter: "messages[\(index)].tool_calls",
                        code: "invalid_parameter"
                    )
                }
                lines.append("[assistant_tool_calls]")
                lines.append(try toolCalls.jsonString)
            }
            if role == "tool" {
                guard let toolCallID = message["tool_call_id"]?.stringValue,
                      !toolCallID.isEmpty
                else {
                    throw ChatCompletionsFailure(
                        .invalidRequest,
                        message: "Tool messages require tool_call_id",
                        parameter: "messages[\(index)].tool_call_id",
                        code: "missing_required_parameter"
                    )
                }
                lines.append("[tool_call_id:\(toolCallID)]")
            }
        }
        return (lines.joined(separator: "\n"), images)
    }

    private static func appendContent(
        _ content: PackageJSONValue,
        role: String,
        messageIndex: Int,
        lines: inout [String],
        images: inout [AgentPromptContext.Image],
        imageIndex: inout Int
    ) throws {
        if let string = content.stringValue {
            lines.append(string)
            return
        }
        if case .null = content {
            return
        }
        guard let parts = content.arrayValue else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "messages[\(messageIndex)].content must be string, null, or an array",
                parameter: "messages[\(messageIndex)].content",
                code: "invalid_parameter"
            )
        }

        for (partIndex, partValue) in parts.enumerated() {
            guard let part = partValue.objectValue,
                  let type = part["type"]?.stringValue
            else {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "Content part type is required",
                    parameter: "messages[\(messageIndex)].content[\(partIndex)].type",
                    code: "invalid_parameter"
                )
            }
            switch type {
            case "text":
                try rejectUnknownFields(
                    in: part,
                    allowed: ["type", "text"],
                    parameter: "messages[\(messageIndex)].content[\(partIndex)]"
                )
                guard let text = part["text"]?.stringValue else {
                    throw ChatCompletionsFailure(
                        .invalidRequest,
                        message: "Text content part requires text",
                        parameter: "messages[\(messageIndex)].content[\(partIndex)].text",
                        code: "invalid_parameter"
                    )
                }
                lines.append(text)
            case "image_url":
                guard role == "user" else {
                    throw ChatCompletionsFailure(
                        .invalidRequest,
                        message: "image_url content is supported only in user messages",
                        parameter: "messages[\(messageIndex)].content[\(partIndex)]",
                        code: "unsupported_parameter"
                    )
                }
                try rejectUnknownFields(
                    in: part,
                    allowed: ["type", "image_url"],
                    parameter: "messages[\(messageIndex)].content[\(partIndex)]"
                )
                guard let imageObject = part["image_url"]?.objectValue,
                      let urlString = imageObject["url"]?.stringValue
                else {
                    throw ChatCompletionsFailure(
                        .invalidRequest,
                        message: "image_url content part requires image_url.url",
                        parameter: "messages[\(messageIndex)].content[\(partIndex)].image_url.url",
                        code: "invalid_parameter"
                    )
                }
                try rejectUnknownFields(
                    in: imageObject,
                    allowed: ["url", "detail"],
                    parameter:
                        "messages[\(messageIndex)].content[\(partIndex)].image_url"
                )
                if let detail = imageObject["detail"]?.stringValue, detail != "auto" {
                    throw ChatCompletionsFailure(
                        .invalidRequest,
                        message: "Only image detail 'auto' is supported",
                        parameter: "messages[\(messageIndex)].content[\(partIndex)].image_url.detail",
                        code: "unsupported_parameter"
                    )
                }
                imageIndex += 1
                lines.append("<image:\(imageIndex)>")
                images.append(try parseImageURL(urlString))
            default:
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "Unsupported content part type: \(type)",
                    parameter: "messages[\(messageIndex)].content[\(partIndex)].type",
                    code: "unsupported_parameter"
                )
            }
        }
    }

    private static func parseImageURL(
        _ source: String
    ) throws -> AgentPromptContext.Image {
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ",") else {
                throw invalidDataURL()
            }
            let metadata = String(source[source.index(source.startIndex, offsetBy: 5)..<comma])
            let components = metadata.split(separator: ";").map(String.init)
            guard components.count == 2,
                  components[1].lowercased() == "base64",
                  components[0].lowercased().hasPrefix("image/"),
                  let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
                  !data.isEmpty
            else {
                throw invalidDataURL()
            }
            return .data(data, mimeType: components[0].lowercased())
        }
        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "image_url.url must be an HTTP(S), file, or image data URL",
                parameter: "messages.content.image_url.url",
                code: "invalid_parameter"
            )
        }
        return .url(url)
    }

    private static func invalidDataURL() -> ChatCompletionsFailure {
        ChatCompletionsFailure(
            .invalidRequest,
            message: "Image data URL must contain non-empty base64 image data",
            parameter: "messages.content.image_url.url",
            code: "invalid_parameter"
        )
    }

    private static func parseResponseSchema(
        _ value: PackageJSONValue?
    ) throws -> PackageJSONValue? {
        guard let value else { return nil }
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue
        else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "response_format.type is required",
                parameter: "response_format.type",
                code: "invalid_parameter"
            )
        }
        switch type {
        case "text":
            try rejectUnknownFields(
                in: object,
                allowed: ["type"],
                parameter: "response_format"
            )
            return nil
        case "json_object":
            try rejectUnknownFields(
                in: object,
                allowed: ["type"],
                parameter: "response_format"
            )
            return .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
            ])
        case "json_schema":
            try rejectUnknownFields(
                in: object,
                allowed: ["type", "json_schema"],
                parameter: "response_format"
            )
            guard let specification = object["json_schema"]?.objectValue,
                  let name = specification["name"]?.stringValue,
                  !name.isEmpty,
                  let schema = specification["schema"],
                  schema.objectValue != nil
            else {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "response_format.json_schema requires name and an object schema",
                    parameter: "response_format.json_schema",
                    code: "missing_required_parameter"
                )
            }
            try rejectUnknownFields(
                in: specification,
                allowed: ["name", "description", "schema", "strict"],
                parameter: "response_format.json_schema"
            )
            if let description = specification["description"],
               description.stringValue == nil
            {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "response_format.json_schema.description must be a string",
                    parameter: "response_format.json_schema.description",
                    code: "invalid_parameter"
                )
            }
            if let strict = specification["strict"], strict.boolValue == nil {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "response_format.json_schema.strict must be boolean",
                    parameter: "response_format.json_schema.strict",
                    code: "invalid_parameter"
                )
            }
            return schema
        default:
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Unsupported response_format.type: \(type)",
                parameter: "response_format.type",
                code: "unsupported_parameter"
            )
        }
    }

    private static func parseTools(
        _ value: PackageJSONValue?
    ) throws -> [PackageJSONValue] {
        guard let value else { return [] }
        guard let tools = value.arrayValue else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "tools must be an array",
                parameter: "tools",
                code: "invalid_parameter"
            )
        }
        for (index, toolValue) in tools.enumerated() {
            guard let tool = toolValue.objectValue,
                  tool["type"]?.stringValue == "function",
                  let function = tool["function"]?.objectValue,
                  let name = function["name"]?.stringValue,
                  !name.isEmpty,
                  function["parameters"]?.objectValue != nil
            else {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "tools[\(index)] must be a named function with parameters",
                    parameter: "tools[\(index)]",
                    code: "invalid_parameter"
                )
            }
            try rejectUnknownFields(
                in: tool,
                allowed: ["type", "function"],
                parameter: "tools[\(index)]"
            )
            try rejectUnknownFields(
                in: function,
                allowed: ["name", "description", "parameters", "strict"],
                parameter: "tools[\(index)].function"
            )
            if let description = function["description"],
               description.stringValue == nil
            {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "tools[\(index)].function.description must be a string",
                    parameter: "tools[\(index)].function.description",
                    code: "invalid_parameter"
                )
            }
            if let strict = function["strict"], strict.boolValue == nil {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "tools[\(index)].function.strict must be boolean",
                    parameter: "tools[\(index)].function.strict",
                    code: "invalid_parameter"
                )
            }
        }
        return tools
    }

    private static func parseToolChoice(
        _ value: PackageJSONValue?,
        tools: [PackageJSONValue]
    ) throws -> PackageJSONValue {
        guard let value else { return .string("auto") }
        guard !tools.isEmpty else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "tool_choice requires tools",
                parameter: "tool_choice",
                code: "invalid_parameter"
            )
        }
        if let string = value.stringValue {
            guard ["none", "auto", "required"].contains(string) else {
                throw ChatCompletionsFailure(
                    .invalidRequest,
                    message: "Unsupported tool_choice: \(string)",
                    parameter: "tool_choice",
                    code: "unsupported_parameter"
                )
            }
            return value
        }
        guard let object = value.objectValue,
              object["type"]?.stringValue == "function",
              let function = object["function"]?.objectValue,
              let name = function["name"]?.stringValue
        else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "tool_choice must select a named function",
                parameter: "tool_choice",
                code: "invalid_parameter"
            )
        }
        try rejectUnknownFields(
            in: object,
            allowed: ["type", "function"],
            parameter: "tool_choice"
        )
        try rejectUnknownFields(
            in: function,
            allowed: ["name"],
            parameter: "tool_choice.function"
        )
        let toolNames = Set(
            tools.compactMap {
                $0.objectValue?["function"]?.objectValue?["name"]?.stringValue
            }
        )
        guard toolNames.contains(name) else {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "tool_choice selects an undeclared function: \(name)",
                parameter: "tool_choice.function.name",
                code: "invalid_parameter"
            )
        }
        return value
    }

    private static func toolEnvelopeSchema(
        tools: [PackageJSONValue],
        contentSchema: PackageJSONValue?
    ) -> PackageJSONValue {
        let calls = tools.compactMap { tool -> PackageJSONValue? in
            guard let function = tool.objectValue?["function"]?.objectValue,
                  let name = function["name"]?.stringValue,
                  let parameters = function["parameters"]
            else {
                return nil
            }
            return .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "type": .object(["const": .string("function")]),
                    "function": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["const": .string(name)]),
                            "arguments": parameters,
                        ]),
                        "required": .array([.string("name"), .string("arguments")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
                "required": .array([
                    .string("id"), .string("type"), .string("function"),
                ]),
                "additionalProperties": .bool(false),
            ])
        }
        let content = contentSchema ?? .object(["type": .string("string")])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "content": .object([
                    "anyOf": .array([
                        content,
                        .object(["type": .string("null")]),
                    ])
                ]),
                "tool_calls": .object([
                    "type": .string("array"),
                    "items": .object(["oneOf": .array(calls)]),
                ]),
            ]),
            "required": .array([.string("content"), .string("tool_calls")]),
            "additionalProperties": .bool(false),
        ])
    }

    private static func number(_ value: PackageJSONValue) -> Double? {
        guard case .number(let number) = value else { return nil }
        return number
    }

    private static func rejectUnknownFields(
        in object: [String: PackageJSONValue],
        allowed: Set<String>,
        parameter: String
    ) throws {
        if let field = Set(object.keys).subtracting(allowed).sorted().first {
            throw ChatCompletionsFailure(
                .invalidRequest,
                message: "Unsupported parameter: \(parameter).\(field)",
                parameter: "\(parameter).\(field)",
                code: "unsupported_parameter"
            )
        }
    }
}
