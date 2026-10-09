//
//  CloudSyncModel.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  iCloud sync, part 1: what syncs, and how each value becomes a record payload and a
//  fingerprint. Nothing here touches CloudKit, so all of it is unit tested (CloudSyncTests).
//
//  Every synced value is one record in the `UserData` zone of the user's private
//  CloudKit database. The record name is the value's stable id and the record carries
//  three fields: `payload` (the value's JSON, end-to-end encrypted), `modifiedAt` and
//  `schemaVersion`.
//
//  What syncs: schedule plans, degree plans (without the student name and ID from an
//  imported audit), the watchlist (without each device's seat-check results), saved
//  courses, and the preferences in `CloudSyncedPreferences`. Recent courses and search
//  history stay on the device.
//

import CryptoKit
import Foundation

/// Build-level iCloud sync settings.
enum CloudSyncConfig {
    /// Info.plist key with the CloudKit container identifier. A build without it never
    /// touches CloudKit, and Settings says sync isn't set up in this build.
    static let containerInfoKey = "NEUCloudKitContainerIdentifier"

    /// Custom zone in the private database that holds every record.
    static let zoneName = "UserData"

    /// The payload format this build writes and reads. A record with a higher version was
    /// written by a newer version of the app, and this build leaves it alone rather than
    /// overwrite data it doesn't understand. Bump it whenever an older build would lose
    /// information by rewriting a record.
    static let schemaVersion = 1

    /// The container identifier from Info.plist, if this build is set up for iCloud.
    static func containerIdentifier(in bundle: Bundle = .main) -> String? {
        containerIdentifier(from: bundle.object(forInfoDictionaryKey: containerInfoKey))
    }

    /// A usable container identifier (`iCloud.…`) from an Info.plist value, or nil.
    static func containerIdentifier(from value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "$(…)" would be a build setting that was never filled in.
        guard identifier.hasPrefix("iCloud."), identifier.count > "iCloud.".count, !identifier.contains("$(") else { return nil }
        return identifier
    }
}

/// A kind of synced record. The raw value is the CloudKit record type.
enum CloudSyncRecordType: String, CaseIterable, Codable, Sendable {
    case schedulePlan = "SchedulePlan"
    case degreePlan = "DegreePlan"
    case watchItem = "WatchItem"
    case savedCourse = "SavedCourse"
    case preferences = "Preferences"
}

/// One synced record: its type and its CloudKit record name.
struct CloudSyncKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    var type: CloudSyncRecordType
    var recordName: String

    init(type: CloudSyncRecordType, recordName: String) {
        self.type = type
        self.recordName = recordName
    }

    /// The key of a value with the given stable id.
    init(type: CloudSyncRecordType, id: String) {
        self.init(type: type, recordName: Self.recordName(forID: id))
    }

    /// The single preferences record.
    static let preferences = CloudSyncKey(type: .preferences, recordName: "preferences")

    var description: String { "\(type.rawValue) \(recordName)" }

    static func < (lhs: CloudSyncKey, rhs: CloudSyncKey) -> Bool {
        (lhs.type.rawValue, lhs.recordName) < (rhs.type.rawValue, rhs.recordName)
    }

    /// The record name for a stable id: the id itself.
    ///
    /// CloudKit record names must be 1–255 printable ASCII characters that don't start with
    /// an underscore. Every id the app makes qualifies (UUIDs for plans, `202710|CS 3000` for
    /// saved courses, `202710|12345` for watched sections), and the formats can't collide
    /// across types. Anything else gets a stable digest instead.
    static func recordName(forID id: String) -> String {
        let usable = !id.isEmpty
            && id.utf8.count <= 255
            && !id.hasPrefix("_")
            && id.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        if usable { return id }
        return "sha256-" + CloudSyncCoding.hexDigest(of: Data(id.utf8))
    }
}

/// A value from the local store that syncs as one record.
enum CloudSyncEntity: Hashable, Sendable {
    case schedulePlan(SchedulePlan)
    case degreePlan(DegreePlan)
    case watchItem(WatchItem)
    case savedCourse(SavedCourse)
    /// All preferences; only the `CloudSyncedPreferences` part leaves the device.
    case preferences(AppPreferences)

    var key: CloudSyncKey {
        switch self {
        case .schedulePlan(let plan): CloudSyncKey(type: .schedulePlan, id: plan.id.uuidString)
        case .degreePlan(let plan): CloudSyncKey(type: .degreePlan, id: plan.id.uuidString)
        case .watchItem(let item): CloudSyncKey(type: .watchItem, id: item.id)
        case .savedCourse(let course): CloudSyncKey(type: .savedCourse, id: course.id)
        case .preferences: .preferences
        }
    }
}

/// A value decoded from a record's payload.
enum CloudSyncRemoteValue: Hashable, Sendable {
    case schedulePlan(SchedulePlan)
    case degreePlan(DegreePlan)
    case watchItem(WatchItem)
    case savedCourse(SavedCourse)
    /// The synced preferences and when each field last changed (keyed by field name;
    /// a missing entry means "unknown").
    case preferences(CloudSyncedPreferences, changedAt: [String: Date])

    var key: CloudSyncKey {
        switch self {
        case .schedulePlan(let plan): CloudSyncEntity.schedulePlan(plan).key
        case .degreePlan(let plan): CloudSyncEntity.degreePlan(plan).key
        case .watchItem(let item): CloudSyncEntity.watchItem(item).key
        case .savedCourse(let course): CloudSyncEntity.savedCourse(course).key
        case .preferences: .preferences
        }
    }
}

// MARK: - Preferences

/// The preferences that follow the user to their other devices: how they plan (preferred
/// campus, calendar weekends and hours).
///
/// The rest of `AppPreferences` describes this device and never leaves it: the term being
/// browsed (`selectedTermCode`), whether onboarding ran here (`hasCompletedOnboarding`) and
/// what the device fetches on its own (`autoRefreshSeats`, `backgroundRefreshEnabled`, which
/// also schedules this device's background checks).
///
/// Fields are merged one by one, newest change first, so changing the campus on one device
/// and the calendar hours on another keeps both. A field added later must treat a missing
/// value as "not sent" and keep the local one, because older versions don't send it.
struct CloudSyncedPreferences: Codable, Hashable, Sendable {
    var preferredCampus: String?
    var showWeekends: Bool
    var calendarStartHour: Int
    var calendarEndHour: Int

    enum Field: String, CaseIterable, Sendable {
        case preferredCampus, showWeekends, calendarStartHour, calendarEndHour
    }

    init(_ preferences: AppPreferences) {
        preferredCampus = preferences.preferredCampus
        showWeekends = preferences.showWeekends
        calendarStartHour = preferences.calendarStartHour
        calendarEndHour = preferences.calendarEndHour
    }

    /// Tolerant decoding: missing or invalid values fall back to the defaults.
    init(from decoder: Decoder) throws {
        let defaults = CloudSyncedPreferences(AppPreferences())
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredCampus = (try? c.decodeIfPresent(String.self, forKey: .preferredCampus)) ?? nil
        showWeekends = (try? c.decodeIfPresent(Bool.self, forKey: .showWeekends)) ?? defaults.showWeekends
        let start = (try? c.decodeIfPresent(Int.self, forKey: .calendarStartHour)) ?? defaults.calendarStartHour
        let end = (try? c.decodeIfPresent(Int.self, forKey: .calendarEndHour)) ?? defaults.calendarEndHour
        // Settings' steppers rely on 0 ≤ start < end ≤ 24.
        if (0...23).contains(start), (1...24).contains(end), start < end {
            calendarStartHour = start
            calendarEndHour = end
        } else {
            calendarStartHour = defaults.calendarStartHour
            calendarEndHour = defaults.calendarEndHour
        }
    }

    /// `preferences` with these values; the device-only fields are kept.
    func applied(to preferences: AppPreferences) -> AppPreferences {
        var result = preferences
        result.preferredCampus = preferredCampus
        result.showWeekends = showWeekends
        result.calendarStartHour = calendarStartHour
        result.calendarEndHour = calendarEndHour
        return result
    }

    /// Fields whose values differ from `other`.
    func fieldsDiffering(from other: CloudSyncedPreferences) -> [Field] {
        Field.allCases.filter { field in
            switch field {
            case .preferredCampus: preferredCampus != other.preferredCampus
            case .showWeekends: showWeekends != other.showWeekends
            case .calendarStartHour: calendarStartHour != other.calendarStartHour
            case .calendarEndHour: calendarEndHour != other.calendarEndHour
            }
        }
    }

    /// A copy with one field taken from `other`.
    func copying(_ field: Field, from other: CloudSyncedPreferences) -> CloudSyncedPreferences {
        var result = self
        switch field {
        case .preferredCampus: result.preferredCampus = other.preferredCampus
        case .showWeekends: result.showWeekends = other.showWeekends
        case .calendarStartHour: result.calendarStartHour = other.calendarStartHour
        case .calendarEndHour: result.calendarEndHour = other.calendarEndHour
        }
        return result
    }

    /// The result of merging two copies field by field.
    struct Merge: Equatable, Sendable {
        var values: CloudSyncedPreferences
        var changedAt: [String: Date]
    }

    /// Field-by-field last-writer-wins. A local field wins when it changed more recently than
    /// the server's, or when only the local change time is known. Ties go to the server copy,
    /// so every device settles on the same values. When neither time is known (values set
    /// before sync existed), a customized value beats a default one, so a new device never
    /// resets settings chosen on another.
    static func merge(
        local: CloudSyncedPreferences,
        localChangedAt: [String: Date],
        remote: CloudSyncedPreferences,
        remoteChangedAt: [String: Date]
    ) -> Merge {
        let defaults = CloudSyncedPreferences(AppPreferences())
        var values = remote
        var changedAt = remoteChangedAt
        for field in Field.allCases {
            let name = field.rawValue
            let localWins: Bool
            switch (localChangedAt[name], remoteChangedAt[name]) {
            case let (localTime?, remoteTime?):
                localWins = localTime > remoteTime
            case (.some, nil):
                localWins = true
            case (nil, .some):
                localWins = false
            case (nil, nil):
                let localIsDefault = !local.fieldsDiffering(from: defaults).contains(field)
                let remoteIsDefault = !remote.fieldsDiffering(from: defaults).contains(field)
                localWins = remoteIsDefault && !localIsDefault
            }
            guard localWins else { continue }
            values = values.copying(field, from: local)
            if let localTime = localChangedAt[name] { changedAt[name] = localTime }
        }
        return Merge(values: values, changedAt: changedAt)
    }
}

/// The JSON a Preferences record carries.
struct CloudSyncPreferencesPayload: Codable, Hashable, Sendable {
    var values: CloudSyncedPreferences
    /// When each field last changed on the device that wrote it, by field name.
    var changedAt: [String: Date]

    init(values: CloudSyncedPreferences, changedAt: [String: Date]) {
        self.values = values
        self.changedAt = changedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decode(CloudSyncedPreferences.self, forKey: .values)
        changedAt = (try? c.decodeIfPresent([String: Date].self, forKey: .changedAt)) ?? [:]
    }
}

// MARK: - Coding

/// Turns values into record payloads and back, and fingerprints them for change tracking.
enum CloudSyncCoding {
    enum PayloadError: Error, Equatable {
        /// The payload decoded, but to a value with a different id than the record's name.
        case mismatchedRecord
    }

    /// Payload keys whose arrays were encoded from a `Set`. `Set` iteration order changes
    /// from one launch to the next, so these are sorted to keep fingerprints stable.
    static let unorderedArrayKeys: Set<String> = ["excludedCRNs"]

    /// The JSON a record carries for `entity`.
    static func payload(for entity: CloudSyncEntity, preferenceChangedAt: [String: Date] = [:]) throws -> Data {
        switch entity {
        case .schedulePlan(let plan):
            try canonicalJSON(plan)
        case .degreePlan(let plan):
            try canonicalJSON(syncedForm(of: plan))
        case .watchItem(let item):
            try canonicalJSON(item)
        case .savedCourse(let course):
            try canonicalJSON(course)
        case .preferences(let preferences):
            try canonicalJSON(CloudSyncPreferencesPayload(values: CloudSyncedPreferences(preferences), changedAt: preferenceChangedAt))
        }
    }

    /// Decodes a payload written for a record of `type`. Throws for JSON this build can't read.
    static func decode(_ payload: Data, as type: CloudSyncRecordType) throws -> CloudSyncRemoteValue {
        let decoder = JSONDecoder.userData
        switch type {
        case .schedulePlan:
            return .schedulePlan(try decoder.decode(SchedulePlan.self, from: payload))
        case .degreePlan:
            return .degreePlan(syncedForm(of: try decoder.decode(DegreePlan.self, from: payload)))
        case .watchItem:
            return .watchItem(try decoder.decode(WatchItem.self, from: payload))
        case .savedCourse:
            return .savedCourse(try decoder.decode(SavedCourse.self, from: payload))
        case .preferences:
            let decoded = try decoder.decode(CloudSyncPreferencesPayload.self, from: payload)
            return .preferences(decoded.values, changedAt: decoded.changedAt)
        }
    }

    /// Fingerprint of the part of a local value that syncs. Two values with the same
    /// fingerprint need no upload; a value whose fingerprint changed does.
    static func fingerprint(of entity: CloudSyncEntity) -> String {
        switch entity {
        case .schedulePlan(let plan): fingerprint(plan)
        case .degreePlan(let plan): fingerprint(syncedForm(of: plan))
        case .watchItem(let item): fingerprint(trackedForm(of: item))
        case .savedCourse(let course): fingerprint(course)
        case .preferences(let preferences): fingerprint(CloudSyncedPreferences(preferences))
        }
    }

    /// Fingerprint of a decoded value, comparable with `fingerprint(of:)` for local values.
    static func fingerprint(ofRemote value: CloudSyncRemoteValue) -> String {
        switch value {
        case .schedulePlan(let plan): fingerprint(plan)
        case .degreePlan(let plan): fingerprint(syncedForm(of: plan))
        case .watchItem(let item): fingerprint(trackedForm(of: item))
        case .savedCourse(let course): fingerprint(course)
        case .preferences(let values, _): fingerprint(values)
        }
    }

    /// The time a local value counts as written, for last-writer-wins: the value's own
    /// `updatedAt` where it has one (or when it last changed here, if later, because making a
    /// plan primary doesn't touch `updatedAt`), otherwise when it last changed here, falling
    /// back to when it was created.
    static func modifiedAt(
        of entity: CloudSyncEntity,
        localChangedAt: Date?,
        preferenceChangedAt: [String: Date] = [:]
    ) -> Date {
        switch entity {
        case .schedulePlan(let plan): max(plan.updatedAt, localChangedAt ?? .distantPast)
        case .degreePlan(let plan): max(plan.updatedAt, localChangedAt ?? .distantPast)
        case .watchItem(let item): localChangedAt ?? item.addedAt
        case .savedCourse(let course): localChangedAt ?? course.savedAt
        case .preferences: preferenceChangedAt.values.max() ?? localChangedAt ?? .distantPast
        }
    }

    // MARK: Synced forms

    /// A degree plan as it syncs: the student name and ID from an imported audit stay on the
    /// device that imported it.
    static func syncedForm(of plan: DegreePlan) -> DegreePlan {
        var plan = plan
        plan.studentName = nil
        plan.studentID = nil
        return plan
    }

    /// The part of a watch item that tracks the user's intent. Seat numbers and check times
    /// are each device's own results: the payload carries them so a new device starts from
    /// sensible numbers, but changes to them alone aren't uploaded.
    static func trackedForm(of item: WatchItem) -> WatchItem {
        var item = item
        item.lastSeatsRemaining = 0
        item.lastWaitlistRemaining = 0
        item.seatCapacity = 0
        item.lastCheckedAt = nil
        item.lastNotifiedAt = nil
        return item
    }

    // MARK: Canonical JSON

    /// Deterministic JSON: sorted keys, ISO 8601 dates (the same precision as the local file,
    /// so a value fingerprints the same after a relaunch) and `Set`-backed arrays sorted.
    static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        return try JSONSerialization.data(
            withJSONObject: sortingUnorderedArrays(in: object),
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    private static func sortingUnorderedArrays(in value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dictionary {
                if unorderedArrayKeys.contains(key), let strings = child as? [String] {
                    result[key] = strings.sorted()
                } else {
                    result[key] = sortingUnorderedArrays(in: child)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { sortingUnorderedArrays(in: $0) }
        }
        return value
    }

    private static func fingerprint<Value: Encodable>(_ value: Value) -> String {
        // Encoding plain model values can't fail; the fallback just keeps the type total.
        guard let json = try? canonicalJSON(value) else { return "unencodable" }
        return hexDigest(of: json)
    }

    static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Snapshot

/// The synced values in the store at one moment, with their fingerprints.
struct CloudSyncSnapshot: Sendable {
    struct Item: Sendable {
        var entity: CloudSyncEntity
        var fingerprint: String
    }

    private(set) var items: [CloudSyncKey: Item] = [:]
    private var keysByRecordName: [String: CloudSyncKey] = [:]
    /// All local preferences, including the device-only ones.
    let preferences: AppPreferences

    init(_ data: UserData) {
        preferences = data.preferences
        add(.preferences(data.preferences))
        for plan in data.plans { add(.schedulePlan(plan)) }
        for plan in data.degreePlans { add(.degreePlan(plan)) }
        for item in data.watchlist { add(.watchItem(item)) }
        for course in data.saved { add(.savedCourse(course)) }
    }

    subscript(key: CloudSyncKey) -> Item? { items[key] }

    /// The key of the local value with a record name (record names are unique across types).
    func key(forRecordName name: String) -> CloudSyncKey? { keysByRecordName[name] }

    private mutating func add(_ entity: CloudSyncEntity) {
        let key = entity.key
        // The store never holds two values with one id; if it ever did, the first wins.
        guard items[key] == nil else { return }
        items[key] = Item(entity: entity, fingerprint: CloudSyncCoding.fingerprint(of: entity))
        keysByRecordName[key.recordName] = key
    }
}
