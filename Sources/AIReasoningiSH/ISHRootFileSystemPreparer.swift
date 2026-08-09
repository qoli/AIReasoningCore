// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

public enum ISHRootFileSystemPreparationError: Error, LocalizedError, Sendable, Equatable {
    case invalidDistribution(String)
    case invalidDigest(String)
    case digestMismatch(expected: String, actual: String)
    case destinationConflict(String)
    case unsupportedSymbolicLink(String)
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDistribution(let path):
            "The iSH rootfs distribution is invalid: \(path)"
        case .invalidDigest(let digest):
            "The expected iSH rootfs SHA-256 is invalid: \(digest)"
        case .digestMismatch(let expected, let actual):
            "The iSH rootfs digest does not match (expected \(expected), got \(actual))"
        case .destinationConflict(let path):
            "A different or unverified iSH rootfs already exists at \(path)"
        case .unsupportedSymbolicLink(let path):
            "The iSH rootfs distribution contains an unsupported symbolic link: \(path)"
        case .fileOperation(let message):
            "The iSH rootfs could not be prepared: \(message)"
        }
    }
}

public struct ISHRootFileSystemDistribution: Sendable, Equatable {
    public let sourceDirectoryURL: URL
    public let identifier: String
    public let version: String
    public let sha256: String

    public init(
        sourceDirectoryURL: URL,
        identifier: String,
        version: String,
        sha256: String
    ) {
        self.sourceDirectoryURL = sourceDirectoryURL
        self.identifier = identifier
        self.version = version
        self.sha256 = sha256.lowercased()
    }
}

public struct ISHRootFileSystemPreparer: Sendable {
    public init() {}

    /// Copies an immutable bundled fakefs distribution into an app-owned,
    /// writable directory. Existing mutable roots are accepted only when the
    /// marker matches the exact distribution; they are never overwritten.
    public func prepare(
        _ distribution: ISHRootFileSystemDistribution,
        at destinationURL: URL
    ) throws -> URL {
        let expected = distribution.sha256
        guard expected.count == 64,
              expected.allSatisfy({ $0.isHexDigit })
        else {
            throw ISHRootFileSystemPreparationError.invalidDigest(expected)
        }
        try validateFakeFS(at: distribution.sourceDirectoryURL)

        let marker = Marker(
            identifier: distribution.identifier,
            version: distribution.version,
            sha256: expected
        )
        let markerURL = destinationURL.appendingPathComponent(markerFileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard let data = try? Data(contentsOf: markerURL),
                  let existing = try? JSONDecoder().decode(Marker.self, from: data),
                  existing == marker
            else {
                throw ISHRootFileSystemPreparationError.destinationConflict(destinationURL.path)
            }
            try validateFakeFS(at: destinationURL)
            return destinationURL
        }

        let actual = try directoryDigest(distribution.sourceDirectoryURL)
        guard actual == expected else {
            throw ISHRootFileSystemPreparationError.digestMismatch(
                expected: expected,
                actual: actual
            )
        }

        let parent = destinationURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).prepare-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: distribution.sourceDirectoryURL, to: staging)
            let markerData = try JSONEncoder().encode(marker)
            try markerData.write(
                to: staging.appendingPathComponent(markerFileName),
                options: .atomic
            )
            try FileManager.default.moveItem(at: staging, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw ISHRootFileSystemPreparationError.fileOperation(error.localizedDescription)
        }
        return destinationURL
    }

    public func digest(of distributionURL: URL) throws -> String {
        try validateFakeFS(at: distributionURL)
        return try directoryDigest(distributionURL)
    }

    private func validateFakeFS(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: url.appendingPathComponent("data").path),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("meta.db").path)
        else {
            throw ISHRootFileSystemPreparationError.invalidDistribution(url.path)
        }
    }

    private func directoryDigest(_ root: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw ISHRootFileSystemPreparationError.invalidDistribution(root.path)
        }
        var files: [(relativePath: String, url: URL)] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ISHRootFileSystemPreparationError.unsupportedSymbolicLink(url.path)
            }
            if values.isRegularFile == true {
                files.append((
                    url.pathComponents.suffix(enumerator.level).joined(separator: "/"),
                    url
                ))
            }
        }
        files.sort { $0.relativePath < $1.relativePath }

        var hasher = SHA256()
        for file in files {
            let path = Data(file.relativePath.utf8)
            hasher.update(data: withBigEndianLength(path.count))
            hasher.update(data: path)
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func withBigEndianLength(_ count: Int) -> Data {
        var length = UInt64(count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }
}

private let markerFileName = ".ai-reasoning-rootfs.json"

private struct Marker: Codable, Equatable {
    let identifier: String
    let version: String
    let sha256: String
}
