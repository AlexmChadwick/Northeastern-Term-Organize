//
//  CourseDependents.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The "Leads to" list on the course page: the courses that mention this one
//  among their prerequisites, and whether each of them needs it.
//
//  Being mentioned is not the same as being required. CS 3000's prerequisite is
//  `((CS 2100 or CS 2510 or ...) and (CS 1800 or ...)) or CS 2700`: every course in
//  it is "a prerequisite for CS 3000" and none of them is required. In the bundled
//  catalog this course is required for only about one dependent in five. Nothing
//  here touches SwiftUI.
//

import Foundation

/// A course whose prerequisites mention another course (the one whose page it is).
struct CourseDependent: Hashable, Sendable, Identifiable {
    /// What the other course is to this one's prerequisites.
    enum Role: String, Hashable, Sendable {
        /// The prerequisites can't be met without it.
        case required
        /// One of several ways to meet them.
        case option

        /// The label over a group of dependents.
        var caption: String {
            switch self {
            case .required: "Required"
            case .option: "One option"
            }
        }

        /// What VoiceOver adds after the course: "CS 3000, one option among its prerequisites".
        var spokenNote: String {
            switch self {
            case .required: "required prerequisite"
            case .option: "one option among its prerequisites"
            }
        }
    }

    var key: CourseKey
    /// Nil when the course's prerequisites aren't known, or don't mention the other
    /// course after all, so there is nothing to say.
    var role: Role?
    /// Whether this term's catalog lists the course, so it has a page to open.
    var isOffered: Bool

    var id: CourseKey { key }
}

extension Requisite {
    /// How `course` figures in this requisite.
    ///
    /// `.required` when the requisite can't be met without it, even if every other course it
    /// mentions has been taken; `.option` when some other way meets it; nil when it isn't
    /// mentioned. (Requisites only ever ask for more, so if taking all the others doesn't
    /// meet it, no smaller set does.) Placement tests count as met, as in the degree plan's
    /// own checks, so `A or [Graduate Admission]` doesn't require A.
    func role(of course: CourseKey) -> CourseDependent.Role? {
        guard let tree = normalizedForDisplay() else { return nil }
        var others = Set(tree.referencedCourses)
        guard others.remove(course) != nil else { return nil }
        return tree.isSatisfied(by: others, assumeTestsMet: true) ? .option : .required
    }
}

extension CourseDependent {
    /// The courses in `keys` (those that mention `course`) in the order the list shows
    /// them: the ones that require it first, then the ones where it is one option, then any
    /// whose prerequisites can't be read. Courses offered this term come before the rest
    /// within each, and otherwise the order of `keys` is kept.
    static func arranged(
        _ keys: [CourseKey],
        of course: CourseKey,
        prerequisites: (CourseKey) -> Requisite?,
        isOffered: (CourseKey) -> Bool
    ) -> [CourseDependent] {
        func rank(_ dependent: CourseDependent) -> Int {
            let roleRank: Int
            switch dependent.role {
            case .required: roleRank = 0
            case .option: roleRank = 1
            case nil: roleRank = 2
            }
            return roleRank * 2 + (dependent.isOffered ? 0 : 1)
        }
        return keys
            .map { CourseDependent(key: $0, role: prerequisites($0)?.role(of: course), isOffered: isOffered($0)) }
            .enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.element), rank(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
