//
//  CourseDetailView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The course page, modeled on SearchNEU's /catalog/[term]/[course]
//  (https://github.com/sandboxnu/searchneu, AGPL-3.0): description,
//  requirements and a live table of sections, rebuilt natively.
//

import SwiftUI

struct CourseDetailView: View {
    var termCode: String
    var key: CourseKey

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData

    @State private var resolver = CourseIndexResolver()
    @State private var didRecordView = false
    @State private var detailsAttemptFinished = false
    @State private var refreshFailed = false

    /// Seat data fresher than this is not refreshed again automatically.
    private static let autoRefreshInterval: TimeInterval = 5 * 60

    private struct TaskID: Hashable {
        var termCode: String
        var key: CourseKey
    }

    private var index: CatalogIndex? {
        resolver.index(for: termCode, in: catalog)
    }

    private var term: Term? {
        resolver.term(for: termCode, in: catalog)
    }

    private var termName: String { term?.name ?? "this term" }

    private var isLoadingDetails: Bool {
        catalog.loadingDetails.contains(key) || !detailsAttemptFinished
    }

    var body: some View {
        content
            .navigationTitle(key.description)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(termName)
            .task(id: TaskID(termCode: termCode, key: key)) {
                await prepare()
            }
            .courseReloadsIndex(resolver, termCode: termCode)
            .sensoryFeedback(.error, trigger: refreshFailed) { _, failed in failed }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let index, let course = index.course(key) {
            CourseDetailContent(
                course: course,
                index: index,
                termCode: termCode,
                detailsStatus: detailsStatus(for: course),
                isLoadingDetails: isLoadingDetails,
                refreshFailed: refreshFailed,
                onRetryDetails: { Task { await loadDetails() } },
                onRefresh: { await pullToRefresh(course: course) }
            )
        } else if let index {
            // The term's schedule doesn't list the course (not offered this term, or retired):
            // read what Banner's course catalog says about it.
            CourseCatalogEntryView(key: key, termCode: termCode, termName: termName, index: index)
        } else if resolver.isLoading(termCode: termCode, in: catalog) {
            ProgressView("Loading course…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            catalogUnavailable
        }
    }

    private var catalogUnavailable: some View {
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
    }

    private func detailsStatus(for course: Course) -> CourseDetailsStatus {
        if course.detailsLoaded { return .ready }
        return isLoadingDetails ? .loading : .unavailable
    }

    // MARK: Loading

    /// Records the visit, fetches missing details, then refreshes seats when they are stale.
    private func prepare() async {
        await resolver.resolve(termCode: termCode, catalog: catalog)
        guard let index, index.course(key) != nil else { return }
        if !didRecordView {
            didRecordView = true
            userData.recordView(key, termCode: termCode)
        }
        await loadDetails()
        // The screen may have been left while details were downloading.
        guard !Task.isCancelled else { return }
        if shouldAutoRefresh {
            await refreshSeats()
        }
    }

    private var shouldAutoRefresh: Bool {
        guard userData.preferences.autoRefreshSeats, term?.isViewOnly != true else { return false }
        if let last = catalog.liveRefreshedAt[key] {
            return Date.now.timeIntervalSince(last) > Self.autoRefreshInterval
        }
        return true
    }

    /// Network work runs in an unstructured task so leaving the screen does not cancel it.
    private func loadDetails() async {
        let catalog = self.catalog
        let key = self.key
        let termCode = self.termCode
        await Task { await catalog.ensureDetails(for: key, termCode: termCode) }.value
        detailsAttemptFinished = true
    }

    private func refreshSeats() async {
        guard !catalog.refreshingCourses.contains(key) else { return }
        let catalog = self.catalog
        let key = self.key
        let termCode = self.termCode
        let before = catalog.liveRefreshedAt[key]
        refreshFailed = false
        await Task { await catalog.refresh(course: key, termCode: termCode) }.value
        // A successful refresh always stamps a new time; no stamp means it failed.
        refreshFailed = catalog.liveRefreshedAt[key] == before
    }

    private func pullToRefresh(course: Course) async {
        if !course.detailsLoaded || sectionsMissingInstructors {
            await loadDetails()
        }
        await refreshSeats()
    }

    private var sectionsMissingInstructors: Bool {
        index?.sections(for: key).contains { $0.instructors == nil } ?? false
    }
}
