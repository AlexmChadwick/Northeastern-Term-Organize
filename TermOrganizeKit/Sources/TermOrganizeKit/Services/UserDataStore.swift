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
        let stored: UserData
        switch UserDataFile.inspect(at: fileURL) {
        case .ready(let data):
            stored = data
        case .missing, .unreadable:
            // An unreadable file is not an empty document. Leaving memory empty
            // here is safe because `writeNow` refuses to replace that file.
            stored = UserData()
        }
        preferences = stored.preferences
        saved = stored.saved
        recents = stored.recents
        plans = stored.plans
        watchlist = stored.watchlist
        searchHistory = stored.searchHistory
        degreePlans = stored.degreePlans
        loadedData = stored
        fileStamp = UserDataFile.stamp(of: stored, at: fileURL)
        startWatchingFile()
    }

    deinit {
        fileWatcher?.stop()
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

    /// True while a local edit is waiting to be written. A reload waits for the flush,
    /// and the flush merges instead of replacing an external write.
    @ObservationIgnored private var hasPendingLocalEdit = false
    /// The file contents last loaded or written, used as the merge base.
    @ObservationIgnored private var loadedData: UserData
    /// Revision map, modification time, and content hash of that load.
    @ObservationIgnored private var fileStamp: UserDataFileStamp
    /// Fires while the app is active, including after an atomic replace of the file.
    @ObservationIgnored private var fileWatcher: UserDataFileWatcher?

    private func scheduleSave() {
        guard !isApplyingRemoteChanges else { return }
        hasUnreportedChanges = true
        hasPendingLocalEdit = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Picks up plan edits made by the local MCP server. Does nothing while a local
    /// edit is still waiting to be saved; that flush merges the file instead.
    func reloadExternalChanges() {
        guard !hasPendingLocalEdit, !isApplyingRemoteChanges else { return }
        guard let snapshot = UserDataFile.snapshotIfChanged(at: fileURL, since: fileStamp) else { return }
        applySnapshot(snapshot)
    }

    /// Writes synchronously on the calling (main) actor. Use when the process may be
    /// suspended right after, e.g. at the end of a background refresh.
    func flushNow() {
        writeNow()
        reportChanges()
    }

    /// Writes immediately (call when the app moves to the background).
    func flush() {
        writeNow()
        reportChanges()
    }

    /// Before replacing `UserData.json`, compares it with the last load. Plans the
    /// two sides edited separately are combined. A plan both sides edited keeps the
    /// file version and also stores this process's version under a new name.
    private func writeNow() {
        saveTask?.cancel()
        saveTask = nil
        if case .unreadable = UserDataFile.inspect(at: fileURL) {
            scheduleSave()
            return
        }
        let outcome: UserDataSaveResolution
        do {
            outcome = try UserDataFile.writeResolvingConflicts(
                local: data, loaded: loadedData, baseline: fileStamp, to: fileURL)
        } catch {
            // The edit is still only in memory. Try again on the normal delay.
            scheduleSave()
            return
        }
        adopt(outcome)
        hasPendingLocalEdit = false
    }

    private func startWatchingFile() {
        let watcher = UserDataFileWatcher()
        fileWatcher = watcher
        watcher.start(fileURL: fileURL) { [weak self] in
            Task { @MainActor in
                self?.reloadExternalChanges()
            }
        }
    }

    private func applySnapshot(_ snapshot: UserDataFileSnapshot) {
        adopt(UserDataSaveResolution(data: snapshot.data, stamp: snapshot.stamp))
    }

    /// Installs `outcome` without scheduling another save.
    private func adopt(_ outcome: UserDataSaveResolution) {
        let merged = outcome.data
        isApplyingRemoteChanges = true
        if merged.preferences != preferences { preferences = merged.preferences }
        if merged.saved != saved { saved = merged.saved }
        if merged.recents != recents { recents = merged.recents }
        if merged.watchlist != watchlist { watchlist = merged.watchlist }
        if merged.searchHistory != searchHistory { searchHistory = merged.searchHistory }
        if merged.degreePlans != degreePlans { degreePlans = merged.degreePlans }
        let plansChanged = merged.plans != plans
        if plansChanged { plans = merged.plans }
        loadedData = merged
        fileStamp = outcome.stamp
        isApplyingRemoteChanges = false
        if plansChanged { onPlansChanged?() }
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

