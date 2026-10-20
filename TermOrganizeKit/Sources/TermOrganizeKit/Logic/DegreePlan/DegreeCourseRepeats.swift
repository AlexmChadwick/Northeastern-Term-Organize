//
//  DegreeCourseRepeats.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// When a course is in a plan more than once, whether the listings are different courses.
enum DegreeCourseRepeats {
    /// Whether another listing of a course counts as a course of its own: a topics course taken
    /// on another topic (the titles differ, or it's a topics course), not a repeat of the same
    /// class. Lines without credit never do.
    static func countsSeparately(title: String, credits: Double, from otherTitle: String, credits otherCredits: Double) -> Bool {
        guard credits > 0, otherCredits > 0 else { return false }
        let first = normalizedTitle(title), second = normalizedTitle(otherTitle)
        if !first.isEmpty, !second.isEmpty, first != second { return true }
        return first.contains("topic") || second.contains("topic")
    }

    static func countsSeparately(_ a: DegreePlanCourse, _ b: DegreePlanCourse) -> Bool {
        countsSeparately(title: a.title, credits: a.credits, from: b.title, credits: b.credits)
    }

    /// Lowercased letters and digits, with "&" as "and": `Algorithms & Data` matches
    /// `Algorithms and Data`.
    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
