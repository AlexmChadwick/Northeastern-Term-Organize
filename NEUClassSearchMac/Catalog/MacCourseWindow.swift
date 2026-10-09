//
//  MacCourseWindow.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The course window, modeled on SearchNEU's /catalog/[term]/[course]
//  (https://github.com/sandboxnu/searchneu, AGPL-3.0): description, requirements and a live table of
//  sections, rebuilt natively.
//

import SwiftUI

/// A course in its own window: opened with
/// `openWindow(id: MacWindowID.course, value: CourseWindowValue(...))` from anywhere.
///
/// Opening it records the view in the recents, loads what the catalog only has as a stub (description,
/// requisites, instructors) from Banner, and refreshes the seats when they are stale, like the iPhone
/// and iPad page. As the preview pane of a table of courses (`presentation: .pane`) it is the same page
/// without any of that: no title, no toolbar, nothing recorded, and seats only refresh on request.
struct MacCourseWindow: View {
    var value: CourseWindowValue
    var presentation: MacCoursePresentation = .window

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

    private var termCode: String { value.termCode }
    private var key: CourseKey { value.key }
    private var index: CatalogIndex? { resolver.index(for: termCode, in: catalog) }
    private var term: Term? { resolver.term(for: termCode, in: catalog) }
    private var termName: String { term?.name ?? "this term" }

    private var isLoadingDetails: Bool {
        catalog.loadingDetails.contains(key) || !detailsAttemptFinished
    }

    /// The window's title: the course code and title.
    private var title: String {
        if let course = index?.course(key) { return "\(key.description) – \(course.title)" }
        return key.description
    }

    var body: some View {
        content
            .macCatalogApplying(if: presentation == .window) { view in
                // A window can shrink to this; the sections table scrolls sideways below its columns.
                view
                    .frame(minWidth: 640, minHeight: 520)
                    .navigationTitle(title)
                    .navigationSubtitle(termName)
            }
            .task(id: TaskID(termCode: termCode, key: key)) {
                await prepare()
            }
            .courseReloadsIndex(resolver, termCode: termCode)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let index, let course = index.course(key) {
            MacCourseDetail(
                course: course,
                index: index,
                termCode: termCode,
                detailsStatus: detailsStatus(for: course),
                isLoadingDetails: isLoadingDetails,
                refreshFailed: refreshFailed,
                onRetryDetails: { Task { await loadDetails() } },
                onRefresh: { await refreshAll(course: course) },
                presentation: presentation
            )
        } else if let index {
            // The term's schedule doesn't list the course (not offered this term, or retired): read
            // what Banner's course catalog says about it.
            MacCourseCatalogEntry(key: key, termCode: termCode, termName: termName, index: index, presentation: presentation)
        } else if resolver.isLoading(termCode: termCode, in: catalog) {
            ProgressView("Loading course…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Catalog Unavailable", systemImage: "icloud.slash")
            } description: {
                Text("The catalog for \(termName) isn't on this Mac yet.")
            } actions: {
                Button("Try Again") {
                    Task { await resolver.resolve(termCode: termCode, catalog: catalog) }
                }
            }
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
        if !didRecordView, presentation == .window {
            didRecordView = true
            userData.recordView(key, termCode: termCode)
        }
        await loadDetails()
        // The window may have been closed while details were downloading.
        guard !Task.isCancelled else { return }
        // A preview pane follows the selection from row to row: it doesn't ask Banner for each one.
        if presentation == .window, shouldAutoRefresh {
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

    /// Network work runs in an unstructured task so closing the window does not cancel it.
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

    /// The refresh button: also loads details that are still missing.
    private func refreshAll(course: Course) async {
        if !course.detailsLoaded || sectionsMissingInstructors {
            await loadDetails()
        }
        await refreshSeats()
    }

    private var sectionsMissingInstructors: Bool {
        index?.sections(for: key).contains { $0.instructors == nil } ?? false
    }
}

// MARK: - A course the term doesn't list

/// The window of a course the loaded term's catalog doesn't list: one that isn't offered this term,
/// or that has been retired (CS 2510 after the renumbering).
///
/// A term's schedule only lists the courses that have sections, so there is nothing to show about
/// seats or meetings. Banner's course catalog still knows the course, though, so the window reads it
/// through `CourseInfoStore`: title, credits, prerequisites and corequisites, drawn like any course's,
/// and a note saying why it isn't in the term.
struct MacCourseCatalogEntry: View {
    var key: CourseKey
    var termCode: String
    /// The loaded term, e.g. `Fall 2026`.
    var termName: String
    var index: CatalogIndex
    var presentation: MacCoursePresentation = .window

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    /// The term's courses that mention this one in their prerequisites ("Leads to"). Nil until worked
    /// out, which is before the lookup starts, so the window never shows an empty list that then fills in.
    @State private var dependents: [CourseKey]?
    @State private var isRetrying = false
    @State private var stillFailing = false
    /// The page's width, measured after it is laid out.
    @State private var width: CGFloat = 0

    private struct LoadID: Hashable {
        var key: CourseKey
        var indexVersion: Int
    }

    var body: some View {
        content
            .task(id: LoadID(key: key, indexVersion: catalog.indexVersion)) {
                await load()
            }
            .macCatalogToolbar {
                if presentation == .window {
                    ToolbarItem(placement: .primaryAction) {
                        if let url = BannerClient.catalogPageURL(term: termCode, course: key) {
                            Button("View on Northeastern Website", systemImage: "safari") { openURL(url) }
                                .help("Open this course's entry in Northeastern's course catalog")
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch CourseInfoStore.shared.state(for: key) {
        case .found(let info):
            if let dependents {
                details(info, dependents: dependents)
            } else {
                checking
            }
        case .unknown, .loading:
            checking
        case .notFound:
            notListed
        case .failed:
            unreachable
        }
    }

    private var checking: some View {
        ProgressView("Checking Banner's catalog…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Details

    private func details(_ info: CourseInfo, dependents: [CourseKey]) -> some View {
        let note = availability(of: info)
        let named = (info.prerequisites?.referencedCourses ?? []) + (info.corequisites?.referencedCourses ?? [])
        let compact = width > 0 && width < 560
        return ScrollView {
            VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                header(info, note: note, compact: compact)
                MacCourseRequirements(
                    key: key,
                    prereqs: info.prerequisites,
                    coreqs: info.corequisites,
                    postreqs: dependents,
                    index: index,
                    termCode: termCode,
                    status: .ready,
                    onRetry: {}
                )
            }
            .padding(compact ? 16 : 20)
            .frame(maxWidth: 820, alignment: .leading)
            // Centered in a wide window, where there is nothing to put beside it; at the left of a pane.
            .frame(maxWidth: .infinity, alignment: presentation == .window ? .center : .leading)
        }
        .environment(\.macCourseCompact, compact)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .courseLoadsEquivalents(for: [key] + named)
    }

    private func header(_ info: CourseInfo, note: (text: String, symbol: String), compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key.description)
                    .font(compact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                if let credits = info.creditsLabel {
                    Text(credits)
                        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, compact ? 2 : 3)
                        .background(.quaternary.opacity(0.6), in: .capsule)
                }
            }
            if !info.title.isEmpty {
                Text(info.title)
                    .font(compact ? .title3.weight(.semibold) : .title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
            }
            Label(note.text, systemImage: note.symbol)
                .foregroundStyle(.secondary)
            if let standing = userData.courseDegreePlanStanding(for: key) {
                MacCourseDegreePlanTag(standing: standing)
                    .padding(.top, 2)
            }
            // A pane has no toolbar to carry the link.
            if presentation == .pane, let url = BannerClient.catalogPageURL(term: termCode, course: key) {
                Button("View on Northeastern Website", systemImage: "safari") { openURL(url) }
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Why there are no sections: the course has been retired (the catalog that lists it is an older
    /// term's), or it just isn't taught in the loaded term.
    private func availability(of info: CourseInfo) -> (text: String, symbol: String) {
        if info.isRetired == true {
            return ("No longer offered; last listed \(OfferingHistory.label(ofTerm: info.sourceTerm))", "archivebox")
        }
        return ("Not offered in \(termName)", "calendar.badge.minus")
    }

    // MARK: Other states

    /// No catalog Banner was asked about lists the course.
    private var notListed: some View {
        ContentUnavailableView {
            Label("\(key.description) Isn't Offered in \(termName)", systemImage: "magnifyingglass")
        } description: {
            Text("Banner's recent course catalogs don't list it either, so the course code may have changed.")
        } actions: {
            Button("Search for \(key.description)") {
                MacCatalogNavigation.search(text: key.description, navigator: navigator, openWindow: openWindow)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Banner didn't answer. Quiet: the course may well be fine, only unchecked.
    private var unreachable: some View {
        ContentUnavailableView {
            Label("\(key.description) Isn't Offered in \(termName)", systemImage: "magnifyingglass")
        } description: {
            Text(stillFailing
                 ? "Banner's course catalog still isn't answering. Try again in a minute."
                 : "Banner's course catalog didn't answer, so the course's details couldn't be checked.")
        } actions: {
            Button("Try Again") {
                Task { await retry() }
            }
            .disabled(isRetrying)
        }
    }

    // MARK: Loading

    /// Reads the catalog entry. The lookup runs in an unstructured task so closing the window doesn't
    /// cancel it: the answer is cached for next time.
    private func load() async {
        dependents = Self.courses(mentioning: key, in: index)
        let store = CourseInfoStore.shared
        let key = self.key
        let indexes = catalog.loadedIndexes
        await Task { await store.load([key], indexes: indexes) }.value
    }

    private func retry() async {
        isRetrying = true
        stillFailing = false
        let store = CourseInfoStore.shared
        let key = self.key
        let indexes = catalog.loadedIndexes
        await Task { await store.load([key], indexes: indexes) }.value
        isRetrying = false
        // After a failure the store waits a minute before asking Banner again, so an immediate retry
        // can change nothing; say so rather than look dead.
        if case .failed = store.state(for: key) {
            stillFailing = true
        }
    }

    /// The courses of the term whose prerequisites mention `key`: what `Course.postreqs` is for a
    /// course the term lists.
    private static func courses(mentioning key: CourseKey, in index: CatalogIndex) -> [CourseKey] {
        index.courses
            .filter { $0.prereqs?.referencedCourses.contains(key) == true }
            .map(\.key)
            .sorted()
    }
}
