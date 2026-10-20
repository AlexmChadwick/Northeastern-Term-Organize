//
//  DegreePlanReordering.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Suggests how to reorder a degree plan when one of its semesters can't be scheduled, because
/// some of its courses aren't taught then: move such a course to a later semester, swap it with a
/// course of a later semester that is taught now, or add a semester for it.
///
/// A course only moves to a semester whose season it is likely taught in (from its
/// `OfferingHistory`; when the history can't say, the move is still offered but ranked lower),
/// when its prerequisites are met by everything before that semester, when nothing that needs
/// it is planned at or before that semester, and when the semester stays within the credit
/// limit. Prerequisites count equivalent courses (`CourseEquivalences`).
///
/// Everything here is a pure function of the plan, so it is easy to test.
enum DegreePlanReordering {
    /// A course moving from one semester of the plan to another (by `DegreePlanTerm.id`).
    struct Move: Hashable, Sendable {
        var course: CourseKey
        var from: UUID
        var to: UUID
    }

    struct Suggestion: Identifiable, Hashable, Sendable {
        /// Stable for the same suggestion on the same plan.
        var id: String
        var moves: [Move]
        /// e.g. `Move CS 3386 to Spring 2028`.
        var title: String
        /// Why it works, e.g. `Offered every spring`, `Prerequisites still met`,
        /// `Spring 2028 would have 12 credits`.
        var reasons: [String]
        /// A semester to add to the plan first, when the course needs one the plan doesn't have.
        var addsSemester: DegreePlanTerm?
    }

    /// At most this many suggestions are returned.
    static let maxSuggestions = 5

    // MARK: - Suggestions

    /// Ways to reorder `plan` so the semester `termID` no longer holds the `blocking` courses.
    ///
    /// Ranked by the fewest moves (a swap is two), then the earliest target semester, then how
    /// sure the offering history and the prerequisite check are.
    ///
    /// - Parameters:
    ///   - blocking: courses of the semester that can't be scheduled (not taught this term).
    ///   - history: from `CourseInfoStore.offeringHistory(for:)`; include the blocking courses and
    ///     the courses of later semesters (swap candidates).
    ///   - prerequisites: a course's prerequisites: nil when unknown, `.some(nil)` when it has
    ///     none (`CourseInfoStore.requisiteLookup()` is one).
    ///   - equivalences: which courses count as which; the plan's declared ones always apply.
    ///   - maxCreditsPerTerm: a semester isn't loaded past this many credits.
    static func suggestions(
        for plan: DegreePlan,
        termID: UUID,
        blocking: [CourseKey],
        history: OfferingHistory,
        prerequisites: (CourseKey) -> Requisite??,
        equivalences: CourseEquivalences,
        maxCreditsPerTerm: Double = 20
    ) -> [Suggestion] {
        var plan = plan
        plan.sortTerms()
        guard let origin = plan.terms.firstIndex(where: { $0.id == termID }) else { return [] }

        var requirements: [CourseKey: Requirements] = [:]
        for key in plan.terms.flatMap({ $0.courses.compactMap(\.key) }) where requirements[key] == nil {
            switch prerequisites(key) {
            case .none: requirements[key] = .unknown
            case .some(.none): requirements[key] = .nothing
            case .some(.some(let requisite)): requirements[key] = .needs(requisite)
            }
        }
        let engine = Engine(
            plan: plan,
            origin: origin,
            history: history,
            requirements: requirements,
            equivalences: equivalences.merging(plan.declaredEquivalences),
            maxCredits: maxCreditsPerTerm
        )

        var candidates: [Candidate] = []
        var seen = Set<CourseKey>()
        for (order, key) in blocking.enumerated() where seen.insert(key).inserted {
            guard let course = plan.terms[origin].courses.first(where: { $0.key == key }) else { continue }
            candidates += engine.candidates(for: course, order: order, blocking: Set(blocking))
        }
        candidates.sort { $0.rank < $1.rank }
        return candidates.prefix(maxSuggestions).map(\.suggestion)
    }

    // MARK: - Applying

    /// Makes a suggestion's changes: adds the semester it needs, then moves each course to the
    /// end of its new semester. Does nothing when the plan no longer matches the suggestion (a
    /// course or semester has gone), so a stale suggestion can't half-apply.
    static func apply(_ suggestion: Suggestion, to plan: inout DegreePlan) {
        var updated = plan
        var semesterID: [UUID: UUID] = [:]
        if let semester = suggestion.addsSemester {
            if let existing = updated.terms.first(where: { $0.season == semester.season && $0.year == semester.year }) {
                // The plan got the semester since: use it.
                semesterID[semester.id] = existing.id
            } else {
                updated.terms.append(semester)
                updated.sortTerms()
            }
        }
        for move in suggestion.moves {
            guard performMove(move.course, from: move.from, to: semesterID[move.to] ?? move.to, in: &updated) else { return }
        }
        plan = updated
    }

    /// Moves the first planned `course` of semester `from` to the end of semester `to`.
    @discardableResult
    private static func performMove(_ course: CourseKey, from: UUID, to: UUID, in plan: inout DegreePlan) -> Bool {
        guard let source = plan.terms.firstIndex(where: { $0.id == from }),
              let target = plan.terms.firstIndex(where: { $0.id == to }),
              let position = plan.terms[source].courses.firstIndex(where: { $0.key == course }) else { return false }
        let moved = plan.terms[source].courses.remove(at: position)
        plan.terms[target].courses.append(moved)
        return true
    }

    // MARK: - Candidates

    /// What a course needs before it. (Not an optional, so `.none` can't be mistaken for "no entry".)
    private enum Requirements {
        /// Its prerequisites aren't known.
        case unknown
        /// It has none.
        case nothing
        case needs(Requisite)
    }

    /// Whether a course's prerequisites are covered.
    private enum Check {
        case met, missing, unknown
    }

    private struct Candidate {
        struct Rank: Comparable {
            var moves: Int
            var target: Int
            var uncertainty: Int
            var order: Int
            var detail: Int

            static func < (lhs: Rank, rhs: Rank) -> Bool {
                (lhs.moves, lhs.target, lhs.uncertainty, lhs.order, lhs.detail)
                    < (rhs.moves, rhs.target, rhs.uncertainty, rhs.order, rhs.detail)
            }
        }

        var suggestion: Suggestion
        var rank: Rank
    }

    private struct Engine {
        let plan: DegreePlan
        let origin: Int
        let history: OfferingHistory
        let requirements: [CourseKey: Requirements]
        let equivalences: CourseEquivalences
        let maxCredits: Double
        /// Prerequisite checks of every planned course in the plan as it is.
        let before: [UUID: Check]

        init(plan: DegreePlan, origin: Int, history: OfferingHistory, requirements: [CourseKey: Requirements],
             equivalences: CourseEquivalences, maxCredits: Double) {
            self.plan = plan
            self.origin = origin
            self.history = history
            self.requirements = requirements
            self.equivalences = equivalences
            self.maxCredits = maxCredits
            self.before = Self.evaluate(plan, requirements: requirements, equivalences: equivalences)
        }

        // MARK: Prerequisites

        static func check(_ key: CourseKey, taken: Set<CourseKey>, requirements: [CourseKey: Requirements], equivalences: CourseEquivalences) -> Check {
            switch requirements[key] ?? .unknown {
            case .unknown: return .unknown
            case .nothing: return .met
            case .needs(let requisite):
                return DegreePlanAnalysis.status(of: requisite, satisfiedBy: taken, equivalences: equivalences) == .met ? .met : .missing
            }
        }

        /// The prerequisite check of every planned course, by `DegreePlanCourse.id`: a course
        /// needs its prerequisites among the completed courses and the earlier semesters.
        static func evaluate(_ plan: DegreePlan, requirements: [CourseKey: Requirements], equivalences: CourseEquivalences) -> [UUID: Check] {
            var taken = plan.completedKeys
            var checks: [UUID: Check] = [:]
            for term in plan.terms {
                for course in term.courses {
                    guard let key = course.key else { continue }
                    checks[course.id] = check(key, taken: taken, requirements: requirements, equivalences: equivalences)
                }
                taken.formUnion(term.courses.compactMap(\.key))
            }
            return checks
        }

        /// The checks after a change, when it breaks nothing that worked: the checks of the
        /// `moved` courses, which must not be missing, and every course that was met before, which
        /// must still be (this is what keeps a course from landing before what it needs, and from
        /// landing at or before a course that needs it). Nil when something breaks.
        func checks(after changed: DegreePlan, moved: Set<UUID>) -> [UUID: Check]? {
            let after = Self.evaluate(changed, requirements: requirements, equivalences: equivalences)
            for (id, check) in after {
                if moved.contains(id) {
                    if check == .missing { return nil }
                } else if before[id] == .met && check == .missing {
                    return nil
                }
            }
            return after
        }

        // MARK: Credits and history

        func creditsLabel(_ credits: Double) -> String {
            "\(CreditFormatter.number(credits)) \(credits == 1 ? "credit" : "credits")"
        }

        /// 1 when the history can't say whether the course is taught in the season; nil when it
        /// says it isn't.
        func uncertainty(of key: CourseKey, in season: PlanSeason) -> Int? {
            switch history.isLikelyOffered(key, in: season) {
            case false?: nil
            case true?: 0
            case nil: 1
            }
        }

        func offeringReason(of key: CourseKey, in season: PlanSeason, named: Bool) -> String {
            let text = history.summary(of: key, in: season)
            return named ? "\(key.description): \(text.prefix(1).lowercased() + text.dropFirst())" : text
        }

        func prerequisiteReason(of key: CourseKey, check: Check, wasMet: Bool, named: Bool) -> String {
            let text: String
            switch (requirements[key] ?? .unknown, check) {
            case (_, .unknown): text = "Prerequisites couldn’t be checked"
            case (.nothing, _): text = "No prerequisites"
            case (_, .met): text = wasMet ? "Prerequisites still met" : "Prerequisites met by then"
            case (_, .missing): text = "Prerequisites not met"
            }
            return named ? "\(key.description): \(text.prefix(1).lowercased() + text.dropFirst())" : text
        }

        // MARK: Finding candidates

        /// Every way to get `course` (of the origin semester) out of it, best first.
        func candidates(for course: DegreePlanCourse, order: Int, blocking: Set<CourseKey>) -> [Candidate] {
            guard let key = course.key else { return [] }
            var found: [Candidate] = []
            for target in (origin + 1)..<max(origin + 1, plan.terms.count) {
                if let single = singleMove(course, key: key, to: target, order: order) { found.append(single) }
                for (position, partner) in plan.terms[target].courses.enumerated() {
                    guard let partnerKey = partner.key, !blocking.contains(partnerKey), partnerKey != key else { continue }
                    if let swap = swap(course, key: key, with: partner, partnerKey: partnerKey, in: target, order: order, detail: position) {
                        found.append(swap)
                    }
                }
            }
            if found.isEmpty, let appended = appendedSemester(for: course, key: key, order: order) {
                found.append(appended)
            }
            return found
        }

        func singleMove(_ course: DegreePlanCourse, key: CourseKey, to target: Int, order: Int) -> Candidate? {
            let semester = plan.terms[target]
            let season = semester.season
            guard let offering = uncertainty(of: key, in: season) else { return nil }
            let total = semester.credits + course.credits
            guard total <= maxCredits else { return nil }

            let move = Move(course: key, from: plan.terms[origin].id, to: semester.id)
            var changed = plan
            guard DegreePlanReordering.performMove(key, from: move.from, to: move.to, in: &changed),
                  let after = checks(after: changed, moved: [course.id]) else { return nil }
            let check = after[course.id] ?? .unknown

            let reasons = [
                offeringReason(of: key, in: season, named: false),
                prerequisiteReason(of: key, check: check, wasMet: before[course.id] == .met, named: false),
                "\(semester.shortName) would have \(creditsLabel(total))",
            ]
            let suggestion = Suggestion(
                id: "move-\(key)-\(move.to.uuidString)",
                moves: [move],
                title: "Move \(key.description) to \(semester.shortName)",
                reasons: reasons,
                addsSemester: nil
            )
            return Candidate(suggestion: suggestion, rank: .init(
                moves: 1, target: target, uncertainty: offering + (check == .unknown ? 1 : 0), order: order, detail: 0
            ))
        }

        /// `course` moves to the target semester and `partner`, a course planned there, takes its
        /// place in the origin semester.
        func swap(_ course: DegreePlanCourse, key: CourseKey, with partner: DegreePlanCourse, partnerKey: CourseKey,
                  in target: Int, order: Int, detail: Int) -> Candidate? {
            let semester = plan.terms[target]
            let home = plan.terms[origin]
            guard let courseOffering = uncertainty(of: key, in: semester.season),
                  let partnerOffering = uncertainty(of: partnerKey, in: home.season) else { return nil }

            // Both semesters stay within the limit, or at least no heavier than they are.
            let newHome = home.credits - course.credits + partner.credits
            let newTarget = semester.credits - partner.credits + course.credits
            guard newHome <= max(maxCredits, home.credits), newTarget <= max(maxCredits, semester.credits) else { return nil }

            let moves = [
                Move(course: key, from: home.id, to: semester.id),
                Move(course: partnerKey, from: semester.id, to: home.id),
            ]
            var changed = plan
            for move in moves {
                guard DegreePlanReordering.performMove(move.course, from: move.from, to: move.to, in: &changed) else { return nil }
            }
            guard let after = checks(after: changed, moved: [course.id, partner.id]) else { return nil }
            let courseCheck = after[course.id] ?? .unknown
            let partnerCheck = after[partner.id] ?? .unknown

            let reasons = [
                offeringReason(of: key, in: semester.season, named: true),
                offeringReason(of: partnerKey, in: home.season, named: true),
                prerequisiteReason(of: key, check: courseCheck, wasMet: before[course.id] == .met, named: true),
                prerequisiteReason(of: partnerKey, check: partnerCheck, wasMet: before[partner.id] == .met, named: true),
                "\(home.shortName) would have \(creditsLabel(newHome))",
                "\(semester.shortName) would have \(creditsLabel(newTarget))",
            ]
            let suggestion = Suggestion(
                id: "swap-\(key)-\(semester.id.uuidString)-\(partnerKey)",
                moves: moves,
                title: "Move \(key.description) to \(semester.shortName) and \(partnerKey.description) to \(home.shortName)",
                reasons: reasons,
                addsSemester: nil
            )
            let unsure = courseOffering + partnerOffering + (courseCheck == .unknown ? 1 : 0) + (partnerCheck == .unknown ? 1 : 0)
            return Candidate(suggestion: suggestion, rank: .init(moves: 2, target: target, uncertainty: unsure, order: order, detail: detail))
        }

        /// A new semester after the plan's last one, in the first season the course is taught in.
        func appendedSemester(for course: DegreePlanCourse, key: CourseKey, order: Int) -> Candidate? {
            guard course.credits <= maxCredits else { return nil }
            let home = plan.terms[origin]
            for upcoming in DegreePlanAutofill.nextSemesters(after: plan, count: 8) {
                // Later than the semester the course leaves, whatever the plan's last season is.
                guard upcoming.sortKey > home.sortKey,
                      let offering = uncertainty(of: key, in: upcoming.season) else { continue }
                var semester = DegreePlanTerm(season: upcoming.season, year: upcoming.year)
                semester.id = DegreePlanReordering.stableID(for: "degree-plan-term-\(semester.season.rawValue)-\(semester.year)")

                var changed = plan
                changed.terms.append(semester)
                changed.sortTerms()
                let move = Move(course: key, from: home.id, to: semester.id)
                guard DegreePlanReordering.performMove(key, from: move.from, to: move.to, in: &changed),
                      let after = checks(after: changed, moved: [course.id]) else { continue }
                let check = after[course.id] ?? .unknown

                let reasons = [
                    offeringReason(of: key, in: semester.season, named: false),
                    prerequisiteReason(of: key, check: check, wasMet: before[course.id] == .met, named: false),
                    "Adds \(semester.shortName) to your plan, with \(creditsLabel(course.credits))",
                ]
                let suggestion = Suggestion(
                    id: "move-\(key)-\(semester.id.uuidString)",
                    moves: [move],
                    title: "Move \(key.description) to a new \(semester.shortName) semester",
                    reasons: reasons,
                    addsSemester: semester
                )
                return Candidate(suggestion: suggestion, rank: .init(
                    moves: 1, target: plan.terms.count, uncertainty: offering + (check == .unknown ? 1 : 0), order: order, detail: 0
                ))
            }
            return nil
        }
    }

    /// A UUID that depends only on the text, so a semester that is added has the same id every
    /// time the same suggestion is made.
    static func stableID(for text: String) -> UUID {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in text.utf8 {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            second = (second &+ UInt64(byte)) &* 0x0000_0100_0000_01b3 ^ first
        }
        let hex = Array(String(format: "%016llx%016llx", first, second))
        let formatted = [(0, 8), (8, 12), (12, 16), (16, 20), (20, 32)]
            .map { String(hex[$0.0..<$0.1]) }
            .joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}
