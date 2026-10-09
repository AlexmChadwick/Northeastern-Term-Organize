//
//  EquivalenceSuggestions.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A guess at the course a retired course became, or the other way around.
///
/// Banner doesn't say which course replaced a renumbered one (its mutual exclusion lists are
/// empty for the computer science renumbering), but two kinds of evidence point at it:
///
/// - **Listed together.** When a department renumbers a course it lists both numbers as
///   alternatives in the courses that need it ("CS 2100 or CS 2510"). The more of the courses
///   that name the retired course also name a current one next to it, the likelier the current
///   one took its place (`together` of `total`).
/// - **A similar title.** A replacement often keeps the title: "Human Computer Interaction" (IS 4300)
///   became "Principles of Human-Computer Interaction" (CS 2484), and the two never appear in
///   a prerequisite together. That is weaker evidence (`similarTitle`, see `CourseTitleMatcher`).
///
/// It is only a hint. Courses that appear together as alternatives are interchangeable *for
/// those prerequisites* without being the same course (ANTH 1101 and POLS 1160 are listed
/// together too), and titles can match by accident, so a suggestion is never applied on its own:
/// the student confirms it, which declares an equivalence in the degree plan.
struct EquivalenceSuggestion: Hashable, Sendable, Identifiable {
    /// The retired course.
    var course: CourseKey
    /// The course it may count as: a current course, or one the student has.
    var candidate: CourseKey
    /// In how many courses' prerequisites the two are listed as alternatives (0 for a
    /// suggestion that rests on the titles alone).
    var together: Int
    /// In how many courses' prerequisites the retired course is named.
    var total: Int
    /// The candidate's title, when it is similar to the retired course's.
    var similarTitle: String? = nil
    /// How alike the titles are, from 0.6 to 1 (nil when the titles aren't evidence).
    var titleScore: Double? = nil

    var id: String { "\(course)|\(candidate)" }

    /// The share of the retired course's dependents that list the candidate beside it. 0 for a
    /// suggestion that rests on the titles alone.
    var confidence: Double { total > 0 ? Double(together) / Double(total) : 0 }

    /// Why it is suggested:
    /// - `Listed together in 7 of the 10 prerequisites that name CS 2510`,
    /// - `Similar title: Principles of Human-Computer Interaction`,
    /// - or the first followed by ` · similar title` when both point at the candidate.
    var evidence: String {
        var listing: String?
        if together > 0 {
            listing = total == 1
                ? "Listed together in the prerequisites of the 1 course that names \(course)"
                : "Listed together in \(together) of the \(total) prerequisites that name \(course)"
        }
        switch (listing, similarTitle) {
        case let (listing?, _?): return "\(listing) · similar title"
        case let (listing?, nil): return listing
        case let (nil, title?): return "Similar title: \(title)"
        case (nil, nil): return ""
        }
    }

    /// Whether the prerequisites list the two together, the stronger evidence.
    var isListedTogether: Bool { together > 0 }
}

enum EquivalenceSuggester {
    /// The courses a retired course may count as, most likely first: the ones its prerequisites
    /// list beside it (strongest evidence first), then the ones with a similar title. Both kinds
    /// are returned, and when a title suggestion exists at least one is kept within `limit`.
    ///
    /// - Parameters:
    ///   - retired: a course the catalog no longer lists.
    ///   - prerequisites: every course's prerequisites to read (the newest term's catalog).
    ///   - isCurrent: whether a course is in the current catalog; only those can be suggested
    ///     because of the prerequisites.
    ///   - known: courses already known to be equivalent are left out.
    ///   - minimumTogether: the fewest prerequisites that must list both.
    ///   - minimumShare: the smallest share of the retired course's prerequisites that must.
    ///   - title: a course's title from the best source on hand (catalog titles of the degree's
    ///     courses, then Banner's, then the plan's); nil when unknown. Without the retired course's
    ///     title no title is compared.
    ///   - titleCandidates: the courses to compare titles with: the student's completed and planned
    ///     courses, and any a requirement lists. They need not be current.
    ///   - minimumTitleSimilarity: see `CourseTitleMatcher`.
    static func suggestions(
        for retired: CourseKey,
        prerequisites: [(course: CourseKey, requisite: Requisite)],
        isCurrent: (CourseKey) -> Bool,
        excluding known: CourseEquivalences = .none,
        minimumTogether: Int = 2,
        minimumShare: Double = 0.5,
        limit: Int = 3,
        title: (CourseKey) -> String? = { _ in nil },
        titleCandidates: [CourseKey] = [],
        minimumTitleSimilarity: Double = CourseTitleMatcher.minimumSimilarity
    ) -> [EquivalenceSuggestion] {
        guard limit > 0 else { return [] }
        let (listed, dependents) = listedTogether(retired, prerequisites: prerequisites, isCurrent: isCurrent, known: known,
                                                  minimumTogether: minimumTogether, minimumShare: minimumShare)
        let similar = similarTitles(retired, candidates: titleCandidates, known: known, title: title, minimum: minimumTitleSimilarity)

        // A candidate both kinds point at is one suggestion, with both kinds of evidence.
        var byPrerequisites = listed.map { suggestion -> EquivalenceSuggestion in
            var suggestion = suggestion
            if let match = similar[suggestion.candidate] {
                suggestion.similarTitle = match.title
                suggestion.titleScore = match.score
            }
            return suggestion
        }
        byPrerequisites.sort { ($1.together, $0.candidate) < ($0.together, $1.candidate) }

        let listedKeys = Set(listed.map(\.candidate))
        let byTitle = similar
            .filter { !listedKeys.contains($0.key) }
            .map { EquivalenceSuggestion(course: retired, candidate: $0.key, together: 0, total: dependents,
                                         similarTitle: $0.value.title, titleScore: $0.value.score) }
            .sorted { ($0.titleScore ?? 0, $1.candidate) > ($1.titleScore ?? 0, $0.candidate) }

        // Titles rank below the prerequisites, but when the prerequisites would fill the list a
        // title suggestion still gets a place (unless only one fits).
        let free = max(0, limit - byPrerequisites.count)
        let reserved = limit >= 2 && !byPrerequisites.isEmpty ? 1 : 0
        let titleSlots = min(byTitle.count, max(free, reserved))
        return Array(byPrerequisites.prefix(limit - titleSlots)) + Array(byTitle.prefix(titleSlots))
    }

    /// The current courses the retired course's prerequisites list beside it, and how many
    /// courses' prerequisites name it.
    private static func listedTogether(
        _ retired: CourseKey,
        prerequisites: [(course: CourseKey, requisite: Requisite)],
        isCurrent: (CourseKey) -> Bool,
        known: CourseEquivalences,
        minimumTogether: Int,
        minimumShare: Double
    ) -> (suggestions: [EquivalenceSuggestion], dependents: Int) {
        var dependents = Set<CourseKey>()
        var listedTogether: [CourseKey: Set<CourseKey>] = [:]

        for (course, requisite) in prerequisites where course != retired {
            var mentionsRetired = false
            func visit(_ node: Requisite) {
                switch node {
                case .course(let key):
                    if key == retired { mentionsRetired = true }
                case .test:
                    break
                case .and(let items):
                    items.forEach(visit)
                case .or(let items):
                    let alternatives = items.compactMap { item -> CourseKey? in
                        if case .course(let key) = item { return key }
                        return nil
                    }
                    if alternatives.contains(retired) {
                        for other in alternatives where other != retired { listedTogether[other, default: []].insert(course) }
                    }
                    items.forEach(visit)
                }
            }
            // Nested "or"s are one list of alternatives.
            if let flat = requisite.simplified() { visit(flat) }
            if mentionsRetired { dependents.insert(course) }
        }

        let total = dependents.count
        guard total > 0 else { return ([], 0) }
        let found = listedTogether.compactMap { candidate, courses -> EquivalenceSuggestion? in
            guard isCurrent(candidate), !known.areEquivalent(retired, candidate),
                  courses.count >= minimumTogether, Double(courses.count) / Double(total) >= minimumShare else { return nil }
            return EquivalenceSuggestion(course: retired, candidate: candidate, together: courses.count, total: total)
        }
        return (found, total)
    }

    /// The candidates whose titles are like the retired course's, with the candidate's title and
    /// the score. Nothing when the retired course has no title, or one too generic to compare.
    private static func similarTitles(
        _ retired: CourseKey,
        candidates: [CourseKey],
        known: CourseEquivalences,
        title: (CourseKey) -> String?,
        minimum: Double
    ) -> [CourseKey: (title: String, score: Double)] {
        guard !candidates.isEmpty, let retiredText = title(retired) else { return [:] }
        let retiredTitle = CourseTitleMatcher.Title(retiredText)
        guard retiredTitle.isDistinctive else { return [:] }

        var found: [CourseKey: (title: String, score: Double)] = [:]
        for candidate in candidates where candidate != retired && found[candidate] == nil && !known.areEquivalent(retired, candidate) {
            guard let text = title(candidate)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let score = CourseTitleMatcher.similarity(of: retiredTitle, to: CourseTitleMatcher.Title(text), minimum: minimum) else { continue }
            found[candidate] = (text, score)
        }
        return found
    }
}
