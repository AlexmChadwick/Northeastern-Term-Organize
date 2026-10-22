//
//  DegreePlanLogic.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Prerequisite analysis

enum DegreePlanAnalysis {
    enum PrerequisiteStatus: Hashable, Sendable {
        /// No prerequisites, or all are covered.
        case met
        /// Something is still missing, e.g. `CS 3500` or `(CS 2100 or CS 2510)`.
        case missing(String)
        /// The course isn't in the catalog, so its prerequisites are unknown.
        case unknown

        var isMissing: Bool {
            if case .missing = self { return true }
            return false
        }
    }

    /// Everything done before a planned term: completed courses plus every earlier term.
    static func coursesBefore(termIndex: Int, in plan: DegreePlan) -> Set<CourseKey> {
        var keys = plan.completedKeys
        for term in plan.terms.prefix(max(0, termIndex)) {
            keys.formUnion(term.courses.compactMap(\.key))
        }
        return keys
    }

    /// Whether a planned course's prerequisites are covered by the time it's taken.
    ///
    /// The requisites come from `catalog` (any recent term works). A term's schedule only lists
    /// the courses taught in it, so for a course it doesn't list (or lists without details)
    /// `lookup` is asked: it answers from Banner's course catalog, which lists a course whether or
    /// not it has sections, and from earlier years for a course that has since been retired.
    /// `CourseInfoStore.requisiteLookup()` is that function. Without an answer the status is
    /// `.unknown`.
    ///
    /// `equivalences` say which courses count as which (a renumbered course and its
    /// replacement); the equivalences declared in the plan always apply too.
    static func prerequisiteStatus(
        of key: CourseKey,
        termIndex: Int,
        in plan: DegreePlan,
        catalog: CatalogIndex?,
        lookup: ((CourseKey) -> Requisite??)? = nil,
        equivalences: CourseEquivalences = .none
    ) -> PrerequisiteStatus {
        let taken = coursesBefore(termIndex: termIndex, in: plan)
        let counting = equivalences.merging(plan.declaredEquivalences)
        if let listed = catalog?.course(key), listed.detailsLoaded {
            return status(of: listed.prereqs, satisfiedBy: taken, equivalences: counting)
        }
        // `lookup` answers nil when it doesn't know the course, and `.some(nil)` when it knows
        // the course has no prerequisites.
        if let lookup, let known = lookup(key) {
            return status(of: known, satisfiedBy: taken, equivalences: counting)
        }
        return .unknown
    }

    /// Status of a requisite given a set of courses taken. Placement tests are
    /// assumed satisfied, since plans don't record them. A course counts as taken when an
    /// equivalent was.
    static func status(of requisite: Requisite?, satisfiedBy taken: Set<CourseKey>, equivalences: CourseEquivalences = .none) -> PrerequisiteStatus {
        guard let requisite, let missing = unmetSummary(requisite, satisfied: taken, equivalences: equivalences) else { return .met }
        return .missing(missing)
    }

    /// For each course a requisite names that was not taken itself but is covered by an equivalent
    /// that was, the equivalent: `[CS 2100: CS 2510]` for "Completed via CS 2510".
    static func coveringEquivalents(of requisite: Requisite, taken: Set<CourseKey>, equivalences: CourseEquivalences) -> [CourseKey: CourseKey] {
        var covering: [CourseKey: CourseKey] = [:]
        for key in requisite.referencedCourses where !taken.contains(key) {
            if let equivalent = equivalences.satisfier(of: key, in: taken) { covering[key] = equivalent }
        }
        return covering
    }

    /// The part of a requisite that isn't satisfied yet, in a few words; nil when satisfied.
    /// Kept short for status lines (the requisite tree has the details):
    /// - an unmet "or" of courses lists at most three (`CS 2100, CS 201M or 2 others`),
    /// - an "or" of larger options names the one needing the fewest courses
    ///   (`CS 2700 or another option`),
    /// - an "and" shows at most three parts (`NRSG 3344, NRSG 3345 and 6 more`).
    /// Repeated alternatives (Banner lists some several times) are shown once.
    static func unmetSummary(_ requisite: Requisite, satisfied: Set<CourseKey>, equivalences: CourseEquivalences = .none) -> String? {
        unmet(requisite, covered: equivalences.expanding(satisfied))
    }

    private static func unmet(_ requisite: Requisite, covered satisfied: Set<CourseKey>) -> String? {
        switch requisite {
        case .course(let key):
            return satisfied.contains(key) ? nil : key.description
        case .test:
            return nil
        case .and(let items):
            let parts = unique(items.compactMap { unmet($0, covered: satisfied) })
            switch parts.count {
            case 0, 1:
                return parts.first
            case 2, 3:
                return parts.map(parenthesizedIfCompound).joined(separator: " and ")
            default:
                return parts.prefix(2).map(parenthesizedIfCompound).joined(separator: ", ") + " and \(parts.count - 2) more"
            }
        case .or(let items):
            if items.contains(where: { unmet($0, covered: satisfied) == nil }) { return nil }
            let courses = items.compactMap { item -> CourseKey? in
                if case .course(let key) = item { return key }
                return nil
            }
            if courses.count == items.count {
                let names = unique(courses.map(\.description))
                return names.count <= 3
                    ? names.joined(separator: " or ")
                    : "\(names[0]), \(names[1]) or \(names.count - 2) others"
            }
            // The cheapest option (the first on a tie, as Banner lists the usual path first).
            guard let best = items.min(by: { count($0, covered: satisfied) < count($1, covered: satisfied) }),
                  let text = unmet(best, covered: satisfied) else { return requisite.summary }
            return "\(parenthesizedIfCompound(text)) or another option"
        }
    }

    /// The fewest courses still needed to satisfy a requisite.
    static func missingCount(_ requisite: Requisite, satisfied: Set<CourseKey>, equivalences: CourseEquivalences = .none) -> Int {
        count(requisite, covered: equivalences.expanding(satisfied))
    }

    private static func count(_ requisite: Requisite, covered satisfied: Set<CourseKey>) -> Int {
        switch requisite {
        case .course(let key): satisfied.contains(key) ? 0 : 1
        case .test: 0
        case .and(let items): items.reduce(0) { $0 + count($1, covered: satisfied) }
        case .or(let items): items.map { count($0, covered: satisfied) }.min() ?? 0
        }
    }

    private static func parenthesizedIfCompound(_ text: String) -> String {
        text.contains(" or ") || text.contains(" and ") || text.hasSuffix(" more") ? "(\(text))" : text
    }

    private static func unique(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }

    /// Courses the plan should warn about. A planned row is a duplicate of an earlier
    /// planned row, or of a completed row, when `DegreeCourseRepeats.countsSeparately`
    /// says they are the same course. Completed rows are compared with each other the
    /// same way. The warning does not stop the row from counting: the audit keeps every
    /// copy that has credit. Another section of the same number is not a duplicate when
    /// it counts on its own: a different CRN, or (when neither row has a CRN) a topics
    /// course taken again.
    static func duplicateKeys(in plan: DegreePlan) -> Set<CourseKey> {
        let planned = plan.terms.flatMap(\.courses)
        let completed = plan.completed
        var duplicates = Set<CourseKey>()
        for (index, course) in planned.enumerated() {
            guard let key = course.key else { continue }
            let repeatsPlanned = planned[..<index].contains { $0.key == key && !DegreeCourseRepeats.countsSeparately($0, course) }
            let repeatsCompleted = completed.contains { $0.key == key && !DegreeCourseRepeats.countsSeparately($0, course) }
            if repeatsPlanned || repeatsCompleted { duplicates.insert(key) }
        }
        for (index, course) in completed.enumerated() {
            guard let key = course.key else { continue }
            let repeatsEarlier = completed[..<index].contains { $0.key == key && !DegreeCourseRepeats.countsSeparately($0, course) }
            if repeatsEarlier { duplicates.insert(key) }
        }
        return duplicates
    }
}

// MARK: - Autofill

/// A ready-made set of courses to start a new schedule with.
struct ScheduleAutofillSuggestion: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case degreePlan(id: UUID, termID: UUID)
        case schedulePlan(id: UUID)
    }

    var source: Source
    /// The name of the plan the courses come from, e.g. `New Plan`.
    var planName: String
    /// The degree plan's semester, e.g. `Spring 2027`; nil for a copy of a schedule.
    var semester: String?
    /// e.g. `From “New Plan” · Spring 2027`.
    var title: String
    /// e.g. `Your plan for this term` or `Closest planned term`.
    var detail: String
    /// True when the plan's term is the same semester as the schedule's.
    var isExactTerm: Bool
    /// Courses to add (offered this term, when that's known).
    var courses: [CourseKey]
    /// Planned courses that aren't offered this term.
    var unavailable: [CourseKey]

    var id: String {
        switch source {
        case .degreePlan(let id, let termID): "degree-\(id)-\(termID)"
        case .schedulePlan(let id): "schedule-\(id)"
        }
    }
}

enum DegreePlanAutofill {
    /// Month index (for "closest term" math) of a Banner term.
    static func monthIndex(of term: Term) -> Int {
        let season = PlanSeason(termSeason: term.season)
        return term.calendarYear * 12 + season.startMonth - 1
    }

    /// Suggestions for filling a schedule plan in `term`, best first:
    /// 1. the degree plan's courses for this exact semester,
    /// 2. other schedule plans for the same term,
    /// 3. the degree plan's closest semester that has courses.
    /// Completed courses and courses already in the schedule are left out.
    static func scheduleSuggestions(
        for term: Term,
        degreePlans: [DegreePlan],
        schedulePlans: [SchedulePlan],
        excludingPlanID: UUID? = nil,
        alreadyInPlan: Set<CourseKey> = [],
        index: CatalogIndex?
    ) -> [ScheduleAutofillSuggestion] {
        let target = monthIndex(of: term)
        var exact: [ScheduleAutofillSuggestion] = []
        var closest: [ScheduleAutofillSuggestion] = []

        func split(_ keys: [CourseKey]) -> (offered: [CourseKey], unavailable: [CourseKey]) {
            guard let index, index.term.code == term.code else { return (keys, []) }
            var offered: [CourseKey] = [], unavailable: [CourseKey] = []
            for key in keys {
                if index.sections(for: key).isEmpty { unavailable.append(key) } else { offered.append(key) }
            }
            return (offered, unavailable)
        }

        for plan in degreePlans.sorted(by: { ($0.isPrimary ? 0 : 1, -$0.updatedAt.timeIntervalSince1970) < ($1.isPrimary ? 0 : 1, -$1.updatedAt.timeIntervalSince1970) }) {
            let done = plan.completedKeys
            let candidates = plan.terms.compactMap { planTerm -> (DegreePlanTerm, [CourseKey], Int)? in
                var seen = Set<CourseKey>()
                let keys = planTerm.courses.compactMap(\.key).filter { !done.contains($0) && !alreadyInPlan.contains($0) && seen.insert($0).inserted }
                guard !keys.isEmpty else { return nil }
                return (planTerm, keys, abs(planTerm.monthIndex - target))
            }
            // Closest semester; on a tie prefer the later one (plans look forward).
            guard let best = candidates.min(by: { ($0.2, -$0.0.sortKey) < ($1.2, -$1.0.sortKey) }) else { continue }
            let (planTerm, keys, distance) = best
            let parts = split(keys)
            guard !parts.offered.isEmpty || !parts.unavailable.isEmpty else { continue }
            let isExact = planTerm.matches(term)
            let suggestion = ScheduleAutofillSuggestion(
                source: .degreePlan(id: plan.id, termID: planTerm.id),
                planName: plan.name,
                semester: planTerm.shortName,
                title: "From “\(plan.name)” · \(planTerm.shortName)",
                detail: isExact ? "Your plan for this term" : (distance == 0 ? "Planned for this time" : "Closest semester you planned"),
                isExactTerm: isExact,
                courses: parts.offered,
                unavailable: parts.unavailable
            )
            if isExact { exact.append(suggestion) } else { closest.append(suggestion) }
        }

        let copies: [ScheduleAutofillSuggestion] = schedulePlans
            .filter { $0.termCode == term.code && $0.id != excludingPlanID && !$0.courses.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(2)
            .compactMap { plan in
                let keys = plan.courses.map(\.key).filter { !alreadyInPlan.contains($0) }
                guard !keys.isEmpty else { return nil }
                return ScheduleAutofillSuggestion(
                    source: .schedulePlan(id: plan.id),
                    planName: plan.name,
                    semester: nil,
                    title: "Copy “\(plan.name)”",
                    detail: plan.isPrimary ? "Your schedule for this term" : "Another schedule for this term",
                    isExactTerm: true,
                    courses: keys,
                    unavailable: []
                )
            }

        return exact + copies + closest
    }

    /// A draft for a new degree plan: a copy of the closest previous plan (the
    /// primary one), updated with the courses in your "My Schedule" plans for
    /// terms that haven't ended.
    static func newDegreePlanDraft(
        name: String,
        basedOn source: DegreePlan?,
        schedulePlans: [SchedulePlan],
        catalogIndex: (String) -> CatalogIndex?,
        now: Date = .now
    ) -> DegreePlan {
        var draft = DegreePlan(name: name)
        if let source {
            draft.program = source.program
            draft.studentName = source.studentName
            draft.studentID = source.studentID
            // Same degree: same catalog year, program, concentration and approved substitutions.
            draft.catalogYear = source.catalogYear
            draft.catalogProgramPath = source.catalogProgramPath
            draft.catalogProgramTitle = source.catalogProgramTitle
            draft.concentrationID = source.concentrationID
            draft.substitutions = source.substitutions.map { var copy = $0; copy.id = UUID(); return copy }
            // Equivalences are facts about the student's courses, not about one plan.
            draft.courseEquivalences = source.courseEquivalences.map { var copy = $0; copy.id = UUID(); return copy }
            draft.completed = source.completed.map { var c = $0; c.id = UUID(); return c }
            draft.terms = source.terms.map { term in
                var copy = term
                copy.id = UUID()
                copy.courses = term.courses.map { var c = $0; c.id = UUID(); return c }
                return copy
            }
        }

        for plan in schedulePlans where plan.isPrimary && !plan.courses.isEmpty {
            if let window = TermCalendar.approximateWindow(for: plan.termCode), window.upperBound < now { continue }
            let term = Term(code: plan.termCode, bannerDescription: "")
            let season = PlanSeason(termSeason: term.season)
            let index = catalogIndex(plan.termCode)
            let termPosition: Int
            if let existing = draft.terms.firstIndex(where: { $0.season == season && $0.year == term.calendarYear }) {
                termPosition = existing
            } else {
                draft.terms.append(DegreePlanTerm(season: season, year: term.calendarYear))
                termPosition = draft.terms.count - 1
            }
            var unmatched = draft.terms[termPosition].courses + draft.completed
            for planCourse in plan.courses {
                let crn = chosenCRN(planCourse, in: plan, index: index)
                // One schedule row lines up with one degree-plan row. A second copy of the
                // same number is not absorbed by the first, even when neither has a CRN.
                if let match = unmatched.firstIndex(where: { row in
                    guard row.key == planCourse.key else { return false }
                    return Self.sameSection(row.crn, crn)
                }) {
                    unmatched.remove(at: match)
                    continue
                }
                let course = index?.course(planCourse.key)
                let added = DegreePlanCourse(
                    key: planCourse.key,
                    title: DegreePlanFormat.exportTitle(course?.title ?? planCourse.key.description),
                    credits: course?.maxCredits ?? 4,
                    crn: crn
                )
                draft.terms[termPosition].courses.append(added)
            }
        }
        draft.sortTerms()
        return draft
    }

    /// Whether two copied rows name the same section. Nil and a blank CRN are the same.
    private static func sameSection(_ stored: String?, _ incoming: String?) -> Bool {
        func pin(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        return pin(stored) == pin(incoming)
    }

    /// The section a schedule row should copy onto a degree plan. A stored pin wins.
    /// A single row whose choice lives only in `selectedCRNs` still copies that CRN.
    private static func chosenCRN(_ planCourse: PlanCourse, in plan: SchedulePlan, index: CatalogIndex?) -> String? {
        if let crn = planCourse.pinnedCRN, !crn.isEmpty { return crn }
        let siblings = plan.courses.contains { $0.key == planCourse.key && $0.id != planCourse.id }
        guard !siblings, let index else { return nil }
        let matches = plan.selectedCRNs.filter { index.section(crn: $0)?.courseKey == planCourse.key }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The next few semesters after the plan's last one (or after now), for "Add semester".
    static func nextSemesters(after plan: DegreePlan, count: Int = 4, now: Date = .now) -> [DegreePlanTerm] {
        let order: [PlanSeason] = [.spring, .summerA, .summerB, .fall]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TermCalendar.newYork
        var year = calendar.component(.year, from: now)
        var seasonIndex: Int = {
            let month = calendar.component(.month, from: now)
            return month < 5 ? 0 : (month < 7 ? 1 : (month < 9 ? 2 : 3))
        }()
        if let last = plan.terms.last, let i = order.firstIndex(of: last.season) {
            year = last.year
            seasonIndex = i + 1
        }
        let existing = Set(plan.terms.map { "\($0.season.rawValue)-\($0.year)" })
        var result: [DegreePlanTerm] = []
        while result.count < count {
            if seasonIndex >= order.count { seasonIndex = 0; year += 1 }
            let candidate = DegreePlanTerm(season: order[seasonIndex], year: year)
            if !existing.contains("\(candidate.season.rawValue)-\(candidate.year)") { result.append(candidate) }
            seasonIndex += 1
        }
        return result
    }
}
