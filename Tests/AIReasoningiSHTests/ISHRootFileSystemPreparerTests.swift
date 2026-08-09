// SPDX-License-Identifier: GPL-3.0-or-later

import AIReasoningiSH
import Foundation
import Testing

@Suite
struct ISHRootFileSystemPreparerTests {
    @Test
    func preparesVerifiedDistributionAndReusesOnlyMatchingMarker() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("distribution", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("metadata".utf8).write(to: source.appendingPathComponent("meta.db"))
        try Data([0, 1, 2, 3]).write(to: source.appendingPathComponent("data/root"))

        let preparer = ISHRootFileSystemPreparer()
        let digest = try preparer.digest(of: source)
        let distribution = ISHRootFileSystemDistribution(
            sourceDirectoryURL: source,
            identifier: "fixture",
            version: "1",
            sha256: digest
        )
        let destination = base.appendingPathComponent("writable", isDirectory: true)

        #expect(try preparer.prepare(distribution, at: destination) == destination)
        try Data("mutable".utf8).write(to: destination.appendingPathComponent("data/runtime"))
        #expect(try preparer.prepare(distribution, at: destination) == destination)

        let changed = ISHRootFileSystemDistribution(
            sourceDirectoryURL: source,
            identifier: "fixture",
            version: "2",
            sha256: digest
        )
        #expect(throws: ISHRootFileSystemPreparationError.destinationConflict(destination.path)) {
            try preparer.prepare(changed, at: destination)
        }
    }

    @Test
    func digestMismatchDoesNotCreateDestination() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("distribution", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("data", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("meta.db").path,
            contents: Data("metadata".utf8)
        )
        let destination = base.appendingPathComponent("writable", isDirectory: true)
        let distribution = ISHRootFileSystemDistribution(
            sourceDirectoryURL: source,
            identifier: "fixture",
            version: "1",
            sha256: String(repeating: "0", count: 64)
        )

        #expect(throws: ISHRootFileSystemPreparationError.self) {
            try ISHRootFileSystemPreparer().prepare(distribution, at: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func digestDependsOnRelativePathsAndContentsNotAbsoluteRootPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source", isDirectory: true)
        let copy = base.appendingPathComponent("copy-with-a-longer-name", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("data/usr/bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("metadata".utf8).write(to: source.appendingPathComponent("meta.db"))
        try Data("binary".utf8).write(
            to: source.appendingPathComponent("data/usr/bin/example")
        )
        try FileManager.default.copyItem(at: source, to: copy)

        let preparer = ISHRootFileSystemPreparer()
        #expect(try preparer.digest(of: source) == preparer.digest(of: copy))
    }
}
