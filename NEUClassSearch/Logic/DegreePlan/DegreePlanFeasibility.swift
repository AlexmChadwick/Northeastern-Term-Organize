//
//  DegreePlanFeasibility.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Whether a planned semester can actually be taken: every course is offered then, and the
/// courses have a conflict-free combination of sections when that term's catalog is on the
/// device.
///
/// Offering comes from the term's own sections when its catalog is loaded (a course with no
/// sections isn't taught that term). Otherwise it comes from `OfferingHistory`, and the
/// wording says the conclusion is a prediction. A season the history can't speak to isn't
/// treated as unoffered. Time clashes are only reported when section data exists; sections
/// without a weekly meeting never conflict, the same rule the schedule generator uses.
///
/// A co-op term (one that holds a co-op work experience) is also unworkable when the classes
/// beside the co-op exceed `DegreePlanLoad.coopClassCredits`. Past semesters are left alone.
enum DegreePlanFeasibility {
    /// Where an "isn't offered" conclusion came from.
    enum OfferingBasis: Hashable, Sendable {
        /// The term's catalog is loaded, and the course has no sections in it.
        case catalog
        /// No catalog for that term; recent terms of the same season didn't list it.
        case prediction
    }

    struct Problem: Hashable, Identifiable, Sendable {
        enum Kind: Hashable, Sendable {
            case notOffered(OfferingBasis)
            case timeClash
            /// Classes beside a co-op exceed the co-op load.
            case coopLoad
        }

        var id: String
        /// The planned row, when the problem is about one course.
        var courseID: UUID?
        var course: CourseKey?
        var kind: Kind
        /// One line for the semester, e.g. `Predicted: CS 3386 not offered in a spring term in the last 2 years`.
        var text: String

        var isPrediction: Bool {
            if case .notOffered(.prediction) = kind { return true }
            return false
        }
    }

    struct TermReport: Hashable, Identifiable, Sendable {
        var termID: UUID
        var name: String
        var problems: [Problem]
        /// Courses that have to leave for the semester to work: not offered, the smallest set
        /// whose removal removes a time clash, or the classes that put a co-op term over its load.
        var coursesToMove: [UUID]

        var isInfeasible: Bool { !problems.isEmpty }
        var isPredicted: Bool { problems.contains(where: \.isPrediction) && !problems.contains { !$0.isPrediction } }
    }

    struct Report: Hashable, Sendable {
        var terms: [TermReport]

        func report(for termID: UUID) -> TermReport? { terms.first { $0.termID == termID } }

        var infeasibleTerms: [TermReport] { terms.filter(\.isInfeasible) }

        /// The line that replaces `On track to finish after …` when a semester at or before the
        /// finish can't be taken. Nil when the finish still holds, or when the degree is already
        /// complete (later semesters don't change that).
        func blockedFinishLine(milestone: DegreeMilestone?, plan: DegreePlan, now: Date = .now) -> String? {
            guard case .after(let termID, _) = milestone,
                  let finish = plan.terms.first(where: { $0.id == termID }) else { return nil }
            let blocking = infeasibleTerms.compactMap { report -> DegreePlanTerm? in
                guard let term = plan.terms.first(where: { $0.id == report.termID }) else { return nil }
                guard term.sortKey <= finish.sortKey, !term.degreePlanHasEnded(now: now) else { return nil }
                return term
            }
            guard !blocking.isEmpty else { return nil }
            if blocking.count == 1 { return "\(blocking[0].name) can’t be taken as planned" }
            return "\(blocking.count) semesters can’t be taken as planned"
        }

        /// The line for the plan header. A known finish is blocked only by a semester at or
        /// before it (later semesters are optional once the degree is met). With no finish yet,
        /// any upcoming semester that can't be taken is named.
        func warningLine(milestone: DegreeMilestone?, plan: DegreePlan, now: Date = .now) -> String? {
            if let blocked = blockedFinishLine(milestone: milestone, plan: plan, now: now) { return blocked }
            guard milestone == nil else { return nil }
            let upcoming = infeasibleTerms.compactMap { report -> String? in
                guard let term = plan.terms.first(where: { $0.id == report.termID }),
                      !term.degreePlanHasEnded(now: now) else { return nil }
                return term.name
            }
            guard !upcoming.isEmpty else { return nil }
            if upcoming.count == 1 { return "\(upcoming[0]) can’t be taken as planned" }
            return "\(upcoming.count) semesters can’t be taken as planned"
        }
    }

    /// Sections of courses in one loaded term. A course mapped to `[]` was looked up and has
    /// no sections. Courses that might move into the term belong in the map too.
    struct TermSections: Hashable, Sendable {
        var byCourse: [CourseKey: [CourseSection]]
    }

    /// - Parameters:
    ///   - sections: the term's catalog, or nil when it isn't loaded. Keys are the courses to
    ///     judge; a missing course is treated as having no sections.
    static func assess(
        plan: DegreePlan,
        history: OfferingHistory,
        sections: (DegreePlanTerm) -> TermSections?,
        now: Date = .now
    ) -> Report {
        var plan = plan
        plan.sortTerms()
        var terms: [TermReport] = []
        for term in plan.terms where !term.degreePlanHasEnded(now: now) && !term.courses.isEmpty {
            terms.append(report(for: term, history: history, sections: sections(term)))
        }
        return Report(terms: terms)
    }

    /// The loaded catalog's sections for `keys` in `term`, or nil when that term's catalog
    /// isn't on the device. A key with no sections maps to `[]`.
    static func sectionMap(in snapshot: DegreePlanCatalogSnapshot, for term: DegreePlanTerm, keys: [CourseKey]) -> TermSections? {
        guard let banner = snapshot.bannerTerm(for: term), let index = snapshot.index(for: banner.code) else { return nil }
        var byCourse: [CourseKey: [CourseSection]] = [:]
        for key in keys { byCourse[key] = index.sections(for: key) }
        return TermSections(byCourse: byCourse)
    }

    /// Whether some choice of one section per course has no overlapping weekly meetings.
    /// Courses are ordered so the ones with fewer sections are chosen first. If the space is
    /// too large to finish, the answer is true: a clash is only reported when it has been shown.
    static func hasConflictFreeCombination(_ groups: [[CourseSection]], nodeLimit: Int = 100_000) -> Bool {
        let ordered = groups.sorted { $0.count < $1.count }
        var nodes = 0
        func search(_ index: Int, chosen: [CourseSection]) -> Bool? {
            if index == ordered.count { return true }
            nodes += 1
            if nodes > nodeLimit { return nil }
            for section in ordered[index] where chosen.allSatisfy({ !$0.conflicts(with: section) }) {
                if let found = search(index + 1, chosen: chosen + [section]) { return found }
            }
            return false
        }
        return search(0, chosen: []) ?? true
    }

    // MARK: - One semester

    private static func report(for term: DegreePlanTerm, history: OfferingHistory, sections: TermSections?) -> TermReport {
        var problems: [Problem] = []
        var toMove: [UUID] = []
        var offered: [(id: UUID, key: CourseKey)] = []

        for course in term.courses {
            guard let key = course.key else { continue }
            if let sections {
                let listed = sections.byCourse[key] ?? []
                if listed.isEmpty {
                    problems.append(Problem(
                        id: "offered-\(course.id.uuidString)",
                        courseID: course.id,
                        course: key,
                        kind: .notOffered(.catalog),
                        text: "\(key.description) isn’t offered in \(term.name)"
                    ))
                    toMove.append(course.id)
                } else {
                    offered.append((course.id, key))
                }
            } else if history.isLikelyOffered(key, in: term.season) == false {
                let summary = history.summary(of: key, in: term.season)
                let rest = summary.prefix(1).lowercased() + summary.dropFirst()
                problems.append(Problem(
                    id: "offered-\(course.id.uuidString)",
                    courseID: course.id,
                    course: key,
                    kind: .notOffered(.prediction),
                    text: "Predicted: \(key.description) \(rest)"
                ))
                toMove.append(course.id)
            } else {
                offered.append((course.id, key))
            }
        }

        if let sections, offered.count >= 2 {
            let groups = offered.map { sections.byCourse[$0.key] ?? [] }
            if !hasConflictFreeCombination(groups) {
                let blocking = smallestBlockingSet(offered: offered, sections: sections)
                let keys = blocking.compactMap { id in offered.first { $0.id == id }?.key }
                problems.append(Problem(
                    id: "clash-\(term.id.uuidString)",
                    courseID: nil,
                    course: nil,
                    kind: .timeClash,
                    text: clashText(keys)
                ))
                for id in blocking where !toMove.contains(id) { toMove.append(id) }
            }
        }

        if let load = coopLoadProblem(in: term) {
            problems.append(load.problem)
            for id in load.move where !toMove.contains(id) { toMove.append(id) }
        }

        return TermReport(termID: term.id, name: term.name, problems: problems, coursesToMove: toMove)
    }

    /// The smallest set of courses whose removal leaves a conflict-free combination, trying
    /// the courses in plan order so the choice is stable. Falls back to every offered course.
    private static func smallestBlockingSet(offered: [(id: UUID, key: CourseKey)], sections: TermSections) -> [UUID] {
        let ids = offered.map(\.id)
        for size in 1..<ids.count {
            for combo in combinations(ids, size) {
                let keep = offered.filter { !combo.contains($0.id) }
                let groups = keep.map { sections.byCourse[$0.key] ?? [] }
                if hasConflictFreeCombination(groups) { return combo }
            }
        }
        return ids
    }

    private static func combinations<T>(_ items: [T], _ size: Int) -> [[T]] {
        guard size > 0 else { return [[]] }
        guard items.count >= size else { return [] }
        if size == 1 { return items.map { [$0] } }
        var result: [[T]] = []
        for (index, item) in items.enumerated() where items.count - index >= size {
            for rest in combinations(Array(items[(index + 1)...]), size - 1) {
                result.append([item] + rest)
            }
        }
        return result
    }

    private static func clashText(_ keys: [CourseKey]) -> String {
        let names = keys.map(\.description)
        guard let last = names.last else { return "No conflict-free schedule" }
        if names.count == 1 { return "No conflict-free schedule for \(last)" }
        if names.count == 2 { return "No conflict-free schedule: \(names[0]) overlaps \(names[1])" }
        return "No conflict-free schedule for \(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    /// Classes beside the co-op, when they exceed the load a co-op term can take. The courses
    /// past the cap (later rows first) are the ones to move; the co-op itself stays.
    private static func coopLoadProblem(in term: DegreePlanTerm) -> (problem: Problem, move: [UUID])? {
        let classes = term.courses.filter { !DegreePlanLoad.isCoop($0) }
        let academic = classes.reduce(0.0) { $0 + $1.credits }
        guard DegreePlanLoad.isCoopTerm(term), academic > DegreePlanLoad.coopClassCredits else { return nil }
        var kept = 0.0
        var move: [UUID] = []
        for course in classes {
            if kept + course.credits <= DegreePlanLoad.coopClassCredits {
                kept += course.credits
            } else {
                move.append(course.id)
            }
        }
        let credits = DegreePlanText.credits(academic)
        let cap = DegreePlanText.credits(DegreePlanLoad.coopClassCredits)
        let problem = Problem(
            id: "coop-\(term.id.uuidString)",
            courseID: nil,
            course: nil,
            kind: .coopLoad,
            text: "\(term.name) is a co-op term with \(credits) of classes. A co-op term can take \(cap) besides the co-op."
        )
        return (problem, move)
    }
}

/// Credit limits the planner keeps while it moves courses around. A semester stays at or under
/// `maxCreditsPerTerm` (the same cap single-course suggestions use). A co-op term keeps the
/// co-op and at most `coopClassCredits` of other classes, which is one ordinary course.
enum DegreePlanLoad {
    static let maxCreditsPerTerm = 20.0
    static let coopClassCredits = 4.0

    static func isCoop(_ course: DegreePlanCourse) -> Bool {
        if course.key?.subject == "COOP" { return true }
        return course.title.firstMatch(of: #/(?i)co-?op\s+(?:work\s+)?experience|cooperative\s+education/#) != nil
    }

    static func isCoopTerm(_ term: DegreePlanTerm) -> Bool { term.courses.contains(where: isCoop) }

    static func classCredits(in term: DegreePlanTerm) -> Double {
        term.courses.filter { !isCoop($0) }.reduce(0) { $0 + $1.credits }
    }
}
