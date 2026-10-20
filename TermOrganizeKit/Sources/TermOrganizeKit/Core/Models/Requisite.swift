//
//  Requisite.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu): the recursive and/or condition over
//  courses and placement tests follows the requisite types in
//  packages/scraper/src/types.ts, and `referencedCourses` and `simplified()` follow
//  `getAllPrereqsForSingleCourse` and `mergeSameConditionTypes` in
//  packages/scraper/src/generate/steps/reqs.ts, Copyright (C) Sandbox at
//  Northeastern University and the SearchNEU contributors, licensed under the GNU
//  Affero General Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift as an indirect enum;
//  satisfaction checks, a one-line summary and a compact Codable encoding were added.
//

import Foundation

/// A prerequisite or corequisite expression.
indirect enum Requisite: Hashable, Sendable {
    case course(CourseKey)
    case test(name: String, score: Double?)
    case and([Requisite])
    case or([Requisite])

    /// Every course referenced anywhere in the tree, in first-seen order.
    var referencedCourses: [CourseKey] {
        var seen = Set<CourseKey>()
        var out: [CourseKey] = []
        func visit(_ r: Requisite) {
            switch r {
            case .course(let key):
                if seen.insert(key).inserted { out.append(key) }
            case .test:
                break
            case .and(let items), .or(let items):
                items.forEach(visit)
            }
        }
        visit(self)
        return out
    }

    /// Whether the expression is satisfied given a set of completed courses.
    /// Tests are treated as unsatisfied unless `assumeTestsMet` is set.
    func isSatisfied(by completed: Set<CourseKey>, assumeTestsMet: Bool = false) -> Bool {
        switch self {
        case .course(let key): return completed.contains(key)
        case .test: return assumeTestsMet
        case .and(let items): return items.allSatisfy { $0.isSatisfied(by: completed, assumeTestsMet: assumeTestsMet) }
        case .or(let items): return items.contains { $0.isSatisfied(by: completed, assumeTestsMet: assumeTestsMet) }
        }
    }

    /// Collapses single-child conditions and merges nested conditions of the
    /// same kind, e.g. `or(a, or(b, c))` becomes `or(a, b, c)`.
    /// The same requisite with every course key transformed.
    func mapCourses(_ transform: (CourseKey) -> CourseKey) -> Requisite {
        switch self {
        case .course(let key): .course(transform(key))
        case .test: self
        case .and(let items): .and(items.map { $0.mapCourses(transform) })
        case .or(let items): .or(items.map { $0.mapCourses(transform) })
        }
    }

    func simplified() -> Requisite? {
        switch self {
        case .course, .test:
            return self
        case .and(let items):
            let flat = items.compactMap { $0.simplified() }.flatMap { child -> [Requisite] in
                if case .and(let inner) = child { return inner }
                return [child]
            }
            if flat.isEmpty { return nil }
            return flat.count == 1 ? flat[0] : .and(flat)
        case .or(let items):
            let flat = items.compactMap { $0.simplified() }.flatMap { child -> [Requisite] in
                if case .or(let inner) = child { return inner }
                return [child]
            }
            if flat.isEmpty { return nil }
            return flat.count == 1 ? flat[0] : .or(flat)
        }
    }

    /// A compact single-line description, e.g. `(CS 2100 or CS 2510) and CS 1800`.
    var summary: String {
        switch self {
        case .course(let key): return key.description
        case .test(let name, let score):
            if let score { return "\(name) (\(score.formatted(.number.grouping(.never))))" }
            return name
        case .and(let items):
            return items.map { $0.isCondition ? "(\($0.summary))" : $0.summary }.joined(separator: " and ")
        case .or(let items):
            return items.map { $0.isCondition ? "(\($0.summary))" : $0.summary }.joined(separator: " or ")
        }
    }

    var isCondition: Bool {
        switch self {
        case .and, .or: true
        default: false
        }
    }
}

// MARK: - Codable

extension Requisite: Codable {
    private enum CodingKeys: String, CodingKey {
        case subject = "s", number = "n", test, score, and, or
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let items = try c.decodeIfPresent([Requisite].self, forKey: .and) {
            self = .and(items)
        } else if let items = try c.decodeIfPresent([Requisite].self, forKey: .or) {
            self = .or(items)
        } else if let name = try c.decodeIfPresent(String.self, forKey: .test) {
            self = .test(name: name, score: try c.decodeIfPresent(Double.self, forKey: .score))
        } else {
            self = .course(CourseKey(
                subject: try c.decode(String.self, forKey: .subject),
                number: try c.decode(String.self, forKey: .number)
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .course(let key):
            try c.encode(key.subject, forKey: .subject)
            try c.encode(key.number, forKey: .number)
        case .test(let name, let score):
            try c.encode(name, forKey: .test)
            try c.encodeIfPresent(score, forKey: .score)
        case .and(let items):
            try c.encode(items, forKey: .and)
        case .or(let items):
            try c.encode(items, forKey: .or)
        }
    }
}
