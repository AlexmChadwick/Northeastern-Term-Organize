//
//  CourseCompletion.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

extension UserDataStore {
    /// What the primary degree plan lists as completed, and everything that counts as something
    /// else: what Banner says (mutual exclusions, cross-listed courses), merged with the
    /// equivalences the student declared in the plan.
    ///
    /// Read it once per screen update and ask `completion(for:)` of the result: reading the
    /// equivalences takes a little work, and a requirement tree asks about dozens of courses.
    func completedCourses() -> CompletedCourses {
        CompletedCourses(
            taken: completedCourseKeys,
            equivalences: CourseInfoStore.shared.equivalences(for: primaryDegreePlan)
        )
    }

    /// Whether the user has completed `key`, and which course counted if it was a different one.
    ///
    /// Every completed mark on the course screens asks here: the green checks and "Done with"
    /// captions in the requirements card, the degree plan tag in the course header. (The
    /// prerequisite status line asks `DegreePlanAnalysis` with the same equivalences.) When a
    /// renumbered or cross-listed course counts, `via` is the one the student took and the card
    /// says "Completed via CS 2510".
    func completion(for key: CourseKey) -> (isComplete: Bool, via: CourseKey?) {
        completedCourses().completion(for: key)
    }
}
