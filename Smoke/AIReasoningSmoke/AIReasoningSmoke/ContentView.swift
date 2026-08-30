// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ContentView: View {
  @StateObject private var viewModel: SmokeViewModel
  private let browserHost: SmokeBrowserHost

  init() {
    let browserHost = SmokeBrowserHost()
    self.browserHost = browserHost
    _viewModel = StateObject(wrappedValue: SmokeViewModel(browserHost: browserHost))
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Label(viewModel.summary, systemImage: viewModel.summaryIcon)
              .foregroundStyle(viewModel.summaryColor)
            Spacer()
            if viewModel.isRunning {
              ProgressView()
            }
          }

          Button("Run complete smoke suite") {
            viewModel.run()
          }
          .disabled(viewModel.isRunning)
          .accessibilityIdentifier("run-smoke-suite")
        } header: {
          Text("Native + Interactive Tools")
        } footer: {
          Text("Deterministic fixtures only. No provider credential or paid API is used.")
        }

        Section("Checks") {
          ForEach(viewModel.checks) { check in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Image(systemName: check.status.symbol)
                  .foregroundStyle(check.status.color)
                Text(check.name)
                  .font(.headline)
                Spacer()
                Text(check.capability)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if !check.detail.isEmpty {
                Text(check.detail)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("smoke-check-\(check.id)")
          }
        }

        Section("App-owned browser") {
          SmokeBrowserView(host: browserHost)
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
            }
            .accessibilityIdentifier("smoke-browser")
        }

        if let preview = viewModel.assetPreview {
          Section("Managed image asset") {
            Image(uiImage: preview)
              .resizable()
              .scaledToFit()
              .frame(maxHeight: 180)
              .accessibilityIdentifier("smoke-asset-preview")
          }
        }

        if let reportURL = viewModel.reportURL {
          Section("Automation evidence") {
            Text(reportURL.path)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
      }
      .navigationTitle("AIReasoning Smoke")
    }
    .task {
      await viewModel.runIfNeeded()
    }
  }
}

extension SmokeCheck.Status {
  fileprivate var symbol: String {
    switch self {
    case .pending: "circle"
    case .running: "arrow.trianglehead.2.clockwise.rotate.90"
    case .passed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .pending: .secondary
    case .running: .blue
    case .passed: .green
    case .failed: .red
    }
  }
}
