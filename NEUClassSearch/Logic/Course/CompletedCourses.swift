//
//  CompletedCourses.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// The courses the user has completed and what counts as what, read once.
///
/// A requirements card asks about dozens of courses, and the screen around it asks again (the
/// status line, the header tag). Reading the equivalences takes a little work, so a screen gathers
/// them once per update (`UserDataStore.completedCourses()`) and asks this.
struct CompletedCourses {
    /// What the primary degree plan lists as completed (the audit counts courses in progress too).
    var taken: Set<CourseKey> = []
    /// Which courses count as which: Banner's, cross-listed courses and the plan's declared ones.
    var equivalences: CourseEquivalences = .none

    static let none = CompletedCourses()

    /// Whether `key` is done, and which completed course counted when it wasn't `key` itself
    /// ("Completed via CS 2510").
    ///
    /// The one place the course screens decide this. The via course is the one
    /// `CourseEquivalences.satisfier(of:in:)` picks (the lowest-numbered when several were taken),
    /// which is also how `DegreePlanAnalysis.coveringEquivalents` reads it.
    func completion(for key: CourseKey) -> (isComplete: Bool, via: CourseKey?) {
        guard let counted = equivalences.satisfier(of: key, in: taken) else { return (false, nil) }
        return (true, counted == key ? nil : counted)
    }

    /// Every course that counts as done: the ones taken and what they count as.
    var covered: Set<CourseKey> { equivalences.expanding(taken) }

    /// Whether a requisite is met. Placement tests count as met, as in the degree plan's own checks.
    func meets(_ requisite: Requisite) -> Bool {
        requisite.isSatisfied(by: covered, assumeTestsMet: true)
    }
}
