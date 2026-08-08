import AIReasoningCore
import AIReasoningiSH
import AnyLanguageModel
import Foundation

#if canImport(AIReasoningiSHHost)
    import AIReasoningiSHHost
#endif

@MainActor enum ISHHostBootstrap {
    private(set) static var registrationError: String?
    private(set) static var bootError: String?

    static func registerLinkedHostIfPresent() {
        #if canImport(AIReasoningiSHHost)
            guard let runtime = ARISHOpenMinisHostRuntimeV1() else {
                registrationError = "The linked iSH host returned no runtime table."
                return
            }
            do { try ISHEmbeddedRuntime.register(hostRuntime: runtime) } catch {
                registrationError = error.localizedDescription
                recordSmokeStatus(.init(state: "failed", detail: error.localizedDescription))
                return
            }
            do { try bootBundledRootFileSystemIfPresent() } catch {
                bootError = error.localizedDescription
                recordSmokeStatus(.init(state: "failed", detail: error.localizedDescription))
            }
        #endif
    }

    private static func bootBundledRootFileSystemIfPresent() throws {
        let source = Bundle.main.url(forResource: "iSHRootFS", withExtension: nil)
        let manifestURL = Bundle.main.url(forResource: "iSHRootFSManifest", withExtension: "plist")
        if source == nil, manifestURL == nil { return }
        guard let source, let manifestURL else { throw SmokeFailure.incompleteRootFileSystemResources }
        guard let supervisor = Bundle.main.url(forResource: "ishsv", withExtension: nil) else {
            throw ISHEmbeddedRuntimeError.invalidSupervisor("Bundle.main/ishsv")
        }

        let manifest = try PropertyListDecoder().decode(
            RootFileSystemManifest.self, from: Data(contentsOf: manifestURL))
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = applicationSupport.appendingPathComponent("AIReasoningiSH", isDirectory: true)
            .appendingPathComponent("\(manifest.identifier)-\(manifest.version)", isDirectory: true)
        let prepared = try ISHRootFileSystemPreparer().prepare(
            .init(
                sourceDirectoryURL: source, identifier: manifest.identifier, version: manifest.version,
                sha256: manifest.sha256), at: destination)
        try ISHEmbeddedRuntime.shared.boot(.init(rootFileSystemURL: prepared, supervisorExecutableURL: supervisor))
        recordSmokeStatus(.init(state: "booted", detail: prepared.path))
        Task {
            await runGuestCommandSmoke(
                codexExecutablePath: manifest.codexExecutablePath,
                openCodeExecutablePath: manifest.openCodeExecutablePath, openCodeModel: manifest.openCodeModel,
                openCodeProviderID: manifest.openCodeProviderID, openCodeBaseURL: manifest.openCodeBaseURL,
                openCodeAPIKeyEnvironmentVariable: manifest.openCodeAPIKeyEnvironmentVariable)
        }
    }

    private static func runGuestCommandSmoke(
        codexExecutablePath: String?, openCodeExecutablePath: String?, openCodeModel: String?,
        openCodeProviderID: String?, openCodeBaseURL: String?, openCodeAPIKeyEnvironmentVariable: String?
    ) async {
        var phase = "guest /bin/cat"
        do {
            let cat = try await runGuestCommand(
                executablePath: "/bin/cat", arguments: [], standardInput: Data("AIReasoningiSH-host-smoke\n".utf8),
                timeout: .seconds(15))
            guard cat.exitCode == 0, cat.output.contains("AIReasoningiSH-host-smoke") else {
                throw SmokeFailure.guestCommand(executablePath: "/bin/cat", exitCode: cat.exitCode, output: cat.output)
            }

            var guestEnvironment = [
                "HOME": "/root", "PATH": "/usr/local/bin:/usr/bin:/bin", "SSL_CERT_FILE": "/etc/ssl/cert.pem",
            ]
            var codex: CodexSmokeStatus?
            if let codexExecutablePath {
                phase = "Codex version"
                guard codexExecutablePath.hasPrefix("/") else {
                    throw SmokeFailure.invalidGuestExecutablePath(codexExecutablePath)
                }
                let version = try await runGuestCommand(
                    executablePath: codexExecutablePath, arguments: ["--version"], environment: guestEnvironment,
                    timeout: .seconds(30))
                guard version.exitCode == 0, !version.output.isEmpty else {
                    throw SmokeFailure.guestCommand(
                        executablePath: codexExecutablePath, exitCode: version.exitCode, output: version.output)
                }

                let initializeRequest = Data(
                    """
                    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai_reasoning_smoke","title":"AIReasoning Smoke","version":"0.1.0"}}}

                    """.utf8)
                let appServer = try await runGuestCommand(
                    executablePath: codexExecutablePath, arguments: ["app-server", "--listen", "stdio://"],
                    environment: guestEnvironment, standardInput: initializeRequest, timeout: .seconds(30))
                guard appServer.exitCode == 0, containsInitializeResponse(appServer.standardOutputLines),
                    !containsFatalRuntimeFailure(appServer.standardErrorLines)
                else {
                    throw SmokeFailure.codexAppServerInitialize(exitCode: appServer.exitCode, output: appServer.output)
                }

                let authentication = try await runGuestCommand(
                    executablePath: codexExecutablePath, arguments: ["login", "status"], environment: guestEnvironment,
                    timeout: .seconds(30))
                codex = CodexSmokeStatus(
                    executablePath: codexExecutablePath, version: version.output,
                    appServerInitializeOutput: appServer.output, authenticationExitCode: authentication.exitCode,
                    authenticationOutput: authentication.output, authenticated: authentication.exitCode == 0)
            }

            var openCode: OpenCodeSmokeStatus?
            if let openCodeExecutablePath {
                phase = "OpenCode version"
                guard openCodeExecutablePath.hasPrefix("/") else {
                    throw SmokeFailure.invalidGuestExecutablePath(openCodeExecutablePath)
                }
                let version = try await runGuestCommand(
                    executablePath: openCodeExecutablePath, arguments: ["--version"], environment: guestEnvironment,
                    timeout: .seconds(30))
                guard version.exitCode == 0, !version.output.isEmpty else {
                    throw SmokeFailure.guestCommand(
                        executablePath: openCodeExecutablePath, exitCode: version.exitCode, output: version.output)
                }

                var generationOutput: String?
                if let openCodeModel, !openCodeModel.isEmpty {
                    phase = "OpenCode ACP generation"
                    let providerValues = [
                        openCodeProviderID, openCodeBaseURL, openCodeAPIKeyEnvironmentVariable,
                    ]
                    let provider: OpenCodeLanguageModel.ProviderConfiguration?
                    if providerValues.allSatisfy({ $0 == nil }) {
                        provider = nil
                    } else {
                        guard let openCodeProviderID, let openCodeBaseURL,
                            let baseURL = URL(string: openCodeBaseURL),
                            let openCodeAPIKeyEnvironmentVariable,
                            let apiKey = ProcessInfo.processInfo.environment[openCodeAPIKeyEnvironmentVariable],
                            !apiKey.isEmpty
                        else {
                            throw SmokeFailure.incompleteOpenCodeProviderConfiguration
                        }
                        guestEnvironment[openCodeAPIKeyEnvironmentVariable] = apiKey
                        provider = .init(
                            id: openCodeProviderID, baseURL: baseURL,
                            apiKeyEnvironmentVariable: openCodeAPIKeyEnvironmentVariable)
                    }
                    let model = OpenCodeLanguageModel(
                        configuration: .init(
                            executableURL: URL(fileURLWithPath: openCodeExecutablePath), model: openCodeModel,
                            workingDirectoryURL: URL(fileURLWithPath: "/root"), environment: guestEnvironment,
                            timeout: .seconds(120), provider: provider), executor: ISHEmbeddedProcessExecutor())
                    let response = try await LanguageModelSession(model: model).respond(
                        to: "Reply with exactly: iSH OpenCode OK")
                    generationOutput = response.content
                }
                openCode = .init(
                    executablePath: openCodeExecutablePath, version: version.output, model: openCodeModel,
                    providerID: openCodeProviderID, baseURL: openCodeBaseURL, generationOutput: generationOutput)
            }
            recordSmokeStatus(.init(state: "succeeded", detail: cat.output, codex: codex, openCode: openCode))
        } catch {
            let detail = "\(phase): \(error.localizedDescription)"
            bootError = detail
            recordSmokeStatus(.init(state: "failed", detail: detail))
        }
    }

    private static func runGuestCommand(
        executablePath: String, arguments: [String], environment: [String: String] = [:], standardInput: Data? = nil,
        timeout: Duration
    ) async throws -> GuestCommandResult {
        let session = try await ISHEmbeddedProcessExecutor().start(
            .init(
                executableURL: URL(fileURLWithPath: executablePath), arguments: arguments, environment: environment,
                workingDirectoryURL: URL(fileURLWithPath: "/"), timeout: timeout))
        if let standardInput { try await session.writeStandardInput(standardInput) }
        try await session.closeStandardInput()

        var standardOutputLines: [String] = []
        var standardErrorLines: [String] = []
        var exitCode: Int32?
        for try await event in session.events {
            switch event {
            case .standardOutputLine(let line): standardOutputLines.append(line)
            case .standardErrorLine(let line): standardErrorLines.append(line)
            case .terminated(let code): exitCode = code
            }
        }
        return GuestCommandResult(
            exitCode: exitCode, standardOutputLines: standardOutputLines, standardErrorLines: standardErrorLines)
    }

    private static func containsInitializeResponse(_ lines: [String]) -> Bool {
        for line in lines {
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let identifier = object["id"] as? NSNumber
            else { continue }
            if identifier.intValue == 1, object["result"] != nil { return true }
        }
        return false
    }

    private static func containsFatalRuntimeFailure(_ lines: [String]) -> Bool {
        lines.contains { line in
            line.contains(" panicked at ") || line.hasPrefix("thread '") && line.contains("panicked at")
        }
    }

    private static func recordSmokeStatus(_ status: SmokeStatus) {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try JSONEncoder().encode(status).write(
                to: applicationSupport.appendingPathComponent("iSHHostSmoke.status.json"), options: .atomic)
        } catch { bootError = "Could not write iSH smoke status: \(error.localizedDescription)" }
    }
}

private struct RootFileSystemManifest: Decodable {
    let identifier: String
    let version: String
    let sha256: String
    let codexExecutablePath: String?
    let openCodeExecutablePath: String?
    let openCodeModel: String?
    let openCodeProviderID: String?
    let openCodeBaseURL: String?
    let openCodeAPIKeyEnvironmentVariable: String?
}

private struct SmokeStatus: Codable {
    let state: String
    let detail: String
    let codex: CodexSmokeStatus?
    let openCode: OpenCodeSmokeStatus?

    init(state: String, detail: String, codex: CodexSmokeStatus? = nil, openCode: OpenCodeSmokeStatus? = nil) {
        self.state = state
        self.detail = detail
        self.codex = codex
        self.openCode = openCode
    }
}

private struct CodexSmokeStatus: Codable {
    let executablePath: String
    let version: String
    let appServerInitializeOutput: String
    let authenticationExitCode: Int32?
    let authenticationOutput: String
    let authenticated: Bool
}

private struct OpenCodeSmokeStatus: Codable {
    let executablePath: String
    let version: String
    let model: String?
    let providerID: String?
    let baseURL: String?
    let generationOutput: String?
}

private struct GuestCommandResult {
    let exitCode: Int32?
    let standardOutputLines: [String]
    let standardErrorLines: [String]

    var output: String { (standardOutputLines + standardErrorLines.map { "stderr: \($0)" }).joined(separator: "\n") }
}

private enum SmokeFailure: Error, LocalizedError {
    case incompleteRootFileSystemResources
    case invalidGuestExecutablePath(String)
    case codexAppServerInitialize(exitCode: Int32?, output: String)
    case guestCommand(executablePath: String, exitCode: Int32?, output: String)
    case incompleteOpenCodeProviderConfiguration

    var errorDescription: String? {
        switch self {
        case .incompleteRootFileSystemResources:
            "The smoke bundle must contain both iSHRootFS and iSHRootFSManifest.plist"
        case .invalidGuestExecutablePath(let path): "The guest smoke executable path must be absolute: \(path)"
        case .codexAppServerInitialize(let exitCode, let output):
            "Codex app-server initialize failed (exit \(exitCode.map(String.init) ?? "missing")): \(output)"
        case .guestCommand(let executablePath, let exitCode, let output):
            "Embedded guest command \(executablePath) failed (exit \(exitCode.map(String.init) ?? "missing")): \(output)"
        case .incompleteOpenCodeProviderConfiguration:
            "OpenCode provider ID, base URL, API-key environment variable, and launch environment secret are required together"
        }
    }
}
