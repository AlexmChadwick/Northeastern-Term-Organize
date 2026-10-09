//
//  CloudSyncState.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  iCloud sync, part 2: what this device knows about each record, which local changes still
//  have to be sent, and how fetched records merge into the local data. Pure logic, unit
//  tested in CloudSyncTests.
//
//  Change tracking compares fingerprints. For every record the metadata keeps the
//  fingerprint of the local value as last seen (with the time it changed) and of the copy
//  in iCloud as last sent or received. After each local save the store's synced values are
//  fingerprinted again: a value whose fingerprint differs from its iCloud copy is saved, an
//  iCloud copy whose local value is gone is deleted. Values received from iCloud get both
//  fingerprints set to the same value, so they are never sent back.
//
//  Conflicts are last writer wins by modification time (see `CloudSyncCoding.modifiedAt`),
//  ties going to iCloud so every device converges. Preferences merge field by field.
//

import Foundation

/// What this device knows about one record.
struct CloudSyncRecordState: Codable, Equatable, Sendable {
    /// Fingerprint of the local value when last seen; nil after it was deleted here.
    var localFingerprint: String?
    /// When the local value last changed here (for a deleted value, when it was deleted), or,
    /// for a value received from iCloud, when it changed on the device that sent it. Nil when
    /// unknown, e.g. for data that existed before sync did.
    var localChangedAt: Date?
    /// Fingerprint of the iCloud copy as last sent or received.
    var serverFingerprint: String?
    /// The iCloud copy's system fields (`CKRecord.encodeSystemFields(with:)`), which CloudKit
    /// needs to accept an update.
    var systemFields: Data?
    /// The iCloud copy was written by a newer version of the app, or can't be read. This
    /// device neither overwrites nor deletes it.
    var isServerCopyUnreadable = false

    init() {}

    /// Whether iCloud is known to hold a copy.
    var isKnownInICloud: Bool { serverFingerprint != nil || systemFields != nil || isServerCopyUnreadable }

    private enum CodingKeys: String, CodingKey {
        case localFingerprint, localChangedAt, serverFingerprint, systemFields, isServerCopyUnreadable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localFingerprint = try c.decodeIfPresent(String.self, forKey: .localFingerprint)
        localChangedAt = try c.decodeIfPresent(Date.self, forKey: .localChangedAt)
        serverFingerprint = try c.decodeIfPresent(String.self, forKey: .serverFingerprint)
        systemFields = try c.decodeIfPresent(Data.self, forKey: .systemFields)
        isServerCopyUnreadable = try c.decodeIfPresent(Bool.self, forKey: .isServerCopyUnreadable) ?? false
    }
}

/// Everything this device remembers about iCloud sync. Saved as JSON in
/// `Application Support/CloudSync/`, next to the sync engine's own state.
struct CloudSyncMetadata: Equatable, Sendable {
    var records: [CloudSyncKey: CloudSyncRecordState] = [:]
    /// False until the local data was first looked at. Values that existed before then have
    /// unknown change times, so their iCloud copies win conflicts.
    var hasObservedLocalData = false
    /// The synced preferences as last seen here.
    var observedPreferences: CloudSyncedPreferences?
    /// When each synced preference last changed (by field name).
    var preferenceChangedAt: [String: Date] = [:]
    /// The iCloud account (user record name) this device's data last synced with.
    var accountRecordName: String?
    /// Whether the `UserData` zone is known to exist in iCloud.
    var isZoneSaved = false
    /// When a fetch or send last finished without errors.
    var lastSyncDate: Date?

    init() {}

    /// Whether iCloud holds anything this device synced (erasing here would delete it there).
    var hasDataInICloud: Bool { records.values.contains { $0.isKnownInICloud } }

    /// The key of a known record (record names are unique across types).
    func key(forRecordName name: String) -> CloudSyncKey? {
        records.keys.first { $0.recordName == name }
    }

    /// Notes which synced values changed since the last look, and when. Run after every
    /// local change (it's cheap: a fingerprint per value).
    mutating func observeLocalData(_ snapshot: CloudSyncSnapshot, now: Date) {
        let isFirstLook = !hasObservedLocalData
        for (key, item) in snapshot.items {
            var state = records[key] ?? CloudSyncRecordState()
            guard state.localFingerprint != item.fingerprint else { continue }
            state.localFingerprint = item.fingerprint
            state.localChangedAt = isFirstLook ? nil : now
            records[key] = state
        }
        for (key, state) in records where snapshot[key] == nil && state.localFingerprint != nil {
            var deleted = state
            deleted.localFingerprint = nil
            deleted.localChangedAt = isFirstLook ? nil : now
            // Nothing to delete in iCloud for a value that never got there.
            records[key] = deleted.isKnownInICloud ? deleted : nil
        }

        let preferences = CloudSyncedPreferences(snapshot.preferences)
        if let observedPreferences, !isFirstLook {
            for field in preferences.fieldsDiffering(from: observedPreferences) {
                preferenceChangedAt[field.rawValue] = now
            }
        }
        observedPreferences = preferences
        hasObservedLocalData = true
    }

    /// Local values whose iCloud copy is missing or different (to save), and iCloud copies
    /// whose local value was deleted (to delete). Copies written by a newer version are left alone.
    func pendingChanges(for snapshot: CloudSyncSnapshot) -> CloudSyncPendingChanges {
        var changes = CloudSyncPendingChanges()
        for (key, item) in snapshot.items {
            let state = records[key]
            if state?.isServerCopyUnreadable == true { continue }
            if state?.serverFingerprint != item.fingerprint { changes.saves.append(key) }
        }
        for (key, state) in records where snapshot[key] == nil && state.isKnownInICloud && !state.isServerCopyUnreadable {
            changes.deletes.append(key)
        }
        changes.saves.sort()
        changes.deletes.sort()
        return changes
    }

    /// Forgets everything about iCloud (after a sign-out, an account switch, or when sync is
    /// turned off) but keeps the local change history, so a later merge still knows what
    /// changed when. The next sync starts over: it downloads iCloud's copies, merges them, and
    /// uploads what's only here.
    mutating func forgetICloud() {
        for (key, state) in records {
            var local = state
            local.serverFingerprint = nil
            local.systemFields = nil
            local.isServerCopyUnreadable = false
            records[key] = local.localFingerprint == nil ? nil : local
        }
        isZoneSaved = false
        lastSyncDate = nil
    }

    /// Notes that iCloud confirmed a save. `fingerprint` is that of the payload sent.
    mutating func recordSaved(_ key: CloudSyncKey, fingerprint: String?, systemFields: Data?) {
        var state = records[key] ?? CloudSyncRecordState()
        state.serverFingerprint = fingerprint
        state.systemFields = systemFields
        state.isServerCopyUnreadable = false
        records[key] = state
    }

    /// Notes that a record is gone from iCloud.
    mutating func recordDeletedFromICloud(_ key: CloudSyncKey) {
        guard var state = records[key] else { return }
        state.serverFingerprint = nil
        state.systemFields = nil
        state.isServerCopyUnreadable = false
        records[key] = state.localFingerprint == nil ? nil : state
    }
}

extension CloudSyncMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case records, hasObservedLocalData, observedPreferences, preferenceChangedAt
        case accountRecordName, isZoneSaved, lastSyncDate
    }

    private struct Entry: Codable {
        var key: CloudSyncKey
        var state: CloudSyncRecordState
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decodeIfPresent([Entry].self, forKey: .records) ?? []
        records = Dictionary(entries.map { ($0.key, $0.state) }, uniquingKeysWith: { first, _ in first })
        hasObservedLocalData = try c.decodeIfPresent(Bool.self, forKey: .hasObservedLocalData) ?? false
        observedPreferences = try c.decodeIfPresent(CloudSyncedPreferences.self, forKey: .observedPreferences)
        preferenceChangedAt = try c.decodeIfPresent([String: Date].self, forKey: .preferenceChangedAt) ?? [:]
        accountRecordName = try c.decodeIfPresent(String.self, forKey: .accountRecordName)
        isZoneSaved = try c.decodeIfPresent(Bool.self, forKey: .isZoneSaved) ?? false
        lastSyncDate = try c.decodeIfPresent(Date.self, forKey: .lastSyncDate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let entries = records.sorted { $0.key < $1.key }.map { Entry(key: $0.key, state: $0.value) }
        try c.encode(entries, forKey: .records)
        try c.encode(hasObservedLocalData, forKey: .hasObservedLocalData)
        try c.encodeIfPresent(observedPreferences, forKey: .observedPreferences)
        try c.encode(preferenceChangedAt, forKey: .preferenceChangedAt)
        try c.encodeIfPresent(accountRecordName, forKey: .accountRecordName)
        try c.encode(isZoneSaved, forKey: .isZoneSaved)
        try c.encodeIfPresent(lastSyncDate, forKey: .lastSyncDate)
    }
}

/// Records to save to and delete from iCloud.
struct CloudSyncPendingChanges: Equatable, Sendable {
    var saves: [CloudSyncKey] = []
    var deletes: [CloudSyncKey] = []

    var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
}

// MARK: - Merging fetched records

/// A record fetched from iCloud (or returned with a save conflict), reduced to what merging needs.
struct CloudSyncIncomingRecord: Sendable {
    var key: CloudSyncKey
    /// Missing in a record means version 1.
    var schemaVersion: Int
    var modifiedAt: Date
    var payload: Data?
    /// The record's system fields, kept for the next update.
    var systemFields: Data?
}

/// How to change the local store after merging fetched records.
struct CloudSyncMergeResult: Equatable, Sendable {
    /// Values to write; each replaces the local value with the same id, or is added.
    var saves: [CloudSyncEntity] = []
    /// Values to remove.
    var deletes: [CloudSyncKey] = []
    /// Local values kept over the iCloud copy because they changed more recently (or were
    /// edited here while deleted elsewhere). They are sent again.
    var keptLocal: [CloudSyncKey] = []
    /// iCloud copies left alone because a newer version wrote them or they can't be read.
    var skipped: [CloudSyncKey] = []

    var changesLocalData: Bool { !saves.isEmpty || !deletes.isEmpty }
}

enum CloudSyncMerge {
    /// Merges fetched records into the local data.
    ///
    /// - A value that changed only in iCloud replaces the local one; one that changed on both
    ///   sides goes to the newer change (ties to iCloud).
    /// - A value deleted in iCloud is deleted here, unless it changed here since it was last
    ///   synced; then it's kept and uploaded again.
    /// - A value deleted here after the iCloud copy was written stays deleted.
    /// - Records from a newer version of the app, or that can't be decoded, are skipped and
    ///   never deleted or overwritten. Nothing here traps on bad input.
    /// - Device-only data survives: degree plans keep their student name and ID, watched
    ///   sections keep this device's seat numbers, preferences keep their device-only fields.
    ///
    /// Updates `metadata` so that values taken from iCloud aren't sent back.
    static func merge(
        modifications: [CloudSyncIncomingRecord],
        deletions: [CloudSyncKey],
        into snapshot: CloudSyncSnapshot,
        metadata: inout CloudSyncMetadata,
        now: Date = .now
    ) -> CloudSyncMergeResult {
        var working = Working(snapshot: snapshot)
        var result = CloudSyncMergeResult()
        var applied: [CloudSyncKey] = []

        for record in modifications {
            let key = record.key
            var state = metadata.records[key] ?? CloudSyncRecordState()
            let wasKnownInICloud = state.isKnownInICloud
            let previousServerFingerprint = state.serverFingerprint

            guard record.schemaVersion <= CloudSyncConfig.schemaVersion,
                  let payload = record.payload,
                  let remote = try? CloudSyncCoding.decode(payload, as: key.type),
                  remote.key == key else {
                state.isServerCopyUnreadable = true
                state.systemFields = record.systemFields
                metadata.records[key] = state
                result.skipped.append(key)
                continue
            }
            let remoteFingerprint = CloudSyncCoding.fingerprint(ofRemote: remote)
            state.isServerCopyUnreadable = false
            state.systemFields = record.systemFields
            state.serverFingerprint = remoteFingerprint

            if case .preferences(let values, let changedAt) = remote {
                let local = CloudSyncedPreferences(working.preferences)
                let merged = CloudSyncedPreferences.merge(
                    local: local, localChangedAt: metadata.preferenceChangedAt,
                    remote: values, remoteChangedAt: changedAt
                )
                if merged.values != local {
                    working.write(.preferences(merged.values.applied(to: working.preferences)))
                }
                metadata.preferenceChangedAt = merged.changedAt
                metadata.observedPreferences = merged.values
                state.localFingerprint = CloudSyncCoding.fingerprint(of: .preferences(working.preferences))
                state.localChangedAt = merged.changedAt.values.max()
                metadata.records[key] = state
                if merged.values != values { result.keptLocal.append(key) }
                continue
            }

            guard let current = working.local[key] else {
                if wasKnownInICloud, state.localFingerprint == nil,
                   let deletedAt = state.localChangedAt, deletedAt > record.modifiedAt {
                    // Deleted here after this copy was written: the deletion stands and is sent.
                    metadata.records[key] = state
                    result.keptLocal.append(key)
                    continue
                }
                let value = localValue(for: remote, replacing: nil)
                working.write(value)
                state.localFingerprint = CloudSyncCoding.fingerprint(of: value)
                state.localChangedAt = record.modifiedAt
                metadata.records[key] = state
                applied.append(key)
                continue
            }

            let localFingerprint = CloudSyncCoding.fingerprint(of: current)
            if localFingerprint == remoteFingerprint {
                state.localFingerprint = localFingerprint
                metadata.records[key] = state
                continue
            }
            if previousServerFingerprint != localFingerprint {
                // Changed here too: the newer change wins, ties go to iCloud.
                let localTime = CloudSyncCoding.modifiedAt(of: current, localChangedAt: state.localChangedAt)
                if localTime > record.modifiedAt {
                    metadata.records[key] = state
                    result.keptLocal.append(key)
                    continue
                }
            }
            let value = localValue(for: remote, replacing: current)
            working.write(value)
            state.localFingerprint = CloudSyncCoding.fingerprint(of: value)
            state.localChangedAt = record.modifiedAt
            metadata.records[key] = state
            applied.append(key)
        }

        for key in deletions {
            let state = metadata.records[key]
            if key.type == .preferences {
                // Preferences always exist here: keep them and send them again.
                var kept = state ?? CloudSyncRecordState()
                kept.serverFingerprint = nil
                kept.systemFields = nil
                kept.isServerCopyUnreadable = false
                metadata.records[key] = kept
                result.keptLocal.append(key)
                continue
            }
            guard let current = working.local[key] else {
                metadata.records[key] = nil
                continue
            }
            let localFingerprint = CloudSyncCoding.fingerprint(of: current)
            if let state, state.serverFingerprint == localFingerprint {
                working.delete(key)
                metadata.records[key] = nil
            } else {
                // Changed here since it was last synced, or never synced: keep it and upload it again.
                var kept = state ?? CloudSyncRecordState()
                kept.serverFingerprint = nil
                kept.systemFields = nil
                kept.isServerCopyUnreadable = false
                kept.localFingerprint = localFingerprint
                metadata.records[key] = kept
                result.keptLocal.append(key)
            }
        }

        normalizePrimaries(after: applied, in: &working, metadata: &metadata, now: now)

        result.saves = working.written.values.sorted { $0.key < $1.key }
        result.deletes = working.deleted.sorted()
        return result
    }

    /// The value to store for a fetched value, keeping what stays on this device.
    static func localValue(for remote: CloudSyncRemoteValue, replacing current: CloudSyncEntity?) -> CloudSyncEntity {
        switch remote {
        case .schedulePlan(let plan):
            return .schedulePlan(plan)
        case .degreePlan(var plan):
            if case .degreePlan(let local)? = current {
                plan.studentName = local.studentName
                plan.studentID = local.studentID
            }
            return .degreePlan(plan)
        case .watchItem(var item):
            if case .watchItem(let local)? = current {
                item.lastSeatsRemaining = local.lastSeatsRemaining
                item.lastWaitlistRemaining = local.lastWaitlistRemaining
                item.seatCapacity = local.seatCapacity
                item.lastCheckedAt = local.lastCheckedAt
                item.lastNotifiedAt = local.lastNotifiedAt
            }
            return .watchItem(item)
        case .savedCourse(let course):
            return .savedCourse(course)
        case .preferences(let values, _):
            var base = AppPreferences()
            if case .preferences(let local)? = current { base = local }
            return .preferences(values.applied(to: base))
        }
    }

    /// A plan made primary on another device can meet a different primary plan here (for the
    /// same term, or any degree plan). The more recently changed one stays primary (ties by
    /// record name, so every device picks the same one) and the others are demoted here;
    /// the demotion is a local change and gets sent.
    private static func normalizePrimaries(
        after applied: [CloudSyncKey],
        in working: inout Working,
        metadata: inout CloudSyncMetadata,
        now: Date
    ) {
        func rank(_ key: CloudSyncKey, _ entity: CloudSyncEntity) -> (Date, String) {
            (CloudSyncCoding.modifiedAt(of: entity, localChangedAt: metadata.records[key]?.localChangedAt), key.recordName)
        }
        func demote(_ key: CloudSyncKey, to value: CloudSyncEntity) {
            working.write(value)
            var state = metadata.records[key] ?? CloudSyncRecordState()
            state.localFingerprint = CloudSyncCoding.fingerprint(of: value)
            state.localChangedAt = now
            metadata.records[key] = state
        }

        var terms = Set<String>()
        var touchesDegreePlans = false
        for key in applied {
            switch working.local[key] {
            case .schedulePlan(let plan)?: terms.insert(plan.termCode)
            case .degreePlan?: touchesDegreePlans = true
            default: break
            }
        }

        for term in terms.sorted() {
            let primaries = working.local.filter { _, entity in
                if case .schedulePlan(let plan) = entity { return plan.termCode == term && plan.isPrimary }
                return false
            }
            guard primaries.count > 1,
                  let keep = primaries.max(by: { rank($0.key, $0.value) < rank($1.key, $1.value) })?.key else { continue }
            for (key, entity) in primaries where key != keep {
                guard case .schedulePlan(var plan) = entity else { continue }
                plan.isPrimary = false
                demote(key, to: .schedulePlan(plan))
            }
        }

        if touchesDegreePlans {
            let primaries = working.local.filter { _, entity in
                if case .degreePlan(let plan) = entity { return plan.isPrimary }
                return false
            }
            if primaries.count > 1,
               let keep = primaries.max(by: { rank($0.key, $0.value) < rank($1.key, $1.value) })?.key {
                for (key, entity) in primaries where key != keep {
                    guard case .degreePlan(var plan) = entity else { continue }
                    plan.isPrimary = false
                    demote(key, to: .degreePlan(plan))
                }
            }
        }
    }

    /// The local values while a batch is merged.
    private struct Working {
        var local: [CloudSyncKey: CloudSyncEntity]
        var preferences: AppPreferences
        var written: [CloudSyncKey: CloudSyncEntity] = [:]
        var deleted: Set<CloudSyncKey> = []

        init(snapshot: CloudSyncSnapshot) {
            local = snapshot.items.mapValues { $0.entity }
            preferences = snapshot.preferences
        }

        mutating func write(_ entity: CloudSyncEntity) {
            let key = entity.key
            local[key] = entity
            written[key] = entity
            deleted.remove(key)
            if case .preferences(let preferences) = entity { self.preferences = preferences }
        }

        mutating func delete(_ key: CloudSyncKey) {
            local[key] = nil
            written[key] = nil
            deleted.insert(key)
        }
    }
}

// MARK: - Applying to the local data

extension UserData {
    /// A copy with fetched values written (replacing the value with the same id, or added in
    /// date order) and deleted values removed.
    func applyingCloudChanges(saves: [CloudSyncEntity], deletes: [CloudSyncKey]) -> UserData {
        var data = self
        if !deletes.isEmpty {
            let removed = Set(deletes)
            data.plans.removeAll { removed.contains(CloudSyncEntity.schedulePlan($0).key) }
            data.degreePlans.removeAll { removed.contains(CloudSyncEntity.degreePlan($0).key) }
            data.watchlist.removeAll { removed.contains(CloudSyncEntity.watchItem($0).key) }
            data.saved.removeAll { removed.contains(CloudSyncEntity.savedCourse($0).key) }
        }
        for entity in saves {
            switch entity {
            case .schedulePlan(let plan):
                if let index = data.plans.firstIndex(where: { $0.id == plan.id }) {
                    data.plans[index] = plan
                } else {
                    data.plans.append(plan)
                }
            case .degreePlan(let plan):
                if let index = data.degreePlans.firstIndex(where: { $0.id == plan.id }) {
                    data.degreePlans[index] = plan
                } else {
                    data.degreePlans.append(plan)
                }
            case .watchItem(let item):
                if let index = data.watchlist.firstIndex(where: { $0.id == item.id }) {
                    data.watchlist[index] = item
                } else {
                    // The watchlist is newest first.
                    let index = data.watchlist.firstIndex { $0.addedAt < item.addedAt } ?? data.watchlist.endIndex
                    data.watchlist.insert(item, at: index)
                }
            case .savedCourse(let course):
                if let index = data.saved.firstIndex(where: { $0.id == course.id }) {
                    data.saved[index] = course
                } else {
                    let index = data.saved.firstIndex { $0.savedAt < course.savedAt } ?? data.saved.endIndex
                    data.saved.insert(course, at: index)
                }
            case .preferences(let preferences):
                data.preferences = preferences
            }
        }
        return data
    }
}
