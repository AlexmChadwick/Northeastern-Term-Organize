//
//  MacCourseDetail.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The course window once the course has been found, modeled on SearchNEU's /catalog/[term]/[course]
//  (https://github.com/sandboxnu/searchneu, AGPL-3.0) as the iPhone and iPad page is: description,
//  requirements and a live table of sections, laid out for a Mac window.
//

import SwiftUI

/// How a course page is shown: the course window (with its toolbar), or the preview pane beside a
/// table of courses (with its own row of actions, and no toolbar of its own to add to the window's).
enum MacCoursePresentation: Sendable {
    case window, pane
}

extension EnvironmentValues {
    /// Whether a course page has little room (a narrow preview pane or window): smaller type, tighter
    /// spacing and stacked rows.
    @Entry var macCourseCompact = false
}

extension View {
    /// Applies `transform` only while `condition` holds.
    @ViewBuilder
    func macCatalogApplying<Result: View>(if condition: Bool, _ transform: (Self) -> Result) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// The content of a course page. Wide, it has the overview (header, description, requirements) on the
/// left and the sections table on the right, with a divider to drag; narrower, the overview is above
/// the table. In the course window the actions are toolbar items; in a preview pane they are a row
/// above the overview.
struct MacCourseDetail: View {
    var course: Course
    var index: CatalogIndex
    var termCode: String
    var detailsStatus: CourseDetailsStatus
    /// Whether lazily loaded details (instructors, topic descriptions) may still arrive.
    var isLoadingDetails: Bool
    var refreshFailed: Bool
    var onRetryDetails: () -> Void
    var onRefresh: () async -> Void
    var presentation: MacCoursePresentation = .window

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.catalogToast) private var toast
    @Environment(\.macCourseCompact) private var compact

    @State private var selection: Set<String> = []
    @State private var newSchedule: MacCatalogNewScheduleRequest?
    /// The page's width, measured after it is laid out (nothing is measured on the first pass).
    @State private var width: CGFloat = 0

    /// The width from which the overview and the sections sit side by side.
    private static let twoColumnWidth: CGFloat = 980
    /// Below this, the page uses its compact type and stacked rows.
    private static let compactWidth: CGFloat = 560

    private var key: CourseKey { course.key }
    private var sections: [CourseSection] { index.sections(for: key) }
    private var isSaved: Bool { userData.isSaved(key, termCode: termCode) }
    private var isRefreshing: Bool { catalog.refreshingCourses.contains(key) }
    private var isWindow: Bool { presentation == .window }

    /// When the seat counts on screen were last refreshed: live this session, or when the catalog was built.
    private var lastUpdated: Date? {
        catalog.liveRefreshedAt[key] ?? index.catalog.sectionsUpdatedAt
    }

    private var selectedSections: [CourseSection] {
        sections.filter { selection.contains($0.crn) }
    }

    /// This course and the ones its requirements name: whether the user's completed courses count for
    /// them depends on equivalences the course store has to look up.
    private var namedCourses: [CourseKey] {
        [key] + (course.prereqs?.referencedCourses ?? []) + (course.coreqs?.referencedCourses ?? [])
    }

    var body: some View {
        layout(wide: width >= Self.twoColumnWidth)
            .environment(\.macCourseCompact, width > 0 && width < Self.compactWidth)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .macCatalogToolbar { toolbarContent }
        .courseLoadsEquivalents(for: namedCourses)
        .catalogNewScheduleAlert($newSchedule)
        .catalogToastHost()
        .macCatalogApplying(if: isWindow) { view in
            view.focusedSceneValue(\.macReload, MacMenuAction(title: "Refresh Seats") { Task { await onRefresh() } })
        }
        .onChange(of: sections.map(\.crn)) { _, crns in
            // A live refresh can drop sections; never keep one selected that is gone.
            let present = Set(crns)
            if !selection.isSubset(of: present) { selection = selection.intersection(present) }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func layout(wide: Bool) -> some View {
        if wide {
            MacSplitPane(
                storageKey: "mac.split.catalog.course",
                paneEdge: .trailing,
                defaultShare: 0.58,
                paneMinWidth: 520,
                primaryMinWidth: 380,
                maxShare: 0.75
            ) {
                ScrollView {
                    overview
                        .padding(20)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } pane: {
                if sections.isEmpty {
                    noSections
                } else {
                    sectionsPane(showsWeek: true)
                }
            }
        } else if sections.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    overview
                    noSections
                }
                .padding(compact ? 16 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            MacCatalogStackedSplit(storageKey: "mac.split.catalog.courseStacked", defaultBottomShare: 0.44, topMinHeight: 200, bottomMinHeight: 230) {
                ScrollView {
                    overview
                        .padding(compact ? 16 : 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } bottom: {
                sectionsPane(showsWeek: false)
            }
        }
    }

    private func sectionsPane(showsWeek: Bool) -> some View {
        MacCourseSectionsPane(
            course: course,
            sections: sections,
            termCode: termCode,
            isLoadingDetails: isLoadingDetails,
            lastUpdated: lastUpdated,
            isRefreshing: isRefreshing,
            refreshFailed: refreshFailed,
            showsWeek: showsWeek,
            onRefresh: { Task { await onRefresh() } },
            selection: $selection,
            newSchedule: $newSchedule
        )
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 24) {
            if presentation == .pane {
                paneActions
            }
            MacCourseHeader(course: course, term: index.term, hasHonorsSections: index.stats(for: key).hasHonors)
            MacCourseDescription(course: course, status: detailsStatus, onRetry: onRetryDetails)
            MacCourseRequirements(
                key: key,
                prereqs: course.prereqs,
                coreqs: course.coreqs,
                postreqs: course.postreqs,
                index: index,
                termCode: termCode,
                status: detailsStatus,
                onRetry: onRetryDetails
            )
        }
    }

    private var noSections: some View {
        ContentUnavailableView {
            Label("No Sections This Term", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("Northeastern hasn't published any sections of \(course.code) for \(index.term.name).")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    /// What "Add to Schedule" adds: the selected section with its course, or just the course.
    private var scheduleAdditions: [MacCatalogScheduleAddition] {
        if selectedSections.count == 1, let section = selectedSections.first {
            return [MacCatalogScheduleAddition(key: key, crn: section.crn)]
        }
        return [MacCatalogScheduleAddition(key: key, crn: nil)]
    }

    private var allSelectedWatched: Bool {
        !selectedSections.isEmpty && selectedSections.allSatisfy { userData.isWatching(crn: $0.crn, termCode: termCode) }
    }

    /// The instructors of the selected sections, else of every section.
    private var instructors: [Instructor] {
        let pool = selectedSections.isEmpty ? sections : selectedSections
        var seen = Set<String>()
        return pool.flatMap { $0.courseSortedInstructors ?? [] }.filter { seen.insert($0.name).inserted }
    }

    private var addToScheduleHelp: String {
        selectedSections.count == 1
            ? "Add \(key.description) with section \(selectedSections[0].sectionNumber) to a schedule"
            : "Add \(key.description) to a schedule"
    }

    private var watchHelp: String {
        selectedSections.isEmpty
            ? "Select a section to watch it for open seats"
            : (allSelectedWatched ? "Stop watching the selected sections" : "Watch the selected sections for open seats")
    }

    private func openProfessor(_ instructor: Instructor) {
        openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: instructor.name))
    }

    private var shareTitle: String { "\(course.code) – \(course.title) (\(index.term.name))" }

    /// The window's toolbar: save, add to a schedule, watch, instructors | refresh, share, more.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isWindow {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark") {
                    userData.toggleSaved(key, termCode: termCode)
                }
                .keyboardShortcut("d", modifiers: .command)
                .help(isSaved ? "Remove \(key.description) from your saved courses (⌘D)" : "Save \(key.description) (⌘D)")

                MacCatalogAddToScheduleMenu(termCode: termCode, additions: scheduleAdditions, newSchedule: $newSchedule) {
                    Label("Add to Schedule", systemImage: "calendar.badge.plus")
                }
                .macCatalogStores(MacCatalogStores(catalog: catalog, userData: userData, navigator: navigator))
                .help(addToScheduleHelp)

                Button(allSelectedWatched ? "Stop Watching" : "Watch", systemImage: allSelectedWatched ? "bell.fill" : "bell") {
                    toggleWatch()
                }
                .disabled(selectedSections.isEmpty)
                .help(watchHelp)

                Menu {
                    ForEach(instructors, id: \.name) { instructor in
                        Button(instructor.displayName) { openProfessor(instructor) }
                    }
                } label: {
                    Label("Open Professor", systemImage: "person")
                }
                .disabled(instructors.isEmpty)
                .help("Open an instructor's window")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Refresh Seats", systemImage: "arrow.clockwise") {
                    Task { await onRefresh() }
                }
                .disabled(isRefreshing)
                .help("Download the latest seat counts for \(key.description)")

                if let link = CourseLinks.course(termCode: termCode, key: key) {
                    ShareLink(item: link, subject: Text(shareTitle), message: Text(shareTitle)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share a link to this course")
                }

                Menu {
                    moreItems
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
    }

    /// The row above the overview in a preview pane: what the window's toolbar would offer.
    private var paneActions: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 8) {
            Button {
                openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
            } label: {
                Label("Open", systemImage: "macwindow.badge.plus")
            }
            .help("Open \(key.description) in its own window")

            Button {
                userData.toggleSaved(key, termCode: termCode)
            } label: {
                Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
            }
            .help(isSaved ? "Remove \(key.description) from your saved courses" : "Save \(key.description)")

            MacCatalogAddToScheduleMenu(termCode: termCode, additions: scheduleAdditions, newSchedule: $newSchedule) {
                Label("Add to Schedule", systemImage: "calendar.badge.plus")
            }
            .menuStyle(.button)
            .fixedSize()
            .help(addToScheduleHelp)

            Menu {
                Button(allSelectedWatched ? "Stop Watching Selected Sections" : "Watch Selected Sections", systemImage: allSelectedWatched ? "bell.fill" : "bell") {
                    toggleWatch()
                }
                .disabled(selectedSections.isEmpty)
                Menu("Open Professor", systemImage: "person") {
                    ForEach(instructors, id: \.name) { instructor in
                        Button(instructor.displayName) { openProfessor(instructor) }
                    }
                }
                .disabled(instructors.isEmpty)
                Button("Refresh Seats", systemImage: "arrow.clockwise") {
                    Task { await onRefresh() }
                }
                .disabled(isRefreshing)
                if let link = CourseLinks.course(termCode: termCode, key: key) {
                    ShareLink(item: link, subject: Text(shareTitle), message: Text(shareTitle)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                moreItems
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("More actions")
        }
        .controlSize(.small)
    }

    /// Copying, going elsewhere in the app, and the course's page on Northeastern's site.
    @ViewBuilder
    private var moreItems: some View {
        Button("Copy Course Code", systemImage: "doc.on.doc") { MacCatalogClipboard.copy(course.code) }
        if let link = CourseLinks.course(termCode: termCode, key: key) {
            Button("Copy Link", systemImage: "link") { MacCatalogClipboard.copy(link.absoluteString) }
        }
        if !selectedSections.isEmpty {
            Button(selectedSections.count == 1 ? "Copy CRN" : "Copy CRNs", systemImage: "number") {
                MacCatalogClipboard.copy(selectedSections.map(\.crn).joined(separator: "\n"))
            }
        }
        Divider()
        Button("Show \(key.subject) Courses", systemImage: "square.grid.2x2") {
            MacCatalogNavigation.showSubject(key.subject, navigator: navigator, openWindow: openWindow)
        }
        Button("Search Similar Courses", systemImage: "magnifyingglass") {
            var filters = SearchFilters()
            filters.subjects = [key.subject]
            MacCatalogNavigation.search(filters: filters, navigator: navigator, openWindow: openWindow)
        }
        if let url = BannerClient.catalogPageURL(term: termCode, course: key) {
            Divider()
            Button("View on Northeastern Website", systemImage: "safari") { openURL(url) }
        }
    }

    private func toggleWatch() {
        let shouldWatch = !allSelectedWatched
        for section in selectedSections where userData.isWatching(crn: section.crn, termCode: termCode) != shouldWatch {
            userData.toggleWatch(section, courseTitle: course.title, termCode: termCode)
        }
        if shouldWatch {
            let what = selectedSections.count == 1 ? "section \(selectedSections[0].sectionNumber)" : "\(selectedSections.count) sections"
            let note = MacCatalogWatching.announcement(of: what)
            toast(note.message, systemImage: note.symbol, tint: note.tint, actionTitle: "Show Watchlist") {
                MacCatalogNavigation.showWatchlist(navigator: navigator, openWindow: openWindow)
            }
        }
    }
}

// MARK: - Header

/// The top of the window: code, credits, title, college and tags.
struct MacCourseHeader: View {
    var course: Course
    var term: Term
    var hasHonorsSections: Bool

    @Environment(UserDataStore.self) private var userData
    @Environment(\.macCourseCompact) private var compact

    /// `Khoury College of Computer Sciences · Computer Science`
    private var affiliation: String? {
        let parts = [course.college, course.department]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(course.code)
                    .font(compact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                Text(course.creditsLabel)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, compact ? 8 : 10)
                    .padding(.vertical, compact ? 2 : 3)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
            Text(course.title)
                .font(compact ? .title3.weight(.semibold) : .title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if let affiliation {
                Text(affiliation)
                    .foregroundStyle(.secondary)
            }
            chips
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var chips: some View {
        let nupaths = course.nupaths
        let standing = userData.courseDegreePlanStanding(for: course.key)
        let hasTags = hasHonorsSections || course.specialTopics || term.isViewOnly || standing != nil
        if !nupaths.isEmpty || hasTags {
            CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(nupaths) { nupath in
                    NUPathChip(nupath: nupath, showsName: true)
                }
                if hasHonorsSections {
                    TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
                }
                if course.specialTopics {
                    TagLabel(text: "Special topics", systemImage: "sparkles", tint: .orange)
                }
                if term.isViewOnly {
                    TagLabel(text: "View only term", systemImage: "lock.fill")
                }
                if let standing {
                    MacCourseDegreePlanTag(standing: standing)
                }
            }
        }
    }
}

/// A header tag saying what the primary degree plan does with a course: "Completed", or "Planned ·
/// Spring 2027". Clicking it shows the plan in the main window.
struct MacCourseDegreePlanTag: View {
    var standing: CourseDegreePlanStanding

    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    private var tint: Color {
        switch standing.kind {
        case .completed: .green
        case .planned: .blue
        }
    }

    var body: some View {
        Button {
            MacCatalogNavigation.showDegreePlan(standing.planID, navigator: navigator, openWindow: openWindow)
        } label: {
            // Same metrics as `TagLabel`, plus a chevron because this tag is a link.
            HStack(spacing: 3) {
                Image(systemName: standing.symbol)
                    .imageScale(.small)
                Text(standing.text)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .opacity(0.7)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help("Show the degree plan in the main window")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(standing.spokenText)
        .accessibilityHint("Shows the degree plan")
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Description

/// The course description, with loading and empty states.
struct MacCourseDescription: View {
    var course: Course
    var status: CourseDetailsStatus
    var onRetry: () -> Void

    @Environment(\.macCourseCompact) private var compact

    private var text: String {
        course.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description")
                .font(compact ? .headline : .title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading where text.isEmpty:
            Text("Loading the course description from Northeastern. This only takes a moment while the details download for the first time.")
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading")
        case .unavailable where text.isEmpty:
            HStack(spacing: 10) {
                Label("The description couldn't be loaded.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .controlSize(.small)
            }
        default:
            if text.isEmpty {
                Text("No description available.")
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
