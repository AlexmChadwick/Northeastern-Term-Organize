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

enum UserDataInspection {
    case missing
    case ready(UserData)
    /// The file exists, or its absence cannot be told apart from a permission
    /// failure. `reason` is never empty.
    case unreadable(path: String, reason: String)
}

enum UserDataFileError: Error {
    case missing(path: String)
    case unreadable(path: String, reason: String)
    case lockFailed(path: String)
    case replaceFailed(path: String)

    /// Tool-facing text. Includes the path and the reason, and is never empty.
    var storageMessage: String {
        switch self {
        case .missing(let path):
            return "Cannot read \(path): file not found"
        case .unreadable(let path, let reason):
            let detail = reason.isEmpty ? "unreadable" : reason
            return "Cannot read \(path): \(detail)"
        case .lockFailed(let path):
            return "Cannot lock \(path): lock failed"
        case .replaceFailed(let path):
            return "Cannot replace \(path): replace failed"
        }
    }
}

enum UserDataFile {
    /// Files this build knows how to load. A higher `version` is refused.
    static let supportedVersion = 1

    static func read(from url: URL) throws -> UserData {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            if isMissingError(error) { throw UserDataFileError.missing(path: url.path) }
            throw unreadableError(url, error)
        }
        return try decodeDocument(raw, at: url)
    }

    /// Missing is the only empty document. Permission denied, malformed JSON,
    /// and a newer `version` stay unreadable so callers do not invent an empty file.
    static func inspect(at url: URL) -> UserDataInspection {
        do {
            return .ready(try read(from: url))
        } catch let error as UserDataFileError {
            switch error {
            case .missing:
                return .missing
            case .unreadable(let path, let reason):
                return .unreadable(path: path, reason: reason.isEmpty ? "unreadable" : reason)
            case .lockFailed, .replaceFailed:
                return .unreadable(path: url.path, reason: error.storageMessage)
            }
        } catch {
            return .unreadable(path: url.path, reason: reasonText(for: error))
        }
    }

    static func write(_ data: UserData, to url: URL) throws {
        let encoded = try JSONEncoder.userData.encode(data)
        try writeAtomically(encoded, to: url)
    }

    /// Reads the file (or an empty document when the file is absent), applies
    /// `change`, and writes it back, all while holding the lock. A file that
    /// exists but cannot be decoded is left untouched.
    static func modify(at url: URL, _ change: (inout UserData) throws -> Void) throws {
        try withLock(at: url) {
            var data = try loadForUpdate(at: url)
            try change(&data)
            let encoded = try JSONEncoder.userData.encode(data)
            try writeReplacing(encoded, to: url)
        }
    }

    /// Caller holds the lock. Missing becomes an empty document. Any other read
    /// failure throws before a write.
    static func loadForUpdate(at url: URL) throws -> UserData {
        do {
            return try read(from: url)
        } catch let error as UserDataFileError {
            if case .missing = error { return UserData() }
            throw error
        }
    }

    static func decodeDocument(_ raw: Data, at url: URL) throws -> UserData {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw UserDataFileError.unreadable(path: url.path, reason: "malformed JSON")
        }
        guard let document = object as? [String: Any] else {
            throw UserDataFileError.unreadable(path: url.path, reason: "malformed JSON")
        }
        if document["version"] != nil {
            guard let version = integerValue(document["version"]) else {
                throw UserDataFileError.unreadable(path: url.path, reason: "malformed JSON")
            }
            if version > supportedVersion {
                throw UserDataFileError.unreadable(path: url.path, reason: "unknown newer version \(version)")
            }
        }
        do {
            return try JSONDecoder.userData.decode(UserData.self, from: raw)
        } catch {
            throw UserDataFileError.unreadable(path: url.path, reason: "malformed JSON")
        }
    }

    /// Writes `encoded` to `url` under an exclusive lock. The previous file, if any,
    /// is copied to `url` + `.bak` first. The new bytes land in a temp file in the
    /// same directory and then replace `url`.
    static func writeAtomically(_ encoded: Data, to url: URL) throws {
        try withLock(at: url) {
            do {
                _ = try read(from: url)
            } catch let error as UserDataFileError {
                if case .missing = error {
                    // A missing file is the only case replaced with new bytes.
                } else {
                    throw error
                }
            }
            try writeReplacing(encoded, to: url)
        }
    }

    /// Holds the exclusive lock for `body`. The directory is created first.
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw unreadableError(url, error)
        }
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            _ = FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        }
        let lock: FileHandle
        do {
            lock = try FileHandle(forUpdating: lockURL)
        } catch {
            throw unreadableError(url, error)
        }
        guard flock(lock.fileDescriptor, LOCK_EX) == 0 else { throw UserDataFileError.lockFailed(path: url.path) }
        defer { flock(lock.fileDescriptor, LOCK_UN); try? lock.close() }
        return try body()
    }

    /// Caller holds the lock.
    static func writeReplacing(_ encoded: Data, to url: URL) throws {
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
            throw UserDataFileError.replaceFailed(path: url.path)
        }
    }

    static func unreadableError(_ url: URL, _ error: Error) -> UserDataFileError {
        UserDataFileError.unreadable(path: url.path, reason: reasonText(for: error))
    }

    static func reasonText(for error: Error) -> String {
        let ns = error as NSError
        if isPermissionError(ns) { return "permission denied" }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, isPermissionError(underlying as NSError) {
            return "permission denied"
        }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission") || lower.contains("not permitted") { return "permission denied" }
        return text.isEmpty ? "unreadable" : text
    }

    static func isMissingError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == 260 || ns.code == 4) { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == 2 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isMissingError(underlying) }
        return false
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && (error.code == 1 || error.code == 13) { return true }
        if error.domain == NSCocoaErrorDomain && (error.code == 257 || error.code == 513) { return true }
        return false
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            if double.rounded() != double { return nil }
            return number.intValue
        }
        return nil
    }
}

/// Copies the pre-app-group container file into the group container once.
/// The original is deleted only after the copy's bytes match. A backup named
/// `UserData.json.premigration.bak` is kept beside the original and is never
/// overwritten. An unreadable original is left in place.
enum UserDataMigration {
    static func migrate(from legacy: URL, to destination: URL) throws {
        if legacy.standardizedFileURL.path == destination.standardizedFileURL.path { return }
        let manager = FileManager.default
        var legacyIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory), !legacyIsDirectory.boolValue else {
            return
        }
        if manager.fileExists(atPath: destination.path) { return }

        let original: Data
        do {
            original = try Data(contentsOf: legacy)
        } catch {
            throw UserDataFile.unreadableError(legacy, error)
        }
        let digest = SHA256Hex.hash(original)
        let backup = URL(fileURLWithPath: legacy.path + ".premigration.bak")
        if !manager.fileExists(atPath: backup.path) {
            try original.write(to: backup, options: .atomic)
            let saved = try Data(contentsOf: backup)
            guard saved == original, SHA256Hex.hash(saved) == digest else {
                try? manager.removeItem(at: backup)
                throw UserDataFileError.unreadable(path: legacy.path, reason: "premigration backup did not match the original")
            }
        }

        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".UserData.migrate.\(UUID().uuidString).tmp")
        try original.write(to: temp, options: .atomic)
        if rename(temp.path, destination.path) != 0 {
            try? manager.removeItem(at: temp)
            throw UserDataFileError.replaceFailed(path: destination.path)
        }
        let copied: Data
        do {
            copied = try Data(contentsOf: destination)
        } catch {
            try? manager.removeItem(at: destination)
            throw UserDataFile.unreadableError(destination, error)
        }
        guard copied == original, SHA256Hex.hash(copied) == digest else {
            try? manager.removeItem(at: destination)
            throw UserDataFileError.unreadable(path: destination.path, reason: "migrated copy did not match the original")
        }
        try manager.removeItem(at: legacy)
    }

    #if os(macOS)
    /// Sandbox container path used before the Mac app group. Not compiled for iOS.
    static func legacyContainerURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/\(PlanFileLocation.bundleIdentifier)/Data/Library/Application Support/UserData.json"
        )
    }

    static func migrateLegacyContainerIfNeeded(to destination: URL) {
        if let override = ProcessInfo.processInfo.environment["TERM_ORGANIZE_USER_DATA"], !override.isEmpty {
            return
        }
        try? migrate(from: legacyContainerURL(), to: destination)
    }
    #endif
}

/// Where `UserData.json` lives for the MCP process.
///
/// `TERM_ORGANIZE_USER_DATA` overrides the path. Tests set it and never touch a
/// real plans file. On macOS the override is also what skips the one-time move
/// out of the old sandbox container.
enum PlanFileLocation {
    static let bundleIdentifier = "com.alexchadwick.neuclasssearch"

    static func resolve() -> URL {
        if let override = ProcessInfo.processInfo.environment["TERM_ORGANIZE_USER_DATA"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return AppPaths.userDataURL
    }
}
