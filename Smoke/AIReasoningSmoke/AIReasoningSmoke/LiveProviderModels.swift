// SPDX-License-Identifier: GPL-3.0-or-later

import AnyLanguageModel
import Foundation
import PiAIProviderRuntime

enum LiveProviderTask: String, CaseIterable, Codable, Identifiable, Sendable {
  case textStream
  case structuredOutput
  case functionCall
  case imageInput
  case imageGeneration

  var id: String { rawValue }

  var name: String {
    switch self {
    case .textStream: "Text Stream"
    case .structuredOutput: "Structured Output"
    case .functionCall: "Function Call"
    case .imageInput: "Image Input"
    case .imageGeneration: "Image Generation"
    }
  }

  var symbol: String {
    switch self {
    case .textStream: "text.bubble"
    case .structuredOutput: "curlybraces.square"
    case .functionCall: "function"
    case .imageInput: "photo.badge.arrow.down"
    case .imageGeneration: "wand.and.stars"
    }
  }
}

@Generable
struct LiveStructuredAnswer {
  let status: String
  let count: Int
}

struct LiveProviderResult: Identifiable, Codable, Sendable {
  enum Status: String, Codable, Sendable {
    case running
    case passed
    case failed
  }

  let id: UUID
  let task: LiveProviderTask
  let providerID: String
  let modelID: String
  let startedAt: Date
  var finishedAt: Date?
  var status: Status
  var detail: String
}

struct LiveAuthorizationPresentation: Equatable, Sendable {
  enum ResponseKind: Equatable, Sendable {
    case information
    case value(AuthorizationPromptKind)
    case callbackURL
  }

  let providerID: String
  let title: String
  let message: String
  let responseKind: ResponseKind
  let url: URL?
  let userCode: String?
}

actor LiveEchoRecorder {
  private(set) var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }
}

struct LiveEchoTool: Tool {
  @Generable
  struct Arguments {
    let value: String
  }

  let name = "echo"
  let description = "Echo the required live smoke-test value."
  let recorder: LiveEchoRecorder

  func call(arguments: Arguments) async throws -> String {
    await recorder.record(arguments.value)
    return arguments.value
  }
}

struct LiveSmokeFailure: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}
