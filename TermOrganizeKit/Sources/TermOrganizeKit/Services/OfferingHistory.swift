//
//  OfferingHistory.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// In which recent Banner terms courses had sections, so a plan can avoid putting a course in a
/// semester it has never been taught in.
///
/// It covers a window of recent terms (about two years, summers included). A course is
/// "likely offered" in a season when it had sections in at least one checked term of that
/// season. Fall, spring and summer are what matters; Summer 1, Summer 2 and the full summer
/// term all count as summer (see `PlanSeason.matches`).
struct OfferingHistory: Codable, Hashable, Sendable {
    /// Banner term codes that were checked, newest first.
    var checkedTerms: [String]
    /// For each course, the checked terms in which it had sections.
    var offered: [CourseKey: Set<String>]
    /// The courses that were checked. Nil means every course was, so a course missing from
    /// `offered` was not offered in any checked term. A history made for some courses says
    /// nothing about others (`isLikelyOffered` is nil for them).
    var checkedKeys: Set<CourseKey>?

    init(checkedTerms: [String] = [], offered: [CourseKey: Set<String>] = [:], checkedKeys: Set<CourseKey>? = nil) {
        self.checkedTerms = checkedTerms
        self.offered = offered
        self.checkedKeys = checkedKeys
    }

    /// Nothing is known.
    static let empty = OfferingHistory()

    /// Whether the history says anything about the course.
    func isChecked(_ key: CourseKey) -> Bool {
        !checkedTerms.isEmpty && (checkedKeys?.contains(key) ?? true)
    }

    /// The checked terms in which the course had sections, newest first.
    func offeredTerms(of key: CourseKey) -> [String] {
        guard let terms = offered[key] else { return [] }
        return checkedTerms.filter(terms.contains)
    }

    /// The seasons the course was taught in, over the checked terms.
    func seasons(of key: CourseKey) -> Set<PlanSeason> {
        Set(offeredTerms(of: key).map { PlanSeason(termSeason: Self.termSeason($0)) })
    }

    /// Whether the course is likely taught in a season of the plan: true when it had sections
    /// in a checked term of that season, false when it had none in any, and nil when that can't
    /// be said (the course wasn't checked, or no term of that season was).
    func isLikelyOffered(_ key: CourseKey, in season: PlanSeason) -> Bool? {
        guard isChecked(key) else { return nil }
        let relevant = checkedTerms.filter { season.matches(Self.termSeason($0)) }
        guard !relevant.isEmpty else { return nil }
        let terms = offered[key] ?? []
        return relevant.contains(where: terms.contains)
    }

    /// A short description of when the course is taught: `Offered every spring`,
    /// `Offered every fall and spring`, `Offered every spring, and sometimes in the fall`,
    /// `Last offered Spring 2025`, `Not offered in the last 2 years` or `Offering history unknown`.
    func summary(of key: CourseKey) -> String {
        guard isChecked(key) else { return "Offering history unknown" }
        let terms = offeredTerms(of: key)
        guard let latest = terms.first else {
            let years = checkedYears
            return years == 1 ? "Not offered in the last year" : "Not offered in the last \(years) years"
        }
        let regular = Family.allCases.filter { isRegular($0, key: key) }
        guard !regular.isEmpty else { return "Last offered \(Self.label(ofTerm: latest))" }
        let others = Family.allCases.filter { family in
            !regular.contains(family) && terms.contains { Family(Self.termSeason($0)) == family }
        }
        let regularly = "Offered every " + Self.list(regular.map(\.name))
        return others.isEmpty ? regularly : regularly + ", and sometimes in the " + Self.list(others.map(\.name))
    }

    /// Why the course is, or isn't, likely taught in a season of a plan: `Offered every spring`,
    /// `Offered in Spring 2025`, `Not offered in a fall term in the last 2 years`, or
    /// `Offering history unknown` when the history can't say.
    func summary(of key: CourseKey, in season: PlanSeason) -> String {
        guard isLikelyOffered(key, in: season) != nil else { return "Offering history unknown" }
        let family = Family(season)
        let relevant = checkedTerms.filter { season.matches(Self.termSeason($0)) }
        let terms = offered[key] ?? []
        guard let latest = relevant.first(where: terms.contains) else {
            let years = checkedYears
            let span = years == 1 ? "the last year" : "the last \(years) years"
            return "Not offered in a \(family?.name ?? season.shortName.lowercased()) term in \(span)"
        }
        if let family, isRegular(family, key: key) { return "Offered every \(family.name)" }
        return "Offered in \(Self.label(ofTerm: latest))"
    }

    /// Both histories combined: terms are merged, a course offered in a term in either was
    /// offered, and a course counts as checked when it was in either.
    func merging(_ other: OfferingHistory) -> OfferingHistory {
        let terms = Set(checkedTerms).union(other.checkedTerms).sorted(by: >)
        var combined = offered
        for (key, codes) in other.offered { combined[key, default: []].formUnion(codes) }
        let keys: Set<CourseKey>?
        switch (checkedKeys, other.checkedKeys) {
        case let (a?, b?): keys = a.union(b)
        default: keys = nil
        }
        return OfferingHistory(checkedTerms: terms, offered: combined, checkedKeys: keys)
    }

    // MARK: - Details

    /// Terms of a season family are grouped by calendar year: every fall and every spring is
    /// its own period, and the summer terms of one year (Summer 1, Summer 2, full summer) are one.
    private enum Family: CaseIterable {
        case fall, spring, summer

        var name: String {
            switch self {
            case .fall: "fall"
            case .spring: "spring"
            case .summer: "summer"
            }
        }

        init?(_ season: Term.Season) {
            switch season {
            case .fall: self = .fall
            case .spring: self = .spring
            case .summer1, .summerFull, .summer2: self = .summer
            case .winter: return nil
            }
        }

        init?(_ season: PlanSeason) {
            switch season {
            case .fall: self = .fall
            case .spring: self = .spring
            case .summerA, .summerFull, .summerB: self = .summer
            case .winter: return nil
            }
        }
    }

    /// Offered in every checked period of the season, and at least two periods were checked.
    private func isRegular(_ family: Family, key: CourseKey) -> Bool {
        let offeredTerms = offered[key] ?? []
        var periods: [Int: Bool] = [:]
        for code in checkedTerms where Family(Self.termSeason(code)) == family {
            let year = Term(code: code, bannerDescription: "").calendarYear
            periods[year] = (periods[year] ?? false) || offeredTerms.contains(code)
        }
        return periods.count >= 2 && !periods.values.contains(false)
    }

    /// The span of the checked terms in whole years (at least one).
    private var checkedYears: Int {
        guard let newest = checkedTerms.first, let oldest = checkedTerms.last else { return 1 }
        let months = Self.monthIndex(newest) - Self.monthIndex(oldest)
        return max(1, Int((Double(months) / 12).rounded()))
    }

    private static func termSeason(_ code: String) -> Term.Season {
        Term(code: code, bannerDescription: "").season
    }

    /// Months since year 0 of the start of a term, to measure distances between terms.
    static func monthIndex(ofTerm code: String) -> Int { monthIndex(code) }

    private static func monthIndex(_ code: String) -> Int {
        let term = Term(code: code, bannerDescription: "")
        return term.calendarYear * 12 + PlanSeason(termSeason: term.season).startMonth - 1
    }

    /// `Spring 2025`, `Summer 1 2025`, `Fall 2024`.
    static func label(ofTerm code: String) -> String {
        let term = Term(code: code, bannerDescription: "")
        return "\(term.season.displayName) \(term.calendarYear)"
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0, 1: items.first ?? ""
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }
}

// MARK: - Codable

/// Courses are keyed by their code (`CS 3386`) so the JSON stays readable.
extension OfferingHistory {
    private enum CodingKeys: String, CodingKey {
        case checkedTerms, offered, checkedKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let terms = try container.decodeIfPresent([String].self, forKey: .checkedTerms) ?? []
        let raw = try container.decodeIfPresent([String: [String]].self, forKey: .offered) ?? [:]
        var offered: [CourseKey: Set<String>] = [:]
        for (code, termCodes) in raw {
            guard let key = CourseKey(string: code) else { continue }
            offered[key] = Set(termCodes)
        }
        let checked = try container.decodeIfPresent([String].self, forKey: .checkedKeys)
        self.init(checkedTerms: terms, offered: offered, checkedKeys: checked.map { Set($0.compactMap { CourseKey(string: $0) }) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(checkedTerms, forKey: .checkedTerms)
        var raw: [String: [String]] = [:]
        for (key, codes) in offered { raw[key.description] = codes.sorted(by: >) }
        try container.encode(raw, forKey: .offered)
        try container.encodeIfPresent(checkedKeys.map { $0.map(\.description).sorted() }, forKey: .checkedKeys)
    }
}
