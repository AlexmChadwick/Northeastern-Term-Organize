//
//  EquivalencePrompt.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  "Did CS 2510 count as CS 2100?" Banner has no renumbering links, so a requirement that names
//  CS 2100 can look unmet to a student who took CS 2510, the course it replaced. The catalog's
//  prerequisites often list the two side by side (see `EquivalenceSuggestion`); when they do, the
//  course page asks, and the answer is the student's to give. Nothing here touches SwiftUI.
//

import Foundation

/// A question for the student: did a course they completed count as one a requirement names?
struct EquivalencePrompt: Hashable, Sendable, Identifiable {
    /// The course the student completed, one the catalog no longer lists.
    var taken: CourseKey
    /// The course the requirement names, which `taken` may count as.
    var required: CourseKey
    /// Why it is asked: "Listed together in 7 of the 10 prerequisites that name CS 2510".
    var evidence: String
    /// In how many prerequisites the two are listed together; more is likelier.
    var together: Int

    var id: String { "\(taken)|\(required)" }

    /// The questions a requirement calls for, likeliest first.
    ///
    /// A question is asked only when answering it matters here:
    /// - the requirement isn't met yet (counting what the student's equivalences already cover),
    /// - it names `required` and the student hasn't completed that or anything counting as it,
    /// - and it doesn't name `taken` itself. When it lists both ("CS 2100 or CS 2510") the student's
    ///   course already counts as written, and asking would be noise.
    ///
    /// - Parameters:
    ///   - dismissed: the pairs the student said no to (`EquivalenceSuggestionDismissals.decode`).
    ///     They are left out before the limit applies, so a dismissed one never takes a slot.
    ///   - suggestions: the current courses a retired course may count as (the course store's
    ///     `equivalenceSuggestions(for:plan:)`); empty for a course that isn't retired.
    ///   - limit: the most questions to ask at once.
    static func choose(
        for requisite: Requisite,
        completed: CompletedCourses,
        dismissed: Set<String> = [],
        suggestions: (CourseKey) -> [EquivalenceSuggestion],
        limit: Int = 2
    ) -> [EquivalencePrompt] {
        guard let tree = requisite.normalizedForDisplay(), !completed.meets(tree) else { return [] }
        let covered = completed.covered
        let named = Set(tree.referencedCourses)
        let unmet = named.subtracting(covered)
        guard !unmet.isEmpty else { return [] }

        var best: [CourseKey: EquivalenceSuggestion] = [:]
        for taken in completed.taken.sorted() where !named.contains(taken) {
            for suggestion in suggestions(taken) where unmet.contains(suggestion.candidate) {
                let pair = EquivalenceSuggestionDismissals.pairID(taken, suggestion.candidate)
                if dismissed.contains(pair) { continue }
                if let current = best[suggestion.candidate], current.together >= suggestion.together { continue }
                best[suggestion.candidate] = suggestion
            }
        }
        return best.values
            .sorted { ($1.together, $0.candidate) < ($0.together, $1.candidate) }
            .prefix(limit)
            .map { EquivalencePrompt(taken: $0.course, required: $0.candidate, evidence: $0.evidence, together: $0.together) }
    }
}

/// The suggestions the student turned down, kept on this device.
///
/// A suggestion is a guess; when it is wrong the student says so once and it never comes back, on
/// any page. The pairs live in one newline-separated string in `@AppStorage(storageKey)` (which
/// can't hold a set), the way the schedule's autofill nudges do, newest last, at most `limit` of
/// them. A view reads it with `@AppStorage(EquivalenceSuggestionDismissals.storageKey) var raw = ""`,
/// asks `isDismissed(_:_:in:)` (or `decode` once for many), and calls `dismiss(_:_:in:)` with `&raw`.
///
/// The key and the pair id are the ones the degree plan screens use for their own suggestions
/// (`DegreeEquivalenceDismissals`, `DegreeEquivalencePrompt.pairID`), so turning one down in either
/// place turns it down in both. The pair is unordered: "CS 2510 counts as CS 2100" and "CS 2100
/// counts as CS 2510" are one suggestion.
enum EquivalenceSuggestionDismissals {
    /// The `@AppStorage` key.
    static let storageKey = "degreePlan.dismissedEquivalenceSuggestions"
    /// The most pairs remembered; past it the oldest are forgotten.
    static let limit = 200

    /// Identifies a suggestion, the same for either order of the two courses: `CS 2100|CS 2510`.
    static func pairID(_ a: CourseKey, _ b: CourseKey) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// The pair ids in a stored string.
    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    /// Whether the student turned down the suggestion that `a` and `b` count as one another.
    static func isDismissed(_ a: CourseKey, _ b: CourseKey, in raw: String) -> Bool {
        let id = pairID(a, b)
        return raw.split(separator: "\n").contains { $0 == id }
    }

    static func isDismissed(_ prompt: EquivalencePrompt, in raw: String) -> Bool {
        isDismissed(prompt.taken, prompt.required, in: raw)
    }

    /// Remembers that the student turned down the suggestion that `a` and `b` count as one
    /// another. Pass the `@AppStorage` string as `&raw`.
    static func dismiss(_ a: CourseKey, _ b: CourseKey, in raw: inout String) {
        raw = adding(pairID(a, b), to: raw)
    }

    static func dismiss(_ prompt: EquivalencePrompt, in raw: inout String) {
        dismiss(prompt.taken, prompt.required, in: &raw)
    }

    /// `raw` with the pair id added as the newest; only the newest `limit` are kept.
    static func adding(_ id: String, to raw: String, limit: Int = EquivalenceSuggestionDismissals.limit) -> String {
        var ids = raw.split(separator: "\n").map(String.init).filter { $0 != id }
        ids.append(id)
        return ids.suffix(limit).joined(separator: "\n")
    }
}
