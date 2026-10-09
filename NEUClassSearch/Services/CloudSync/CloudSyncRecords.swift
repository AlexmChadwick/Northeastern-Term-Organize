//
//  CloudSyncRecords.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Converts between CloudKit records and the sync model, and keeps the sync bookkeeping on
//  disk. The field names are part of the iCloud schema: don't rename them.
//

import CloudKit
import Foundation

enum CloudSyncRecords {
    enum Field {
        /// The value's JSON (`Data`), stored in CloudKit's end-to-end encrypted values.
        static let payload = "payload"
        /// When the value last changed (`Date`), for last-writer-wins.
        static let modifiedAt = "modifiedAt"
        /// Payload format (`Int`), see `CloudSyncConfig.schemaVersion`.
        static let schemaVersion = "schemaVersion"
    }

    /// The `UserData` zone in the user's private database.
    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: CloudSyncConfig.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    static var zone: CKRecordZone { CKRecordZone(zoneID: zoneID) }

    static func recordID(for key: CloudSyncKey) -> CKRecord.ID {
        CKRecord.ID(recordName: key.recordName, zoneID: zoneID)
    }

    /// The record to save for a local value. It starts from the last known iCloud copy's
    /// system fields, so CloudKit accepts it as an update rather than a conflicting new record.
    static func record(
        for key: CloudSyncKey,
        entity: CloudSyncEntity,
        state: CloudSyncRecordState?,
        preferenceChangedAt: [String: Date]
    ) -> CKRecord? {
        guard let payload = try? CloudSyncCoding.payload(for: entity, preferenceChangedAt: preferenceChangedAt) else { return nil }
        let recordID = recordID(for: key)
        var record = CKRecord(recordType: key.type.rawValue, recordID: recordID)
        if let fields = state?.systemFields, let known = decodeSystemFields(fields),
           known.recordID == recordID, known.recordType == key.type.rawValue {
            record = known
        }
        record.encryptedValues[Field.payload] = payload
        record[Field.modifiedAt] = CloudSyncCoding.modifiedAt(
            of: entity,
            localChangedAt: state?.localChangedAt,
            preferenceChangedAt: preferenceChangedAt
        )
        record[Field.schemaVersion] = CloudSyncConfig.schemaVersion
        return record
    }

    /// A fetched (or conflicting) record, if it belongs to this app's zone and record types.
    /// Records of types this build doesn't know (from a newer version) are ignored.
    static func incoming(from record: CKRecord) -> CloudSyncIncomingRecord? {
        guard record.recordID.zoneID == zoneID,
              let type = CloudSyncRecordType(rawValue: record.recordType) else { return nil }
        let encryptedPayload: Data? = record.encryptedValues[Field.payload]
        let plainPayload: Data? = record[Field.payload]
        let schemaVersion: Int? = record[Field.schemaVersion]
        let modifiedAt: Date? = record[Field.modifiedAt]
        return CloudSyncIncomingRecord(
            key: CloudSyncKey(type: type, recordName: record.recordID.recordName),
            schemaVersion: schemaVersion ?? 1,
            modifiedAt: modifiedAt ?? record.modificationDate ?? .distantPast,
            payload: encryptedPayload ?? plainPayload,
            systemFields: encodeSystemFields(of: record)
        )
    }

    /// The key of a record deleted in iCloud, if it's one of this app's.
    static func key(forDeleted recordID: CKRecord.ID, recordType: CKRecord.RecordType) -> CloudSyncKey? {
        guard recordID.zoneID == zoneID, let type = CloudSyncRecordType(rawValue: recordType) else { return nil }
        return CloudSyncKey(type: type, recordName: recordID.recordName)
    }

    /// Fingerprint of the payload in a record this device saved.
    static func fingerprint(of incoming: CloudSyncIncomingRecord) -> String? {
        guard let payload = incoming.payload,
              let value = try? CloudSyncCoding.decode(payload, as: incoming.key.type) else { return nil }
        return CloudSyncCoding.fingerprint(ofRemote: value)
    }

    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}

/// Sync bookkeeping on disk, in `Application Support/CloudSync/`: this app's metadata (record
/// fingerprints and system fields) and the sync engine's state serialization.
struct CloudSyncFiles {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? AppPaths.applicationSupport.appendingPathComponent("CloudSync", isDirectory: true)
    }

    private var metadataURL: URL { directory.appendingPathComponent("Metadata.json") }
    private var engineStateURL: URL { directory.appendingPathComponent("EngineState.json") }

    func loadMetadata() -> CloudSyncMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(CloudSyncMetadata.self, from: data)
    }

    func save(_ metadata: CloudSyncMetadata) {
        write(try? JSONEncoder().encode(metadata), to: metadataURL)
    }

    func loadEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: engineStateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    func saveEngineState(_ state: CKSyncEngine.State.Serialization) {
        write(try? JSONEncoder().encode(state), to: engineStateURL)
    }

    func deleteEngineState() {
        try? FileManager.default.removeItem(at: engineStateURL)
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
