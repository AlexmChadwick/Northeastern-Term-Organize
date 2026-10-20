//
//  CourseInfo.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// What Banner's course catalog says about a course, read for a course key and a term
/// without needing a section (a CRN).
///
/// A term's schedule only lists the courses that have sections that term, but the catalog is
/// effective-dated: it lists every course that is active in the term, offered or not. That is
/// what lets prerequisites be checked for a course that isn't taught this semester, and, by
/// reading an earlier term's catalog, for a course that has been retired or renumbered since.
struct CourseInfo: Codable, Hashable, Sendable {
    var key: CourseKey
    var title: String
    /// Credit hours; nil when the catalog entry doesn't say.
    var minCredits: Double?
    var maxCredits: Double?
    var prerequisites: Requisite?
    var corequisites: Requisite?
    /// Courses that count as this one: the ones Banner says credit can't be earned alongside
    /// (mutual exclusions, which is how Northeastern links a renumbered course to its
    /// replacement). Sorted.
    var equivalents: [CourseKey]
    /// The term whose catalog the entry was read from, e.g. `202630`. Older than the newest
    /// term when the course has been retired since.
    var sourceTerm: String
    /// Whether the course has been retired: true when only catalogs older than the newest term
    /// list it (CS 2510 after the renumbering), false when the newest term's catalog does, nil
    /// when that wasn't checked (the entry comes from the schedule of an older term).
    var isRetired: Bool?
    var fetchedAt: Date

    init(
        key: CourseKey,
        title: String,
        minCredits: Double? = nil,
        maxCredits: Double? = nil,
        prerequisites: Requisite? = nil,
        corequisites: Requisite? = nil,
        equivalents: [CourseKey] = [],
        sourceTerm: String,
        isRetired: Bool? = nil,
        fetchedAt: Date = .now
    ) {
        self.key = key
        self.title = title
        self.minCredits = minCredits
        self.maxCredits = maxCredits
        self.prerequisites = prerequisites
        self.corequisites = corequisites
        self.equivalents = Array(Set(equivalents.filter { $0 != key })).sorted()
        self.sourceTerm = sourceTerm
        self.isRetired = isRetired
        self.fetchedAt = fetchedAt
    }

    /// `4 credits`, `1–4 credits`; nil when the credit hours are unknown.
    var creditsLabel: String? {
        guard let low = minCredits ?? maxCredits else { return nil }
        return CreditFormatter.label(min: low, max: maxCredits ?? low)
    }
}
