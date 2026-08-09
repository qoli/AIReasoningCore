// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningCore
import AIReasoningOpenAICompatibility
import Darwin
import Foundation

@main
enum AIReasoningCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var protocolOutput: ProtocolOutput?
        do {
            let options = try CLIOptions.parse(arguments)
            let input = try Data(contentsOf: options.inputURL)
            let output = try ProtocolOutput(url: options.outputURL)
            protocolOutput = output
            let configuration = ChatCompletionsExecutionConfiguration(
                backend: options.backend,
                executableURL: try options.resolvedExecutableURL(),
                baseURL: options.baseURL,
                workingDirectoryURL: options.workingDirectoryURL,
                timeoutSeconds: options.timeoutSeconds,
                environment: ProcessInfo.processInfo.environment,
                openCodeProvider: try options.openCodeProviderConfiguration()
            )
            let runTask = Task {
                await ChatCompletionsRunner().run(
                    input: input,
                    configuration: configuration,
                    emit: { data in try output.write(data) },
                    log: { message in
                        FileHandle.standardError.write(
                            Data("[ai-reasoning] \(message)\n".utf8)
                        )
                    }
                )
            }
            let interruptSource = InterruptSource {
                runTask.cancel()
            }
            let exitCode = await runTask.value
            interruptSource.cancel()
            output.close()
            exit(exitCode)
        } catch {
            let message = "[ai-reasoning] \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            let envelope = """
            {"error":{"message":\(jsonString(String(describing: error))),"type":"invalid_request_error","param":null,"code":"invalid_cli_argument"}}
            """
            let data = Data((envelope + "\n").utf8)
            do {
                if let protocolOutput {
                    try protocolOutput.write(data)
                    protocolOutput.close()
                } else {
                    try FileHandle.standardOutput.write(contentsOf: data)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("[ai-reasoning] Failed to write protocol error: \(error)\n".utf8)
                )
                exit(74)
            }
            exit(64)
        }
    }

    private static func jsonString(_ value: String) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            guard let result = String(data: data, encoding: .utf8) else {
                throw CLIError.unavailable("JSON encoder produced non-UTF-8 data")
            }
            return result
        } catch {
            FileHandle.standardError.write(
                Data("[ai-reasoning] Failed to encode protocol error: \(error)\n".utf8)
            )
            exit(74)
        }
    }
}

private final class InterruptSource: @unchecked Sendable {
    private let source: DispatchSourceSignal

    init(cancel: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler(handler: cancel)
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

private struct CLIOptions {
    let backend: ChatCompletionsBackend
    let inputURL: URL
    let outputURL: URL?
    let executablePath: String?
    let baseURL: URL?
    let workingDirectoryURL: URL
    let timeoutSeconds: Double
    let providerID: String?
    let apiKeyEnvironmentVariable: String?

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        guard arguments.first == "chat" else {
            throw CLIError.usage("Expected subcommand 'chat'")
        }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw CLIError.usage("Invalid argument: \(flag)")
            }
            guard values[flag] == nil else {
                throw CLIError.usage("Duplicate flag: \(flag)")
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        let known: Set<String> = [
            "--backend", "--input", "--output", "--executable",
            "--base-url", "--cwd", "--timeout-seconds",
            "--provider-id", "--api-key-env",
        ]
        if let unknown = Set(values.keys).subtracting(known).sorted().first {
            throw CLIError.usage("Unknown flag: \(unknown)")
        }
        guard let backendValue = values["--backend"],
              let backend = ChatCompletionsBackend(rawValue: backendValue)
        else {
            throw CLIError.usage("--backend openai|codex|claude|opencode is required")
        }
        guard let inputPath = values["--input"], !inputPath.isEmpty else {
            throw CLIError.usage("--input request.json is required")
        }
        let cwdPath = values["--cwd"] ?? FileManager.default.currentDirectoryPath
        let timeout: Double
        if let value = values["--timeout-seconds"] {
            guard let parsed = Double(value), parsed > 0 else {
                throw CLIError.usage("--timeout-seconds must be positive")
            }
            timeout = parsed
        } else {
            timeout = 120
        }
        let baseURL: URL?
        if let value = values["--base-url"] {
            guard let parsed = URL(string: value), parsed.scheme != nil else {
                throw CLIError.usage("--base-url must be an absolute URL")
            }
            baseURL = parsed
        } else {
            baseURL = nil
        }
        return .init(
            backend: backend,
            inputURL: URL(fileURLWithPath: inputPath),
            outputURL: values["--output"].map(URL.init(fileURLWithPath:)),
            executablePath: values["--executable"],
            baseURL: baseURL,
            workingDirectoryURL: URL(fileURLWithPath: cwdPath, isDirectory: true),
            timeoutSeconds: timeout,
            providerID: values["--provider-id"],
            apiKeyEnvironmentVariable: values["--api-key-env"]
        )
    }

    func openCodeProviderConfiguration() throws -> OpenCodeLanguageModel.ProviderConfiguration? {
        let values = [baseURL != nil, providerID != nil, apiKeyEnvironmentVariable != nil]
        guard values.contains(true) else { return nil }
        guard backend == .opencode else {
            if backend == .openai, providerID == nil, apiKeyEnvironmentVariable == nil { return nil }
            throw CLIError.usage("--provider-id and --api-key-env are valid only for the opencode backend")
        }
        guard let baseURL, let providerID, !providerID.isEmpty,
            let apiKeyEnvironmentVariable, !apiKeyEnvironmentVariable.isEmpty
        else {
            throw CLIError.usage(
                "OpenCode custom providers require --base-url, --provider-id, and --api-key-env together")
        }
        guard let apiKey = ProcessInfo.processInfo.environment[apiKeyEnvironmentVariable], !apiKey.isEmpty else {
            throw CLIError.unavailable("Missing API key environment variable: \(apiKeyEnvironmentVariable)")
        }
        return .init(id: providerID, baseURL: baseURL, apiKeyEnvironmentVariable: apiKeyEnvironmentVariable)
    }

    func resolvedExecutableURL() throws -> URL? {
        guard FileManager.default.fileExists(atPath: workingDirectoryURL.path) else {
            throw CLIError.unavailable(
                "Working directory is unavailable: \(workingDirectoryURL.path)"
            )
        }
        if backend != .openai, backend != .opencode, baseURL != nil {
            throw CLIError.usage("--base-url is valid only for the openai or opencode backend")
        }
        guard backend != .openai else {
            if executablePath != nil {
                throw CLIError.usage("--executable is not valid for the openai backend")
            }
            return nil
        }
        if let executablePath {
            guard executablePath.hasPrefix("/") else {
                throw CLIError.usage("--executable must be an absolute path")
            }
            let url = URL(fileURLWithPath: executablePath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw CLIError.unavailable("Executable is unavailable: \(url.path)")
            }
            return url
        }

        let name: String
        switch backend {
        case .codex: name = "codex"
        case .claude: name = "claude"
        case .opencode: name = "opencode"
        case .openai: return nil
        }
        guard let path = resolveOnPATH(name) else {
            throw CLIError.unavailable(
                "\(name) was not found on PATH; pass --executable /absolute/path"
            )
        }
        return URL(fileURLWithPath: path)
    }

    private func resolveOnPATH(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

private final class ProtocolOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let shouldClose: Bool

    init(url: URL?) throws {
        if let url {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CLIError.unavailable("Could not create output file: \(url.path)")
            }
            self.handle = try FileHandle(forWritingTo: url)
            self.shouldClose = true
        } else {
            self.handle = .standardOutput
            self.shouldClose = false
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func close() {
        guard shouldClose else { return }
        try? handle.close()
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .usage(let message), .unavailable(let message): message
        }
    }
}
