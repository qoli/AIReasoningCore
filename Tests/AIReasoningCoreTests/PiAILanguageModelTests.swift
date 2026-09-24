import AnyLanguageModel
import Foundation
import PiAIProviderRuntime
import XCTest

@testable import AIReasoningCore

final class PiAILanguageModelTests: XCTestCase {
  func testTextResponseUsesProviderRuntime() async throws {
    let runtime = FakeRuntime { request in
      responseEvents(for: request, text: "Hello from pi")
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    let response = try await session.respond(to: "Hello")

    XCTAssertEqual(response.content, "Hello from pi")
    XCTAssertEqual(session.transcript.count, 2)
  }

  func testStreamingProducesCumulativeSnapshots() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .textDelta("Hel"),
        .textDelta("lo"),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.text("Hello")], finishReason: .stop)),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )
    var values: [String] = []

    for try await snapshot in session.streamResponse(to: "Hello") {
      values.append(snapshot.content)
    }

    XCTAssertEqual(values, ["Hel", "Hello"])
  }

  func testDisplayReasoningYieldsIndependentlyAndSurvivesBothResponseModes() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .reasoningDelta("plan "), .reasoningDelta("step"),
        .reasoningSignatureDelta("opaque-secret"),
        .textDelta("answer"),
        .responseSnapshot(
          responseSnapshot(
            for: request,
            content: [
              .reasoning(
                .init(text: "plan step", signature: "opaque-secret", providerMetadata: [:])),
              .text("answer"),
            ], finishReason: .stop)),
        .completed(.stop),
      ]
    }
    let model = PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    let session = LanguageModelSession(model: model)
    var snapshots: [LanguageModelSession.ResponseStream<String>.Snapshot] = []
    for try await snapshot in session.streamResponse(to: "Hello") { snapshots.append(snapshot) }
    XCTAssertEqual(snapshots.map(\.content), ["", "", "answer", "answer"])
    XCTAssertEqual(
      snapshots.map { visibleReasoning($0.transcriptEntries) },
      ["plan ", "plan step", "plan step", "plan step"])
    XCTAssertEqual(
      Set(snapshots.compactMap { reasoningEntries($0.transcriptEntries).first?.id }).count, 1)
    XCTAssertEqual(
      reasoningEntries(snapshots.last!.transcriptEntries).first?.signature,
      Data("opaque-secret".utf8))
    for streaming in [false, true] {
      let fresh = LanguageModelSession(model: model)
      let response =
        try await streaming
        ? fresh.streamResponse(to: "Hello").collect() : fresh.respond(to: "Hello")
      XCTAssertEqual(response.content, "answer")
      XCTAssertEqual(visibleReasoning(response.transcriptEntries), "plan step")
      let transcript = String(decoding: try JSONEncoder().encode(fresh.transcript), as: UTF8.self)
      XCTAssertTrue(transcript.contains("plan step"))
      let entries = reasoningEntries(fresh.transcript)
      XCTAssertEqual(entries.count, 1)
      XCTAssertEqual(entries.first?.signature, Data("opaque-secret".utf8))
      let restored = try JSONDecoder().decode(Transcript.self, from: Data(transcript.utf8))
      XCTAssertEqual(reasoningEntries(restored), entries)
    }
  }

  func testReasoningAcrossToolRoundsPreservesReplayAndExecutesOnce() async throws {
    let call = ProviderToolCall(
      id: "call", name: "echo", arguments: .object(["value": .string("weather")]))
    let reasoning = ProviderReasoningContent(
      text: "first ", signature: "opaque-signature", providerMetadata: ["opaque": .string("state")])
    for streaming in [false, true] {
      let executions = ExecutionCounter()
      let runtime = FakeRuntime { request in
        if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
          guard
            let assistant = request.messages.compactMap({ message -> ProviderAssistantMessage? in
              if case .assistantMessage(let value) = message { return value }
              return nil
            }).last
          else { throw TestFailure.missingReplayAssistantMessage }
          XCTAssertEqual(assistant.content, [.reasoning(reasoning), .toolCall(call)])
          return [
            .responseStarted(metadata(for: request)), .reasoningDelta("second"),
            .textDelta("answer"),
            .responseSnapshot(
              responseSnapshot(
                for: request,
                content: [
                  .reasoning(.init(text: "second", signature: nil, providerMetadata: [:])),
                  .text("answer"),
                ], finishReason: .stop)),
            .completed(.stop),
          ]
        }
        return [
          .responseStarted(metadata(for: request)), .reasoningDelta("first "),
          .reasoningSignatureDelta("opaque-signature"),
          .toolCallStarted(id: call.id, name: call.name), .toolCallCompleted(call),
          .responseSnapshot(
            responseSnapshot(
              for: request, content: [.reasoning(reasoning), .toolCall(call)],
              finishReason: .toolCalls)),
          .completed(.toolCalls),
        ]
      }
      let session = LanguageModelSession(
        model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
        tools: [CountingEchoTool(counter: executions)])
      if streaming {
        var snapshots: [LanguageModelSession.ResponseStream<String>.Snapshot] = []
        for try await snapshot in session.streamResponse(to: "Use tool") {
          snapshots.append(snapshot)
        }
        XCTAssertEqual(
          snapshots.map { visibleReasoning($0.transcriptEntries) },
          ["first ", "first ", "first ", "first second", "first second"])
        XCTAssertEqual(snapshots.map(\.content), ["", "", "", "", "answer"])
        XCTAssertEqual(snapshots.last?.transcriptEntries.count, 4)
      } else {
        let response = try await session.respond(to: "Use tool")
        XCTAssertEqual(visibleReasoning(response.transcriptEntries), "first second")
        XCTAssertEqual(response.content, "answer")
      }
      let count = await executions.count
      XCTAssertEqual(count, 1)
      XCTAssertEqual(session.transcript.count, 6)
      let blocks = reasoningEntries(session.transcript)
      XCTAssertEqual(blocks.count, 2)
      XCTAssertNotEqual(blocks[0].id, blocks[1].id)
      XCTAssertEqual(blocks[0].signature, Data("opaque-signature".utf8))
      XCTAssertEqual(
        blocks[0].metadata["pi-ai-swift.providerMetadata"]?.jsonString, #"{"opaque":"state"}"#)
    }
  }

  func testStructuredReasoningDoesNotEnterJSONParser() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)), .reasoningDelta("not JSON { reasoning"),
        .textDelta(#"{"answer":"yes"}"#), .reasoningDelta(" after answer"),
        .responseSnapshot(
          responseSnapshot(
            for: request,
            content: [
              .reasoning(
                .init(text: "not JSON { reasoning", signature: nil, providerMetadata: [:])),
              .text(#"{"answer":"yes"}"#),
              .reasoning(.init(text: " after answer", signature: nil, providerMetadata: [:])),
            ], finishReason: .stop)),
        .completed(.stop),
      ]
    }
    let model = PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    var snapshots: [LanguageModelSession.ResponseStream<StructuredAnswer>.Snapshot] = []
    for try await snapshot in LanguageModelSession(model: model).streamResponse(
      to: "Answer", generating: StructuredAnswer.self)
    {
      snapshots.append(snapshot)
    }
    XCTAssertEqual(snapshots.count, 3)
    XCTAssertNil(snapshots.first?.content.answer)
    XCTAssertEqual(snapshots.last?.content.answer, "yes")
    XCTAssertEqual(
      snapshots.last.map { visibleReasoning($0.transcriptEntries) } ?? nil,
      "not JSON { reasoning after answer")
    for streaming in [false, true] {
      let session = LanguageModelSession(model: model)
      let response =
        try await streaming
        ? session.streamResponse(to: "Answer", generating: StructuredAnswer.self).collect()
        : session.respond(to: "Answer", generating: StructuredAnswer.self)
      XCTAssertEqual(response.content.answer, "yes")
      XCTAssertEqual(
        visibleReasoning(response.transcriptEntries), "not JSON { reasoning after answer")
    }
  }

  func testUsageAndOpaqueReasoningDoNotInventDisplayText() async throws {
    let runtime = FakeRuntime { request in
      var terminal = responseEvents(for: request, text: "answer")
      terminal.insert(
        contentsOf: [
          .reasoningSignatureDelta("opaque"),
          .usage(
            .init(
              inputTokens: 1, outputTokens: 4, reasoningTokens: 3, cachedInputTokens: 0,
              totalTokens: 5, providerMetadata: [:])),
        ], at: 1)
      return terminal
    }
    let model = PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    let response = try await LanguageModelSession(model: model).streamResponse(to: "Answer")
      .collect()
    XCTAssertNil(visibleReasoning(response.transcriptEntries))
    XCTAssertEqual(response.content, "answer")
  }

  func testReasoningDoesNotBypassTerminalValidation() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)), .reasoningDelta("plan"), .textDelta("answer"),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.text("contradiction")], finishReason: .stop)),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"))
    do {
      _ = try await session.streamResponse(to: "Answer").collect()
      XCTFail("expected terminal mismatch")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidProviderResponse)
    }
    XCTAssertEqual(session.transcript.count, 1)
  }

  func testScalarStructuredReasoningWaitsForRepresentableAnswer() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)), .reasoningDelta("counting"), .textDelta("42"),
        .responseSnapshot(
          responseSnapshot(
            for: request,
            content: [
              .reasoning(.init(text: "counting", signature: nil, providerMetadata: [:])),
              .text("42"),
            ], finishReason: .stop)),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"))
    var snapshots: [LanguageModelSession.ResponseStream<Int>.Snapshot] = []
    for try await snapshot in session.streamResponse(to: "Count", generating: Int.self) {
      snapshots.append(snapshot)
    }
    // Int cannot represent an absent value; never invent a zero to deliver reasoning.
    XCTAssertEqual(snapshots.map(\.content), [42])
    XCTAssertEqual(snapshots.map { visibleReasoning($0.transcriptEntries) }, ["counting"])
  }

  func testStoppedToolRetainsReasoningWithoutExecuting() async throws {
    let call = ProviderToolCall(
      id: "call", name: "echo", arguments: .object(["value": .string("ignored")]))
    for streaming in [false, true] {
      let counter = ExecutionCounter()
      let runtime = FakeRuntime { request in
        [
          .responseStarted(metadata(for: request)), .reasoningDelta("plan"),
          .toolCallStarted(id: call.id, name: call.name), .toolCallCompleted(call),
          .responseSnapshot(
            responseSnapshot(
              for: request,
              content: [
                .reasoning(.init(text: "plan", signature: nil, providerMetadata: [:])),
                .toolCall(call),
              ], finishReason: .toolCalls)),
          .completed(.toolCalls),
        ]
      }
      let session = LanguageModelSession(
        model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
        tools: [CountingEchoTool(counter: counter)])
      session.toolExecutionDelegate = StopTools()
      let response =
        try await streaming
        ? session.streamResponse(to: "Stop").collect() : session.respond(to: "Stop")
      XCTAssertEqual(visibleReasoning(response.transcriptEntries), "plan")
      XCTAssertEqual(response.content, "")
      let count = await counter.count
      XCTAssertEqual(count, 0)
    }
  }

  func testCancellationAfterReasoningDoesNotCommitResponse() async throws {
    let received = expectation(description: "reasoning snapshot")
    let stopped = expectation(description: "provider cancelled")
    let session = LanguageModelSession(
      model: PiAILanguageModel(
        runtime: HangingRuntime(providerStopped: stopped, reasoningOnly: true), providerID: "test",
        modelID: "model"))
    let consumer = Task {
      for try await snapshot in session.streamResponse(to: "Wait") {
        XCTAssertEqual(snapshot.content, "")
        XCTAssertEqual(visibleReasoning(snapshot.transcriptEntries), "planning")
        received.fulfill()
      }
    }
    await fulfillment(of: [received], timeout: 2)
    consumer.cancel()
    await fulfillment(of: [stopped], timeout: 2)
    _ = await consumer.result
    await session.waitForResponseCompletion()
    XCTAssertFalse(session.isResponding)
    XCTAssertEqual(session.transcript.count, 1)
  }

  func testRedactedReasoningHasNoVisibleSegmentsAndReplaysAfterCodableRoundTrip() async throws {
    let hidden = ProviderReasoningContent(
      text: "opaque-redacted-payload", signature: "signed-redacted", isRedacted: true,
      providerMetadata: ["nested": .object(["number": .integer(7)])])
    for streaming in [false, true] {
      let runtime = FakeRuntime { request in
        if request.messages.contains(where: { message in
          if case .assistant(let content) = message {
            return content.contains(.reasoning(hidden))
          }
          return false
        }) {
          return responseEvents(for: request, text: "replayed")
        }
        return [
          .responseStarted(metadata(for: request)), .reasoningSignatureDelta("signed-redacted"),
          .textDelta("answer"),
          .responseSnapshot(
            responseSnapshot(
              for: request, content: [.reasoning(hidden), .text("answer")], finishReason: .stop)),
          .completed(.stop),
        ]
      }
      let model = PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
      let session = LanguageModelSession(model: model)
      let response =
        try await streaming
        ? session.streamResponse(to: "Answer").collect() : session.respond(to: "Answer")
      XCTAssertEqual(response.content, "answer")
      XCTAssertNil(visibleReasoning(response.transcriptEntries))
      let block = try XCTUnwrap(reasoningEntries(session.transcript).first)
      XCTAssertTrue(block.segments.isEmpty)
      XCTAssertEqual(block.signature, Data("signed-redacted".utf8))
      let restored = try JSONDecoder().decode(
        Transcript.self, from: JSONEncoder().encode(session.transcript))
      XCTAssertEqual(reasoningEntries(restored), [block])
      let replay = LanguageModelSession(model: model, transcript: restored)
      let next = try await replay.respond(to: "Continue")
      XCTAssertEqual(next.content, "replayed")
    }
  }

  func testCancellationPreservesToolCheckpointAndPartialReasoningWithoutAnswer() async throws {
    let received = expectation(description: "second round reasoning received")
    let stopped = expectation(description: "second round provider cancelled")
    let executions = ExecutionCounter()
    let session = LanguageModelSession(
      model: PiAILanguageModel(
        runtime: ToolCheckpointRuntime(providerStopped: stopped), providerID: "test",
        modelID: "model"),
      tools: [CountingEchoTool(counter: executions)])
    session.transcriptErrorHandlingPolicy = .preserveTranscript
    let consumer = Task {
      for try await snapshot in session.streamResponse(to: "Use tool") {
        if visibleReasoning(snapshot.transcriptEntries) == "completed planpartial next plan" {
          received.fulfill()
        }
      }
    }
    await fulfillment(of: [received], timeout: 2)
    consumer.cancel()
    _ = await consumer.result
    await fulfillment(of: [stopped], timeout: 2)
    await session.waitForResponseCompletion()
    XCTAssertFalse(session.isResponding)
    XCTAssertEqual(visibleReasoning(session.transcript), "completed planpartial next plan")
    XCTAssertEqual(session.transcript.count, 5)
    guard session.transcript.count == 5,
      case .reasoning = session.transcript[1],
      case .toolCalls = session.transcript[2], case .toolOutput = session.transcript[3],
      case .reasoning = session.transcript[4]
    else { return XCTFail("expected committed reasoning and executed tool checkpoint") }
    let count = await executions.count
    XCTAssertEqual(count, 1)
  }

  func testReasoningSelectionPreservesDefaultOffAndTypedEffortInBothModes() async throws {
    for effort: ProviderReasoningEffort? in [nil, .off, .high, .max] {
      let runtime = FakeRuntime { request in
        XCTAssertEqual(request.options.reasoningEffort, effort)
        return responseEvents(for: request, text: "configured")
      }
      let session = LanguageModelSession(
        model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"))
      var options = GenerationOptions()
      options[custom: PiAILanguageModel.self] = .init(reasoningEffort: effort)
      _ = try await session.respond(to: "Hello", options: options)
      _ = try await session.streamResponse(to: "Hello", options: options).collect()
    }
  }

  func testStructuredOutputUsesGenerationSchema() async throws {
    let runtime = FakeRuntime { request in
      XCTAssertNotNil(request.options.responseSchema)
      return responseEvents(for: request, text: #"{"answer":"yes"}"#)
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    let response = try await session.respond(to: "Answer", generating: StructuredAnswer.self)

    XCTAssertEqual(response.content.answer, "yes")
  }

  func testStructuredStreamingProducesRequestedType() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .textDelta(#"{"answer":"ye"#),
        .textDelta(#"s"}"#),
        .responseSnapshot(
          responseSnapshot(
            for: request,
            content: [.text(#"{"answer":"yes"}"#)],
            finishReason: .stop
          )),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    var partialAnswers: [String?] = []
    for try await snapshot in session.streamResponse(
      to: "Answer", generating: StructuredAnswer.self)
    {
      partialAnswers.append(snapshot.content.answer)
    }

    XCTAssertEqual(partialAnswers.last!, "yes")
  }

  func testToolSchemaMaterializesRootAndPreservesNestedDefinitions() async throws {
    let schema = try JSONDecoder().decode(
      GenerationSchema.self,
      from: Data(
        ##"{"$ref":"#/$defs/Arguments","$defs":{"Arguments":{"type":"object","properties":{"location":{"$ref":"#/$defs/Location"}},"required":["location"]},"Location":{"type":"object","properties":{"latitude":{"type":"number"}},"required":["latitude"]}}}"##
          .utf8))
    let runtime = FakeRuntime { request in
      guard case .object(let root) = request.tools.first?.inputSchema,
        case .object(let properties) = root["properties"],
        case .object(let definitions) = root["$defs"]
      else { throw TestFailure.missingToolResults }
      XCTAssertNil(root["$ref"])
      XCTAssertEqual(root["type"], .string("object"))
      XCTAssertEqual(root["required"], .array([.string("location")]))
      XCTAssertEqual(properties["location"], .object(["$ref": .string("#/$defs/Location")]))
      XCTAssertNotNil(definitions["Location"])
      return responseEvents(for: request, text: "ready")
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [SchemaTool(parameters: schema)])
    _ = try await session.respond(to: "Check tools")
    _ = try await session.streamResponse(to: "Check tools").collect()
  }

  func testUnsupportedToolSchemaRootsFailBeforeProviderRequest() async throws {
    let schemas = [
      ##"{"$ref":"#/$defs/Missing"}"##,
      ##"{"$ref":"#/$defs/Loop","$defs":{"Loop":{"$ref":"#/$defs/Loop"}}}"##,
      ##"{"type":"string"}"##,
    ]
    for json in schemas {
      let schema = try JSONDecoder().decode(GenerationSchema.self, from: Data(json.utf8))
      let runtime = FakeRuntime { request in
        XCTFail("Invalid tool schema must fail before calling the provider")
        return responseEvents(for: request, text: "unexpected")
      }
      let session = LanguageModelSession(
        model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
        tools: [SchemaTool(parameters: schema)])
      do {
        _ = try await session.respond(to: "Check tools")
        XCTFail("Expected unsupported tool schema")
      } catch let error as AIReasoningCoreError {
        XCTAssertEqual(error.code, .unsupportedOperation)
      }
    }
  }

  func testToolCallExecutesAndContinuesProviderConversation() async throws {
    let call = ProviderToolCall(
      id: "call-1",
      name: "echo",
      arguments: .object(["value": .string("ping")])
    )
    let runtime = FakeRuntime { request in
      if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
        return responseEvents(for: request, text: "tool complete")
      }
      return [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "echo"),
        .toolCallCompleted(call),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.toolCall(call)], finishReason: .toolCalls)),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )

    let response = try await session.respond(to: "Use echo")

    XCTAssertEqual(response.content, "tool complete")
    XCTAssertEqual(session.transcript.count, 4)
    guard case .toolCalls(let calls) = session.transcript[1] else {
      return XCTFail("expected tool calls")
    }
    XCTAssertEqual(calls.first?.toolName, "echo")
    guard case .toolOutput(let output) = session.transcript[2] else {
      return XCTFail("expected tool output")
    }
    XCTAssertEqual(output.toolName, "echo")
  }

  func testMixedAssistantTurnPreservesOrderThroughContinuationAndPersistedReplay() async throws {
    let firstCall = ProviderToolCall(
      id: "call-1",
      name: "echo",
      arguments: .object(["value": .string("first")]),
      thoughtSignature: "thought-1",
      namespace: "functions"
    )
    let secondCall = ProviderToolCall(
      id: "call-2",
      name: "echo",
      arguments: .object(["value": .string("second")]),
      thoughtSignature: "thought-2",
      namespace: "functions"
    )
    let expected: [ProviderAssistantContent] = [
      .reasoning(
        ProviderReasoningContent(
          text: "plan",
          signature: "reasoning-signature",
          providerMetadata: [:]
        )),
      .signedText(
        ProviderTextContent(text: "Checking now.", signature: "text-signature-1")),
      .toolCall(firstCall),
      .signedText(
        ProviderTextContent(text: "Also checking.", signature: "text-signature-2")),
      .toolCall(secondCall),
      .signedText(ProviderTextContent(text: "Waiting.", signature: "text-signature-3")),
    ]
    let runtime = FakeRuntime { request in
      if let resultIndex = request.messages.firstIndex(where: {
        if case .toolResult = $0 { true } else { false }
      }) {
        let isImmediateContinuation =
          request.messages.last.map {
            if case .toolResult = $0 { return true }
            return false
          } ?? false
        if isImmediateContinuation {
          guard case .assistantMessage(let message) = request.messages[resultIndex - 1] else {
            throw TestFailure.missingReplayAssistantMessage
          }
          XCTAssertEqual(
            message,
            try responseSnapshot(
              for: request,
              content: expected,
              finishReason: .toolCalls
            ).replayAssistantMessage()
          )
        } else {
          guard case .assistant(let content) = request.messages[resultIndex - 1] else {
            throw TestFailure.missingPersistedAssistantMessage
          }
          XCTAssertEqual(
            content,
            [
              expected[0],
              .text("Checking now."),
              .toolCall(
                ProviderToolCall(
                  id: firstCall.id,
                  name: firstCall.name,
                  arguments: firstCall.arguments
                )),
              .text("Also checking."),
              .toolCall(
                ProviderToolCall(
                  id: secondCall.id,
                  name: secondCall.name,
                  arguments: secondCall.arguments
                )),
              .text("Waiting."),
            ]
          )
        }
        XCTAssertEqual(
          request.messages.filter {
            if case .assistantMessage(let message) = $0 {
              return message.content.contains { if case .toolCall = $0 { true } else { false } }
            }
            if case .assistant(let content) = $0 {
              return content.contains { if case .toolCall = $0 { true } else { false } }
            }
            return false
          }.count, 1)
        guard case .toolResult(let first) = request.messages[resultIndex],
          case .toolResult(let second) = request.messages[resultIndex + 1]
        else { throw TestFailure.missingToolResults }
        XCTAssertEqual(first.toolCallID, "call-1")
        XCTAssertEqual(second.toolCallID, "call-2")
        return responseEvents(for: request, text: "done")
      }
      return [
        .responseStarted(metadata(for: request)),
        .reasoningDelta("plan"),
        .reasoningSignatureDelta("reasoning-signature"),
        .textDelta("Checking "), .textDelta("now."),
        .toolCallStarted(id: firstCall.id, name: firstCall.name),
        .textDelta("Also checking."),
        .toolCallStarted(id: secondCall.id, name: secondCall.name),
        .toolCallCompleted(secondCall), .toolCallCompleted(firstCall),
        .textDelta("Waiting."),
        .responseSnapshot(
          responseSnapshot(for: request, content: expected, finishReason: .toolCalls)),
        .completed(.toolCalls),
      ]
    }
    let model = PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    let session = LanguageModelSession(model: model, tools: [EchoTool()])
    let response = try await session.respond(to: "Check both")
    XCTAssertEqual(response.content, "done")
    XCTAssertEqual(session.transcript.count, 10)
    guard case .reasoning = session.transcript[1],
      case .response(let preamble) = session.transcript[2],
      case .text(let text) = preamble.segments.first
    else { return XCTFail("expected persisted preamble") }
    XCTAssertEqual(text.content, "Checking now.")

    let restored = try JSONDecoder().decode(
      Transcript.self, from: JSONEncoder().encode(session.transcript))
    let replay = LanguageModelSession(model: model, tools: [EchoTool()], transcript: restored)
    _ = try await replay.respond(to: "Follow up")
  }

  func testMalformedFinalStructuredOutputFailsInBothModesForStopAndLength() async throws {
    for reason: ProviderFinishReason in [.stop, .length] {
      for json in [#"{"answer":"yes""#, #"{"answer":"yes"} trailing"#] {
        for streaming in [false, true] {
          let runtime = FakeRuntime { request in
            [
              .responseStarted(metadata(for: request)),
              .textDelta(json),
              .responseSnapshot(
                responseSnapshot(for: request, content: [.text(json)], finishReason: reason)),
              .completed(reason),
            ]
          }
          let session = LanguageModelSession(
            model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"))
          do {
            if streaming {
              _ = try await session.streamResponse(
                to: "Answer", generating: StructuredAnswer.self
              ).collect()
            } else {
              _ = try await session.respond(to: "Answer", generating: StructuredAnswer.self)
            }
            XCTFail("expected malformed final JSON rejection")
          } catch let error as AIReasoningCoreError {
            XCTAssertEqual(error.code, .invalidStructuredOutput)
          }
          XCTAssertFalse(
            session.transcript.contains {
              if case .response = $0 { true } else { false }
            })
        }
      }
    }
  }

  private enum TestFailure: Error {
    case missingToolResults
    case missingReplayAssistantMessage
    case missingPersistedAssistantMessage
  }

  func testOneToolIterationAllowsFollowingFinalResponse() async throws {
    let call = ProviderToolCall(
      id: "call-1",
      name: "echo",
      arguments: .object(["value": .string("ping")])
    )
    let runtime = FakeRuntime { request in
      if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
        return responseEvents(for: request, text: "done")
      }
      return [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "echo"),
        .toolCallCompleted(call),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.toolCall(call)], finishReason: .toolCalls)),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )
    var options = GenerationOptions()
    options[custom: PiAILanguageModel.self] = .init(maximumToolIterations: 1)

    let response = try await session.respond(to: "Use echo", options: options)

    XCTAssertEqual(response.content, "done")
  }

  func testCustomGenerationOptionsMapToProviderRequest() async throws {
    let recorder = RequestRecorder()
    let runtime = FakeRuntime { request in
      Task { await recorder.record(request) }
      return responseEvents(for: request, text: "configured")
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )
    var options = GenerationOptions()
    options.maximumResponseTokens = 321
    options.temperature = 0.25
    options[custom: PiAILanguageModel.self] = .init(
      reasoningEffort: .high,
      providerOptions: ["debug": .bool(true)],
      outputModality: .image,
      sessionID: "session-1",
      cacheRetention: .long,
      serviceTier: "priority",
      toolChoice: .object([
        "type": .string("function"),
        "name": .string("echo"),
      ])
    )

    _ = try await session.respond(to: "Configure", options: options)
    let requests = await recorder.requests
    let request = try XCTUnwrap(requests.first)

    XCTAssertEqual(request.options.maximumOutputTokens, 321)
    XCTAssertEqual(request.options.temperature, 0.25)
    XCTAssertEqual(request.options.reasoningEffort, .high)
    XCTAssertEqual(request.options.providerOptions["debug"], .bool(true))
    XCTAssertEqual(request.options.outputModality, .image)
    XCTAssertEqual(request.options.sessionID, "session-1")
    XCTAssertEqual(request.options.cacheRetention, .long)
    XCTAssertEqual(request.options.serviceTier, "priority")
    XCTAssertEqual(
      request.options.toolChoice,
      .object(["type": .string("function"), "name": .string("echo")])
    )
  }

  func testReasoningSignatureDeltaIsAcceptedAsOpaqueMetadata() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .reasoningSignatureDelta("opaque-signature"),
        .textDelta("answer"),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.text("answer")], finishReason: .stop)),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    let response = try await session.respond(to: "Reason")

    XCTAssertEqual(response.content, "answer")
  }

  func testImageTranscriptMapsToProviderImage() async throws {
    let recorder = RequestRecorder()
    let runtime = FakeRuntime { request in
      Task { await recorder.record(request) }
      return responseEvents(for: request, text: "seen")
    }
    let image = Transcript.ImageSegment(data: Data([1, 2, 3]), mimeType: "image/png")
    let transcript = Transcript(entries: [
      .prompt(
        Transcript.Prompt(
          segments: [.text(.init(content: "describe")), .image(image)]
        )
      )
    ])
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      transcript: transcript
    )

    _ = try await session.respond(to: "")
    let requests = await recorder.requests

    XCTAssertTrue(
      requests.flatMap(\.messages).contains { message in
        guard case .user(let content) = message else { return false }
        return content.contains { item in
          guard case .image(.data(let data, mimeType: let mimeType)) = item else { return false }
          return data == Data([1, 2, 3]) && mimeType == "image/png"
        }
      })
  }

  func testStreamingToolCallsContinueTwiceAndPersistBeforeCompletion() async throws {
    let first = ProviderToolCall(
      id: "call-1", name: "echo", arguments: .object(["value": .string("one")]))
    let second = ProviderToolCall(
      id: "call-2", name: "echo", arguments: .object(["value": .string("two")]))
    let runtime = FakeRuntime { request in
      let outputCount = request.messages.filter {
        if case .toolResult = $0 { return true }
        return false
      }.count
      if outputCount == 2 { return responseEvents(for: request, text: "done") }
      let call = outputCount == 0 ? first : second
      return [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: call.id, name: call.name),
        .toolCallCompleted(call),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.toolCall(call)], finishReason: .toolCalls)),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )

    var snapshots: [LanguageModelSession.ResponseStream<String>.Snapshot] = []
    for try await snapshot in session.streamResponse(to: "Use echo") {
      snapshots.append(snapshot)
    }
    XCTAssertEqual(snapshots.last?.content, "done")
    XCTAssertEqual(snapshots.last?.transcriptEntries.count, 4)
    XCTAssertEqual(session.transcript.count, 6)
    guard case .toolCalls(let firstCalls) = session.transcript[1],
      case .toolOutput(let firstOutput) = session.transcript[2],
      case .toolCalls(let secondCalls) = session.transcript[3],
      case .toolOutput(let secondOutput) = session.transcript[4]
    else { return XCTFail("expected ordered tool calls and results") }
    XCTAssertEqual(firstCalls.first?.id, "call-1")
    XCTAssertEqual(firstOutput.id, "call-1")
    XCTAssertEqual(secondCalls.first?.id, "call-2")
    XCTAssertEqual(secondOutput.id, "call-2")
    let restored = try JSONDecoder().decode(
      Transcript.self, from: JSONEncoder().encode(session.transcript))
    XCTAssertEqual(restored.count, session.transcript.count)
    let replay = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()], transcript: restored)
    let followUp = try await replay.respond(to: "Follow up")
    XCTAssertEqual(followUp.content, "done")
  }

  func testStreamingMixedToolTurnKeepsTextInTranscriptOrder() async throws {
    let call = ProviderToolCall(
      id: "call-1", name: "echo", arguments: .object(["value": .string("ping")]))
    let runtime = FakeRuntime { request in
      if request.messages.contains(where: {
        if case .toolResult = $0 { return true }
        return false
      }) {
        return responseEvents(for: request, text: "done")
      }
      return [
        .responseStarted(metadata(for: request)),
        .textDelta("checking"),
        .toolCallStarted(id: call.id, name: call.name),
        .toolCallCompleted(call),
        .responseSnapshot(
          responseSnapshot(
            for: request, content: [.text("checking"), .toolCall(call)], finishReason: .toolCalls)),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()])
    var snapshots: [LanguageModelSession.ResponseStream<String>.Snapshot] = []
    for try await snapshot in session.streamResponse(to: "Use echo") { snapshots.append(snapshot) }

    XCTAssertEqual(snapshots.map(\.content), ["checking", "", "", "done"])
    XCTAssertEqual(snapshots.last?.transcriptEntries.count, 3)
    XCTAssertEqual(session.transcript.count, 5)
    guard case .response(let preamble) = session.transcript[1],
      case .text(let text) = preamble.segments.first,
      case .toolCalls = session.transcript[2],
      case .toolOutput = session.transcript[3],
      case .response(let answer) = session.transcript[4],
      case .text(let answerText) = answer.segments.first
    else { return XCTFail("expected ordered assistant text, tool exchange, and answer") }
    XCTAssertEqual(text.content, "checking")
    XCTAssertEqual(answerText.content, "done")
  }

  func testSessionStreamCancellationReachesProviderStream() async throws {
    let firstSnapshot = expectation(description: "session delivered first snapshot")
    let providerStopped = expectation(description: "provider stream terminated")
    let runtime = HangingRuntime(providerStopped: providerStopped)
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"))
    let consumer = Task {
      for try await _ in session.streamResponse(to: "Wait") {
        firstSnapshot.fulfill()
      }
    }
    await fulfillment(of: [firstSnapshot], timeout: 2)
    consumer.cancel()
    await fulfillment(of: [providerStopped], timeout: 2)
    _ = await consumer.result
    await session.waitForResponseCompletion()
    XCTAssertFalse(session.isResponding)
  }

  func testUnknownToolFailsExplicitly() async throws {
    let call = ProviderToolCall(id: "call-1", name: "missing", arguments: .object([:]))
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .toolCallStarted(id: "call-1", name: "missing"),
        .toolCallCompleted(call),
        .responseSnapshot(
          responseSnapshot(for: request, content: [.toolCall(call)], finishReason: .toolCalls)),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    do {
      _ = try await session.respond(to: "Use missing tool")
      XCTFail("expected unknown tool failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .unknownTool)
    }
  }

  func testProviderAssetRequiresAssetStore() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .asset(
          ProviderAsset(
            id: "asset-1",
            kind: .image,
            mimeType: "image/png",
            data: Data([1]),
            providerMetadata: [:]
          )
        ),
        .textDelta("image"),
        .completed(.stop),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    do {
      _ = try await session.respond(to: "Generate")
      XCTFail("expected missing asset store failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .missingAssetStore)
    }
  }

  func testProviderMustStartStreamBeforeContent() async throws {
    let runtime = FakeRuntime { _ in [.textDelta("invalid"), .completed(.stop)] }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )

    do {
      _ = try await session.respond(to: "Hello")
      XCTFail("expected event ordering failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidProviderResponse)
    }
  }

  func testMissingAndMismatchedTerminalSnapshotsFailInBothModes() async throws {
    for includesMismatchedSnapshot in [false, true] {
      for streaming in [false, true] {
        let runtime = FakeRuntime { request in
          var events: [ProviderEvent] = [
            .responseStarted(metadata(for: request)),
            .textDelta("answer"),
          ]
          if includesMismatchedSnapshot {
            events.append(
              .responseSnapshot(
                responseSnapshot(
                  for: request,
                  content: [.text("different")],
                  finishReason: .stop
                )))
          }
          events.append(.completed(.stop))
          return events
        }
        let session = LanguageModelSession(
          model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
        )

        do {
          if streaming {
            _ = try await session.streamResponse(to: "Hello").collect()
          } else {
            _ = try await session.respond(to: "Hello")
          }
          XCTFail("expected terminal response snapshot validation failure")
        } catch let error as AIReasoningCoreError {
          XCTAssertEqual(error.code, .invalidProviderResponse)
        }
      }
    }
  }

  func testToolCompletionWithoutStartFailsBeforeExecution() async throws {
    let runtime = FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)),
        .toolCallCompleted(
          ProviderToolCall(
            id: "call-1",
            name: "echo",
            arguments: .object(["value": .string("ping")])
          )
        ),
        .completed(.toolCalls),
      ]
    }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool()]
    )

    do {
      _ = try await session.respond(to: "Use echo")
      XCTFail("expected invalid tool lifecycle failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidProviderResponse)
    }
  }

  func testDuplicateToolNamesFailExplicitly() async throws {
    let runtime = FakeRuntime { request in responseEvents(for: request, text: "unused") }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model"),
      tools: [EchoTool(), EchoTool()]
    )

    do {
      _ = try await session.respond(to: "Hello")
      XCTFail("expected duplicate tool failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .invalidTranscript)
    }
  }

  func testUnsupportedSamplingFailsInsteadOfBeingIgnored() async throws {
    let runtime = FakeRuntime { request in responseEvents(for: request, text: "unused") }
    let session = LanguageModelSession(
      model: PiAILanguageModel(runtime: runtime, providerID: "test", modelID: "model")
    )
    let options = GenerationOptions(sampling: .greedy)

    do {
      _ = try await session.respond(to: "Hello", options: options)
      XCTFail("expected unsupported sampling failure")
    } catch let error as AIReasoningCoreError {
      XCTAssertEqual(error.code, .unsupportedOperation)
    }
  }
}

@Generable
private struct StructuredAnswer: Equatable {
  let answer: String
}

private struct EchoTool: Tool {
  @Generable
  struct Arguments {
    let value: String
  }

  let name = "echo"
  let description = "Echo a value"

  func call(arguments: Arguments) async throws -> String {
    arguments.value
  }
}

private struct SchemaTool: Tool {
  let name = "schema_tool"
  let description = "Exercise dynamically supplied tool schemas"
  let parameters: GenerationSchema

  func call(arguments: GeneratedContent) async throws -> String { "unused" }
}

private struct FakeRuntime: ProviderRuntime {
  let handler: @Sendable (ProviderRequest) throws -> [ProviderEvent]

  init(handler: @escaping @Sendable (ProviderRequest) throws -> [ProviderEvent]) {
    self.handler = handler
  }

  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "test", providers: [])
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    switch operation {
    case .login(let providerID, _), .logout(let providerID):
      return .disconnected(providerID: providerID)
    }
  }

  func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      do {
        for event in try handler(request) { continuation.yield(event) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }
}

private struct HangingRuntime: ProviderRuntime {
  let providerStopped: XCTestExpectation
  var reasoningOnly = false

  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "test", providers: [])
  }

  func authorize(
    _ operation: AuthorizationOperation,
    interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    switch operation {
    case .login(let providerID, _), .logout(let providerID):
      return .disconnected(providerID: providerID)
    }
  }

  func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(.responseStarted(metadata(for: request)))
      continuation.yield(reasoningOnly ? .reasoningDelta("planning") : .textDelta("waiting"))
      continuation.onTermination = { _ in providerStopped.fulfill() }
    }
  }
}

private actor RequestRecorder {
  private(set) var requests: [ProviderRequest] = []

  func record(_ request: ProviderRequest) {
    requests.append(request)
  }
}

private func metadata(for request: ProviderRequest) -> ProviderResponseMetadata {
  ProviderResponseMetadata(
    responseID: "response",
    providerID: request.providerID,
    modelID: request.modelID,
    providerMetadata: [:]
  )
}

private func responseEvents(for request: ProviderRequest, text: String) -> [ProviderEvent] {
  [
    .responseStarted(metadata(for: request)),
    .textDelta(text),
    .responseSnapshot(
      responseSnapshot(for: request, content: [.text(text)], finishReason: .stop)),
    .completed(.stop),
  ]
}

private func responseSnapshot(
  for request: ProviderRequest,
  content: [ProviderAssistantContent],
  finishReason: ProviderFinishReason
) -> ProviderResponseSnapshot {
  ProviderResponseSnapshot(
    responseID: "response",
    providerID: request.providerID,
    protocolID: "test-protocol",
    modelID: request.modelID,
    responseModelID: nil,
    content: content.map { item in
      switch item {
      case .text(let text):
        return .text(ProviderTextContent(text: text, signature: nil))
      case .signedText(let text):
        return .text(text)
      case .reasoning(let reasoning):
        return .reasoning(reasoning)
      case .toolCall(let call):
        return .toolCall(call)
      }
    },
    usage: ProviderUsage(
      inputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      cachedInputTokens: 0,
      totalTokens: 0,
      providerMetadata: [:]
    ),
    finishReason: finishReason,
    rawFinishReason: finishReason.rawValue,
    timestampMilliseconds: 0
  )
}

private actor ExecutionCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private struct CountingEchoTool: Tool {
  let counter: ExecutionCounter
  let name = "echo"
  let description = "Count executions"
  func call(arguments: EchoTool.Arguments) async throws -> String {
    await counter.increment()
    return arguments.value
  }
}

private struct StopTools: ToolExecutionDelegate {
  func toolCallDecision(for toolCall: Transcript.ToolCall, in session: LanguageModelSession) async
    -> ToolExecutionDecision
  { .stop }
}

private func reasoningEntries<S: Sequence>(_ entries: S) -> [Transcript.Reasoning]
where S.Element == Transcript.Entry {
  entries.compactMap { entry in
    if case .reasoning(let value) = entry { return value }
    return nil
  }
}

private func visibleReasoning<S: Sequence>(_ entries: S) -> String?
where S.Element == Transcript.Entry {
  let text = reasoningEntries(entries).flatMap(\.segments).compactMap { segment -> String? in
    if case .text(let value) = segment { return value.content }
    return nil
  }.joined()
  return text.isEmpty ? nil : text
}

private struct ToolCheckpointRuntime: ProviderRuntime {
  let providerStopped: XCTestExpectation
  func catalog() async throws -> ProviderCatalog {
    ProviderCatalog(revision: "test", providers: [])
  }
  func authorize(
    _ operation: AuthorizationOperation, interaction: @escaping AuthorizationInteraction
  ) async throws -> AuthorizationState {
    switch operation {
    case .login(let id, _), .logout(let id): return .disconnected(providerID: id)
    }
  }
  func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, any Error> {
    if request.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
      return AsyncThrowingStream { continuation in
        continuation.yield(.responseStarted(metadata(for: request)))
        continuation.yield(.reasoningDelta("partial next plan"))
        continuation.onTermination = { _ in providerStopped.fulfill() }
      }
    }
    let call = ProviderToolCall(
      id: "checkpoint-call", name: "echo", arguments: .object(["value": .string("done")]))
    return FakeRuntime { request in
      [
        .responseStarted(metadata(for: request)), .reasoningDelta("completed plan"),
        .toolCallStarted(id: call.id, name: call.name), .toolCallCompleted(call),
        .responseSnapshot(
          responseSnapshot(
            for: request,
            content: [
              .reasoning(
                .init(text: "completed plan", signature: "signature", providerMetadata: [:])),
              .toolCall(call),
            ], finishReason: .toolCalls)), .completed(.toolCalls),
      ]
    }.stream(request)
  }
}
