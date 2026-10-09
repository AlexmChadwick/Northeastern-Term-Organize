//
//  ScheduleReorderSuggestions.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - What the generator screen shows

/// One way to rearrange the degree plan so this semester's courses work, as the generator screen
/// shows it: a title, why it's a good idea, and what applying it does.
struct ScheduleReorderOption: Identifiable {
    var id: String
    /// e.g. `Move CS 3386 to Spring 2028`.
    var title: String
    /// Short facts, e.g. `Offered every spring`, `Prerequisites still met`, `Offering history unknown`.
    var reasons: [String]
    /// Applying it adds a semester to the degree plan.
    var addsSemester: Bool
    /// The courses that leave this schedule's semester.
    var movedAway: [CourseKey]
    /// The courses that come into it (a swap).
    var movedIn: [CourseKey]
    /// Edits a copy of the degree plan (the real change is made through `UserDataStore.updateDegreePlan`).
    var apply: @Sendable (inout DegreePlan) -> Void

    /// `Moved CS 3386 to Spring 2028`.
    var appliedText: String {
        guard title.hasPrefix("Move ") else { return "Updated your degree plan" }
        return "Moved " + title.dropFirst("Move ".count)
    }

    /// What applying it does to this schedule, for the confirmation: `CS 3386 comes out of this schedule.`
    var scheduleEffect: String {
        var parts: [String] = []
        if !movedAway.isEmpty {
            parts.append("\(Self.list(movedAway)) \(movedAway.count == 1 ? "comes" : "come") out of this schedule.")
        }
        if !movedIn.isEmpty {
            parts.append("\(Self.list(movedIn)) will be added to it if \(movedIn.count == 1 ? "it’s" : "they’re") offered this term.")
        }
        return parts.joined(separator: " ")
    }

    /// `CS 3386`, `CS 3386 and CS 4100`, `CS 3386, CS 4100 and DS 3000`.
    static func list(_ keys: [CourseKey]) -> String {
        let names = keys.map(\.description)
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }
}

struct ScheduleReorderResult {
    var options: [ScheduleReorderOption] = []
    /// False when it couldn’t be checked when the courses were last offered (offline): the options say so.
    var historyKnown = true
}

/// Where the "rearrange your degree plan" suggestions stand.
enum ScheduleReorderState {
    enum Reason {
        /// There is no degree plan to rearrange.
        case noDegreePlan
        /// The degree plan has no semester for this schedule's term, or nothing blocks.
        case notApplicable
    }

    case unavailable(Reason)
    case loading
    case ready(ScheduleReorderResult)
}

// MARK: - The engine

/// Asks the degree plan reordering engine (`DegreePlanReordering`) how to move the blocking courses of
/// a semester to other semesters, using when the courses have been offered before (`OfferingHistory`)
/// and what they require (the loaded catalogs, then `CourseInfoStore`).
enum ScheduleReorderSuggestions {
    /// Gives up waiting for the network after this long (per step) and works with what has arrived.
    static let patience: Duration = .seconds(30)

    /// The suggestions for moving `blocking` courses out of `term`, which must be a semester of `degreePlan`.
    /// Never throws: with no network the suggestions come without offering history (and say so).
    ///
    /// To keep Banner traffic modest it first asks when the blocking courses themselves are taught; only
    /// when that finds no way to simply move one of them does it also look up the courses of later
    /// semesters, to find one to swap places with.
    ///
    /// - Parameter indexes: the loaded catalogs, newest first.
    @MainActor
    static func load(blocking: [CourseKey], degreePlan: DegreePlan, term: Term, indexes: [CatalogIndex]) async -> ScheduleReorderResult {
        var plan = degreePlan
        plan.sortTerms()
        guard let origin = plan.terms.first(where: { $0.matches(term) }) else { return ScheduleReorderResult() }
        // Only courses the degree plan has in this semester can be moved.
        let inSemester = Set(origin.courses.compactMap(\.key))
        let candidates = blocking.filter(inSemester.contains)
        guard !candidates.isEmpty else { return ScheduleReorderResult() }

        let planned = plan.terms.flatMap { $0.courses.compactMap(\.key) }
        let later = Array(plan.terms.drop { $0.id != origin.id }.dropFirst().flatMap { $0.courses.compactMap(\.key) })
        let store = CourseInfoStore.shared

        // What each planned course requires, and when the blocking courses were last taught, in parallel.
        let infoTask = Task { await store.load(planned + candidates, indexes: indexes) }
        let historyTask = Task { await store.offeringHistory(for: candidates, indexes: indexes) }
        var history = await patiently(historyTask, alsoCancelling: { infoTask.cancel() })
        _ = await patiently(infoTask)
        guard !Task.isCancelled else { return ScheduleReorderResult() }

        func suggestions() -> [DegreePlanReordering.Suggestion] {
            DegreePlanReordering.suggestions(
                for: degreePlan,
                termID: origin.id,
                blocking: candidates,
                history: history,
                prerequisites: requisiteLookup(indexes: indexes, store: store),
                equivalences: store.equivalences(for: degreePlan)
            )
        }
        var found = suggestions()
        if found.contains(where: { $0.moves.count == 1 }) {
            // Simply moving a course is enough: swaps with courses whose history wasn't asked for would only add noise.
            found = found.filter { $0.moves.count == 1 }
        } else if !later.isEmpty {
            // A swap needs to know that the course coming back is taught in this season.
            let swapHistory = Task { await store.offeringHistory(for: later, indexes: indexes) }
            history = history.merging(await patiently(swapHistory))
            guard !Task.isCancelled else { return ScheduleReorderResult() }
            found = suggestions()
        }
        return ScheduleReorderResult(
            options: found.map { option(from: $0, origin: origin) },
            historyKnown: !history.checkedTerms.isEmpty
        )
    }

    /// The task's value, cancelling it (and whatever `alsoCancelling` stops) after `patience`, or at once
    /// when the caller is cancelled.
    @MainActor
    private static func patiently<T: Sendable>(_ task: Task<T, Never>, alsoCancelling other: @escaping @Sendable () -> Void = {}) async -> T {
        let watchdog = Task {
            // A cancelled sleep means the work finished (or the caller left) in time.
            do { try await Task.sleep(for: patience) } catch { return }
            task.cancel()
            other()
        }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            other()
            watchdog.cancel()
        }
        watchdog.cancel()
        return value
    }

    /// A course's prerequisites: nil when unknown, `.some(nil)` when it has none. The loaded catalogs
    /// answer first (a stub whose details weren't fetched yet knows nothing), then the course info store.
    @MainActor
    static func requisiteLookup(indexes: [CatalogIndex], store: CourseInfoStore) -> (CourseKey) -> Requisite?? {
        let fromStore = store.requisiteLookup()
        return { key in
            for index in indexes {
                if let course = index.course(key), course.detailsLoaded { return .some(course.prereqs) }
            }
            return fromStore(key)
        }
    }

    /// The engine's suggestion as the generator screen shows it.
    static func option(from suggestion: DegreePlanReordering.Suggestion, origin: DegreePlanTerm) -> ScheduleReorderOption {
        ScheduleReorderOption(
            id: suggestion.id,
            title: suggestion.title,
            reasons: suggestion.reasons,
            addsSemester: suggestion.addsSemester != nil,
            movedAway: suggestion.moves.filter { $0.from == origin.id }.map(\.course),
            movedIn: suggestion.moves.filter { $0.to == origin.id }.map(\.course),
            apply: { DegreePlanReordering.apply(suggestion, to: &$0) }
        )
    }
}
