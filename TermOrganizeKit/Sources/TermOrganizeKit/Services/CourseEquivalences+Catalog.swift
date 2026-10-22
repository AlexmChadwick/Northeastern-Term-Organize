//
//  CourseEquivalences+Catalog.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

extension CourseEquivalences {
    /// The equivalences a student declared in a degree plan.
    init(declared: [CourseEquivalence]) {
        self.init(pairs: declared.map { ($0.course, $0.countsAs) })
    }

    /// Courses that are one course listed under several subjects, read from the cross-listed
    /// sections of a loaded term (`CourseSection.crossListCRNs`).
    ///
    /// Banner cross-lists far more than duplicate courses: combined undergraduate and graduate
    /// sections (CS 3000 with CS 5800) and special-topics shells (ALY 6983 with CS 6983) meet
    /// together too, and are not interchangeable. Only cross-listed courses that have the same
    /// number and the same title in different subjects count (AFCS 1225, HIST 1225 and
    /// WMNS 1225 are "Gender, Race, and Medicine"), and special topics never do.
    init(crossListedIn index: CatalogIndex) {
        var pairs = Set<CrossListedPair>()
        for section in index.catalog.sections where !section.crossListCRNs.isEmpty {
            let key = section.courseKey
            guard index.course(key)?.specialTopics != true else { continue }
            for crn in section.crossListCRNs {
                guard let other = index.section(crn: crn) else { continue }
                let otherKey = other.courseKey
                guard otherKey.number == key.number, otherKey.subject != key.subject,
                      index.course(otherKey)?.specialTopics != true else { continue }
                let title = Self.normalizedTitle(index.course(key)?.title ?? section.title)
                let otherTitle = Self.normalizedTitle(index.course(otherKey)?.title ?? other.title)
                guard !title.isEmpty, title == otherTitle else { continue }
                pairs.insert(CrossListedPair(key, otherKey))
            }
        }
        self.init(pairs: pairs.map { ($0.first, $0.second) })
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

/// An unordered pair of courses.
private struct CrossListedPair: Hashable {
    let first: CourseKey
    let second: CourseKey

    init(_ a: CourseKey, _ b: CourseKey) {
        first = min(a, b)
        second = max(a, b)
    }
}

extension DegreePlan {
    /// The plan's declared equivalences (`courseEquivalences`) as groups.
    var declaredEquivalences: CourseEquivalences { CourseEquivalences(declared: courseEquivalences) }

    /// Declares that taking `course` counts as `countsAs`. Does nothing, and returns false, when
    /// the courses are the same or the plan already declares them equivalent.
    @discardableResult
    mutating func declareEquivalence(course: CourseKey, countsAs: CourseKey, note: String = "") -> Bool {
        guard course != countsAs, !declaredEquivalences.areEquivalent(course, countsAs) else { return false }
        courseEquivalences.append(CourseEquivalence(course: course, countsAs: countsAs, note: note))
        return true
    }

    mutating func removeEquivalence(id: UUID) {
        courseEquivalences.removeAll { $0.id == id }
    }
}

extension CourseInfo {
    /// The entry for a course of a loaded term. Nil for a course that was synced without its
    /// details: it has no requisites yet, which would read as "no prerequisites".
    ///
    /// - Parameter isNewest: whether `index` is the newest term, so a course it lists is current.
    init?(course: Course, in index: CatalogIndex, isNewest: Bool = false, fetchedAt: Date = .now) {
        guard course.detailsLoaded else { return nil }
        self.init(
            key: course.key,
            title: course.title,
            minCredits: course.minCredits,
            maxCredits: course.maxCredits,
            prerequisites: course.prereqs,
            corequisites: course.coreqs,
            sourceTerm: index.term.code,
            isRetired: isNewest ? false : nil,
            fetchedAt: fetchedAt
        )
    }

    /// The entry for a course from the loaded catalogs, newest first; nil when none lists it with
    /// its requisites.
    static func fromLoaded(_ key: CourseKey, in indexes: [CatalogIndex]) -> CourseInfo? {
        for (position, index) in indexes.enumerated() {
            if let course = index.course(key),
               let info = CourseInfo(course: course, in: index, isNewest: position == 0, fetchedAt: index.catalog.generatedAt) {
                return info
            }
        }
        return nil
    }
}
