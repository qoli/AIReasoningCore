#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later


import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: digest-ish-rootfs.swift /absolute/fakefs\n".utf8))
    exit(64)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("data").path),
      FileManager.default.fileExists(atPath: root.appendingPathComponent("meta.db").path)
else {
    FileHandle.standardError.write(Data("invalid fakefs: \(root.path)\n".utf8))
    exit(65)
}
let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
guard let enumerator = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: Array(keys),
    options: []
) else {
    FileHandle.standardError.write(Data("invalid fakefs: \(root.path)\n".utf8))
    exit(65)
}

var files: [(String, URL)] = []
while let url = enumerator.nextObject() as? URL {
    let values = try url.resourceValues(forKeys: keys)
    if values.isSymbolicLink == true {
        FileHandle.standardError.write(Data("symbolic link is not allowed: \(url.path)\n".utf8))
        exit(65)
    }
    if values.isRegularFile == true {
        files.append((
            url.pathComponents.suffix(enumerator.level).joined(separator: "/"),
            url
        ))
    }
}
files.sort { $0.0 < $1.0 }

var hasher = SHA256()
for (relativePath, url) in files {
    let path = Data(relativePath.utf8)
    var length = UInt64(path.count).bigEndian
    withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
    hasher.update(data: path)
    do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }
}

print(hasher.finalize().map { String(format: "%02x", $0) }.joined())
