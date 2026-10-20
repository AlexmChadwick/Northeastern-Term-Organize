//
//  CourseDegreePlanStanding.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  What the primary degree plan does with a course, for the tag in the course header. The iPhone
//  and iPad pages draw it as a link (`CourseDegreePlanTag`), the Mac window as a button.
//

import Foundation

/// What the primary degree plan does with a course: "Completed", or "Planned · Spring 2027", and
/// "via CS 2510" when a course that counts as it is the one in the plan.
struct CourseDegreePlanStanding: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Done in the plan: the course itself, or `via` an equivalent that was.
        case completed(via: CourseKey?)
        /// Planned in a semester, e.g. `Spring 2027`: the course itself, or `via` an equivalent that is.
        case planned(String, via: CourseKey?)
    }

    var planID: UUID
    var kind: Kind

    /// `Completed`, `Completed via CS 2510`, `Planned · Spring 2027`, `Planned via CS 2510 · Spring 2027`.
    var text: String {
        switch kind {
        case .completed(let via):
            via.map { "Completed via \($0.description)" } ?? "Completed"
        case .planned(let semester, let via):
            via.map { "Planned via \($0.description) · \(semester)" } ?? "Planned · \(semester)"
        }
    }

    /// The SF Symbol that goes with `text`.
    var symbol: String {
        switch kind {
        case .completed: "checkmark.circle.fill"
        case .planned: "calendar"
        }
    }

    /// `text` as VoiceOver should read it.
    var spokenText: String {
        switch kind {
        case .completed(let via):
            via.map { "Completed via \($0.description), in your degree plan" } ?? "Completed, in your degree plan"
        case .planned(let semester, let via):
            via.map { "Planned via \($0.description) for \(semester) in your degree plan" }
                ?? "Planned for \(semester) in your degree plan"
        }
    }
}

extension UserDataStore {
    /// The standing of a course in the primary degree plan: completed, else planned in one of its
    /// semesters. A course counts when an equivalent is the one in the plan. Nil without a plan or
    /// when the plan omits the course.
    func courseDegreePlanStanding(for key: CourseKey) -> CourseDegreePlanStanding? {
        guard let planID = primaryDegreePlan?.id else { return nil }
        let completed = completedCourses()
        let done = completed.completion(for: key)
        if done.isComplete { return CourseDegreePlanStanding(planID: planID, kind: .completed(via: done.via)) }
        if let planned = plannedTerm(for: key, counting: completed.equivalences) {
            return CourseDegreePlanStanding(planID: planID, kind: .planned(planned.term.shortName, via: planned.via))
        }
        return nil
    }

    /// Where the primary degree plan schedules a course, or a course that counts as it. `via` is
    /// that other course when it isn't `key` itself.
    func plannedTerm(for key: CourseKey, counting equivalences: CourseEquivalences) -> (term: DegreePlanTerm, via: CourseKey?)? {
        if let term = plannedTerm(for: key) { return (term, nil) }
        for other in equivalences.equivalents(of: key).sorted() {
            if let term = plannedTerm(for: other) { return (term, other) }
        }
        return nil
    }
}
