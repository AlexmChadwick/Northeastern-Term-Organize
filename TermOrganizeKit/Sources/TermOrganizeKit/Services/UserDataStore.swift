//
//  UserDataStore.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation

/// The user's plans, watchlist, bookmarks and preferences, persisted as JSON
/// in Application Support. Saves are debounced.
///
/// Each collection is its own stored property so SwiftUI only re-renders the
/// views that read what actually changed (recording a search doesn't touch
/// views that show plans).
@MainActor
@Observable
final class UserDataStore {
    var preferences: AppPreferences {
        didSet { scheduleSave() }
    }
    private(set) var saved: [SavedCourse]
    private(set) var recents: [RecentCourse]
    private(set) var plans: [SchedulePlan]
    private(set) var watchlist: [WatchItem]
    private(set) var searchHistory: [String]
    private(set) var degreePlans: [DegreePlan]

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL
    /// Called after plans change (used to refresh widget data).
    @ObservationIgnored var onPlansChanged: (() -> Void)?
    /// Called after local changes are saved (so at most every 400 ms while editing), for iCloud
    /// sync to look for changes to send. Not called for `applyRemoteChanges(saves:deletes:)`.
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored private var hasUnreportedChanges = false
    /// True while changes from iCloud are being applied (synchronously, on the main actor).
    @ObservationIgnored private(set) var isApplyingRemoteChanges = false

    init(fileURL: URL = AppPaths.userDataURL) {
        self.fileURL = fileURL
        let stored = (try? UserDataFile.read(from: fileURL)) ?? UserData()
        preferences = stored.preferences
        saved = stored.saved
        recents = stored.recents
        plans = stored.plans
        watchlist = stored.watchlist
        searchHistory = stored.searchHistory
        degreePlans = stored.degreePlans
    }

    /// Everything, as persisted.
    var data: UserData {
        var d = UserData()
        d.preferences = preferences
        d.saved = saved
        d.recents = recents
        d.plans = plans
        d.watchlist = watchlist
        d.searchHistory = searchHistory
        d.degreePlans = degreePlans
        return d
    }

    // MARK: Saved courses

    func savedCourses(in termCode: String) -> [SavedCourse] {
        saved.filter { $0.termCode == termCode }.sorted { $0.savedAt > $1.savedAt }
    }

    func isSaved(_ key: CourseKey, termCode: String) -> Bool {
        saved.contains { $0.key == key && $0.termCode == termCode }
    }

    func toggleSaved(_ key: CourseKey, termCode: String) {
        if let i = saved.firstIndex(where: { $0.key == key && $0.termCode == termCode }) {
            saved.remove(at: i)
        } else {
            saved.insert(SavedCourse(termCode: termCode, key: key, savedAt: .now), at: 0)
        }
        scheduleSave()
    }

    // MARK: Recents & history

    func recents(in termCode: String) -> [RecentCourse] {
        recents.filter { $0.termCode == termCode }
    }

    func recordView(_ key: CourseKey, termCode: String) {
        recents.removeAll { $0.key == key && $0.termCode == termCode }
        recents.insert(RecentCourse(termCode: termCode, key: key, viewedAt: .now), at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        scheduleSave()
    }

    func clearRecents() {
        recents.removeAll()
        scheduleSave()
    }

    func recordSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 12 { searchHistory.removeLast(searchHistory.count - 12) }
        scheduleSave()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        scheduleSave()
    }

    // MARK: Plans

    func plans(in termCode: String) -> [SchedulePlan] {
        plans.filter { $0.termCode == termCode }.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            return a.updatedAt > b.updatedAt
        }
    }

    func plan(id: UUID) -> SchedulePlan? { plans.first { $0.id == id } }

    func primaryPlan(in termCode: String) -> SchedulePlan? {
        plans.first { $0.termCode == termCode && $0.isPrimary }
    }

    @discardableResult
    func createPlan(name: String, termCode: String) -> SchedulePlan {
        var plan = SchedulePlan(name: name, termCode: termCode)
        // The first plan of a term becomes the primary schedule.
        plan.isPrimary = !plans.contains { $0.termCode == termCode }
        plan.revision = 1
        plans.append(plan)
        plansDidChange()
        return plan
    }

    /// Replaces the stored plan with the same id.
    func update(_ plan: SchedulePlan) {
        guard let i = plans.firstIndex(where: { $0.id == plan.id }) else { return }
        var updated = plan
        updated.updatedAt = .now
        updated.revision = (plans[i].revision ?? 0) + 1
        plans[i] = updated
        plansDidChange()
    }

    /// Mutates a plan in place.
    func updatePlan(id: UUID, _ change: (inout SchedulePlan) -> Void) {
        guard let i = plans.firstIndex(where: { $0.id == id }) else { return }
        let before = plans[i]
        change(&plans[i])
        guard plans[i] != before else { return }
        plans[i].updatedAt = .now
        plans[i].revision = (before.revision ?? 0) + 1
        plansDidChange()
    }

    func deletePlan(id: UUID) {
        guard let plan = plan(id: id) else { return }
        plans.removeAll { $0.id == id }
        if plan.isPrimary, let next = plans.firstIndex(where: { $0.termCode == plan.termCode }) {
            plans[next].isPrimary = true
        }
        plansDidChange()
    }

    @discardableResult
    func duplicatePlan(id: UUID) -> SchedulePlan? {
        guard var copy = plan(id: id) else { return nil }
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        copy.isPrimary = false
        copy.createdAt = .now
        copy.updatedAt = .now
        plans.append(copy)
        plansDidChange()
        return copy
    }

    func setPrimary(id: UUID) {
        guard let target = plan(id: id) else { return }
        for i in plans.indices where plans[i].termCode == target.termCode {
            let primary = plans[i].id == id
            if plans[i].isPrimary != primary {
                plans[i].isPrimary = primary
                plans[i].revision = (plans[i].revision ?? 0) + 1
                plans[i].updatedAt = .now
            }
        }
        plansDidChange()
    }

    /// Adds a course to a plan (no-op if present). Returns false if it was already there.
    @discardableResult
    func addCourse(_ key: CourseKey, toPlan id: UUID, required: Bool = true) -> Bool {
        var added = false
        updatePlan(id: id) { plan in
            guard !plan.contains(key) else { return }
            plan.courses.append(PlanCourse(key: key, isRequired: required, colorIndex: plan.nextColorIndex))
            added = true
        }
        return added
    }

    /// Removes a course and its chosen section. Favorited combinations that used
    /// the course are dropped too, since they can no longer be applied.
    func removeCourse(_ key: CourseKey, fromPlan id: UUID, sectionsOfCourse: [String] = []) {
        updatePlan(id: id) { plan in
            plan.courses.removeAll { $0.key == key }
            let crns = Set(sectionsOfCourse)
            plan.selectedCRNs.removeAll { crns.contains($0) }
            plan.favoriteCombinations.removeAll { combination in combination.contains { crns.contains($0) } }
        }
    }

    // MARK: Watchlist

    func watchItems(in termCode: String) -> [WatchItem] { watchlist.filter { $0.termCode == termCode } }

    func isWatching(crn: String, termCode: String) -> Bool {
        watchlist.contains { $0.crn == crn && $0.termCode == termCode }
    }

    func watch(_ section: CourseSection, courseTitle: String, termCode: String) {
        guard !isWatching(crn: section.crn, termCode: termCode) else { return }
        watchlist.insert(WatchItem(
            termCode: termCode,
            crn: section.crn,
            courseKey: section.courseKey,
            courseTitle: courseTitle,
            sectionLabel: "\(section.classType) · Section \(section.sectionNumber)",
            lastSeatsRemaining: section.seatsRemaining,
            lastWaitlistRemaining: section.waitlistRemaining,
            seatCapacity: section.seatCapacity,
            lastCheckedAt: .now
        ), at: 0)
        scheduleSave()
    }

    func unwatch(crn: String, termCode: String) {
        watchlist.removeAll { $0.crn == crn && $0.termCode == termCode }
        scheduleSave()
    }

    func toggleWatch(_ section: CourseSection, courseTitle: String, termCode: String) {
        if isWatching(crn: section.crn, termCode: termCode) {
            unwatch(crn: section.crn, termCode: termCode)
        } else {
            watch(section, courseTitle: courseTitle, termCode: termCode)
        }
    }

    func updateWatchItem(_ item: WatchItem) {
        guard let i = watchlist.firstIndex(where: { $0.id == item.id }) else { return }
        watchlist[i] = item
        scheduleSave()
    }

    func replaceWatchlist(_ items: [WatchItem]) {
        watchlist = items
        scheduleSave()
    }

    // MARK: Degree plans

    func degreePlan(id: UUID) -> DegreePlan? { degreePlans.first { $0.id == id } }

    /// The degree plan used for prerequisite checks and autofill: the starred one,
    /// else the most recently updated.
    var primaryDegreePlan: DegreePlan? {
        degreePlans.first(where: \.isPrimary) ?? degreePlans.max { $0.updatedAt < $1.updatedAt }
    }

    /// Degree plans, primary first, then most recently updated.
    var sortedDegreePlans: [DegreePlan] {
        degreePlans.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Adds a plan; the first one becomes primary.
    @discardableResult
    func addDegreePlan(_ plan: DegreePlan) -> DegreePlan {
        var plan = plan
        plan.sortTerms()
        if degreePlans.isEmpty { plan.isPrimary = true }
        if plan.isPrimary {
            for i in degreePlans.indices { degreePlans[i].isPrimary = false }
        }
        degreePlans.append(plan)
        scheduleSave()
        return plan
    }

    func updateDegreePlan(id: UUID, _ change: (inout DegreePlan) -> Void) {
        guard let i = degreePlans.firstIndex(where: { $0.id == id }) else { return }
        change(&degreePlans[i])
        degreePlans[i].sortTerms()
        degreePlans[i].updatedAt = .now
        scheduleSave()
    }

    /// Replaces a stored plan's contents (keeping its id and primary flag).
    func replaceDegreePlan(id: UUID, with plan: DegreePlan) {
        updateDegreePlan(id: id) { stored in
            let keepID = stored.id, keepPrimary = stored.isPrimary, keepCreated = stored.createdAt
            stored = plan
            stored.id = keepID
            stored.isPrimary = keepPrimary
            stored.createdAt = keepCreated
        }
    }

    func deleteDegreePlan(id: UUID) {
        let wasPrimary = degreePlan(id: id)?.isPrimary ?? false
        degreePlans.removeAll { $0.id == id }
        if wasPrimary, let next = degreePlans.indices.max(by: { degreePlans[$0].updatedAt < degreePlans[$1].updatedAt }) {
            degreePlans[next].isPrimary = true
        }
        scheduleSave()
    }

    func setPrimaryDegreePlan(id: UUID) {
        for i in degreePlans.indices { degreePlans[i].isPrimary = degreePlans[i].id == id }
        scheduleSave()
    }

    /// Courses the primary degree plan lists as completed (or in progress).
    var completedCourseKeys: Set<CourseKey> { primaryDegreePlan?.completedKeys ?? [] }

    /// Where the primary degree plan schedules a course, if anywhere.
    func plannedTerm(for key: CourseKey) -> DegreePlanTerm? {
        primaryDegreePlan?.terms.first { term in term.courses.contains { $0.key == key } }
    }

    // MARK: Reset

    /// Erases plans, watchlist, bookmarks, recents and search history.
    func resetAll(keepingPreferences: Bool = false) {
        if !keepingPreferences { preferences = AppPreferences() }
        saved = []
        recents = []
        plans = []
        watchlist = []
        searchHistory = []
        degreePlans = []
        plansDidChange()
    }

    // MARK: Persistence

    private func plansDidChange() {
        scheduleSave()
        onPlansChanged?()
    }

    /// True while a local edit is waiting to be written. External reloads wait for it.
    @ObservationIgnored private var hasPendingLocalEdit = false

    private func scheduleSave() {
        if !isApplyingRemoteChanges { hasUnreportedChanges = true }
        if !isApplyingRemoteChanges { hasPendingLocalEdit = true }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Picks up plan edits made by the local MCP server while this process is open.
    /// Does nothing while a local edit is still waiting to be saved, so the app's
    /// own change is not replaced by a file it has not written yet.
    func reloadExternalChanges() {
        guard !hasPendingLocalEdit, !isApplyingRemoteChanges else { return }
        guard let stored = try? UserDataFile.read(from: fileURL) else { return }
        let disk = stored.plans.map { ($0.id, $0.revision ?? 0, $0.updatedAt) }
        let local = plans.map { ($0.id, $0.revision ?? 0, $0.updatedAt) }
        guard disk.map(\.0) != local.map(\.0) || disk.map(\.1) != local.map(\.1) || disk.map(\.2) != local.map(\.2) else { return }
        isApplyingRemoteChanges = true
        plans = stored.plans
        isApplyingRemoteChanges = false
        onPlansChanged?()
    }

    /// Writes synchronously on the calling (main) actor. Use when the process may be
    /// suspended right after, e.g. at the end of a background refresh.
    func flushNow() {
        writeNow()
        reportChanges()
    }

    /// Writes immediately (call when the app moves to the background).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = data
        let url = fileURL
        hasPendingLocalEdit = false
        Task.detached(priority: .utility) {
            try? UserDataFile.write(snapshot, to: url)
        }
        reportChanges()
    }

    private func writeNow() {
        saveTask?.cancel()
        saveTask = nil
        hasPendingLocalEdit = false
        try? UserDataFile.write(data, to: fileURL)
    }

    private func reportChanges() {
        guard hasUnreportedChanges else { return }
        hasUnreportedChanges = false
        didChange?()
    }

    // MARK: iCloud sync

    /// Applies values received from iCloud: each save replaces the stored value with the same
    /// id (or is added) and each delete removes one. The result is written to disk right away,
    /// before the sync engine records the changes as fetched, and isn't reported through
    /// `didChange`, so nothing is sent back. Widgets update through `onPlansChanged` as usual.
    func applyRemoteChanges(saves: [CloudSyncEntity], deletes: [CloudSyncKey]) {
        guard !saves.isEmpty || !deletes.isEmpty else { return }
        let updated = data.applyingCloudChanges(saves: saves, deletes: deletes)
        let plansChanged = updated.plans != plans
        isApplyingRemoteChanges = true
        if updated.preferences != preferences { preferences = updated.preferences }
        if updated.saved != saved { saved = updated.saved }
        if updated.watchlist != watchlist { watchlist = updated.watchlist }
        if updated.degreePlans != degreePlans { degreePlans = updated.degreePlans }
        if plansChanged { plans = updated.plans }
        isApplyingRemoteChanges = false
        // Local edits still waiting to be reported stay flagged for the next save.
        writeNow()
        if plansChanged { onPlansChanged?() }
    }
}

