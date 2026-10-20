//
//  UserDataFile.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads and writes `UserData.json`, the file `UserDataStore` loads.
///
/// The write replaces the file by rename, after copying the previous contents to
/// `UserData.json.bak` (one backup, replaced on the next write). A lock file
/// serializes writers so the app and the MCP server do not tear the JSON.
extension JSONEncoder {
    static var userData: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var userData: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum UserDataFile {
    enum WriteError: Error {
        case lockFailed
        case replaceFailed
    }

    static func read(from url: URL) throws -> UserData {
        let raw = try Data(contentsOf: url)
        return try JSONDecoder.userData.decode(UserData.self, from: raw)
    }

    static func write(_ data: UserData, to url: URL) throws {
        let encoded = try JSONEncoder.userData.encode(data)
        try writeAtomically(encoded, to: url)
    }

    /// Reads the file (or an empty document), applies `change`, and writes it back,
    /// all while holding the lock.
    static func modify(at url: URL, _ change: (inout UserData) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            _ = FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        }
        let lock = try FileHandle(forUpdating: lockURL)
        guard flock(lock.fileDescriptor, LOCK_EX) == 0 else { throw WriteError.lockFailed }
        defer { flock(lock.fileDescriptor, LOCK_UN); try? lock.close() }
        var data = (try? read(from: url)) ?? UserData()
        try change(&data)
        let encoded = try JSONEncoder.userData.encode(data)
        try writeReplacing(encoded, to: url)
    }

    /// Writes `encoded` to `url` under an exclusive lock. The previous file, if any,
    /// is copied to `url` + `.bak` first. The new bytes land in a temp file in the
    /// same directory and then replace `url`.
    static func writeAtomically(_ encoded: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            _ = FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        }
        let lock = try FileHandle(forUpdating: lockURL)
        guard flock(lock.fileDescriptor, LOCK_EX) == 0 else { throw WriteError.lockFailed }
        defer { flock(lock.fileDescriptor, LOCK_UN); try? lock.close() }
        try writeReplacing(encoded, to: url)
    }

    /// Caller holds the lock.
    private static func writeReplacing(_ encoded: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let backup = URL(fileURLWithPath: url.path + ".bak")
        if FileManager.default.fileExists(atPath: url.path) {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: url, to: backup)
        }
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try encoded.write(to: temp, options: .atomic)
        // `rename` replaces an existing file in one step.
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw WriteError.replaceFailed
        }
    }
}

/// Where the Mac app's `UserData.json` lives, for a process that is not the app.
///
/// The shipping Mac app is sandboxed. Its Application Support directory is inside
/// `~/Library/Containers/com.alexchadwick.neuclasssearch/`. A command-line tool
/// launched by Claude or Cursor is not sandboxed, so it can read and write that
/// file as the same user. The app sandbox itself is unchanged: the tool is not
/// given the app's entitlements, and the app does not gain a new entitlement.
///
/// `TERM_ORGANIZE_USER_DATA` overrides the path (tests use this and never touch
/// the real file).
enum PlanFileLocation {
    static let bundleIdentifier = "com.alexchadwick.neuclasssearch"

    static func resolve() -> URL {
        if let override = ProcessInfo.processInfo.environment["TERM_ORGANIZE_USER_DATA"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let container = home.appendingPathComponent(
            "Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/UserData.json"
        )
        if FileManager.default.fileExists(atPath: container.deletingLastPathComponent().path) {
            return container
        }
        return AppPaths.userDataURL
    }
}
