//
//  VariableCredits.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Banner variable-credit sections report creditHourLow, creditHourHigh and a
//  creditHours default (often 4). Each plan row keeps its own chosen value.
//

import Foundation

/// The credit range of one course or section, plus Banner's default.
struct CreditSpan: Hashable, Sendable {
    var low: Double
    var high: Double
    /// Banner's `creditHours`. A default, not the top of the range.
    var bannerDefault: Double?

    var isVariable: Bool { high != low }

    /// Whole numbers inside the range. Nil when the range holds none.
    var integerBounds: ClosedRange<Int>? {
        let lower = min(low, high)
        let upper = max(low, high)
        let first = Int(lower.rounded(.up))
        let last = Int(upper.rounded(.down))
        guard first <= last else { return nil }
        return first...last
    }

    static func banner(_ section: BannerSection) -> CreditSpan {
        let hours = section.creditHours
        let low = section.creditHourLow ?? hours ?? 0
        let high = section.creditHourHigh ?? low
        return CreditSpan(low: low, high: high, bannerDefault: hours)
    }

    /// Widens to cover another section. The first default is kept.
    func absorb(_ other: CreditSpan) -> CreditSpan {
        CreditSpan(
            low: min(low, other.low),
            high: max(high, other.high),
            bannerDefault: bannerDefault ?? other.bannerDefault
        )
    }

    /// A whole number inside the range. A value outside moves to the nearest end.
    /// A range with no whole number keeps the nearer endpoint.
    func clamp(_ value: Double) -> Double {
        let lower = min(low, high)
        let upper = max(low, high)
        if let bounds = integerBounds {
            let nearest = value.rounded()
            return min(max(nearest, Double(bounds.lowerBound)), Double(bounds.upperBound))
        }
        return abs(value - lower) <= abs(upper - value) ? lower : upper
    }

    /// `creditHours` when it sits in the range, otherwise the low end.
    func defaultChoice() -> Double {
        let lower = min(low, high)
        let upper = max(low, high)
        if let bannerDefault, bannerDefault >= lower, bannerDefault <= upper {
            return clamp(bannerDefault)
        }
        return clamp(lower)
    }

    /// A missing stored value (plans saved before a choice existed) gets the default.
    /// A saved choice is clamped into a new range and is not replaced by the default.
    func resolve(stored: Double?) -> Double {
        guard let stored else { return defaultChoice() }
        return clamp(stored)
    }

    /// `Credits: 4 (1 to 8)`.
    func choiceLabel(_ chosen: Double) -> String {
        let value = resolve(stored: chosen)
        let lower = min(low, high)
        let upper = max(low, high)
        return "Credits: \(CreditFormatter.number(value)) (\(CreditFormatter.number(lower)) to \(CreditFormatter.number(upper)))"
    }
}

enum ChosenCredits {
    /// The section's own range when it has one, otherwise the course's.
    static func span(course: Course?, section: CourseSection?) -> CreditSpan? {
        if let section, let span = section.creditSpan { return span }
        return course?.creditSpan
    }

    /// The credits hours accounting should use. Without a catalog range, a stored
    /// choice is kept and a brand new row falls back to 4.
    static func resolved(stored: Double?, course: Course?, section: CourseSection?) -> Double {
        if let span = span(course: course, section: section) {
            return span.resolve(stored: stored)
        }
        return stored ?? 4
    }

    /// Whole credits for the schedule generator. A course the catalog does not
    /// list, with no stored choice, stays at 0.
    static func generatorCredits(stored: Double?, course: Course?, section: CourseSection?) -> Int {
        if course == nil, section?.creditSpan == nil, stored == nil { return 0 }
        return Int(resolved(stored: stored, course: course, section: section).rounded())
    }

    /// A missing choice stays missing, so a launch can show the default without
    /// writing it. A stored choice outside the current range is clamped.
    /// An in-range choice is returned unchanged.
    static func reconciled(stored: Double?, course: Course?, section: CourseSection?) -> Double? {
        guard let stored else { return nil }
        guard let span = span(course: course, section: section) else { return stored }
        return span.clamp(stored)
    }
}

/// One row's identity when a degree plan and a schedule stay in step.
struct CreditRowIdentity: Hashable, Sendable {
    var key: CourseKey
    var crn: String?
    /// 1 for the first unpinned copy, 2 for the next. Pinned rows are 1.
    var instance: Int
}

enum CreditSync {
    static func normalize(_ crn: String?) -> String? {
        guard let trimmed = crn?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func degreeIdentities(_ courses: [DegreePlanCourse]) -> [(id: UUID, identity: CreditRowIdentity)] {
        var seen = [CourseKey: Int]()
        var rows: [(UUID, CreditRowIdentity)] = []
        for course in courses {
            guard let key = course.key else { continue }
            let crn = normalize(course.crn)
            let instance: Int
            if crn != nil {
                instance = 1
            } else {
                let count = (seen[key] ?? 0) + 1
                seen[key] = count
                instance = count
            }
            rows.append((course.id, CreditRowIdentity(key: key, crn: crn, instance: instance)))
        }
        return rows
    }

    static func scheduleIdentity(_ course: PlanCourse, among courses: [PlanCourse]) -> CreditRowIdentity {
        let crn = normalize(course.pinnedCRN)
        if crn != nil { return CreditRowIdentity(key: course.key, crn: crn, instance: 1) }
        if let instance = course.instance, instance > 0 {
            return CreditRowIdentity(key: course.key, crn: nil, instance: instance)
        }
        var count = 0
        for other in courses where other.key == course.key && normalize(other.pinnedCRN) == nil {
            count += 1
            if other.id == course.id {
                return CreditRowIdentity(key: course.key, crn: nil, instance: count)
            }
        }
        return CreditRowIdentity(key: course.key, crn: nil, instance: 1)
    }

    /// Copies degree-plan credits onto the matching schedule rows. Returns whether any value changed.
    @discardableResult
    static func apply(degree courses: [DegreePlanCourse], to plan: inout SchedulePlan) -> Bool {
        let creditsByID = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0.credits) })
        let byIdentity = Dictionary(degreeIdentities(courses).map { ($0.identity, creditsByID[$0.id]) }, uniquingKeysWith: { _, latest in latest })
        var changed = false
        for index in plan.courses.indices {
            let identity = scheduleIdentity(plan.courses[index], among: plan.courses)
            guard let credits = byIdentity[identity], let credits, plan.courses[index].credits != credits else { continue }
            plan.courses[index].credits = credits
            changed = true
        }
        return changed
    }

    /// Copies one schedule row's credits onto the matching degree-plan row.
    /// A nil schedule value leaves an existing degree row alone.
    @discardableResult
    static func apply(scheduleCredits: Double?, identity: CreditRowIdentity, to courses: inout [DegreePlanCourse]) -> Bool {
        guard let scheduleCredits else { return false }
        guard let match = degreeIdentities(courses).first(where: { $0.identity == identity }) else { return false }
        guard let index = courses.firstIndex(where: { $0.id == match.id }), courses[index].credits != scheduleCredits else { return false }
        courses[index].credits = scheduleCredits
        return true
    }
}

enum ChosenCreditReconcile {
    /// Clamps a stored choice the catalog range no longer contains.
    /// A missing choice stays missing. Readers use `ChosenCredits.resolved`.
    @discardableResult
    static func reconcile(_ plan: inout SchedulePlan, index: CatalogIndex) -> Bool {
        var changed = false
        for row in plan.courses.indices {
            let course = plan.courses[row]
            let listed = index.course(course.key)
            let section = course.pinnedCRN.flatMap { index.section(crn: $0) }
            guard let resolved = ChosenCredits.reconciled(stored: course.credits, course: listed, section: section) else { continue }
            if course.credits != resolved {
                plan.courses[row].credits = resolved
                changed = true
            }
        }
        return changed
    }

    /// Clamps planned rows into the catalog range for that semester. Does not
    /// replace an in-range choice with Banner's default.
    @discardableResult
    static func reconcile(_ plan: inout DegreePlan, indexForTerm: (String) -> CatalogIndex?) -> Bool {
        var changed = false
        for term in plan.terms.indices {
            guard let index = indexForTerm(bannerCode(plan.terms[term])) else { continue }
            for row in plan.terms[term].courses.indices {
                let course = plan.terms[term].courses[row]
                guard let key = course.key, let listed = index.course(key) else { continue }
                let section = course.crn.flatMap { index.section(crn: $0) }
                guard let span = ChosenCredits.span(course: listed, section: section) else { continue }
                let resolved = span.clamp(course.credits)
                if resolved != course.credits {
                    plan.terms[term].courses[row].credits = resolved
                    changed = true
                }
            }
        }
        return changed
    }

    /// Banner code for a semester. Same mapping as `DegreePlanTerm.degreePlanBannerCode`.
    private static func bannerCode(_ term: DegreePlanTerm) -> String {
        switch term.season {
        case .fall: "\(term.year + 1)10"
        case .winter: "\(term.year)20"
        case .spring: "\(term.year)30"
        case .summerA: "\(term.year)40"
        case .summerFull: "\(term.year)50"
        case .summerB: "\(term.year)60"
        }
    }
}
