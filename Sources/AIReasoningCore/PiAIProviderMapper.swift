import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

enum PiAIProviderMapper {
  static func messages(from transcript: Transcript) throws -> [ProviderMessage] {
    var messages: [ProviderMessage] = []
    for entry in transcript {
      let message: ProviderMessage
      switch entry {
      case .instructions(let instructions):
        message = .system(try text(from: instructions.segments))
      case .prompt(let prompt):
        message = .user(try prompt.segments.map(userContent))
      case .response(let response):
        message = .assistant(try response.segments.map(assistantContent))
      case .toolCalls(let calls):
        message = .assistant(
          try calls.map { call in
            .toolCall(
              ProviderToolCall(
                id: call.id,
                name: call.toolName,
                arguments: try jsonValue(call.arguments)
              )
            )
          }
        )
      case .reasoning(let reasoning):
        message = .assistant([.reasoning(try providerReasoning(reasoning))])
      case .toolOutput(let output):
        message = try toolResult(output)
      }
      // A mixed assistant turn is stored as adjacent reasoning/response/toolCalls entries.
      // A tool output, prompt or instructions entry terminates that turn.
      if case .assistant(let content) = message,
        case .assistant(let previous) = messages.last
      {
        messages[messages.count - 1] = .assistant(previous + content)
      } else {
        messages.append(message)
      }
    }
    return messages
  }

  static func entries(
    from content: [ProviderAssistantContent],
    roundID: String = UUID().uuidString
  ) throws -> [Transcript.Entry] {
    var entries: [Transcript.Entry] = []
    var reasoningOrdinal = 0
    for item in content {
      switch item {
      case .text(let text):
        entries.append(.response(.init(assetIDs: [], segments: [.text(.init(content: text))])))
      case .signedText(let text):
        entries.append(
          .response(.init(assetIDs: [], segments: [.text(.init(content: text.text))]))
        )
      case .reasoning(let value):
        entries.append(
          .reasoning(try reasoningEntry(value, id: "\(roundID):reasoning:\(reasoningOrdinal)"))
        )
        reasoningOrdinal += 1
      case .toolCall(let call):
        let mapped = try transcriptToolCall(call)
        if case .toolCalls(let previous) = entries.last {
          entries[entries.count - 1] = .toolCalls(
            .init(id: previous.id, Array(previous) + [mapped])
          )
        } else {
          entries.append(.toolCalls(.init([mapped])))
        }
      }
    }
    return entries
  }

  static func reasoningEntries(
    from content: [ProviderAssistantContent],
    roundID: String
  ) throws -> [Transcript.Entry] {
    try entries(
      from: content.filter { if case .reasoning = $0 { true } else { false } },
      roundID: roundID
    )
  }

  private static func reasoningEntry(
    _ value: ProviderReasoningContent,
    id: String
  ) throws -> Transcript.Reasoning {
    var metadata: [String: GeneratedContent] = [
      "pi-ai-swift.providerMetadata": try generatedContent(.object(value.providerMetadata))
    ]
    if let redacted = value.isRedacted {
      metadata["pi-ai-swift.isRedacted"] = GeneratedContent(redacted)
    }
    if value.isRedacted == true {
      metadata["pi-ai-swift.redactedText"] = GeneratedContent(value.text)
    }
    return .init(
      id: id,
      metadata: metadata,
      segments: value.isRedacted == true || value.text.isEmpty
        ? [] : [.text(.init(id: "\(id):text", content: value.text))],
      signature: value.signature.map { Data($0.utf8) }
    )
  }

  private static func providerReasoning(
    _ value: Transcript.Reasoning
  ) throws -> ProviderReasoningContent {
    let redacted: Bool?
    if let flag = value.metadata["pi-ai-swift.isRedacted"] {
      redacted = try Bool(flag)
    } else {
      redacted = nil
    }
    let display = try text(from: value.segments)
    let originalText =
      redacted == true
      ? try value.metadata["pi-ai-swift.redactedText"].map(String.init) ?? "" : display
    let signature: String?
    if let bytes = value.signature {
      guard let decoded = String(data: bytes, encoding: .utf8) else {
        throw AIReasoningCoreError(.invalidTranscript, "pi-ai reasoning signature is not UTF-8")
      }
      signature = decoded
    } else {
      signature = nil
    }
    var metadata: [String: PiAIProviderRuntime.JSONValue] = [:]
    if let raw = value.metadata["pi-ai-swift.providerMetadata"] {
      guard case .object(let object) = try jsonValue(raw) else {
        throw AIReasoningCoreError(.invalidTranscript, "pi-ai reasoning metadata must be an object")
      }
      metadata = object
    }
    return .init(
      text: originalText,
      signature: signature,
      isRedacted: redacted,
      providerMetadata: metadata
    )
  }

  static func tools(from tools: [any Tool]) throws -> [ProviderToolDefinition] {
    let names = tools.map(\.name)
    guard Set(names).count == names.count else {
      throw AIReasoningCoreError(
        .invalidTranscript,
        "tool names must be unique within a resolved request context"
      )
    }
    return try tools.map { tool in
      ProviderToolDefinition(
        name: tool.name,
        description: tool.description,
        inputSchema: try toolInputSchema(tool.parameters)
      )
    }
  }

  private static func toolInputSchema(
    _ schema: GenerationSchema
  ) throws -> PiAIProviderRuntime.JSONValue {
    guard case .object(var root) = try encodedJSONValue(schema) else {
      throw AIReasoningCoreError(.unsupportedOperation, "tool input schema must be an object")
    }
    let definitions = root["$defs"]
    var visited: Set<String> = []
    while let reference = root["$ref"] {
      guard case .string(let path) = reference,
        path.hasPrefix("#/$defs/"),
        visited.insert(path).inserted,
        case .object(let entries) = definitions,
        case .object(let resolved) = entries[String(path.dropFirst("#/$defs/".count))]
      else {
        throw AIReasoningCoreError(
          .unsupportedOperation,
          "tool input schema has an unsupported or unresolved root reference"
        )
      }
      root = resolved
    }
    guard root["type"] == .string("object") else {
      throw AIReasoningCoreError(
        .unsupportedOperation,
        "tool input schema root must have type object"
      )
    }
    if let definitions { root["$defs"] = definitions }
    return .object(root)
  }

  static func options<Content: Generable>(
    for type: Content.Type,
    options: GenerationOptions,
    custom: PiAILanguageModel.CustomGenerationOptions
  ) throws -> ProviderGenerationOptions {
    guard options.sampling == nil else {
      throw AIReasoningCoreError(
        .unsupportedOperation,
        "pi-ai-swift cannot represent AnyLanguageModel sampling options"
      )
    }
    return ProviderGenerationOptions(
      maximumOutputTokens: options.maximumResponseTokens,
      temperature: options.temperature,
      reasoningEffort: custom.reasoningEffort,
      responseSchema: type == String.self ? nil : try encodedJSONValue(type.generationSchema),
      providerOptions: custom.providerOptions,
      outputModality: custom.outputModality,
      sessionID: custom.sessionID,
      cacheRetention: custom.cacheRetention,
      serviceTier: custom.serviceTier,
      toolChoice: custom.toolChoice
    )
  }

  static func transcriptToolCall(_ call: ProviderToolCall) throws -> Transcript.ToolCall {
    Transcript.ToolCall(
      id: call.id,
      toolName: call.name,
      arguments: try generatedContent(call.arguments)
    )
  }

  static func toolResult(_ output: Transcript.ToolOutput) throws -> ProviderMessage {
    .toolResult(
      ProviderToolResult(
        toolCallID: output.id,
        toolName: output.toolName,
        content: output.segments.map { segment in
          switch segment {
          case .text(let text): return .text(text.content)
          case .structure(let structure): return .text(structure.content.jsonString)
          case .image(let image): return .image(providerImage(image))
          }
        },
        isError: false
      )
    )
  }

  static func validateFinish(_ reason: ProviderFinishReason) throws {
    switch reason {
    case .stop, .length, .toolCalls:
      return
    case .contentFilter:
      throw AIReasoningCoreError(
        .invalidProviderResponse,
        "provider stopped because of content filtering"
      )
    case .cancelled:
      throw CancellationError()
    }
  }

  private static func userContent(_ segment: Transcript.Segment) throws -> ProviderUserContent {
    switch segment {
    case .text(let text): return .text(text.content)
    case .structure(let structure): return .text(structure.content.jsonString)
    case .image(let image): return .image(providerImage(image))
    }
  }

  private static func assistantContent(
    _ segment: Transcript.Segment
  ) throws -> ProviderAssistantContent {
    switch segment {
    case .text(let text): return .text(text.content)
    case .structure(let structure): return .text(structure.content.jsonString)
    case .image:
      throw AIReasoningCoreError(
        .invalidTranscript,
        "pi-ai-swift cannot represent an assistant image transcript segment"
      )
    }
  }

  private static func text(from segments: [Transcript.Segment]) throws -> String {
    try segments.map { segment in
      switch segment {
      case .text(let text): return text.content
      case .structure(let structure): return structure.content.jsonString
      case .image:
        throw AIReasoningCoreError(
          .invalidTranscript,
          "instructions cannot contain image segments"
        )
      }
    }.joined(separator: "\n")
  }

  private static func providerImage(_ image: Transcript.ImageSegment) -> ProviderImage {
    switch image.source {
    case .data(let data, let mimeType): return .data(data, mimeType: mimeType)
    case .url(let url): return .remoteURL(url, mimeType: nil)
    }
  }

  private static func jsonValue(
    _ content: GeneratedContent
  ) throws -> PiAIProviderRuntime.JSONValue {
    guard let data = content.jsonString.data(using: .utf8) else {
      throw AIReasoningCoreError(.invalidStructuredOutput, "generated content is not UTF-8")
    }
    return try JSONDecoder().decode(PiAIProviderRuntime.JSONValue.self, from: data)
  }

  private static func generatedContent(
    _ value: PiAIProviderRuntime.JSONValue
  ) throws -> GeneratedContent {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw AIReasoningCoreError(.invalidStructuredOutput, "tool arguments are not UTF-8")
    }
    return try GeneratedContent(json: json)
  }

  private static func encodedJSONValue<T: Encodable>(
    _ value: T
  ) throws -> PiAIProviderRuntime.JSONValue {
    try JSONDecoder().decode(
      PiAIProviderRuntime.JSONValue.self,
      from: JSONEncoder().encode(value)
    )
  }
}
