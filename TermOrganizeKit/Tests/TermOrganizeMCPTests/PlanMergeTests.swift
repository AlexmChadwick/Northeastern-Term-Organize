//
//  PlanMergeTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import TermOrganizeKit

@Suite
struct PlanMergeTests {
    @Test func sha256MatchesKnownVectors() {
        #expect(SHA256Hex.hash(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Hex.hash(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func stampDetectsRevisionOrHashButNotATimestampTouch() {
        let id = UUID()
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_000_100)
        let baseline = UserDataFileStamp(mtime: earlier, hash: "aaa", revisions: [id: 1])
        #expect(UserDataFileStamp(mtime: earlier, hash: "aaa", revisions: [id: 2]).differs(from: baseline))
        #expect(UserDataFileStamp(mtime: later, hash: "bbb", revisions: [id: 1]).differs(from: baseline))
        #expect(UserDataFileStamp(mtime: earlier, hash: "bbb", revisions: [id: 1]).differs(from: baseline))
        #expect(!UserDataFileStamp(mtime: later, hash: "aaa", revisions: [id: 1]).differs(from: baseline))
    }

    @Test func disjointEditsMergeAndTheAppPreferenceIsKept() {
        let fall = plan(name: "Fall", term: "202710", course: "2500", revision: 1)
        let spring = plan(name: "Spring", term: "202730", course: "3000", revision: 1)
        var baseline = UserData()
        baseline.plans = [fall, spring]
        var disk = baseline
        disk.plans[0].courses = [course("2510")]
        disk.plans[0].revision = 2
        var local = baseline
        local.plans[1].courses = [course("3500")]
        local.plans[1].revision = 2
        local.preferences.selectedTermCode = "202730"

        let merged = UserDataPlanMerge.merging(baseline: baseline, disk: disk, local: local)
        #expect(merged.plans.count == 2)
        #expect(courses(in: merged, name: "Fall") == ["2510"])
        #expect(courses(in: merged, name: "Spring") == ["3500"])
        #expect(merged.preferences.selectedTermCode == "202730")
        #expect(!merged.plans.contains { $0.name.contains(UserDataPlanMerge.editedInAppSuffix) })
    }

    @Test func conflictingEditKeepsTheFileAndCopiesTheAppPlan() {
        let shared = plan(name: "Fall", term: "202710", course: "2500", revision: 1)
        var baseline = UserData()
        baseline.plans = [shared]
        var disk = baseline
        disk.plans[0].courses = [course("2510")]
        disk.plans[0].revision = 2
        var local = baseline
        local.plans[0].courses = [course("2800")]
        local.plans[0].revision = 2
        local.plans[0].isPrimary = true
        disk.plans[0].isPrimary = true

        let merged = UserDataPlanMerge.merging(baseline: baseline, disk: disk, local: local)
        let kept = merged.plans.first { $0.id == shared.id }
        let copy = merged.plans.first { $0.name == "Fall\(UserDataPlanMerge.editedInAppSuffix)" }
        #expect(kept?.courses.map(\.key.number) == ["2510"])
        #expect(kept?.revision == 2)
        #expect(copy?.courses.map(\.key.number) == ["2800"])
        #expect(copy?.id != shared.id)
        #expect(copy?.isPrimary == false)
        #expect(kept?.isPrimary == true)
    }

    @Test func aNewExternalPlanSurvivesAnEditToADifferentPlan() {
        let fall = plan(name: "Fall", term: "202710", course: "2500", revision: 1)
        var baseline = UserData()
        baseline.plans = [fall]
        var disk = baseline
        disk.plans.append(plan(name: "Spring", term: "202730", course: "3000", revision: 1))
        var local = baseline
        local.plans[0].courses = [course("2800")]
        local.plans[0].revision = 2

        let merged = UserDataPlanMerge.merging(baseline: baseline, disk: disk, local: local)
        #expect(courses(in: merged, name: "Fall") == ["2800"])
        #expect(merged.plans.contains { $0.id == fall.id })
        #expect(courses(in: merged, name: "Spring") == ["3000"])
        #expect(!merged.plans.contains { $0.name.contains(UserDataPlanMerge.editedInAppSuffix) })
    }

    @Test func flushMergeDoesNotDropAnExternalWrite() throws {
        let url = try temporaryFile()
        let fall = plan(name: "Fall", term: "202710", course: "2500", revision: 1)
        let spring = plan(name: "Spring", term: "202730", course: "3000", revision: 1)
        var baseline = UserData()
        baseline.plans = [fall, spring]
        try UserDataFile.write(baseline, to: url)
        let loaded = try UserDataFile.read(from: url)
        let stamp = UserDataFile.stamp(of: loaded, at: url)

        var external = loaded
        external.plans[0].courses = [course("2510")]
        external.plans[0].revision = 2
        try UserDataFile.write(external, to: url)

        var local = loaded
        local.plans[1].courses = [course("3500")]
        local.plans[1].revision = 2
        let saved = try UserDataFile.writeResolvingConflicts(local: local, loaded: loaded, baseline: stamp, to: url)
        let stored = try UserDataFile.read(from: url)
        #expect(stored.plans.map(\.id) == saved.data.plans.map(\.id))
        #expect(courses(in: stored, name: "Fall") == ["2510"])
        #expect(courses(in: stored, name: "Spring") == ["3500"])
        #expect(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }

    @Test func flushMergeCopiesTheAppPlanWhenTheSamePlanChanged() throws {
        let url = try temporaryFile()
        let shared = plan(name: "Fall", term: "202710", course: "2500", revision: 1)
        var baseline = UserData()
        baseline.plans = [shared]
        try UserDataFile.write(baseline, to: url)
        let loaded = try UserDataFile.read(from: url)
        let stamp = UserDataFile.stamp(of: loaded, at: url)

        var external = loaded
        external.plans[0].courses = [course("2510")]
        external.plans[0].revision = 2
        try UserDataFile.write(external, to: url)

        var local = loaded
        local.plans[0].courses = [course("2800")]
        local.plans[0].revision = 2
        _ = try UserDataFile.writeResolvingConflicts(local: local, loaded: loaded, baseline: stamp, to: url)
        let stored = try UserDataFile.read(from: url)
        #expect(stored.plans.first { $0.id == shared.id }?.courses.map(\.key.number) == ["2510"])
        #expect(courses(in: stored, name: "Fall\(UserDataPlanMerge.editedInAppSuffix)") == ["2800"])
    }

    @Test func anUnchangedFileIsNotReportedAndAReplacedFileIs() throws {
        let url = try temporaryFile()
        var baseline = UserData()
        baseline.plans = [plan(name: "Fall", term: "202710", course: "2500", revision: 1)]
        try UserDataFile.write(baseline, to: url)
        let stamp = UserDataFile.stamp(of: baseline, at: url)
        #expect(UserDataFile.snapshotIfChanged(at: url, since: stamp) == nil)

        var external = baseline
        external.plans[0].revision = 2
        external.plans[0].courses = [course("2510")]
        try UserDataFile.write(external, to: url)
        let snapshot = try #require(UserDataFile.snapshotIfChanged(at: url, since: stamp))
        #expect(snapshot.data.plans.first?.revision == 2)
        #expect(snapshot.stamp.differs(from: stamp))
    }

    @Test func watcherReportsAnAtomicReplaceWhileTheFileIsOpen() async throws {
        let url = try temporaryFile()
        var baseline = UserData()
        baseline.plans = [plan(name: "Fall", term: "202710", course: "2500", revision: 1)]
        try UserDataFile.write(baseline, to: url)
        let stamp = UserDataFile.stamp(of: baseline, at: url)
        let hits = HitCount()
        let watcher = UserDataFileWatcher()
        defer { watcher.stop() }
        watcher.start(fileURL: url) {
            // Same check `UserDataStore.reloadExternalChanges` makes while the app is active.
            if UserDataFile.snapshotIfChanged(at: url, since: stamp) != nil {
                hits.increment()
            }
        }
        var external = baseline
        external.plans[0].revision = 2
        external.plans[0].courses = [course("2510")]
        try UserDataFile.write(external, to: url)
        let sawChange = await hits.waitUntilPositive()
        #expect(sawChange)
    }

    @Test func writeResolvingConflictsLeavesANewerVersionUntouched() throws {
        let url = try temporaryFile()
        let bytes = Data("{\"version\":2,\"plans\":[]}".utf8)
        try bytes.write(to: url)
        let local = UserData()
        let baseline = UserDataFileStamp(mtime: nil, hash: "", revisions: [:])
        #expect(throws: UserDataFileError.self) {
            _ = try UserDataFile.writeResolvingConflicts(local: local, loaded: local, baseline: baseline, to: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func modifyLeavesMalformedJSONUntouched() throws {
        let url = try temporaryFile()
        let bytes = Data("not json".utf8)
        try bytes.write(to: url)
        #expect(throws: UserDataFileError.self) {
            try UserDataFile.modify(at: url) { data in data.plans = [] }
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func migrationDeletesTheOriginalOnlyAfterTheCopyMatches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)", isDirectory: true)
        let legacy = directory.appendingPathComponent("old/UserData.json")
        let destination = directory.appendingPathComponent("group/UserData.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"version\":1,\"plans\":[{\"name\":\"Keep\"}]}".utf8)
        try bytes.write(to: legacy)
        try UserDataMigration.migrate(from: legacy, to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let backup = URL(fileURLWithPath: legacy.path + ".premigration.bak")
        #expect(try Data(contentsOf: backup) == bytes)
    }

    @Test func migrationLeavesAnUnreadableOriginalInPlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-deny-\(UUID().uuidString)", isDirectory: true)
        let legacy = directory.appendingPathComponent("old/UserData.json")
        let destination = directory.appendingPathComponent("group/UserData.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"version\":1,\"plans\":[{\"name\":\"Keep\"}]}".utf8)
        try bytes.write(to: legacy)
        #expect(chmod(legacy.path, 0) == 0)
        defer { chmod(legacy.path, 0o644) }
        #expect(throws: UserDataFileError.self) {
            try UserDataMigration.migrate(from: legacy, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        chmod(legacy.path, 0o644)
        #expect(try Data(contentsOf: legacy) == bytes)
        #expect(!FileManager.default.fileExists(atPath: legacy.path + ".premigration.bak"))
    }

    @Test func migrationDoesNotReplaceAnExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-dest-\(UUID().uuidString)", isDirectory: true)
        let legacy = directory.appendingPathComponent("old/UserData.json")
        let destination = directory.appendingPathComponent("group/UserData.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"version\":1,\"plans\":[{\"name\":\"Old\"}]}".utf8)
        let current = Data("{\"version\":1,\"plans\":[{\"name\":\"Current\"}]}".utf8)
        try original.write(to: legacy)
        try current.write(to: destination)
        try UserDataMigration.migrate(from: legacy, to: destination)
        #expect(try Data(contentsOf: destination) == current)
        #expect(try Data(contentsOf: legacy) == original)
    }

    private func plan(name: String, term: String, course number: String, revision: Int) -> SchedulePlan {
        var plan = SchedulePlan(name: name, termCode: term)
        plan.courses = [course(number)]
        plan.revision = revision
        return plan
    }

    private func course(_ number: String) -> PlanCourse {
        PlanCourse(key: CourseKey(subject: "CS", number: number), colorIndex: 0)
    }

    private func courses(in data: UserData, name: String) -> [String] {
        data.plans.first { $0.name == name }?.courses.map(\.key.number) ?? []
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("UserData.json")
    }
}

final class HitCount: Sendable {
    private let value = Mutex(0)

    func increment() { value.withLock { $0 += 1 } }

    func read() -> Int { value.withLock { $0 } }

    func waitUntilPositive() async -> Bool {
        for _ in 0..<40 {
            if read() > 0 { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
