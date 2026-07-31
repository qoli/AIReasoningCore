import Foundation

package enum AgentTemporaryArtifacts {
    package static func stageImages(
        _ images: [AgentPromptContext.Image],
        executor: any AgentProcessExecuting,
        configuration: AgentDriverConfiguration
    ) async throws -> [String] {
        var paths: [String] = []
        do {
            for image in images {
                let resolved = try await AgentImageResolver.resolve(
                    image,
                    maximumBytes: configuration.maximumImageBytes
                )
                let path = configuration.workingDirectoryURL
                    .appendingPathComponent(
                        ".ai-reasoning-\(UUID().uuidString).\(fileExtension(for: resolved.mimeType))"
                    )
                    .path
                try await write(
                    resolved.data,
                    to: path,
                    executor: executor,
                    configuration: configuration
                )
                paths.append(path)
            }
            return paths
        } catch {
            do {
                try await remove(
                    paths,
                    executor: executor,
                    configuration: configuration
                )
            } catch let cleanupError {
                throw AgentLanguageModelError.artifactCleanupFailed(
                    "original error: \(error); cleanup error: \(cleanupError)"
                )
            }
            throw error
        }
    }

    package static func remove(
        _ paths: [String],
        executor: any AgentProcessExecuting,
        configuration: AgentDriverConfiguration
    ) async throws {
        guard !paths.isEmpty else { return }
        let request = AgentProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "rm -f -- \"$@\"", "ai-reasoning-cleanup"] + paths,
            environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL,
            timeout: .seconds(15)
        )
        let session = try await executor.start(request)
        try await session.closeStandardInput()
        var stderr: [String] = []
        var exitCode: Int32?
        for try await event in session.events {
            switch event {
            case .standardErrorLine(let line): stderr.append(line)
            case .terminated(let code): exitCode = code
            case .standardOutputLine: break
            }
        }
        guard exitCode == 0 else {
            throw AgentLanguageModelError.artifactCleanupFailed(
                stderr.joined(separator: "\n")
            )
        }
    }

    private static func write(
        _ data: Data,
        to path: String,
        executor: any AgentProcessExecuting,
        configuration: AgentDriverConfiguration
    ) async throws {
        let request = AgentProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "umask 077; set -C; cat > \"$1\"",
                "ai-reasoning-stage",
                path,
            ],
            environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL,
            timeout: .seconds(30)
        )
        let session = try await executor.start(request)
        try await session.writeStandardInput(data)
        try await session.closeStandardInput()
        var stderr: [String] = []
        var exitCode: Int32?
        for try await event in session.events {
            switch event {
            case .standardErrorLine(let line): stderr.append(line)
            case .terminated(let code): exitCode = code
            case .standardOutputLine: break
            }
        }
        guard exitCode == 0 else {
            throw AgentLanguageModelError.protocolFailure(
                driver: "image-staging",
                message: stderr.joined(separator: "\n")
            )
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic": "heic"
        default: "image"
        }
    }
}
