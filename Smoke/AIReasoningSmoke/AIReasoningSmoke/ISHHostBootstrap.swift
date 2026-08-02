import AIReasoningCore
import AIReasoningiSH
import Foundation

#if canImport(AIReasoningiSHHost)
import AIReasoningiSHHost
#endif

@MainActor
enum ISHHostBootstrap {
    private(set) static var registrationError: String?
    private(set) static var bootError: String?

    static func registerLinkedHostIfPresent() {
        #if canImport(AIReasoningiSHHost)
        guard let runtime = ARISHOpenMinisHostRuntimeV1() else {
            registrationError = "The linked iSH host returned no runtime table."
            return
        }
        do {
            try ISHEmbeddedRuntime.register(hostRuntime: runtime)
        } catch {
            registrationError = error.localizedDescription
            recordSmokeStatus(.init(state: "failed", detail: error.localizedDescription))
            return
        }
        do {
            try bootBundledRootFileSystemIfPresent()
        } catch {
            bootError = error.localizedDescription
            recordSmokeStatus(.init(state: "failed", detail: error.localizedDescription))
        }
        #endif
    }

    private static func bootBundledRootFileSystemIfPresent() throws {
        let source = Bundle.main.url(forResource: "iSHRootFS", withExtension: nil)
        let manifestURL = Bundle.main.url(
            forResource: "iSHRootFSManifest",
            withExtension: "plist"
        )
        if source == nil, manifestURL == nil {
            return
        }
        guard let source, let manifestURL else {
            throw SmokeFailure.incompleteRootFileSystemResources
        }
        guard let supervisor = Bundle.main.url(forResource: "ishsv", withExtension: nil) else {
            throw ISHEmbeddedRuntimeError.invalidSupervisor("Bundle.main/ishsv")
        }

        let manifest = try PropertyListDecoder().decode(
            RootFileSystemManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = applicationSupport
            .appendingPathComponent("AIReasoningiSH", isDirectory: true)
            .appendingPathComponent(
                "\(manifest.identifier)-\(manifest.version)",
                isDirectory: true
            )
        let prepared = try ISHRootFileSystemPreparer().prepare(
            .init(
                sourceDirectoryURL: source,
                identifier: manifest.identifier,
                version: manifest.version,
                sha256: manifest.sha256
            ),
            at: destination
        )
        try ISHEmbeddedRuntime.shared.boot(
            .init(
                rootFileSystemURL: prepared,
                supervisorExecutableURL: supervisor
            )
        )
        recordSmokeStatus(.init(state: "booted", detail: prepared.path))
        Task { await runGuestCommandSmoke() }
    }

    private static func runGuestCommandSmoke() async {
        do {
            let session = try await ISHEmbeddedProcessExecutor().start(
                .init(
                    executableURL: URL(fileURLWithPath: "/bin/cat"),
                    arguments: [],
                    workingDirectoryURL: URL(fileURLWithPath: "/"),
                    timeout: .seconds(15)
                )
            )
            try await session.writeStandardInput(Data("AIReasoningiSH-host-smoke\n".utf8))
            try await session.closeStandardInput()
            var lines: [String] = []
            var exitCode: Int32?
            for try await event in session.events {
                switch event {
                case .standardOutputLine(let line): lines.append(line)
                case .standardErrorLine(let line): lines.append("stderr: \(line)")
                case .terminated(let code): exitCode = code
                }
            }
            let output = lines.joined(separator: "\n")
            guard exitCode == 0, output.contains("AIReasoningiSH-host-smoke") else {
                throw SmokeFailure.guestCommand(exitCode: exitCode, output: output)
            }
            recordSmokeStatus(.init(state: "succeeded", detail: output))
        } catch {
            bootError = error.localizedDescription
            recordSmokeStatus(.init(state: "failed", detail: error.localizedDescription))
        }
    }

    private static func recordSmokeStatus(_ status: SmokeStatus) {
        do {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try JSONEncoder().encode(status).write(
                to: applicationSupport.appendingPathComponent("iSHHostSmoke.status.json"),
                options: .atomic
            )
        } catch {
            bootError = "Could not write iSH smoke status: \(error.localizedDescription)"
        }
    }
}

private struct RootFileSystemManifest: Decodable {
    let identifier: String
    let version: String
    let sha256: String
}

private struct SmokeStatus: Codable {
    let state: String
    let detail: String
}

private enum SmokeFailure: Error, LocalizedError {
    case incompleteRootFileSystemResources
    case guestCommand(exitCode: Int32?, output: String)

    var errorDescription: String? {
        switch self {
        case .incompleteRootFileSystemResources:
            "The smoke bundle must contain both iSHRootFS and iSHRootFSManifest.plist"
        case .guestCommand(let exitCode, let output):
            "Embedded guest command failed (exit \(exitCode.map(String.init) ?? "missing")): \(output)"
        }
    }
}
