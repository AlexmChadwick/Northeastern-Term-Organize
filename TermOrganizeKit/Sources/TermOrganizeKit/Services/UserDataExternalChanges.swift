//
//  UserDataExternalChanges.swift
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

/// What the app remembered about `UserData.json` the last time it loaded or wrote it.
struct UserDataFileStamp: Equatable, Sendable {
    var mtime: Date?
    /// SHA-256 of the file bytes, lowercase hex.
    var hash: String
    /// Schedule id to revision. A missing revision is stored as 0.
    var revisions: [UUID: Int]

    /// A plan revision change counts. So does a new SHA-256. A new modification
    /// time with the same bytes does not: that is a timestamp touch. A new hash
    /// with the same modification time still counts, because two writes can share
    /// one timestamp tick.
    func differs(from baseline: UserDataFileStamp) -> Bool {
        if revisions != baseline.revisions { return true }
        return hash != baseline.hash
    }
}

struct UserDataFileSnapshot: Sendable {
    var data: UserData
    var stamp: UserDataFileStamp
}

struct UserDataSaveResolution: Sendable {
    var data: UserData
    var stamp: UserDataFileStamp
}

extension UserDataFile {
    /// Stamp for `data` and the bytes currently at `url`. A missing file stamps as
    /// empty bytes and a nil modification time.
    static func stamp(of data: UserData, at url: URL) -> UserDataFileStamp {
        let bytes = (try? Data(contentsOf: url)) ?? Data()
        return stamp(of: data, bytes: bytes, mtime: modificationDate(of: url))
    }

    /// The decoded file when its stamp differs from `baseline`. Nil when the file
    /// is missing, unreadable, or still the version described by `baseline`.
    static func snapshotIfChanged(at url: URL, since baseline: UserDataFileStamp) -> UserDataFileSnapshot? {
        guard let bytes = try? Data(contentsOf: url),
              let data = try? decodeDocument(bytes, at: url) else { return nil }
        let stamp = stamp(of: data, bytes: bytes, mtime: modificationDate(of: url))
        guard stamp.differs(from: baseline) else { return nil }
        return UserDataFileSnapshot(data: data, stamp: stamp)
    }

    /// Writes `local`, unless the file changed since `stamp`. Then plans edited on
    /// only one side are combined, and a plan edited on both sides keeps the file's
    /// version plus a copy of `local` named "<plan> (edited in app)". The read and
    /// the replace share the file lock, so a writer cannot land between them.
    /// A file that exists but cannot be read is not replaced.
    static func writeResolvingConflicts(
        local: UserData, loaded: UserData, baseline: UserDataFileStamp, to url: URL
    ) throws -> UserDataSaveResolution {
        try withLock(at: url) {
            let existing: UserData
            let diskBytes: Data
            do {
                existing = try read(from: url)
                diskBytes = try Data(contentsOf: url)
            } catch let error as UserDataFileError {
                guard case .missing = error else { throw error }
                let encoded = try JSONEncoder.userData.encode(local)
                try writeReplacing(encoded, to: url)
                return resolution(for: local, bytes: encoded, url: url)
            }
            let disk = existing
            let diskStamp = Self.stamp(of: disk, bytes: diskBytes, mtime: modificationDate(of: url))
            let merged: UserData
            if diskStamp.differs(from: baseline) {
                merged = UserDataPlanMerge.merging(baseline: loaded, disk: disk, local: local)
            } else {
                merged = local
            }
            let encoded = try JSONEncoder.userData.encode(merged)
            try writeReplacing(encoded, to: url)
            return resolution(for: merged, bytes: encoded, url: url)
        }
    }

    static func stamp(of data: UserData, bytes: Data, mtime: Date?) -> UserDataFileStamp {
        UserDataFileStamp(mtime: mtime, hash: SHA256Hex.hash(bytes), revisions: revisionMap(data.plans))
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func resolution(for data: UserData, bytes: Data, url: URL) -> UserDataSaveResolution {
        UserDataSaveResolution(
            data: data,
            stamp: stamp(of: data, bytes: bytes, mtime: modificationDate(of: url))
        )
    }

    private static func revisionMap(_ plans: [SchedulePlan]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for plan in plans { map[plan.id] = plan.revision ?? 0 }
        return map
    }
}

/// Combines an in-memory save with a `UserData.json` that changed after it was loaded.
enum UserDataPlanMerge {
    static let editedInAppSuffix = " (edited in app)"

    static func merging(baseline: UserData, disk: UserData, local: UserData) -> UserData {
        var result = disk
        result.preferences = pick(baseline.preferences, disk.preferences, local.preferences)
        result.saved = pick(baseline.saved, disk.saved, local.saved)
        result.recents = pick(baseline.recents, disk.recents, local.recents)
        result.watchlist = pick(baseline.watchlist, disk.watchlist, local.watchlist)
        result.searchHistory = pick(baseline.searchHistory, disk.searchHistory, local.searchHistory)
        result.degreePlans = pick(baseline.degreePlans, disk.degreePlans, local.degreePlans)
        result.plans = mergePlans(baseline: baseline.plans, disk: disk.plans, local: local.plans)
        return result
    }

    /// One MCP plan is every schedule that shares a `folderID`. A schedule with no
    /// folder is its own plan. Edits to different plans are combined. When both
    /// sides changed the same plan, the file's schedules stay and the in-memory
    /// schedules are appended as a new plan.
    private static func mergePlans(baseline: [SchedulePlan], disk: [SchedulePlan], local: [SchedulePlan]) -> [SchedulePlan] {
        let baseGroups = grouped(baseline)
        let diskGroups = grouped(disk)
        let localGroups = grouped(local)
        var keys: [UUID] = []
        var seen = Set<UUID>()
        for plan in disk + local {
            let key = planKey(plan)
            if seen.insert(key).inserted { keys.append(key) }
        }
        var output: [SchedulePlan] = []
        var copies: [SchedulePlan] = []
        var reserved = Set(disk.map(\.name) + local.map(\.name))
        for key in keys {
            let base = baseGroups[key] ?? []
            let onDisk = diskGroups[key] ?? []
            let inMemory = localGroups[key] ?? []
            let diskEdited = !samePlans(onDisk, base)
            let localEdited = !samePlans(inMemory, base)
            if diskEdited && localEdited && !samePlans(onDisk, inMemory) {
                output.append(contentsOf: onDisk)
                copies.append(contentsOf: copied(inMemory, reserved: &reserved))
            } else if diskEdited {
                output.append(contentsOf: onDisk)
            } else {
                output.append(contentsOf: inMemory)
            }
        }
        output.append(contentsOf: copies)
        clearCopyPrimaryFlags(in: &output, copyIDs: Set(copies.map(\.id)))
        return output
    }

    private static func planKey(_ plan: SchedulePlan) -> UUID { plan.folderID ?? plan.id }

    private static func grouped(_ plans: [SchedulePlan]) -> [UUID: [SchedulePlan]] {
        var groups: [UUID: [SchedulePlan]] = [:]
        for plan in plans { groups[planKey(plan), default: []].append(plan) }
        return groups
    }

    private static func samePlans(_ lhs: [SchedulePlan], _ rhs: [SchedulePlan]) -> Bool {
        lhs.count == rhs.count && Set(lhs) == Set(rhs)
    }

    private static func copied(_ plans: [SchedulePlan], reserved: inout Set<String>) -> [SchedulePlan] {
        guard !plans.isEmpty else { return [] }
        let folder: UUID? = (plans.count > 1 || plans.contains { $0.folderID != nil }) ? UUID() : nil
        return plans.map { plan in
            var copy = plan
            copy.id = UUID()
            copy.folderID = folder
            copy.name = uniqueName(for: plan.name, reserved: &reserved)
            copy.revision = 1
            return copy
        }
    }

    private static func uniqueName(for name: String, reserved: inout Set<String>) -> String {
        let base = name.hasSuffix(editedInAppSuffix) ? name : name + editedInAppSuffix
        if reserved.insert(base).inserted { return base }
        var number = 2
        while !reserved.insert("\(base) \(number)").inserted { number += 1 }
        return "\(base) \(number)"
    }

    /// The file's plan keeps "My Schedule" when it is still here. The copy stays
    /// primary only when that term no longer has one.
    private static func clearCopyPrimaryFlags(in plans: inout [SchedulePlan], copyIDs: Set<UUID>) {
        let terms = Set(plans.map(\.termCode))
        for term in terms {
            let keepsPrimary = plans.contains { $0.termCode == term && !copyIDs.contains($0.id) && $0.isPrimary }
            guard keepsPrimary else { continue }
            for index in plans.indices where plans[index].termCode == term && copyIDs.contains(plans[index].id) {
                plans[index].isPrimary = false
            }
        }
    }

    private static func pick<T: Equatable>(_ baseline: T, _ disk: T, _ local: T) -> T {
        if disk == baseline { return local }
        if local == baseline { return disk }
        return disk
    }
}

/// SHA-256 of the file bytes. No CryptoKit, so the Linux build and the app share it.
enum SHA256Hex {
    static func hash(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitCount = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitCount >> UInt64(shift)) & 0xff))
        }
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = chunk + index * 4
                w[index] = (UInt32(message[start]) << 24) | (UInt32(message[start + 1]) << 16)
                    | (UInt32(message[start + 2]) << 8) | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(w[index - 15], 7) ^ rotate(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotate(w[index - 2], 17) ^ rotate(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[index] &+ w[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for value in h {
            out.append(UInt8((value >> 24) & 0xff))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8(value & 0xff))
        }
        return out
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

/// Reports when `UserData.json` is replaced while the app is open.
///
/// On Apple platforms this is a DispatchSource vnode watch on the file. An atomic
/// rename delivers delete or rename for the old inode, and the watch is armed again
/// on the new file. A file that does not exist yet is waited for on its directory.
/// Linux libdispatch does not subscribe to create or move events on a directory, so
/// that build watches the directory with inotify and a DispatchSource read source.
final class UserDataFileWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "term-organize.userdata.watch")
    private var source: DispatchSourceProtocol?
    private var descriptor: Int32 = -1
    private var directoryDescriptor: Int32 = -1
    private var onChange: (@Sendable () -> Void)?
    private var pending: DispatchWorkItem?
    private var fileURL: URL?

    func start(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        self.fileURL = fileURL
        self.onChange = onChange
        arm()
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            // Cancel handlers close the descriptors.
            source?.cancel()
            source = nil
            directoryDescriptor = -1
            descriptor = -1
            onChange = nil
            fileURL = nil
        }
    }

    private func arm() {
        #if canImport(Darwin)
        armDarwin()
        #else
        armLinux()
        #endif
    }

    private func signal() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    #if canImport(Darwin)
    private func armDarwin() {
        guard let fileURL else { return }
        let flags = O_EVTONLY
        let fileDescriptor = open(fileURL.path, flags)
        if fileDescriptor >= 0 {
            watchDarwinFile(fileDescriptor)
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        let directoryFD = open(directory.path, flags)
        guard directoryFD >= 0 else { return }
        directoryDescriptor = directoryFD
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.promoteDarwinFileWatch()
        }
        source.setCancelHandler { close(directoryFD) }
        source.resume()
        self.source = source
    }

    private func watchDarwinFile(_ fileDescriptor: Int32) {
        descriptor = fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            self.signal()
            if events.contains(.delete) || events.contains(.rename) {
                self.rearmDarwinFile()
            }
        }
        source.setCancelHandler { close(fileDescriptor) }
        source.resume()
        self.source = source
    }

    private func promoteDarwinFileWatch() {
        guard let fileURL, directoryDescriptor >= 0 else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            signal()
            return
        }
        source?.cancel()
        source = nil
        directoryDescriptor = -1
        signal()
        armDarwin()
    }

    private func rearmDarwinFile() {
        source?.cancel()
        source = nil
        descriptor = -1
        armDarwin()
    }
    #else
    private func armLinux() {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        let fd = inotify_init1(Int32(IN_NONBLOCK))
        guard fd >= 0 else { return }
        let watch = inotify_add_watch(
            fd,
            directory.path,
            UInt32(IN_CREATE | IN_MODIFY | IN_MOVED_TO | IN_CLOSE_WRITE | IN_DELETE | IN_ATTRIB)
        )
        guard watch >= 0 else {
            close(fd)
            return
        }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainLinux(fd)
            self?.signal()
        }
        source.setCancelHandler {
            inotify_rm_watch(fd, watch)
            close(fd)
        }
        source.resume()
        self.source = source
    }

    private func drainLinux(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while read(fd, &buffer, buffer.count) > 0 {}
    }
    #endif
}
