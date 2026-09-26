// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

struct SmokeFailure: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

struct SmokeCheck: Identifiable, Codable, Sendable {
  enum Status: String, Codable, Sendable {
    case pending
    case running
    case passed
    case failed
  }

  let id: String
  let capability: String
  let name: String
  var status: Status
  var detail: String
  var durationMilliseconds: Int?
}

private struct SmokeReport: Codable {
  let schemaVersion: Int
  let finishedAt: Date
  let passed: Bool
  let checks: [SmokeCheck]
}

@MainActor
final class SmokeViewModel: ObservableObject {
  @Published private(set) var checks: [SmokeCheck] = SmokeViewModel.initialChecks
  @Published private(set) var isRunning = false
  @Published private(set) var reportURL: URL?

  private var hasRun = false

  var summary: String {
    if isRunning {
      return "Running \(checks.filter { $0.status == .passed }.count)/\(checks.count)"
    }
    if checks.allSatisfy({ $0.status == .passed }) { return "All \(checks.count) checks passed" }
    if checks.contains(where: { $0.status == .failed }) { return "Smoke suite failed" }
    return "Not run"
  }

  var summaryIcon: String {
    if isRunning { return "progress.indicator" }
    if checks.allSatisfy({ $0.status == .passed }) { return "checkmark.seal.fill" }
    if checks.contains(where: { $0.status == .failed }) { return "xmark.octagon.fill" }
    return "circle.dashed"
  }

  var summaryColor: Color {
    if isRunning { return .blue }
    if checks.allSatisfy({ $0.status == .passed }) { return .green }
    if checks.contains(where: { $0.status == .failed }) { return .red }
    return .secondary
  }

  func runIfNeeded() async {
    guard !hasRun else { return }
    run()
  }

  func run() {
    guard !isRunning else { return }
    hasRun = true
    Task { await executeSuite() }
  }

  private func executeSuite() async {
    isRunning = true
    checks = Self.initialChecks

    await runCheck(id: "text-stream", operation: runTextStreamingProbe)
    await runCheck(id: "structured-output", operation: runStructuredOutputProbe)
    await runCheck(id: "reasoning-replay", operation: runReasoningReplayProbe)
    await runCheck(id: "tool-continuation", operation: runToolContinuationProbe)
    await runCheck(id: "cancellation-checkpoint", operation: runCancellationCheckpointProbe)
    await runCheck(id: "asset-delivery", operation: runAssetDeliveryProbe)

    isRunning = false
    do {
      reportURL = try writeReport()
    } catch {
      if let index = checks.indices.last {
        checks[index].status = .failed
        checks[index].detail += " | report write failed: \(error.localizedDescription)"
      }
    }
  }

  private func runCheck(
    id: String,
    operation: () async throws -> String
  ) async {
    guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
    checks[index].status = .running
    let clock = ContinuousClock()
    let start = clock.now
    do {
      checks[index].detail = try await operation()
      checks[index].status = .passed
    } catch {
      checks[index].status = .failed
      checks[index].detail = error.localizedDescription
    }
    let elapsed = start.duration(to: clock.now)
    checks[index].durationMilliseconds =
      Int(elapsed.components.seconds * 1_000)
      + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  private func writeReport() throws -> URL {
    guard
      let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first
    else {
      throw SmokeFailure("Documents directory is unavailable")
    }
    let report = SmokeReport(
      schemaVersion: 1,
      finishedAt: Date(),
      passed: checks.allSatisfy { $0.status == .passed },
      checks: checks
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = documents.appendingPathComponent("SmokeReport.json")
    try encoder.encode(report).write(to: url, options: .atomic)
    return url
  }

  private static let initialChecks: [SmokeCheck] = [
    SmokeCheck(
      id: "text-stream", capability: "Core", name: "Text Streaming",
      status: .pending, detail: ""),
    SmokeCheck(
      id: "structured-output", capability: "Core", name: "Structured Output",
      status: .pending, detail: ""),
    SmokeCheck(
      id: "reasoning-replay", capability: "Core", name: "Reasoning + Replay Metadata",
      status: .pending, detail: ""),
    SmokeCheck(
      id: "tool-continuation", capability: "Core", name: "External Tool Continuation",
      status: .pending, detail: ""),
    SmokeCheck(
      id: "cancellation-checkpoint", capability: "Core", name: "Cancellation Checkpoint",
      status: .pending, detail: ""),
    SmokeCheck(
      id: "asset-delivery", capability: "Core", name: "Provider Asset Delivery",
      status: .pending, detail: ""),
  ]
}
