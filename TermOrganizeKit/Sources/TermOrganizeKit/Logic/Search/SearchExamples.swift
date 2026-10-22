//
//  SearchExamples.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The examples the empty search screen offers, built from the loaded catalog so every one of them
//  finds something (iPhone, iPad and Mac), and the busiest subjects it lists.
//

import Foundation

/// An example query offered on the empty search screen.
struct SearchExample: Identifiable {
    var title: String
    var caption: String
    var symbol: String
    var id: String { caption }
}

/// Builds the examples from real catalog data (so every one of them finds
/// something) once per catalog snapshot rather than on every render.
@MainActor
enum SearchExampleCache {
    private static var cachedKey: String?
    private static var cached: [SearchExample] = []

    static func examples(for index: CatalogIndex) -> [SearchExample] {
        let key = "\(index.term.code)|\(index.catalog.sectionsUpdatedAt.timeIntervalSince1970)"
        if key == cachedKey { return cached }
        let built = build(from: index)
        cachedKey = key
        cached = built
        return built
    }

    private static func build(from index: CatalogIndex) -> [SearchExample] {
        var result: [SearchExample] = []

        let preferred = ["CS 3000", "CS 2500", "MATH 1341", "ENGW 1111", "PHYS 1151"]
        let exampleKey = preferred.compactMap { CourseKey(string: $0) }.first { index.course($0) != nil }
            ?? index.courses.first?.key
        if let exampleKey {
            result.append(SearchExample(title: exampleKey.description, caption: "Course code", symbol: "book.closed"))
        }

        // A topic that really appears in this term's course titles.
        let topics = ["machine learning", "data structures", "calculus", "psychology", "writing"]
        if let topic = topics.first(where: { topic in
            index.searchDocuments.contains { $0.titleNormalized.contains(topic) }
        }) {
            result.append(SearchExample(title: topic, caption: "Topic or title", symbol: "lightbulb"))
        }

        let crn = exampleKey.flatMap { index.sections(for: $0).first?.crn } ?? index.catalog.sections.first?.crn
        if let crn {
            result.append(SearchExample(title: crn, caption: "CRN", symbol: "number"))
        }

        // Someone who teaches the example course, so the results look familiar;
        // otherwise whoever teaches the most courses.
        let teacher = exampleKey
            .flatMap { key in
                index.sections(for: key)
                    .lazy
                    .compactMap { $0.instructors?.first(where: \.primary) ?? $0.instructors?.first }
                    .first
            }
            .flatMap { index.instructor(named: $0.name) }
        if let professor = teacher ?? index.instructors.max(by: { $0.courseKeys.count < $1.courseKeys.count }) {
            result.append(SearchExample(title: professor.displayName, caption: "Professor", symbol: "person.crop.circle"))
        }
        return result
    }
}

extension CatalogIndex {
    /// The subjects with the most courses (ties broken by code), for the quick subject buttons.
    func popularSubjects(limit: Int = 12) -> [Subject] {
        let counts = courseCountBySubject
        let sorted = activeSubjects.sorted { a, b in
            let countA = counts[a.code] ?? 0
            let countB = counts[b.code] ?? 0
            return countA != countB ? countA > countB : a.code < b.code
        }
        return Array(sorted.prefix(limit))
    }
}
