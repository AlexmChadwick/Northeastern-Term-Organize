//
//  CloudSyncTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The pure parts of iCloud sync: payloads, fingerprints, change tracking, merging and
//  conflicts, applying changes, status text and the entitlement check. Nothing here
//  touches CloudKit.
//

import Foundation
import Testing
@testable import NEUClassSearch

struct CloudSyncTests {
    // MARK: Fixtures

    /// Whole seconds, so values survive the ISO 8601 round trip unchanged.
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let container = "iCloud.com.alexchadwick.neuclasssearch"
    static let cs3000 = CourseKey(subject: "CS", number: "3000")
    static let cs3500 = CourseKey(subject: "CS", number: "3500")

    static func plan(
        _ name: String = "My Schedule",
        id: UUID = UUID(),
        termCode: String = "202710",
        isPrimary: Bool = false,
        updatedAt: Date = date
    ) -> SchedulePlan {
        var plan = SchedulePlan(id: id, name: name, termCode: termCode)
        plan.courses = [PlanCourse(key: cs3000, excludedCRNs: ["10001", "10002", "10003"], colorIndex: 0)]
        plan.selectedCRNs = ["10004"]
        plan.isPrimary = isPrimary
        plan.createdAt = date
        plan.updatedAt = updatedAt
        return plan
    }

    static func degreePlan(id: UUID = UUID(), updatedAt: Date = date) -> DegreePlan {
        var plan = DegreePlan(id: id, name: "BSCS")
        plan.program = "CS-B-CSCI-BSCS"
        plan.studentName = "SAMPLE STUDENT"
        plan.studentID = "000000000"
        plan.completed = [DegreePlanCourse(key: cs3000, title: "Algorithms and Data", credits: 4)]
        plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: [DegreePlanCourse(key: cs3500, title: "OOD", credits: 4)])]
        plan.isPrimary = true
        plan.createdAt = date
        plan.updatedAt = updatedAt
        return plan
    }

    static func watchItem(crn: String = "12345", addedAt: Date = date) -> WatchItem {
        WatchItem(
            termCode: "202710", crn: crn, courseKey: cs3000, courseTitle: "Algorithms and Data",
            sectionLabel: "Lecture · Section 01", addedAt: addedAt,
            lastSeatsRemaining: 0, lastWaitlistRemaining: 2, seatCapacity: 40, lastCheckedAt: date
        )
    }

    static func saved(_ key: CourseKey = cs3000, savedAt: Date = date) -> SavedCourse {
        SavedCourse(termCode: "202710", key: key, savedAt: savedAt)
    }

    /// Metadata for `data` as if all of it had been synced.
    static func syncedMetadata(for data: UserData) -> CloudSyncMetadata {
        var metadata = CloudSyncMetadata()
        let snapshot = CloudSyncSnapshot(data)
        metadata.observeLocalData(snapshot, now: date)
        for (key, item) in snapshot.items {
            metadata.recordSaved(key, fingerprint: item.fingerprint, systemFields: Data([1]))
        }
        return metadata
    }

    /// A record as another device would have saved it.
    static func incoming(
        _ entity: CloudSyncEntity,
        modifiedAt: Date,
        schemaVersion: Int = CloudSyncConfig.schemaVersion,
        preferenceChangedAt: [String: Date] = [:]
    ) throws -> CloudSyncIncomingRecord {
        CloudSyncIncomingRecord(
            key: entity.key,
            schemaVersion: schemaVersion,
            modifiedAt: modifiedAt,
            payload: try CloudSyncCoding.payload(for: entity, preferenceChangedAt: preferenceChangedAt),
            systemFields: Data([2])
        )
    }

    // MARK: Payloads

    @Test func payloadsRoundTrip() throws {
        var preferences = AppPreferences()
        preferences.preferredCampus = "Boston"
        preferences.calendarStartHour = 9
        let schedule = Self.plan()
        let degree = Self.degreePlan()
        let watch = Self.watchItem()
        let course = Self.saved()
        let changedAt = ["preferredCampus": Self.date]

        #expect(try CloudSyncCoding.decode(CloudSyncCoding.payload(for: .schedulePlan(schedule)), as: .schedulePlan) == .schedulePlan(schedule))
        #expect(try CloudSyncCoding.decode(CloudSyncCoding.payload(for: .degreePlan(degree)), as: .degreePlan)
            == .degreePlan(CloudSyncCoding.syncedForm(of: degree)))
        #expect(try CloudSyncCoding.decode(CloudSyncCoding.payload(for: .watchItem(watch)), as: .watchItem) == .watchItem(watch))
        #expect(try CloudSyncCoding.decode(CloudSyncCoding.payload(for: .savedCourse(course)), as: .savedCourse) == .savedCourse(course))
        let preferencesPayload = try CloudSyncCoding.payload(for: .preferences(preferences), preferenceChangedAt: changedAt)
        #expect(try CloudSyncCoding.decode(preferencesPayload, as: .preferences)
            == .preferences(CloudSyncedPreferences(preferences), changedAt: changedAt))
    }

    @Test func payloadsFromNewerVersionsWithExtraFieldsStillDecode() throws {
        let watch = Self.watchItem()
        var json = try #require(try JSONSerialization.jsonObject(with: CloudSyncCoding.payload(for: .watchItem(watch))) as? [String: Any])
        json["fieldFromTheFuture"] = ["nested": true]
        let payload = try JSONSerialization.data(withJSONObject: json)
        #expect(try CloudSyncCoding.decode(payload, as: .watchItem) == .watchItem(watch))
    }

    @Test func recordKeysUseStableIDs() {
        let schedule = Self.plan()
        #expect(CloudSyncEntity.schedulePlan(schedule).key == CloudSyncKey(type: .schedulePlan, recordName: schedule.id.uuidString))
        #expect(CloudSyncEntity.savedCourse(Self.saved()).key.recordName == "202710|CS 3000")
        #expect(CloudSyncEntity.watchItem(Self.watchItem()).key.recordName == "202710|12345")
        #expect(CloudSyncEntity.preferences(AppPreferences()).key == .preferences)

        // Ids CloudKit can't take as record names get a stable digest instead.
        for unusable in ["", "_private", "Café", String(repeating: "x", count: 256), "tab\there"] {
            let name = CloudSyncKey.recordName(forID: unusable)
            #expect(name.hasPrefix("sha256-"))
            #expect(name.count <= 255)
            #expect(name == CloudSyncKey.recordName(forID: unusable))
        }
        #expect(CloudSyncKey.recordName(forID: "a") != CloudSyncKey.recordName(forID: "_a"))
    }

    @Test func containerIdentifierComesFromInfoPlist() {
        #expect(CloudSyncConfig.containerIdentifier(from: Self.container) == Self.container)
        #expect(CloudSyncConfig.containerIdentifier(from: " \(Self.container)\n") == Self.container)
        #expect(CloudSyncConfig.containerIdentifier(from: nil) == nil)
        #expect(CloudSyncConfig.containerIdentifier(from: "") == nil)
        #expect(CloudSyncConfig.containerIdentifier(from: "iCloud.") == nil)
        #expect(CloudSyncConfig.containerIdentifier(from: "com.example.app") == nil)
        #expect(CloudSyncConfig.containerIdentifier(from: "$(CLOUDKIT_CONTAINER)") == nil)
        #expect(CloudSyncConfig.containerIdentifier(from: 42) == nil)
    }

    // MARK: Device-only data

    @Test func devicePreferencesAreNotSynced() throws {
        var preferences = AppPreferences()
        preferences.selectedTermCode = "202730"
        preferences.hasCompletedOnboarding = true
        preferences.autoRefreshSeats = false
        preferences.backgroundRefreshEnabled = false
        preferences.preferredCampus = "Boston"

        let payload = try CloudSyncCoding.payload(for: .preferences(preferences))
        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let values = try #require(json["values"] as? [String: Any])
        #expect(Set(values.keys) == ["preferredCampus", "showWeekends", "calendarStartHour", "calendarEndHour"])
        let text = String(decoding: payload, as: UTF8.self)
        for deviceOnly in ["selectedTermCode", "hasCompletedOnboarding", "autoRefreshSeats", "backgroundRefreshEnabled", "202730"] {
            #expect(!text.contains(deviceOnly))
        }

        // Changing a device-only preference isn't a change to sync.
        var other = preferences
        other.selectedTermCode = "202710"
        other.hasCompletedOnboarding = false
        other.autoRefreshSeats = true
        other.backgroundRefreshEnabled = true
        #expect(CloudSyncCoding.fingerprint(of: .preferences(other)) == CloudSyncCoding.fingerprint(of: .preferences(preferences)))

        // Values from another device leave the device-only ones alone.
        var remote = CloudSyncedPreferences(AppPreferences())
        remote.preferredCampus = "Oakland"
        remote.showWeekends = true
        let applied = remote.applied(to: preferences)
        #expect(applied.preferredCampus == "Oakland")
        #expect(applied.showWeekends)
        #expect(applied.selectedTermCode == "202730")
        #expect(applied.hasCompletedOnboarding)
        #expect(!applied.autoRefreshSeats)
        #expect(!applied.backgroundRefreshEnabled)
    }

    @Test func remotePreferencesMergeKeepsDeviceOnlyFields() throws {
        var data = UserData()
        data.preferences.selectedTermCode = "202730"
        data.preferences.hasCompletedOnboarding = true
        data.preferences.backgroundRefreshEnabled = false
        var metadata = Self.syncedMetadata(for: data)
        var remote = AppPreferences()
        remote.preferredCampus = "Oakland"
        let record = try Self.incoming(.preferences(remote), modifiedAt: Self.date + 60, preferenceChangedAt: ["preferredCampus": Self.date + 60])

        let result = CloudSyncMerge.merge(modifications: [record], deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata)

        guard case .preferences(let merged)? = result.saves.first else {
            Issue.record("Expected merged preferences, got \(result.saves)")
            return
        }
        #expect(merged.preferredCampus == "Oakland")
        #expect(merged.selectedTermCode == "202730")
        #expect(merged.hasCompletedOnboarding)
        #expect(!merged.backgroundRefreshEnabled)
    }

    @Test func degreePlanStudentDetailsStayOnDevice() throws {
        let plan = Self.degreePlan()
        let text = String(decoding: try CloudSyncCoding.payload(for: .degreePlan(plan)), as: UTF8.self)
        #expect(!text.contains("SAMPLE STUDENT"))
        #expect(!text.contains("000000000"))
        #expect(!text.contains("studentName"))

        // Removing or changing them here isn't a change to sync…
        var withoutStudent = plan
        withoutStudent.studentName = nil
        withoutStudent.studentID = nil
        #expect(CloudSyncCoding.fingerprint(of: .degreePlan(withoutStudent)) == CloudSyncCoding.fingerprint(of: .degreePlan(plan)))

        // …and a version from another device keeps this device's.
        var remote = CloudSyncCoding.syncedForm(of: plan)
        remote.name = "BSCS (updated)"
        let merged = CloudSyncMerge.localValue(for: .degreePlan(remote), replacing: .degreePlan(plan))
        guard case .degreePlan(let result) = merged else {
            Issue.record("Expected a degree plan")
            return
        }
        #expect(result.name == "BSCS (updated)")
        #expect(result.studentName == "SAMPLE STUDENT")
        #expect(result.studentID == "000000000")
    }

    @Test func watchItemSeatChecksAreDeviceOnly() throws {
        let item = Self.watchItem()
        var checked = item
        checked.lastSeatsRemaining = 3
        checked.lastWaitlistRemaining = 0
        checked.seatCapacity = 45
        checked.lastCheckedAt = Self.date + 600
        checked.lastNotifiedAt = Self.date + 600
        #expect(CloudSyncCoding.fingerprint(of: .watchItem(checked)) == CloudSyncCoding.fingerprint(of: .watchItem(item)))

        var intent = item
        intent.notifyOnWaitlist = true
        #expect(CloudSyncCoding.fingerprint(of: .watchItem(intent)) != CloudSyncCoding.fingerprint(of: .watchItem(item)))

        // Another device's copy brings the intent; this device keeps its own seat numbers.
        var remote = item
        remote.notifyOnWaitlist = true
        remote.lastSeatsRemaining = 0
        remote.lastCheckedAt = Self.date - 600
        guard case .watchItem(let merged) = CloudSyncMerge.localValue(for: .watchItem(remote), replacing: .watchItem(checked)) else {
            Issue.record("Expected a watch item")
            return
        }
        #expect(merged.notifyOnWaitlist)
        #expect(merged.lastSeatsRemaining == 3)
        #expect(merged.seatCapacity == 45)
        #expect(merged.lastCheckedAt == Self.date + 600)
        #expect(merged.lastNotifiedAt == Self.date + 600)
    }

    // MARK: Fingerprints

    @Test func fingerprintsIgnoreSetOrder() throws {
        var first = Self.plan()
        var second = first
        first.courses[0].excludedCRNs = []
        second.courses[0].excludedCRNs = []
        for crn in (1...40).map({ String(20_000 + $0) }) { first.courses[0].excludedCRNs.insert(crn) }
        for crn in (1...40).reversed().map({ String(20_000 + $0) }) { second.courses[0].excludedCRNs.insert(crn) }
        #expect(first == second)
        #expect(try CloudSyncCoding.payload(for: .schedulePlan(first)) == CloudSyncCoding.payload(for: .schedulePlan(second)))
        #expect(CloudSyncCoding.fingerprint(of: .schedulePlan(first)) == CloudSyncCoding.fingerprint(of: .schedulePlan(second)))

        // The payload lists the set sorted, whatever order the set iterates in.
        let json = try #require(try JSONSerialization.jsonObject(with: CloudSyncCoding.payload(for: .schedulePlan(first))) as? [String: Any])
        let courses = try #require(json["courses"] as? [[String: Any]])
        let excluded = try #require(courses.first?["excludedCRNs"] as? [String])
        #expect(excluded.count == 40)
        #expect(excluded == excluded.sorted())
    }

    @Test func fingerprintsSurviveTheLocalFile() throws {
        // In memory, dates have sub-second precision; the local file keeps whole seconds.
        var data = UserData()
        data.plans = [Self.plan(updatedAt: Self.date.addingTimeInterval(0.75))]
        data.saved = [Self.saved(savedAt: Self.date.addingTimeInterval(0.25))]
        data.watchlist = [Self.watchItem(addedAt: Self.date.addingTimeInterval(0.5))]
        let reloaded = try JSONDecoder.userData.decode(UserData.self, from: JSONEncoder.userData.encode(data))
        let before = CloudSyncSnapshot(data)
        let after = CloudSyncSnapshot(reloaded)
        #expect(Set(before.items.keys) == Set(after.items.keys))
        for (key, item) in before.items {
            #expect(after[key]?.fingerprint == item.fingerprint, "\(key)")
        }
    }

    // MARK: Change tracking

    @Test func diffFindsAddsChangesAndDeletes() {
        let schedule = Self.plan()
        let watch = Self.watchItem()
        let course = Self.saved()
        var data = UserData()
        data.plans = [schedule]
        data.watchlist = [watch]
        data.saved = [course]
        var metadata = Self.syncedMetadata(for: data)
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).isEmpty)

        let added = Self.plan("Plan B")
        data.plans.append(added)
        data.watchlist[0].notifyOnWaitlist = true
        data.watchlist[0].lastSeatsRemaining = 7 // device-only: not a change
        data.saved = []
        let snapshot = CloudSyncSnapshot(data)
        metadata.observeLocalData(snapshot, now: Self.date + 10)
        let changes = metadata.pendingChanges(for: snapshot)

        #expect(Set(changes.saves) == [CloudSyncEntity.schedulePlan(added).key, CloudSyncEntity.watchItem(watch).key])
        #expect(changes.deletes == [CloudSyncEntity.savedCourse(course).key])

        // Once iCloud confirms them, nothing is left to send.
        for key in changes.saves {
            metadata.recordSaved(key, fingerprint: snapshot[key]?.fingerprint, systemFields: Data([3]))
        }
        for key in changes.deletes { metadata.recordDeletedFromICloud(key) }
        #expect(metadata.pendingChanges(for: snapshot).isEmpty)
        #expect(metadata.records[CloudSyncEntity.savedCourse(course).key] == nil)
    }

    @Test func freshDeviceUploadsEverything() {
        var data = UserData()
        data.plans = [Self.plan()]
        data.saved = [Self.saved()]
        var metadata = CloudSyncMetadata()
        let snapshot = CloudSyncSnapshot(data)
        metadata.observeLocalData(snapshot, now: Self.date)
        let changes = metadata.pendingChanges(for: snapshot)
        #expect(Set(changes.saves) == Set(snapshot.items.keys))
        #expect(changes.deletes.isEmpty)
        #expect(changes.saves.contains(.preferences))
    }

    @Test func journalDatesLocalChanges() {
        var data = UserData()
        data.plans = [Self.plan(isPrimary: false)]
        let planKey = CloudSyncEntity.schedulePlan(data.plans[0]).key
        var metadata = CloudSyncMetadata()

        // Data from before sync has unknown change times.
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date)
        #expect(metadata.records[planKey]?.localChangedAt == nil)
        #expect(metadata.preferenceChangedAt.isEmpty)

        // Making a plan primary doesn't touch `updatedAt`, but it is a change, dated now.
        data.plans[0].isPrimary = true
        data.preferences.showWeekends = true
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 300)
        #expect(metadata.records[planKey]?.localChangedAt == Self.date + 300)
        #expect(metadata.preferenceChangedAt == ["showWeekends": Self.date + 300])
        #expect(CloudSyncCoding.modifiedAt(of: .schedulePlan(data.plans[0]), localChangedAt: Self.date + 300) == Self.date + 300)
        #expect(CloudSyncCoding.modifiedAt(of: .preferences(data.preferences), localChangedAt: nil,
                                           preferenceChangedAt: metadata.preferenceChangedAt) == Self.date + 300)

        // A deletion is dated too.
        data.plans = []
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 600)
        // Never synced, so nothing is left to track.
        #expect(metadata.records[planKey] == nil)
    }

    @Test func modifiedAtRules() {
        let plan = Self.plan(updatedAt: Self.date + 100)
        #expect(CloudSyncCoding.modifiedAt(of: .schedulePlan(plan), localChangedAt: nil) == Self.date + 100)
        #expect(CloudSyncCoding.modifiedAt(of: .schedulePlan(plan), localChangedAt: Self.date + 50) == Self.date + 100)
        #expect(CloudSyncCoding.modifiedAt(of: .watchItem(Self.watchItem()), localChangedAt: nil) == Self.date)
        #expect(CloudSyncCoding.modifiedAt(of: .savedCourse(Self.saved()), localChangedAt: Self.date + 9) == Self.date + 9)
        #expect(CloudSyncCoding.modifiedAt(of: .preferences(AppPreferences()), localChangedAt: nil) == .distantPast)
    }

    @Test func turningSyncOffForgetsICloudButNotLocalHistory() throws {
        var data = UserData()
        data.plans = [Self.plan()]
        data.saved = [Self.saved()]
        var metadata = Self.syncedMetadata(for: data)
        data.saved = []
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 5)
        metadata.isZoneSaved = true
        metadata.lastSyncDate = Self.date

        metadata.forgetICloud()

        #expect(!metadata.hasDataInICloud)
        #expect(!metadata.isZoneSaved)
        #expect(metadata.lastSyncDate == nil)
        let planState = try #require(metadata.records[CloudSyncEntity.schedulePlan(data.plans[0]).key])
        #expect(planState.localFingerprint != nil)
        #expect(planState.systemFields == nil)
        // The deleted course's iCloud copy is no longer tracked, so turning sync on again
        // merges rather than deleting it from the user's other devices.
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).deletes.isEmpty)
    }

    @Test func metadataRoundTrips() throws {
        var data = UserData()
        data.plans = [Self.plan()]
        data.preferences.preferredCampus = "Boston"
        var metadata = Self.syncedMetadata(for: data)
        metadata.accountRecordName = "_user"
        metadata.preferenceChangedAt = ["preferredCampus": Self.date]
        metadata.records[CloudSyncKey(type: .watchItem, recordName: "202710|1")] = {
            var state = CloudSyncRecordState()
            state.isServerCopyUnreadable = true
            return state
        }()
        let decoded = try JSONDecoder().decode(CloudSyncMetadata.self, from: JSONEncoder().encode(metadata))
        #expect(decoded == metadata)
    }

    // MARK: Merging

    @Test func remoteChangesApplyWithoutEcho() throws {
        let original = Self.plan()
        var data = UserData()
        data.plans = [original]
        var metadata = Self.syncedMetadata(for: data)
        var remote = original
        remote.name = "Renamed elsewhere"
        remote.updatedAt = Self.date + 60

        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(remote), modifiedAt: Self.date + 60)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata, now: Self.date + 120
        )
        #expect(result.saves == [.schedulePlan(remote)])
        #expect(result.keptLocal.isEmpty)
        let key = CloudSyncEntity.schedulePlan(remote).key
        #expect(metadata.records[key]?.systemFields == Data([2]))
        #expect(metadata.records[key]?.localChangedAt == Self.date + 60)

        data = data.applyingCloudChanges(saves: result.saves, deletes: result.deletes)
        #expect(data.plans.map { $0.name } == ["Renamed elsewhere"])
        let after = CloudSyncSnapshot(data)
        metadata.observeLocalData(after, now: Self.date + 180)
        #expect(metadata.pendingChanges(for: after).isEmpty)
        #expect(metadata.records[key]?.localChangedAt == Self.date + 60)
    }

    @Test func identicalRemoteCopyChangesNothing() throws {
        let plan = Self.plan()
        var data = UserData()
        data.plans = [plan]
        var metadata = CloudSyncMetadata()
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date)
        // A first sync finds the same plan in iCloud already.
        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(plan), modifiedAt: Self.date)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata
        )
        #expect(!result.changesLocalData)
        #expect(!metadata.pendingChanges(for: CloudSyncSnapshot(data)).saves.contains(CloudSyncEntity.schedulePlan(plan).key))
    }

    @Test func newerLocalChangeWinsConflict() throws {
        let original = Self.plan()
        var data = UserData()
        data.plans = [original]
        var metadata = Self.syncedMetadata(for: data)
        data.plans[0].name = "Edited here"
        data.plans[0].updatedAt = Self.date + 100
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 100)

        var remote = original
        remote.name = "Edited elsewhere"
        remote.updatedAt = Self.date + 50
        let key = CloudSyncEntity.schedulePlan(original).key
        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(remote), modifiedAt: Self.date + 50)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata
        )
        #expect(result.saves.isEmpty)
        #expect(result.keptLocal == [key])
        // The next save builds on the server copy's change tag, so it goes through.
        #expect(metadata.records[key]?.systemFields == Data([2]))
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).saves == [key])
    }

    @Test func newerRemoteChangeWinsConflict() throws {
        let original = Self.plan()
        var data = UserData()
        data.plans = [original]
        var metadata = Self.syncedMetadata(for: data)
        data.plans[0].name = "Edited here"
        data.plans[0].updatedAt = Self.date + 50
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 50)

        var remote = original
        remote.name = "Edited elsewhere"
        remote.updatedAt = Self.date + 100
        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(remote), modifiedAt: Self.date + 100)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata
        )
        #expect(result.saves == [.schedulePlan(remote)])
        #expect(result.keptLocal.isEmpty)
    }

    @Test func tiesGoToICloud() throws {
        let original = Self.plan()
        var data = UserData()
        data.plans = [original]
        var metadata = Self.syncedMetadata(for: data)
        data.plans[0].name = "Edited here"
        data.plans[0].updatedAt = Self.date + 50
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 50)

        var remote = original
        remote.name = "Edited elsewhere"
        remote.updatedAt = Self.date + 50
        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(remote), modifiedAt: Self.date + 50)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata
        )
        #expect(result.saves == [.schedulePlan(remote)])
    }

    @Test func remoteDeletionRemovesUnchangedValues() {
        let course = Self.saved()
        var data = UserData()
        data.saved = [course]
        var metadata = Self.syncedMetadata(for: data)
        let key = CloudSyncEntity.savedCourse(course).key

        let result = CloudSyncMerge.merge(modifications: [], deletions: [key], into: CloudSyncSnapshot(data), metadata: &metadata)
        #expect(result.deletes == [key])
        #expect(metadata.records[key] == nil)
        data = data.applyingCloudChanges(saves: result.saves, deletes: result.deletes)
        #expect(data.saved.isEmpty)
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).isEmpty)
    }

    @Test func remoteDeletionKeepsLocallyEditedValues() {
        let item = Self.watchItem()
        var data = UserData()
        data.watchlist = [item]
        var metadata = Self.syncedMetadata(for: data)
        data.watchlist[0].notifyOnWaitlist = true
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 30)
        let key = CloudSyncEntity.watchItem(item).key

        let result = CloudSyncMerge.merge(modifications: [], deletions: [key], into: CloudSyncSnapshot(data), metadata: &metadata)
        #expect(result.deletes.isEmpty)
        #expect(result.keptLocal == [key])
        #expect(metadata.records[key]?.systemFields == nil)
        // Uploaded again as a new record.
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).saves == [key])
    }

    @Test func localDeletionNewerThanRemoteEditStands() throws {
        let original = Self.plan()
        var data = UserData()
        data.plans = [original]
        var metadata = Self.syncedMetadata(for: data)
        data.plans = []
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 100)
        let key = CloudSyncEntity.schedulePlan(original).key

        var olderEdit = original
        olderEdit.name = "Edited elsewhere, earlier"
        var newerEdit = original
        newerEdit.name = "Edited elsewhere, later"
        newerEdit.updatedAt = Self.date + 200

        var keepDeleted = metadata
        let stands = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(olderEdit), modifiedAt: Self.date + 50)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &keepDeleted
        )
        #expect(stands.saves.isEmpty)
        #expect(keepDeleted.pendingChanges(for: CloudSyncSnapshot(data)).deletes == [key])

        let resurrected = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(newerEdit), modifiedAt: Self.date + 200)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata
        )
        #expect(resurrected.saves == [.schedulePlan(newerEdit)])
    }

    @Test func recordsFromNewerVersionsAreLeftAlone() throws {
        let plan = Self.plan()
        var data = UserData()
        data.plans = [plan]
        var metadata = Self.syncedMetadata(for: data)
        let key = CloudSyncEntity.schedulePlan(plan).key
        var newer = plan
        newer.name = "Written by version 2"
        var record = try Self.incoming(.schedulePlan(newer), modifiedAt: Self.date + 60, schemaVersion: CloudSyncConfig.schemaVersion + 1)
        record.systemFields = Data([9])

        let result = CloudSyncMerge.merge(modifications: [record], deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata)
        #expect(result.skipped == [key])
        #expect(!result.changesLocalData)
        #expect(metadata.records[key]?.isServerCopyUnreadable == true)

        // Local edits and deletions don't overwrite or delete it.
        data.plans[0].name = "Edited here"
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 120)
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).isEmpty)
        data.plans = []
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 180)
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).isEmpty)
    }

    @Test func unreadablePayloadsAreSkippedNotDeleted() throws {
        let plan = Self.plan()
        var data = UserData()
        data.plans = [plan]
        var metadata = Self.syncedMetadata(for: data)
        let key = CloudSyncEntity.schedulePlan(plan).key
        let garbage = CloudSyncIncomingRecord(key: key, schemaVersion: 1, modifiedAt: Self.date + 60, payload: Data("{ not json".utf8), systemFields: nil)
        let empty = CloudSyncIncomingRecord(key: CloudSyncKey(type: .savedCourse, recordName: "202710|CS 9999"), schemaVersion: 1, modifiedAt: Self.date, payload: nil, systemFields: nil)
        // A payload whose value has a different id than the record.
        var mismatched = try Self.incoming(.schedulePlan(Self.plan("Other")), modifiedAt: Self.date + 60)
        mismatched.key = CloudSyncKey(type: .schedulePlan, recordName: UUID().uuidString)

        let result = CloudSyncMerge.merge(modifications: [garbage, empty, mismatched], deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata)
        #expect(Set(result.skipped) == [key, empty.key, mismatched.key])
        #expect(!result.changesLocalData)
        #expect(data.applyingCloudChanges(saves: result.saves, deletes: result.deletes).plans == [plan])
    }

    @Test func primaryPlanConflictKeepsOnePrimary() throws {
        let first = Self.plan("First", isPrimary: true)
        let second = Self.plan("Second", isPrimary: false)
        var data = UserData()
        data.plans = [first, second]
        var metadata = Self.syncedMetadata(for: data)

        // Another device made "Second" primary; its demotion of "First" hasn't arrived yet.
        var remote = second
        remote.isPrimary = true
        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.schedulePlan(remote), modifiedAt: Self.date + 60)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata, now: Self.date + 90
        )
        data = data.applyingCloudChanges(saves: result.saves, deletes: result.deletes)
        #expect(data.plans.filter { $0.isPrimary }.map { $0.name } == ["Second"])
        // The demotion here is a local change and gets sent.
        let firstKey = CloudSyncEntity.schedulePlan(first).key
        #expect(metadata.records[firstKey]?.localChangedAt == Self.date + 90)
        #expect(metadata.pendingChanges(for: CloudSyncSnapshot(data)).saves == [firstKey])
    }

    @Test func degreePlanPrimaryConflictKeepsOnePrimary() throws {
        var mine = Self.degreePlan()
        mine.name = "Mine"
        var data = UserData()
        data.degreePlans = [mine]
        var metadata = Self.syncedMetadata(for: data)
        var theirs = CloudSyncCoding.syncedForm(of: Self.degreePlan(updatedAt: Self.date + 60))
        theirs.name = "Theirs"
        let result = CloudSyncMerge.merge(
            modifications: [try Self.incoming(.degreePlan(theirs), modifiedAt: Self.date + 60)],
            deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata, now: Self.date + 90
        )
        data = data.applyingCloudChanges(saves: result.saves, deletes: result.deletes)
        #expect(data.degreePlans.count == 2)
        #expect(data.degreePlans.filter { $0.isPrimary }.map { $0.name } == ["Theirs"])
        // The local plan keeps its student details through the demotion.
        #expect(data.degreePlans.first { $0.name == "Mine" }?.studentName == "SAMPLE STUDENT")
    }

    @Test func preferencesMergeFieldByField() throws {
        var data = UserData()
        var metadata = Self.syncedMetadata(for: data)
        data.preferences.preferredCampus = "Boston" // changed here, later
        metadata.observeLocalData(CloudSyncSnapshot(data), now: Self.date + 200)

        var remote = AppPreferences()
        remote.calendarStartHour = 7 // changed elsewhere, earlier
        let record = try Self.incoming(.preferences(remote), modifiedAt: Self.date + 100,
                                       preferenceChangedAt: ["calendarStartHour": Self.date + 100])
        let result = CloudSyncMerge.merge(modifications: [record], deletions: [], into: CloudSyncSnapshot(data), metadata: &metadata)

        guard case .preferences(let merged)? = result.saves.first else {
            Issue.record("Expected merged preferences, got \(result.saves)")
            return
        }
        #expect(merged.preferredCampus == "Boston")
        #expect(merged.calendarStartHour == 7)
        // The campus is newer here, so the merged values go back up.
        #expect(result.keptLocal == [.preferences])
        data = data.applyingCloudChanges(saves: result.saves, deletes: result.deletes)
        let snapshot = CloudSyncSnapshot(data)
        metadata.observeLocalData(snapshot, now: Self.date + 300)
        #expect(metadata.pendingChanges(for: snapshot).saves == [.preferences])
        #expect(metadata.preferenceChangedAt["calendarStartHour"] == Self.date + 100)
        #expect(metadata.preferenceChangedAt["preferredCampus"] == Self.date + 200)
    }

    @Test func customizedPreferencesBeatDefaultsOfUnknownAge() {
        let defaults = CloudSyncedPreferences(AppPreferences())
        var custom = defaults
        custom.calendarStartHour = 10
        custom.showWeekends = true

        // A new device (defaults) meets a device whose settings predate sync: the settings win.
        let keepCustom = CloudSyncedPreferences.merge(local: custom, localChangedAt: [:], remote: defaults, remoteChangedAt: [:])
        #expect(keepCustom.values == custom)
        let adoptCustom = CloudSyncedPreferences.merge(local: defaults, localChangedAt: [:], remote: custom, remoteChangedAt: [:])
        #expect(adoptCustom.values == custom)
        // A dated change beats an undated one, either way round.
        let dated = CloudSyncedPreferences.merge(local: defaults, localChangedAt: ["showWeekends": Self.date], remote: custom, remoteChangedAt: [:])
        #expect(!dated.values.showWeekends)
        #expect(dated.values.calendarStartHour == 10)
    }

    @Test func invalidRemoteCalendarHoursFallBackToDefaults() throws {
        let json = #"{"values":{"calendarStartHour":30,"calendarEndHour":2,"showWeekends":true},"changedAt":{}}"#
        guard case .preferences(let values, _) = try CloudSyncCoding.decode(Data(json.utf8), as: .preferences) else {
            Issue.record("Expected preferences")
            return
        }
        let defaults = AppPreferences()
        #expect(values.calendarStartHour == defaults.calendarStartHour)
        #expect(values.calendarEndHour == defaults.calendarEndHour)
        #expect(values.showWeekends)
        #expect(values.preferredCampus == nil)
    }

    // MARK: Applying

    @Test func applyingCloudChangesReplacesInsertsAndDeletes() {
        let newest = Self.watchItem(crn: "3", addedAt: Self.date + 300)
        let oldest = Self.watchItem(crn: "1", addedAt: Self.date + 100)
        let plan = Self.plan()
        var data = UserData()
        data.watchlist = [newest, oldest]
        data.plans = [plan]
        data.saved = [Self.saved()]

        var renamed = plan
        renamed.name = "Renamed"
        let middle = Self.watchItem(crn: "2", addedAt: Self.date + 200)
        let result = data.applyingCloudChanges(
            saves: [.schedulePlan(renamed), .watchItem(middle), .savedCourse(Self.saved(Self.cs3500, savedAt: Self.date + 50))],
            deletes: [CloudSyncEntity.savedCourse(Self.saved()).key]
        )
        #expect(result.plans.map { $0.name } == ["Renamed"])
        #expect(result.watchlist.map { $0.crn } == ["3", "2", "1"])
        #expect(result.saved.map { $0.key } == [Self.cs3500])
        #expect(result.preferences == data.preferences)
    }

    // MARK: Status

    @Test func statusLines() {
        let now = Self.date
        #expect(CloudSyncStatus.State.upToDate(lastSync: now - 20).summary(relativeTo: now) == "Up to date · just now")
        #expect(CloudSyncStatus.State.upToDate(lastSync: now + 20).summary(relativeTo: now) == "Up to date · just now")
        #expect(CloudSyncStatus.State.upToDate(lastSync: now - 120).summary(relativeTo: now).hasPrefix("Up to date · "))
        #expect(CloudSyncStatus.State.upToDate(lastSync: nil).summary(relativeTo: now) == "Up to date")
        #expect(CloudSyncStatus.State.syncing.summary() == "Syncing…")
        #expect(CloudSyncStatus.State.unavailable(.noAccount).summary() == "Sign in to iCloud in Settings to sync")
        #expect(CloudSyncStatus.State.unavailable(.notConfigured).summary() == "iCloud sync isn't set up in this build")
        #expect(CloudSyncStatus.State.error("Your iCloud storage is full.").summary() == "Your iCloud storage is full.")
    }

    // MARK: Entitlements

    @Test func entitlementCheck() {
        let services = CloudSyncEntitlements.servicesKey
        let containers = CloudSyncEntitlements.containersKey
        let id = Self.container
        #expect(CloudSyncEntitlements.grantsCloudKit([services: ["CloudKit"], containers: [id]], containerIdentifier: id))
        #expect(CloudSyncEntitlements.grantsCloudKit([services: "*", containers: [id]], containerIdentifier: id))
        #expect(!CloudSyncEntitlements.grantsCloudKit([services: ["CloudDocuments"], containers: [id]], containerIdentifier: id))
        #expect(!CloudSyncEntitlements.grantsCloudKit([services: ["CloudKit"], containers: ["iCloud.com.example.other"]], containerIdentifier: id))
        #expect(!CloudSyncEntitlements.grantsCloudKit(["com.apple.security.application-groups": ["group.x"]], containerIdentifier: id))
    }

    @Test func readsEntitlementsFromCodeSignature() throws {
        let entitlements: [String: Any] = [
            CloudSyncEntitlements.servicesKey: ["CloudKit"],
            CloudSyncEntitlements.containersKey: [Self.container],
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        let signed = try #require(CloudSyncEntitlements.codeSignatureEntitlements(in: Self.machO(entitlements: plist)))
        #expect(CloudSyncEntitlements.grantsCloudKit(signed, containerIdentifier: Self.container))

        // Signed without entitlements: readable, and grants nothing.
        let bare = try #require(CloudSyncEntitlements.codeSignatureEntitlements(in: Self.machO(entitlements: nil)))
        #expect(bare.isEmpty)

        // Not a Mach-O, or cut short: unknown rather than a crash.
        #expect(CloudSyncEntitlements.codeSignatureEntitlements(in: Data("not a binary".utf8)) == nil)
        #expect(CloudSyncEntitlements.codeSignatureEntitlements(in: Data()) == nil)
        let truncated = Self.machO(entitlements: plist).prefix(60)
        #expect(CloudSyncEntitlements.codeSignatureEntitlements(in: Data(truncated)) == nil)
    }

    /// A minimal 64-bit Mach-O whose only load command is `LC_CODE_SIGNATURE`, pointing at a
    /// code signature super blob with an optional XML entitlements blob.
    static func machO(entitlements: Data?) -> Data {
        func little(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        func big(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }

        var index: [UInt8] = []
        var blobs: [UInt8] = []
        var count: UInt32 = 0
        if let entitlements {
            index = big(5) + big(12 + 8) // CSSLOT_ENTITLEMENTS, right after the header and index
            blobs = big(0xFADE_7171) + big(UInt32(8 + entitlements.count)) + Array(entitlements)
            count = 1
        }
        let superBlob = big(0xFADE_0CC0) + big(UInt32(12 + index.count + blobs.count)) + big(count) + index + blobs

        let headerSize: UInt32 = 32
        let commandSize: UInt32 = 16
        var bytes: [UInt8] = []
        // mach_header_64: magic, cputype (arm64), cpusubtype, filetype (execute), ncmds, sizeofcmds, flags, reserved
        bytes += little(0xFEED_FACF) + little(0x0100_000C) + little(0) + little(2) + little(1) + little(commandSize) + little(0) + little(0)
        // linkedit_data_command: cmd, cmdsize, dataoff, datasize
        bytes += little(0x1D) + little(commandSize) + little(headerSize + commandSize) + little(UInt32(superBlob.count))
        bytes += superBlob
        return Data(bytes)
    }
}
