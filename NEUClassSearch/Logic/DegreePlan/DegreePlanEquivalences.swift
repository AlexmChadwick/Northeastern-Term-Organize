//
//  DegreePlanEquivalences.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - The plan's courses

extension DegreePlan {
    /// The planned courses, each once, in plan order.
    var degreePlanPlannedKeys: [CourseKey] {
        var seen = Set<CourseKey>()
        return terms.flatMap { $0.courses.compactMap(\.key) }.filter { seen.insert($0).inserted }
    }

    /// The completed courses, each once, in plan order.
    var degreePlanCompletedKeys: [CourseKey] {
        var seen = Set<CourseKey>()
        return completed.compactMap(\.key).filter { seen.insert($0).inserted }
    }

    /// Completed, then planned courses, each once.
    var degreePlanCourseKeys: [CourseKey] {
        var seen = Set<CourseKey>()
        return (degreePlanCompletedKeys + degreePlanPlannedKeys).filter { seen.insert($0).inserted }
    }

    /// `Counts as CS 2100`, for a course the student declared equivalent to another.
    func degreeEquivalenceNote(for key: CourseKey?) -> String? {
        guard let key else { return nil }
        let targets = courseEquivalences.filter { $0.course == key }.map(\.countsAs.description)
        return targets.isEmpty ? nil : "Counts as \(targets.joined(separator: ", "))"
    }
}

// MARK: - Course information

extension CourseInfoStore {
    /// Where the lookups of some courses stand, as a value the plan review can keep.
    func degreeLookupStates(for keys: some Sequence<CourseKey>) -> [CourseKey: LookupState] {
        var states: [CourseKey: LookupState] = [:]
        for key in keys where states[key] == nil {
            states[key] = state(for: key)
        }
        return states
    }

    /// Looks the plan's courses up in Banner's course catalog: planned ones first (their
    /// prerequisites are checked), then completed ones (which may have been renumbered since).
    func degreePlanLoad(_ plan: DegreePlan, indexes: [CatalogIndex]) async {
        await load(plan.degreePlanPlannedKeys, indexes: indexes)
        await load(plan.degreePlanCompletedKeys, indexes: indexes)
        // NUpath attributes, for the NUpath requirements.
        await loadAttributes(plan.degreePlanCourseKeys, indexes: indexes)
    }
}

extension CourseInfoStore.LookupState {
    /// Only catalogs older than the newest term list the course.
    var degreeIsRetired: Bool {
        if case .found(let info) = self { return info.isRetired == true }
        return false
    }

    /// `No longer offered; last listed Spring 2025` for a retired course.
    var degreeRetiredNote: String? {
        guard case .found(let info) = self, info.isRetired == true else { return nil }
        return "No longer offered; last listed \(OfferingHistory.label(ofTerm: info.sourceTerm))"
    }

    var degreeInfo: CourseInfo? {
        if case .found(let info) = self { return info }
        return nil
    }
}

// MARK: - Suggestions

/// "Does CS 2510 count as CS 2100?": an equivalence that prerequisite data hints at, for the
/// student to confirm. It is never applied on its own.
struct DegreeEquivalencePrompt: Identifiable, Hashable {
    /// The course the student has (or would take).
    var course: CourseKey
    /// The course it would count as.
    var countsAs: CourseKey
    /// Why it's suggested: `Listed together in 7 of the 10 prerequisites that name CS 2510`.
    var evidence: String

    var id: String { Self.pairID(course, countsAs) }

    /// `Does CS 2510 count as CS 2100?`, keeping each code on one line.
    var question: String { "Does \(Self.unbroken(course)) count as \(Self.unbroken(countsAs))?" }

    private static func unbroken(_ key: CourseKey) -> String { "\(key.subject)\u{00A0}\(key.number)" }

    /// The same for either order, so a dismissed suggestion stays dismissed both ways.
    static func pairID(_ a: CourseKey, _ b: CourseKey) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }
}

/// The suggestions a screen shows: for courses of the plan that the catalog no longer lists,
/// and for courses a requirement lists that the plan doesn't have.
struct DegreeEquivalencePrompts {
    /// One per retired course of the plan, in plan order.
    var forPlanCourses: [DegreeEquivalencePrompt] = []
    fileprivate var byListedCourse: [CourseKey: DegreeEquivalencePrompt] = [:]

    /// A suggestion that would let the plan satisfy a listed course it doesn't have.
    func forListed(_ key: CourseKey) -> DegreeEquivalencePrompt? { byListedCourse[key] }

    /// The suggestion for a course of the plan that the catalog no longer lists.
    func forPlanCourse(_ key: CourseKey) -> DegreeEquivalencePrompt? { forPlanCourses.first { $0.course == key } }
}

/// Builds suggestions only when their inputs change: what Banner's course catalog has said
/// (`CourseInfoStore.version`, so titles that arrive count), which courses could have one (the
/// newest term doesn't list them and Banner says they were retired, or doesn't know them), the
/// requirements' titles and courses, the equivalences already known, and the dismissed ones.
/// Each suggestion reads every prerequisite of the newest term. Keep one in `@State`.
@MainActor
final class DegreeEquivalenceSuggestionCache {
    private struct Key: Equatable {
        var version: Int
        var planKeys: [CourseKey]
        var eligible: [CourseKey]
        var catalogTitles: [CourseKey: String]
        var alsoComparing: [CourseKey]
        var equivalences: CourseEquivalences
        var dismissed: Set<String>
        var newestTerm: String?
        var newestUpdatedAt: Date?
    }

    private var key: Key?
    private var cached = DegreeEquivalencePrompts()

    /// - Parameters:
    ///   - listed: courses a requirement lists that the plan doesn't have.
    ///   - newest: the newest loaded term (the one `CourseInfoStore` reads prerequisites from).
    ///   - catalogTitles: the degree requirements' course titles (`ProgramRequirements.courseTitles`).
    ///   - alsoComparing: the courses the requirements list, compared by title with the plan's
    ///     (a retired IS 4300 a requirement names, and the plan's CS 2484).
    func prompts(for plan: DegreePlan, listed: [CourseKey] = [], dismissed: Set<String>, info: CourseInfoStore,
                 newest: CatalogIndex?, catalogTitles: [CourseKey: String] = [:], alsoComparing: [CourseKey] = []) -> DegreeEquivalencePrompts {
        let planKeys = plan.degreePlanCourseKeys
        let inPlan = Set(planKeys)
        let candidates = planKeys + listed.filter { !inPlan.contains($0) }
        // The same test `CourseInfoStore.equivalenceSuggestions` starts with.
        let eligible = candidates.filter { key in
            guard newest?.course(key) == nil else { return false }
            switch info.state(for: key) {
            case .found(let found): return found.isRetired != false
            case .notFound: return true
            case .unknown, .loading, .failed: return false
            }
        }
        let key = Key(version: info.version, planKeys: planKeys, eligible: eligible, catalogTitles: catalogTitles,
                      alsoComparing: alsoComparing, equivalences: info.equivalences(for: plan), dismissed: dismissed,
                      newestTerm: newest?.term.code, newestUpdatedAt: newest?.catalog.sectionsUpdatedAt)
        if key == self.key { return cached }
        self.key = key
        cached = Self.build(plan: plan, planKeys: planKeys, eligible: Set(eligible), listed: listed, dismissed: dismissed, info: info,
                            catalogTitles: catalogTitles, alsoComparing: alsoComparing)
        return cached
    }

    private static func build(plan: DegreePlan, planKeys: [CourseKey], eligible: Set<CourseKey>, listed: [CourseKey],
                              dismissed: Set<String>, info: CourseInfoStore,
                              catalogTitles: [CourseKey: String], alsoComparing: [CourseKey]) -> DegreeEquivalencePrompts {
        var result = DegreeEquivalencePrompts()
        let inPlan = Set(planKeys)
        func open(_ course: CourseKey) -> [EquivalenceSuggestion] {
            guard eligible.contains(course) else { return [] }
            return info.equivalenceSuggestions(for: course, plan: plan, catalogTitles: catalogTitles, alsoComparing: alsoComparing).filter {
                !dismissed.contains(DegreeEquivalencePrompt.pairID(course, $0.candidate))
            }
        }

        // A course of the plan the catalog no longer lists may count as a current one.
        for key in planKeys {
            let suggestions = open(key)
            if let best = suggestions.first {
                result.forPlanCourses.append(DegreeEquivalencePrompt(course: key, countsAs: best.candidate, evidence: best.evidence))
            }
            for suggestion in suggestions where result.byListedCourse[suggestion.candidate] == nil {
                result.byListedCourse[suggestion.candidate] = DegreeEquivalencePrompt(
                    course: key, countsAs: suggestion.candidate, evidence: suggestion.evidence
                )
            }
        }

        // A listed course the catalog no longer lists may have been replaced by one the plan has
        // (or one it could have; its row says it's no longer offered).
        for key in listed where !inPlan.contains(key) && result.byListedCourse[key] == nil {
            let suggestions = open(key)
            guard let best = suggestions.first(where: { inPlan.contains($0.candidate) }) ?? suggestions.first else { continue }
            result.byListedCourse[key] = DegreeEquivalencePrompt(course: best.candidate, countsAs: key, evidence: best.evidence)
        }
        return result
    }
}

/// Suggestions the student dismissed, kept on this device (`@AppStorage(storageKey)`).
/// The same store as the course pages', so a dismissal holds everywhere.
typealias DegreeEquivalenceDismissals = EquivalenceSuggestionDismissals

// MARK: - Declaring

extension UserDataStore {
    /// Declares in a plan that `course` counts as `countsAs` (everywhere: prerequisites and
    /// degree requirements). Returns the new equivalence's id, or nil when the plan already
    /// counts them as each other.
    @discardableResult
    func declareDegreeEquivalence(planID: UUID, course: CourseKey, countsAs: CourseKey, note: String = "") -> UUID? {
        guard let plan = degreePlan(id: planID), course != countsAs,
              !plan.declaredEquivalences.areEquivalent(course, countsAs) else { return nil }
        var added: UUID?
        updateDegreePlan(id: planID) { plan in
            if plan.declareEquivalence(course: course, countsAs: countsAs, note: note) {
                added = plan.courseEquivalences.last?.id
            }
        }
        return added
    }
}

// MARK: - Editing

/// What the equivalence sheet starts with.
struct DegreeEquivalenceRequest: Identifiable {
    let id = UUID()
    var planID: UUID
    /// The course the student has, when known (a plan course's "Counts as another course…").
    var course: CourseKey?
    /// The course it counts as, when known (a requirement's "Same course, different number…").
    var countsAs: CourseKey?
    /// The equivalence being edited.
    var existing: CourseEquivalence?
}
