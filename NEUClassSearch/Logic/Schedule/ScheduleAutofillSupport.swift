//
//  ScheduleAutofillSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Glue between a schedule plan and the degree plans' autofill logic
/// (`DegreePlanAutofill`): which suggestions apply, which one deserves a nudge,
/// and the bookkeeping for dismissed nudges.
enum ScheduleAutofillSupport {
    /// The Banner term a schedule plan belongs to, even when the term list hasn't loaded.
    static func term(for code: String, terms: [Term], index: CatalogIndex?) -> Term {
        if let known = terms.first(where: { $0.code == code }) { return known }
        if let indexTerm = index?.term, indexTerm.code == code { return indexTerm }
        return Term(code: code, bannerDescription: "")
    }

    /// Courses worth starting `plan` with, best first: the degree plan's courses for this
    /// semester, other schedules for the term, then the closest planned semester.
    /// Courses already in `plan` (and ones completed in the degree plan) are left out.
    static func suggestions(
        for plan: SchedulePlan,
        terms: [Term],
        degreePlans: [DegreePlan],
        schedulePlans: [SchedulePlan],
        index: CatalogIndex?
    ) -> [ScheduleAutofillSuggestion] {
        // Nothing to suggest from: skip the work (most schedules never have degree plans behind them).
        let hasSiblings = schedulePlans.contains { $0.termCode == plan.termCode && $0.id != plan.id && !$0.courses.isEmpty }
        guard !degreePlans.isEmpty || hasSiblings else { return [] }
        return DegreePlanAutofill.scheduleSuggestions(
            for: term(for: plan.termCode, terms: terms, index: index),
            degreePlans: degreePlans,
            schedulePlans: schedulePlans,
            excludingPlanID: plan.id,
            alreadyInPlan: Set(plan.courses.map(\.key)),
            index: index
        )
    }

    /// The exact-semester degree plan suggestion that still has courses missing from the
    /// schedule, if any, skipping ones the user dismissed. This is what the compact banner on
    /// a partly built plan offers.
    static func nudge(
        from suggestions: [ScheduleAutofillSuggestion],
        skipping isDismissed: (ScheduleAutofillSuggestion) -> Bool = { _ in false }
    ) -> ScheduleAutofillSuggestion? {
        suggestions.first { suggestion in
            guard suggestion.isExactTerm, case .degreePlan = suggestion.source, !suggestion.courses.isEmpty else { return false }
            return !isDismissed(suggestion)
        }
    }

    /// The suggestion an empty schedule previews: the chosen one, else the best that has
    /// courses to add (a degree plan semester whose courses aren't offered doesn't help).
    static func preview(of suggestions: [ScheduleAutofillSuggestion], choice: String?) -> ScheduleAutofillSuggestion? {
        if let choice, let chosen = suggestions.first(where: { $0.id == choice }) { return chosen }
        return suggestions.first { !$0.courses.isEmpty } ?? suggestions.first
    }

    /// `“New Plan”` and `Spring 2027` for a degree plan's semester; `Copy “Name”` and no
    /// semester for another schedule.
    static func sourceParts(of suggestion: ScheduleAutofillSuggestion) -> (name: String, term: String?) {
        switch suggestion.source {
        case .degreePlan: ("“\(suggestion.planName)”", suggestion.semester)
        case .schedulePlan: ("Copy “\(suggestion.planName)”", nil)
        }
    }

    /// `“New Plan” · Spring 2027`.
    static func sourceName(of suggestion: ScheduleAutofillSuggestion) -> String {
        let parts = sourceParts(of: suggestion)
        return parts.term.map { "\(parts.name) · \($0)" } ?? parts.name
    }

    /// The palette indexes `keys` will receive when added to `plan` in order, exactly as
    /// `UserDataStore.addCourse` assigns them, so previews match what lands in the schedule.
    static func colorIndices(for keys: [CourseKey], in plan: SchedulePlan) -> [Int] {
        var scratch = plan
        var indices: [Int] = []
        for key in keys {
            let color = scratch.nextColorIndex
            indices.append(color)
            scratch.courses.append(PlanCourse(key: key, isRequired: true, colorIndex: color))
        }
        return indices
    }

    // MARK: Dismissal

    /// Identifies one nudge for one schedule, for remembering that it was dismissed.
    static func dismissalKey(planID: UUID, suggestion: ScheduleAutofillSuggestion) -> String {
        "\(planID.uuidString)|\(suggestion.id)"
    }

    /// Dismissed nudges are stored as one newline-separated string (`@AppStorage` can't hold sets).
    static func isDismissed(_ key: String, in raw: String) -> Bool {
        raw.split(separator: "\n").contains { $0 == key }
    }

    /// `raw` with `key` added; only the most recent `limit` dismissals are kept.
    static func adding(_ key: String, to raw: String, limit: Int = 200) -> String {
        var keys = raw.split(separator: "\n").map(String.init).filter { $0 != key }
        keys.append(key)
        return keys.suffix(limit).joined(separator: "\n")
    }

    // MARK: Wording

    /// `3 courses`, `1 course`.
    static func courseCountLabel(_ count: Int) -> String {
        count == 1 ? "1 course" : "\(count) courses"
    }

    /// `Not offered this term: CS 3386, MATH 2331`.
    static func unavailableLine(_ keys: [CourseKey]) -> String {
        "Not offered this term: \(keys.map(\.description).joined(separator: ", "))"
    }
}
