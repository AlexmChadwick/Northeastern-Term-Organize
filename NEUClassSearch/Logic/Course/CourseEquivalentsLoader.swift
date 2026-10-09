//
//  CourseEquivalentsLoader.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

extension CatalogStore {
    /// Every catalog loaded in memory, newest term first: what `CourseInfoStore.load` reads
    /// before it asks Banner.
    var loadedIndexes: [CatalogIndex] {
        var codes = terms.map(\.code)
        if let selected = index?.term.code { codes.append(selected) }
        var seen = Set<String>()
        var loaded: [CatalogIndex] = []
        for code in codes {
            guard seen.insert(code).inserted, let found = cachedIndex(for: code) else { continue }
            loaded.append(found)
        }
        return loaded.sorted { $0.term.code > $1.term.code }
    }
}

extension View {
    /// Makes sure the course store knows what it needs to tell whether the user's completed
    /// courses count for `courses` (the ones this screen names, and its own).
    ///
    /// Equivalences come from Banner's catalog entries, which the store only has for courses it
    /// was asked about, so a course the term's catalog no longer lists (CS 2510 after the
    /// renumbering) must be loaded before it can count as CS 2100. The requested courses are the
    /// ones the screen names that aren't completed, plus the completed ones the newest loaded term
    /// doesn't list; courses the term lists need nothing. Answers are cached on disk, so this is
    /// network work only the first time, and nothing happens without a degree plan or when every
    /// course the screen names is already covered.
    func courseLoadsEquivalents(for courses: [CourseKey]) -> some View {
        modifier(CourseEquivalentsLoader(courses: courses))
    }
}

private struct CourseEquivalentsLoader: ViewModifier {
    var courses: [CourseKey]

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData

    private struct LoadID: Hashable {
        var needed: Bool
        var keys: [CourseKey]
        var indexVersion: Int
    }

    func body(content: Content) -> some View {
        let indexes = catalog.loadedIndexes
        let request = request(indexes: indexes)
        content
            .task(id: LoadID(needed: request.needed, keys: request.keys, indexVersion: catalog.indexVersion)) {
                guard request.needed else { return }
                // In an unstructured task, so a change of inputs mid-load restarts this one
                // without cancelling the lookups already in flight (the store skips those).
                let store = CourseInfoStore.shared
                let keys = request.keys
                await Task { await store.load(keys, indexes: indexes) }.value
            }
    }

    /// Whether anything is to be loaded, and which courses.
    private func request(indexes: [CatalogIndex]) -> (needed: Bool, keys: [CourseKey]) {
        guard userData.primaryDegreePlan != nil, let newest = indexes.first else { return (false, []) }
        let completed = userData.completedCourses()
        let unmet = Set(courses).subtracting(completed.covered)
        guard !unmet.isEmpty else { return (false, []) }
        // The newest term lists what is current: those need no lookup.
        var wanted = Set(unmet.filter { newest.course($0) == nil })
        wanted.formUnion(completed.taken.filter { newest.course($0) == nil })
        return (true, wanted.sorted())
    }
}
