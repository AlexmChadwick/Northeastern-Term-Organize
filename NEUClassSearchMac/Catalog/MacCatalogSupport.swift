//
//  MacCatalogSupport.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Small pieces the catalog screens share: the pasteboard, reaching the main window from a course
//  or professor window, the filters and selections the areas remember while the sidebar moves
//  between them, and a few labels.
//

import AppKit
import Observation
import SwiftUI

/// Copying to the Mac's pasteboard.
enum MacCatalogClipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The stores a toolbar's views need, handed to them directly. A toolbar's views are hosted apart from
/// the window's content, so they don't always find the objects in the environment.
struct MacCatalogStores {
    var catalog: CatalogStore
    var userData: UserDataStore
    var navigator: MacNavigator
}

extension View {
    /// Puts the stores in this view's environment: for views drawn in a toolbar.
    func macCatalogStores(_ stores: MacCatalogStores) -> some View {
        environment(stores.catalog)
            .environment(stores.userData)
            .environment(stores.navigator)
    }
}

extension View {
    /// Adds toolbar items to a window's content. (Not in a snapshot that draws the content on its own,
    /// outside any window: there is no toolbar to host the items, and building them there fails.)
    @ViewBuilder
    func macCatalogToolbar<Content: ToolbarContent>(@ToolbarContentBuilder _ content: () -> Content) -> some View {
        #if DEBUG
        if MacCatalogSnapshotArguments.drawsWithoutToolbar {
            self
        } else {
            toolbar(content: content)
        }
        #else
        toolbar(content: content)
        #endif
    }
}

/// What the catalog areas keep while the sidebar moves between them. The detail view of a sidebar
/// item is rebuilt on every switch, so filters and selections that should survive one live here.
@MainActor
@Observable
final class MacCatalogState {
    static let shared = MacCatalogState()

    enum SubjectsMode: String, CaseIterable, Identifiable {
        case subjects = "Subjects"
        case nupath = "NUpath"
        var id: String { rawValue }
    }

    // MARK: Layout

    /// The width of the main window's detail area the last time a screen measured it, so a screen that
    /// is shown again starts from it instead of from nothing. (Not observed: nothing redraws for it.)
    @ObservationIgnored var detailWidth: CGFloat = 0

    // MARK: Search

    /// Bumped by `focusSearch(navigator:)`; the search view focuses the toolbar's field when it sees a
    /// request it hasn't handled.
    var searchFocusRequest = 0
    var handledSearchFocusRequest = 0

    /// Goes to Search and puts the cursor in the toolbar's search field (Find from any area).
    func focusSearch(navigator: MacNavigator) {
        searchFocusRequest += 1
        navigator.selection = .search
    }

    /// The filters beside the search text (which lives in `MacNavigator.searchText`).
    var filters = SearchFilters()
    /// How the results table is sorted; empty is the search's own order ("Best Match").
    var searchSort: [KeyPathComparator<MacCatalogCourseRow>] = []
    /// The preferred campus is applied as the starting filter once per launch, and only to a user who
    /// has not brought a search or filters of their own.
    var didApplyPreferredCampus = false
    var userBroughtOwnSearch = false

    // MARK: Subjects and NUpath

    var subjectsMode = SubjectsMode.subjects
    var selectedSubject: String?
    var selectedNUPath: NUPath?
    var subjectLevel: Int?
    var subjectOpenOnly = false
    var nupathSubject: String?
    var courseListSort: [KeyPathComparator<MacCatalogCourseRow>] = [KeyPathComparator(\.key)]

    // MARK: Saved

    var savedSort: [KeyPathComparator<MacCatalogCourseRow>] = [KeyPathComparator(\.savedSortDate, order: .reverse)]

    private init() {}
}

/// Driving the main window from anywhere (a course window's "Search Similar Courses", a
/// professor's courses…).
@MainActor
enum MacCatalogNavigation {
    /// Searches the catalog in the main window.
    static func search(
        text: String = "",
        filters: SearchFilters = SearchFilters(),
        navigator: MacNavigator,
        openWindow: OpenWindowAction
    ) {
        let state = MacCatalogState.shared
        state.userBroughtOwnSearch = true
        state.filters = filters
        navigator.searchText = text
        navigator.selection = .search
        MacShellWindows.showMain(openWindow: openWindow)
    }

    /// Shows a subject's courses in the main window.
    static func showSubject(_ code: String, navigator: MacNavigator, openWindow: OpenWindowAction) {
        let state = MacCatalogState.shared
        state.subjectsMode = .subjects
        state.selectedSubject = code
        navigator.selection = .subjects
        MacShellWindows.showMain(openWindow: openWindow)
    }

    /// Shows the watchlist in the main window.
    static func showWatchlist(navigator: MacNavigator, openWindow: OpenWindowAction) {
        navigator.selection = .watchlist
        MacShellWindows.showMain(openWindow: openWindow)
    }

    /// Shows a schedule in the main window.
    static func showSchedule(_ id: UUID, navigator: MacNavigator, openWindow: OpenWindowAction) {
        navigator.selection = .schedule(id)
        MacShellWindows.showMain(openWindow: openWindow)
    }

    /// Shows a degree plan in the main window.
    static func showDegreePlan(_ id: UUID, navigator: MacNavigator, openWindow: OpenWindowAction) {
        navigator.selection = .degreePlan(id)
        MacShellWindows.showMain(openWindow: openWindow)
    }
}

// MARK: - Labels

/// "Updated 5 minutes ago", kept current by a loop rather than a `TimelineView`.
struct MacCatalogRelativeDateText: View {
    var date: Date
    var prefix = "Updated"

    @State private var now = Date.now

    var body: some View {
        Text("\(prefix) \(CourseFormat.relative(date, to: now))")
            .task(id: date) {
                now = .now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    now = .now
                }
            }
    }
}

/// A dot and a short phrase for how many sections of a course have open seats.
struct MacCourseAvailabilityLabel: View {
    var stats: CourseStats

    private var color: Color {
        if stats.sectionCount == 0 { return .secondary }
        if stats.openSectionCount == 0 { return .red }
        return stats.seatsRemaining <= 5 ? .orange : .green
    }

    private var text: String {
        if stats.sectionCount == 0 { return "No sections" }
        if stats.openSectionCount == 0 { return stats.sectionCount == 1 ? "Full" : "All \(stats.sectionCount) full" }
        return "\(stats.openSectionCount) of \(stats.sectionCount) open"
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A button style for tiles and rows that aren't in a list: a quiet background on hover, a darker
/// one while pressed.
struct MacCatalogTileButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        MacTileButtonBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct MacTileButtonBody: View {
        var configuration: ButtonStyleConfiguration
        var cornerRadius: CGFloat
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .contentShape(.rect(cornerRadius: cornerRadius))
                .background(
                    configuration.isPressed
                        ? Color.primary.opacity(0.12)
                        : (isHovering ? Color.primary.opacity(0.06) : Color.clear),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .onHover { isHovering = $0 }
        }
    }
}

/// A bold section title with an optional trailing action, for the landing pages.
struct MacCatalogSectionTitle: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }
}

extension CatalogIndex {
    /// The instructors of a course's sections, primary first, without repeats (Banner's names, so
    /// they can open the instructor's window).
    func macCatalogInstructors(_ key: CourseKey) -> [Instructor] {
        var seen = Set<String>()
        var result: [Instructor] = []
        for section in sections(for: key) {
            for instructor in section.courseSortedInstructors ?? [] where seen.insert(instructor.name).inserted {
                result.append(instructor)
            }
        }
        return result
    }
}
