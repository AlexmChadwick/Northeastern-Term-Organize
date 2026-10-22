//
//  CourseEquivalences.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Courses that count as one another.
///
/// Northeastern renumbers courses (the computer science curriculum change replaced CS 2500,
/// CS 2510 and CS 3500 with CS 2000, CS 2100 and CS 3100, for example), and some courses are
/// offered under several subjects. A student who took the old number must count as having the
/// new one when prerequisites and degree requirements are checked, whichever department it is.
///
/// Nothing in here knows about any department. It is only a set of groups of interchangeable
/// courses, filled from data: Banner's mutual exclusions ("credit can't be earned for both"),
/// cross-listed sections, and equivalences the student declares in a degree plan. Groups are
///
/// - symmetric: if A counts as B, B counts as A, and
/// - transitive: A = B and B = C make A = C, so a chain of renumberings is one group.
struct CourseEquivalences: Hashable, Sendable {
    /// No equivalences: every course only counts as itself.
    static let none = CourseEquivalences()

    /// The groups: each is sorted, has at least two courses, and no course is in two groups.
    /// The groups themselves are ordered by their first course.
    private(set) var groups: [[CourseKey]]
    private var groupIndex: [CourseKey: Int]

    init() {
        groups = []
        groupIndex = [:]
    }

    /// Builds groups from lists of courses that count as one another. Lists that share a
    /// course are merged, and lists with a single course are dropped.
    init(groups input: [[CourseKey]]) {
        var sets = DisjointSets()
        for group in input {
            guard let first = group.first else { continue }
            sets.add(first)
            for other in group.dropFirst() { sets.union(first, other) }
        }
        var buckets: [CourseKey: [CourseKey]] = [:]
        for key in sets.keys { buckets[sets.find(key), default: []].append(key) }
        let built = buckets.values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
        var index: [CourseKey: Int] = [:]
        for (i, group) in built.enumerated() {
            for key in group { index[key] = i }
        }
        groups = built
        groupIndex = index
    }

    /// Builds groups from pairs of courses that count as one another.
    init(pairs: [(CourseKey, CourseKey)]) {
        self.init(groups: pairs.map { [$0.0, $0.1] })
    }

    var isEmpty: Bool { groups.isEmpty }

    /// Every course that has at least one equivalent.
    var courses: Set<CourseKey> { Set(groupIndex.keys) }

    /// The other courses that count as `key`; `key` itself is not included.
    func equivalents(of key: CourseKey) -> Set<CourseKey> {
        guard let i = groupIndex[key] else { return [] }
        var members = Set(groups[i])
        members.remove(key)
        return members
    }

    /// `key` together with everything that counts as it, sorted; just `[key]` when it has no
    /// equivalents.
    func group(of key: CourseKey) -> [CourseKey] {
        groupIndex[key].map { groups[$0] } ?? [key]
    }

    func areEquivalent(_ a: CourseKey, _ b: CourseKey) -> Bool {
        if a == b { return true }
        guard let i = groupIndex[a], let j = groupIndex[b] else { return false }
        return i == j
    }

    /// Courses taken plus everything those courses count as. Use it to check a prerequisite:
    /// a student who took CS 2510 satisfies a prerequisite of CS 2100 when the two are
    /// equivalent.
    func expanding(_ taken: Set<CourseKey>) -> Set<CourseKey> {
        guard !isEmpty else { return taken }
        var result = taken
        var seen = Set<Int>()
        for key in taken {
            guard let i = groupIndex[key], seen.insert(i).inserted else { continue }
            result.formUnion(groups[i])
        }
        return result
    }

    /// Every taken course that satisfies `required`: the course itself when it was taken,
    /// then the equivalents that were, in course order.
    func satisfiers(of required: CourseKey, in taken: Set<CourseKey>) -> [CourseKey] {
        var result: [CourseKey] = []
        if taken.contains(required) { result.append(required) }
        if let i = groupIndex[required] {
            result += groups[i].filter { $0 != required && taken.contains($0) }
        }
        return result
    }

    /// The taken course that satisfies `required`, possibly `required` itself; nil when none
    /// does. When several equivalents were taken the lowest-numbered one is returned.
    func satisfier(of required: CourseKey, in taken: Set<CourseKey>) -> CourseKey? {
        if taken.contains(required) { return required }
        guard let i = groupIndex[required] else { return nil }
        return groups[i].first { taken.contains($0) }
    }

    /// The union of two sets of equivalences (overlapping groups are merged).
    func merging(_ other: CourseEquivalences) -> CourseEquivalences {
        if other.isEmpty { return self }
        if isEmpty { return other }
        return CourseEquivalences(groups: groups + other.groups)
    }

    /// A copy where `a` and `b` also count as one another.
    func adding(_ a: CourseKey, _ b: CourseKey) -> CourseEquivalences {
        merging(CourseEquivalences(groups: [[a, b]]))
    }
}

extension CourseEquivalences: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(groups: try container.decode([[CourseKey]].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(groups)
    }
}

/// Union-find over courses, used to merge overlapping groups.
private struct DisjointSets {
    private var parent: [CourseKey: CourseKey] = [:]

    var keys: [CourseKey] { Array(parent.keys) }

    mutating func add(_ key: CourseKey) {
        if parent[key] == nil { parent[key] = key }
    }

    mutating func find(_ key: CourseKey) -> CourseKey {
        add(key)
        var root = key
        while let next = parent[root], next != root { root = next }
        var node = key
        while let next = parent[node], next != root {
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: CourseKey, _ b: CourseKey) {
        let rootA = find(a), rootB = find(b)
        guard rootA != rootB else { return }
        // The smaller course stays the root so the result doesn't depend on input order.
        if rootA < rootB { parent[rootB] = rootA } else { parent[rootA] = rootB }
    }
}
