//
//  TermCatalog.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file (`recomputePostreqs()`) are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), `populatePostReqs` in
//  packages/scraper/src/generate/steps/reqs.ts, Copyright (C) Sandbox at
//  Northeastern University and the SearchNEU contributors, licensed under the GNU
//  Affero General Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift; postrequisites are stored
//  as a sorted list of courses instead of an "and" requisite.
//

import Foundation

/// Everything known about one term: the serialized unit stored on disk and
/// bundled with the app.
struct TermCatalog: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var term: Term
    /// When the catalog (descriptions, requisites) was generated.
    var generatedAt: Date
    /// When section data (seats, times) was last refreshed from Banner.
    var sectionsUpdatedAt: Date
    var courses: [Course]
    var sections: [CourseSection]
    var subjects: [Subject]
    var attributes: [AttributeInfo]
    var campuses: [Campus]

    init(
        term: Term,
        generatedAt: Date = .now,
        sectionsUpdatedAt: Date = .now,
        courses: [Course],
        sections: [CourseSection],
        subjects: [Subject],
        attributes: [AttributeInfo],
        campuses: [Campus]
    ) {
        self.version = TermCatalog.currentVersion
        self.term = term
        self.generatedAt = generatedAt
        self.sectionsUpdatedAt = sectionsUpdatedAt
        self.courses = courses
        self.sections = sections
        self.subjects = subjects
        self.attributes = attributes
        self.campuses = campuses
    }

    /// Recomputes every course's `postreqs` ("prereq for") from the prereqs
    /// of all courses in the catalog.
    mutating func recomputePostreqs() {
        var map: [CourseKey: Set<CourseKey>] = [:]
        for course in courses {
            guard let prereqs = course.prereqs else { continue }
            for key in prereqs.referencedCourses {
                map[key, default: []].insert(course.key)
            }
        }
        for i in courses.indices {
            courses[i].postreqs = (map[courses[i].key] ?? []).sorted()
        }
    }
}

/// Lightweight description of a stored catalog, used for listing terms
/// without decoding every course.
struct TermCatalogSummary: Codable, Hashable, Sendable {
    var term: Term
    var generatedAt: Date
    var sectionsUpdatedAt: Date
    var courseCount: Int
    var sectionCount: Int
}
