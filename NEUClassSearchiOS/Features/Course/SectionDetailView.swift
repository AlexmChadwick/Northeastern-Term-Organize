//
//  SectionDetailView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One section (CRN): seats, schedule, instructors and actions.
struct SectionDetailView: View {
    var termCode: String
    var crn: String

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    @State private var resolver = CourseIndexResolver()
    @State private var detailsAttemptFinished = false
    @State private var refreshFailed = false

    private static let autoRefreshInterval: TimeInterval = 5 * 60

    private struct TaskID: Hashable {
        var termCode: String
        var crn: String
    }

    private var index: CatalogIndex? {
        resolver.index(for: termCode, in: catalog)
    }

    private var section: CourseSection? {
        index?.section(crn: crn)
    }

    private var term: Term? {
        resolver.term(for: termCode, in: catalog)
    }

    private var termName: String { term?.name ?? "this term" }

    private var isLoadingDetails: Bool {
        guard let section else { return false }
        return catalog.loadingDetails.contains(section.courseKey) || !detailsAttemptFinished
    }

    var body: some View {
        content
            .navigationTitle(section.map { "\($0.courseKey.description) · \($0.sectionNumber)" } ?? "CRN \(crn)")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(termName)
            .task(id: TaskID(termCode: termCode, crn: crn)) {
                await prepare()
            }
            .courseReloadsIndex(resolver, termCode: termCode)
            .sensoryFeedback(.error, trigger: refreshFailed) { _, failed in failed }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let index, let section {
            SectionDetailContent(
                section: section,
                course: index.course(section.courseKey),
                index: index,
                termCode: termCode,
                isLoadingDetails: isLoadingDetails,
                refreshFailed: refreshFailed,
                onRetryDetails: { Task { await loadDetails(for: section.courseKey) } },
                onRefresh: { await pullToRefresh(key: section.courseKey) }
            )
        } else if index == nil, resolver.isLoading(termCode: termCode, in: catalog) {
            ProgressView("Loading section…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if index == nil {
            ContentUnavailableView {
                Label("Catalog unavailable", systemImage: "icloud.slash")
            } description: {
                Text("The catalog for \(termName) isn't on this device yet.")
            } actions: {
                Button("Try Again") {
                    Task { await resolver.resolve(termCode: termCode, catalog: catalog) }
                }
                .buttonStyle(.bordered)
            }
        } else {
            ContentUnavailableView {
                Label("Section not found", systemImage: "magnifyingglass")
            } description: {
                Text("CRN \(crn) isn't in the \(termName) catalog.")
            } actions: {
                Button("Search for \(crn)") {
                    router.search(for: crn)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: Loading

    private func prepare() async {
        await resolver.resolve(termCode: termCode, catalog: catalog)
        guard let key = section?.courseKey else { return }
        await loadDetails(for: key)
        // The screen may have been left while details were downloading.
        guard !Task.isCancelled else { return }
        if shouldAutoRefresh(key) {
            await refreshSeats(for: key)
        }
    }

    private func shouldAutoRefresh(_ key: CourseKey) -> Bool {
        guard userData.preferences.autoRefreshSeats, term?.isViewOnly != true else { return false }
        if let last = catalog.liveRefreshedAt[key] {
            return Date.now.timeIntervalSince(last) > Self.autoRefreshInterval
        }
        return true
    }

    /// Network work runs in an unstructured task so leaving the screen does not cancel it.
    private func loadDetails(for key: CourseKey) async {
        let catalog = self.catalog
        let termCode = self.termCode
        await Task { await catalog.ensureDetails(for: key, termCode: termCode) }.value
        detailsAttemptFinished = true
    }

    private func refreshSeats(for key: CourseKey) async {
        guard !catalog.refreshingCourses.contains(key) else { return }
        let catalog = self.catalog
        let termCode = self.termCode
        let before = catalog.liveRefreshedAt[key]
        refreshFailed = false
        await Task { await catalog.refresh(course: key, termCode: termCode) }.value
        // A successful refresh always stamps a new time; no stamp means it failed.
        refreshFailed = catalog.liveRefreshedAt[key] == before
    }

    private func pullToRefresh(key: CourseKey) async {
        if section?.instructors == nil {
            await loadDetails(for: key)
        }
        await refreshSeats(for: key)
    }
}
