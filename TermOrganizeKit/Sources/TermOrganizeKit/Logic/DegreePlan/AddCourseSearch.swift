//
//  AddCourseSearch.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Pure helpers behind "Add Course" in a degree plan.
enum AddCourseSearch {
    /// Merges per-catalog results, given newest catalog first, into one list.
    ///
    /// A course found in several catalogs appears once, as the newest catalog's copy. The
    /// list is ordered by score, with ties kept in catalog order (newest first).
    static func merge(_ resultsNewestFirst: [[SearchResult]]) -> [SearchResult] {
        var seen = Set<CourseKey>()
        var merged: [SearchResult] = []
        for results in resultsNewestFirst {
            for result in results where seen.insert(result.course.key).inserted {
                merged.append(result)
            }
        }
        // `sorted` isn't stable, so break ties on the position in the merged list.
        return merged.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }

    /// The course code the text names when it can be added by code alone: letters, then a
    /// numeric number (`CS 3520`, `cs3520`), else nil.
    static func codeKey(from text: String) -> CourseKey? {
        guard let key = CourseKey(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.number.allSatisfy(\.isNumber) else { return nil }
        return key
    }

    /// Credits for a course added by code, when no catalog lists it.
    static let byCodeCredits: Double = 4
}
