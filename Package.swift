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
        .library(name: "AIReasoningCore", targets: ["AIReasoningCore"]),
        .library(name: "AIReasoningiSH", targets: ["AIReasoningiSH"]),
        .executable(name: "ai-reasoning", targets: ["AIReasoningCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/MacPaw/OpenAI.git",
            exact: "0.5.1"
        ),
    ],
    targets: [
        .target(
            name: "AIReasoningCore",
            dependencies: [
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        .target(
            name: "AIReasoningiSHRuntime",
            path: "Sources/AIReasoningiSHRuntime",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AIReasoningiSH",
            dependencies: [
                "AIReasoningCore",
                "AIReasoningiSHRuntime",
            ]
        ),
        .target(
            name: "AIReasoningSmokeSupport",
            dependencies: [
                "AIReasoningCore",
                "AIReasoningiSH",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ],
            path: "Smoke/AIReasoningSmoke/AIReasoningSmoke",
            exclude: [
                "AIReasoningSmokeApp.swift",
                "ContentView.swift",
            ],
            sources: [
                "ISHHostBootstrap.swift",
                "SmokeConfiguration.swift",
                "SmokeViewModel.swift",
            ]
        ),
        .target(
            name: "AIReasoningiSHTestSupport",
            dependencies: ["AIReasoningiSHRuntime"],
            path: "Tests/AIReasoningiSHTestSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AIReasoningOpenAICompatibility",
            dependencies: [
                "AIReasoningCore",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
                .product(name: "OpenAI", package: "OpenAI"),
            ]
        ),
        .executableTarget(
            name: "AIReasoningCLI",
            dependencies: ["AIReasoningOpenAICompatibility"]
        ),
        .testTarget(
            name: "AIReasoningCoreTests",
            dependencies: [
                "AIReasoningCore",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AIReasoningOpenAICompatibilityTests",
            dependencies: [
                "AIReasoningOpenAICompatibility",
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AIReasoningiSHTests",
            dependencies: [
                "AIReasoningiSH",
                "AIReasoningiSHTestSupport",
            ]
        ),
        .testTarget(
            name: "AIReasoningSmokeTests",
            dependencies: [
                "AIReasoningSmokeSupport",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
    ]
)
