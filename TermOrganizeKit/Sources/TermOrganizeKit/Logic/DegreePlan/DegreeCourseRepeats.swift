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
    /// Whether another listing of a course counts as a course of its own.
    ///
    /// When either listing names a CRN, both must name one and the CRNs must differ
    /// (two special-topics sections). The same CRN twice is one course. When neither
    /// names a CRN, a different title counts on its own, and so does a topics course
    /// (the title contains "topic"), which is how plans imported without CRNs still
    /// count each topic. Lines without credit never count separately.
    static func countsSeparately(
        title: String, credits: Double, crn: String? = nil,
        from otherTitle: String, credits otherCredits: Double, otherCRN: String? = nil
    ) -> Bool {
        guard credits > 0, otherCredits > 0 else { return false }
        if crn != nil || otherCRN != nil {
            guard let crn, let otherCRN else { return false }
            return crn != otherCRN
        }
        let first = normalizedTitle(title), second = normalizedTitle(otherTitle)
        if !first.isEmpty, !second.isEmpty, first != second { return true }
        return first.contains("topic") || second.contains("topic")
    }

    static func countsSeparately(_ a: DegreePlanCourse, _ b: DegreePlanCourse) -> Bool {
        countsSeparately(title: a.title, credits: a.credits, crn: a.crn, from: b.title, credits: b.credits, otherCRN: b.crn)
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
