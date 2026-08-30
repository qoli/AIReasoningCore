// swift-tools-version: 6.1
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
  name: "AIReasoningCore",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "AIReasoningCore", targets: ["AIReasoningCore"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/huggingface/AnyLanguageModel.git",
      exact: "0.9.0"
    ),
    .package(
      url: "https://github.com/qoli/pi-ai-swift.git",
      exact: "0.2.0"
    ),
  ],
  targets: [
    .target(
      name: "AIReasoningCore",
      dependencies: [
        .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
        .product(name: "PiAIProviderRuntime", package: "pi-ai-swift"),
      ]
    ),
    .testTarget(
      name: "AIReasoningCoreTests",
      dependencies: [
        "AIReasoningCore",
        .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
        .product(name: "PiAIProviderRuntime", package: "pi-ai-swift"),
      ],
    ),
  ]
)
