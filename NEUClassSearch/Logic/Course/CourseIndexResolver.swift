//
//  CourseIndexResolver.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Resolving the catalog index a course, section or professor screen reads for its term, shared by
//  the iPhone and iPad screens and the Mac windows.
//

import SwiftUI
import Observation

/// Resolves the catalog index a screen should read for a term.
///
/// Screens read `catalog.cachedIndex(for:)`, which is observed: it returns the
/// store's index while the term is selected and the cached index of any other
/// loaded term, and it changes whenever a load, sync or live course refresh
/// installs a new index. That keeps a screen current without snapshots, even for
/// a term that is not the selected one. The resolver's job is to *load* the index
/// when it is not cached yet and to remember that the first attempt has finished.
@MainActor
@Observable
final class CourseIndexResolver {
    /// Whether the first resolution attempt has finished.
    private(set) var hasResolved = false

    /// Loads the term's index when the store does not have it yet (no-op otherwise).
    func resolve(termCode: String, catalog: CatalogStore) async {
        _ = await catalog.index(for: termCode)
        hasResolved = true
    }

    /// The latest index for the term, if loaded.
    func index(for termCode: String, in catalog: CatalogStore) -> CatalogIndex? {
        catalog.cachedIndex(for: termCode)
    }

    /// The term for titles and subtitles, even while its index is still loading.
    func term(for termCode: String, in catalog: CatalogStore) -> Term? {
        if let index = index(for: termCode, in: catalog) { return index.term }
        if let selected = catalog.selectedTerm, selected.code == termCode { return selected }
        return catalog.terms.first { $0.code == termCode }
    }

    /// Whether the term's catalog is still on its way (first resolution, or the
    /// store is loading it), so screens show progress rather than "unavailable".
    func isLoading(termCode: String, in catalog: CatalogStore) -> Bool {
        if !hasResolved { return true }
        return catalog.selectedTermCode == termCode && catalog.loadState == .loading
    }
}

private struct CourseIndexReloadModifier: ViewModifier {
    var resolver: CourseIndexResolver
    var termCode: String
    @Environment(CatalogStore.self) private var catalog

    func body(content: Content) -> some View {
        content
            .onChange(of: catalog.indexVersion) {
                // Downloaded data was cleared (or the cache dropped): load the term again.
                if catalog.cachedIndex(for: termCode) == nil {
                    Task { await resolver.resolve(termCode: termCode, catalog: catalog) }
                }
            }
    }
}

extension View {
    /// Reloads the term's index when it disappears from the store's cache.
    func courseReloadsIndex(_ resolver: CourseIndexResolver, termCode: String) -> some View {
        modifier(CourseIndexReloadModifier(resolver: resolver, termCode: termCode))
    }
}

extension UserDataStore {
    /// Whether a plan for the term already holds the course (`crn == nil`) or the
    /// given section (a plan's selected CRNs).
    func courseIsInSchedule(termCode: String, key: CourseKey, crn: String? = nil) -> Bool {
        let termPlans = plans(in: termCode)
        if let crn { return termPlans.contains { $0.selectedCRNs.contains(crn) } }
        return termPlans.contains { $0.contains(key) }
    }
}

/// Whether lazily loaded course details (description, requisites, instructors) are available.
enum CourseDetailsStatus: Equatable {
    case ready
    case loading
    case unavailable
}
