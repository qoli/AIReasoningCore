#if canImport(FoundationModels)
  import CoreImage
  import Foundation
  import FoundationModels
  import ImageIO
  import PiAIProviderRuntime
  import UniformTypeIdentifiers

  /// Native OS 27 integration. The system Session owns Tool execution and continuation.
  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  extension PiAILanguageModel: FoundationModels.LanguageModel {
    public var executorConfiguration: UUID { executorID }

    public var capabilities: FoundationModels.LanguageModelCapabilities {
      var values: [FoundationModels.LanguageModelCapabilities.Capability] = []
      if providerCapabilities?.imageInput == true { values.append(.vision) }
      if providerCapabilities?.toolCalling == true { values.append(.toolCalling) }
      if providerCapabilities?.reasoning == true { values.append(.reasoning) }
      if providerCapabilities?.structuredOutput == true { values.append(.guidedGeneration) }
      return .init(values)
    }

    public struct Executor: FoundationModels.LanguageModelExecutor {
      public typealias Model = PiAILanguageModel
      public init(configuration: UUID) {}

      public func respond(
        to request: FoundationModels.LanguageModelExecutorGenerationRequest,
        model: Model, streamingInto channel: FoundationModels.LanguageModelExecutorGenerationChannel
      ) async throws {
        let emitter = FoundationGenerationEmitter(channel: channel)
        let round = try await model.providerAdapter.generateRound(
          messages: FoundationProviderMapper.messages(request.transcript),
          tools: request.enabledToolDefinitions.map {
            .init(
              name: $0.name, description: $0.description,
              inputSchema: try PiAIProviderMapper.toolInputSchema($0.parameters))
          },
          options: FoundationProviderMapper.options(request)
        ) { update in
          await emitter.update(update.content)
        }
        try await emitter.finish(round)
      }
    }
  }

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  enum FoundationProviderMapper {
    static let replayKey = "pi-ai-swift.assistantMessage"
    static let callKey = "pi-ai-swift.toolCall"

    static func generated<T: Encodable>(_ value: T) throws -> FoundationModels.GeneratedContent {
      try .init(json: String(decoding: JSONEncoder().encode(value), as: UTF8.self))
    }

    static func decoded<T: Decodable>(
      _ type: T.Type, _ value: FoundationModels.GeneratedContent
    ) throws -> T {
      try JSONDecoder().decode(type, from: Data(value.jsonString.utf8))
    }

    static func messages(_ transcript: FoundationModels.Transcript) throws -> [ProviderMessage] {
      var result: [ProviderMessage] = []
      var assistant: [ProviderAssistantContent] = []
      var replay: ProviderAssistantMessage?
      func flush() throws {
        guard !assistant.isEmpty else { return }
        if let replay {
          // Never restore an opaque message over an edited/filtered canonical turn.
          guard replay.content == assistant else {
            throw AIReasoningCoreError(
              .invalidTranscript, "assistant replay metadata does not match transcript")
          }
          result.append(.assistantMessage(replay))
        } else {
          result.append(.assistant(assistant))
        }
        assistant.removeAll()
        replay = nil
      }
      func retainReplay(_ metadata: [String: FoundationModels.GeneratedContent]) throws {
        if let value = metadata[replayKey] {
          replay = try decoded(ProviderAssistantMessage.self, value)
        }
      }
      for entry in transcript {
        switch entry {
        case .response(let value):
          for segment in value.segments {
            switch segment {
            case .text(let text):
              if let signed = value.metadata["pi-ai-swift.signedText"] {
                let original = try decoded(ProviderTextContent.self, signed)
                guard original.text == text.content else {
                  throw AIReasoningCoreError(
                    .invalidTranscript, "signed text metadata does not match transcript")
                }
                assistant.append(.signedText(original))
              } else {
                assistant.append(.text(text.content))
              }
            case .structure(let structure): assistant.append(.text(structure.content.jsonString))
            default: throw unsupported(entry)
            }
          }
          try retainReplay(value.metadata)
        case .reasoning(let value):
          let redacted = try value.metadata["pi-ai-swift.isRedacted"].map { try Bool($0) }
          let text =
            redacted == true
            ? try value.metadata["pi-ai-swift.redactedText"].map { try String($0) } ?? ""
            : try text(value.segments)
          let metadata =
            try value.metadata["pi-ai-swift.providerMetadata"].map {
              try decoded([String: PiAIProviderRuntime.JSONValue].self, $0)
            } ?? [:]
          let signature = try value.signature.map { bytes -> String in
            guard let text = String(data: bytes, encoding: .utf8) else {
              throw AIReasoningCoreError(.invalidTranscript, "reasoning signature is not UTF-8")
            }
            return text
          }
          assistant.append(
            .reasoning(
              .init(
                text: text, signature: signature,
                isRedacted: redacted, providerMetadata: metadata)))
          try retainReplay(value.metadata)
        case .toolCalls(let calls):
          for call in calls {
            let arguments = try decoded(PiAIProviderRuntime.JSONValue.self, call.arguments)
            if let value = call.metadata[callKey] {
              let original = try decoded(ProviderToolCall.self, value)
              guard original.id == call.id, original.name == call.toolName,
                original.arguments == arguments
              else {
                throw AIReasoningCoreError(
                  .invalidTranscript, "tool replay metadata does not match transcript")
              }
              assistant.append(.toolCall(original))
            } else {
              assistant.append(
                .toolCall(.init(id: call.id, name: call.toolName, arguments: arguments)))
            }
            try retainReplay(call.metadata)
          }
        case .instructions(let value):
          try flush()
          result.append(.system(try text(value.segments)))
        case .prompt(let value):
          try flush()
          result.append(
            .user(
              try value.segments.map { segment in
                switch segment {
                case .text(let value): return .text(value.content)
                case .structure(let value): return .text(value.content.jsonString)
                case .attachment(let value): return .image(try image(value.content))
                @unknown default: throw unsupported(entry)
                }
              }))
        case .toolOutput(let value):
          try flush()
          result.append(
            .toolResult(
              .init(
                toolCallID: value.id, toolName: value.toolName,
                content: try value.segments.map { segment in
                  switch segment {
                  case .text(let value): return .text(value.content)
                  case .structure(let value): return .text(value.content.jsonString)
                  case .attachment(let value): return .image(try image(value.content))
                  @unknown default: throw unsupported(entry)
                  }
                }, isError: false)))
        @unknown default: throw unsupported(entry)
        }
      }
      try flush()
      return result
    }

    private static func unsupported(_ entry: FoundationModels.Transcript.Entry) -> any Error {
      FoundationModels.LanguageModelError.unsupportedTranscriptContent(
        .init(
          unsupportedContent: [entry],
          debugDescription: "provider cannot represent transcript content"))
    }

    private static func text(_ segments: [FoundationModels.Transcript.Segment]) throws -> String {
      try segments.map { segment in
        switch segment {
        case .text(let value): return value.content
        case .structure(let value): return value.content.jsonString
        default:
          throw AIReasoningCoreError(
            .invalidTranscript, "instructions/reasoning cannot contain attachments")
        }
      }.joined(separator: "\n")
    }

    static func image(_ attachment: FoundationModels.Transcript.Attachment) throws -> ProviderImage
    {
      switch attachment {
      case .image(let value):
        // The native contract is image content, including orientation, rather than an
        // encoded-byte format. Encode upright pixels for the provider DTO boundary.
        let oriented = value.ciImage.oriented(forExifOrientation: Int32(value.orientation.rawValue))
        guard let pixels = CIContext().createCGImage(oriented, from: oriented.extent) else {
          throw AIReasoningCoreError(.invalidTranscript, "image attachment cannot be decoded")
        }
        let data = NSMutableData()
        guard
          let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else {
          throw AIReasoningCoreError(.invalidTranscript, "image attachment cannot be encoded")
        }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination) else {
          throw AIReasoningCoreError(.invalidTranscript, "image attachment cannot be encoded")
        }
        return .data(data as Data, mimeType: "image/png")
      @unknown default:
        throw AIReasoningCoreError(.invalidTranscript, "provider cannot represent attachment type")
      }
    }

    static func options(_ request: FoundationModels.LanguageModelExecutorGenerationRequest) throws
      -> ProviderGenerationOptions
    {
      guard request.generationOptions.samplingMode == nil else {
        throw AIReasoningCoreError(.unsupportedOperation, "provider cannot represent sampling mode")
      }
      let effort: ProviderReasoningEffort?
      switch request.contextOptions.reasoningLevel {
      case nil: effort = nil
      case .light: effort = .low
      case .moderate: effort = .medium
      case .deep: effort = .high
      case .custom(let value):
        guard let parsed = ProviderReasoningEffort(rawValue: value) else {
          throw AIReasoningCoreError(.unsupportedOperation, "unsupported reasoning level")
        }
        effort = parsed
      @unknown default:
        throw AIReasoningCoreError(.unsupportedOperation, "unsupported reasoning level")
      }
      let choice: PiAIProviderRuntime.JSONValue?
      switch request.generationOptions.toolCallingMode?.kind {
      case nil, .allowed: choice = nil
      case .required: choice = .string("required")
      case .disallowed: choice = .string("none")
      @unknown default:
        throw AIReasoningCoreError(.unsupportedOperation, "unsupported tool calling mode")
      }
      return .init(
        maximumOutputTokens: request.generationOptions.maximumResponseTokens,
        temperature: request.generationOptions.temperature, reasoningEffort: effort,
        responseSchema: try request.schema.map {
          try decoded(PiAIProviderRuntime.JSONValue.self, generated($0))
        },
        providerOptions: [:], toolChoice: choice)
    }
  }

  @available(macOS 27, iOS 27, visionOS 27, watchOS 27, *)
  private actor FoundationGenerationEmitter {
    let channel: FoundationModels.LanguageModelExecutorGenerationChannel
    // A logical request ID can span several executor invocations for Tool rounds.
    // Transcript entry IDs must be unique for this invocation, including continuation.
    let roundID = UUID()
    var emitted: [Int: String] = [:]

    init(channel: FoundationModels.LanguageModelExecutorGenerationChannel) {
      self.channel = channel
    }

    func update(_ content: [ProviderAssistantContent]) async {
      for (index, item) in content.enumerated() {
        let id = "\(roundID):\(index)"
        switch item {
        case .text(let text):
          if emitted[index] != text {
            await channel.send(
              .response(
                entryID: id, action: .replaceTextSegment(text, segmentID: id, tokenCount: 0)))
            emitted[index] = text
          }
        case .signedText(let value):
          if emitted[index] != value.text {
            await channel.send(
              .response(
                entryID: id, action: .replaceTextSegment(value.text, segmentID: id, tokenCount: 0)))
            emitted[index] = value.text
          }
        case .reasoning(let value):
          if emitted[index] != value.text, value.isRedacted != true {
            await channel.send(
              .reasoning(
                entryID: id, action: .replaceTextSegment(value.text, segmentID: id, tokenCount: 0)))
            emitted[index] = value.text
          }
        case .toolCall:
          // Tool side effects must wait for the validated terminal snapshot.
          // Later content stays behind this call to preserve assistant ordering.
          return
        }
      }
    }

    func finish(_ round: PiAIProviderRound) async throws {
      let replay = try FoundationProviderMapper.generated(round.snapshot.replayAssistantMessage())
      let input = FoundationModels.LanguageModelExecutorGenerationChannel.Usage.Input(
        totalTokenCount: round.usage.inputTotal, cachedTokenCount: round.usage.cachedInput)
      let output = FoundationModels.LanguageModelExecutorGenerationChannel.Usage.Output(
        totalTokenCount: round.usage.outputTotal, reasoningTokenCount: round.usage.reasoningOutput)
      for (index, item) in round.content.enumerated() {
        let id = "\(roundID):\(index)"
        var metadata: [String: FoundationModels.GeneratedContent] = [:]
        if index == round.content.count - 1 {
          metadata[FoundationProviderMapper.replayKey] = replay
        }
        switch item {
        case .text: break
        case .signedText(let value):
          if emitted[index] != value.text {
            await channel.send(
              .response(
                entryID: id,
                action: .replaceTextSegment(value.text, segmentID: id, tokenCount: 0)))
          }
          metadata["pi-ai-swift.signedText"] = try FoundationProviderMapper.generated(value)
          await channel.send(.response(entryID: id, action: .updateMetadata(metadata)))
          if index == round.content.count - 1 {
            await channel.send(
              .response(entryID: id, action: .updateUsage(input: input, output: output)))
          }
        case .reasoning(let value):
          if emitted[index] != value.text, value.isRedacted != true {
            await channel.send(
              .reasoning(
                entryID: id,
                action: .replaceTextSegment(value.text, segmentID: id, tokenCount: 0)))
          }
          metadata["pi-ai-swift.providerMetadata"] = try FoundationProviderMapper.generated(
            value.providerMetadata)
          if let redacted = value.isRedacted {
            metadata["pi-ai-swift.isRedacted"] = .init(redacted)
            if redacted { metadata["pi-ai-swift.redactedText"] = .init(value.text) }
          }
          await channel.send(.reasoning(entryID: id, action: .updateMetadata(metadata)))
          if let signature = value.signature {
            await channel.send(
              .reasoning(entryID: id, action: .updateSignature(Data(signature.utf8), tokenCount: 0))
            )
          }
          if index == round.content.count - 1 {
            await channel.send(
              .reasoning(entryID: id, action: .updateUsage(input: input, output: output)))
          }
        case .toolCall(let call):
          metadata[FoundationProviderMapper.callKey] = try FoundationProviderMapper.generated(call)
          await channel.send(
            .toolCalls(
              entryID: id,
              action: .toolCall(
                id: call.id, name: call.name,
                action: .updateMetadata(metadata))))
          if index == round.content.count - 1 {
            await channel.send(
              .toolCalls(entryID: id, action: .updateUsage(input: input, output: output)))
          }
          // Apple requires per-call metadata before the first argument event.
          let json = String(decoding: try JSONEncoder().encode(call.arguments), as: UTF8.self)
          await channel.send(
            .toolCalls(
              entryID: id,
              action: .toolCall(
                id: call.id,
                name: call.name, action: .appendArguments(json, tokenCount: 0))))
        }
      }
    }
  }
#endif
