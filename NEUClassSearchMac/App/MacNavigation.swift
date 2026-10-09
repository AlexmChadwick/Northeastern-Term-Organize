//
//  MacNavigation.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation
import SwiftUI

/// Window identifiers for the Mac app's scenes.
enum MacWindowID {
    static let main = "main"
    static let course = "course"
    static let professor = "professor"
}

/// The main window's sidebar. Schedules and degree plans appear as their own rows, the way
/// Mail lists mailboxes, so the student can jump straight to one.
enum MacSidebarItem: Hashable, Codable, Sendable {
    // Browse
    case search
    case subjects
    case saved
    case professors
    case rooms
    // Plan
    case schedules
    case schedule(UUID)
    case degreePlans
    case degreePlan(UUID)
    case degreeRequirements(UUID)
    // Alerts
    case watchlist
}

/// A course shown in its own window. Any screen can open one with
/// `openWindow(id: MacWindowID.course, value: CourseWindowValue(...))`, so areas never need
/// to take over the main window to show a course.
struct CourseWindowValue: Hashable, Codable, Sendable {
    var termCode: String
    var subject: String
    var number: String

    init(termCode: String, key: CourseKey) {
        self.termCode = termCode
        self.subject = key.subject
        self.number = key.number
    }

    var key: CourseKey { CourseKey(subject: subject, number: number) }
}

/// A professor shown in its own window.
struct ProfessorWindowValue: Hashable, Codable, Sendable {
    var termCode: String
    var name: String
}

/// Main-window navigation shared by every area: the sidebar selection, the toolbar search
/// text, and requests that menu commands make of the window (import a PDF, new schedule…).
@MainActor
@Observable
final class MacNavigator {
    var selection: MacSidebarItem? = .search
    /// The toolbar search field (Catalog › Search).
    var searchText = ""
    /// Set by File › Import Degree Plan… (⌘O) and by dropping a PDF on the window.
    var isDegreePlanImporterPresented = false
    /// A degree-plan PDF waiting to be reviewed and imported (from Open, drag and drop, or
    /// the Finder's Open With).
    var pendingDegreePlanFile: URL?
    /// Set by File › New Schedule (⌘N).
    var isNewSchedulePresented = false
    /// Set by File › New Degree Plan (⇧⌘N).
    var isNewDegreePlanPresented = false

    /// The app's links (`termorganize://`, and the old `neuclasssearch://`) and files opened
    /// with the app.
    func handle(url: URL) {
        if url.isFileURL {
            pendingDegreePlanFile = url
            selection = .degreePlans
            return
        }
        guard AppLink.isAppLink(url) else { return }
        let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "schedule": selection = .schedules
        case "watchlist": selection = .watchlist
        case "plan" where parts.count >= 2:
            if let id = UUID(uuidString: parts[1]) { selection = .schedule(id) }
        case "search":
            searchText = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            selection = .search
        default:
            break
        }
    }
}

/// An action the focused window offers to the menu bar, such as File › Export… for the schedule
/// or degree plan on screen. Areas publish one with `.focusedSceneValue(\.macExport, …)`, and
/// `MacCommands` shows it (disabled when nothing offers one).
struct MacMenuAction {
    /// The menu item's title, e.g. `Export Degree Plan as PDF…`.
    var title: String
    var perform: @MainActor () -> Void
}

/// The side pane of the area on screen (the requirements beside a degree plan, a schedule's
/// preview…), for View › Show/Hide (⌥⌘0). Areas publish one with
/// `.focusedSceneValue(\.macSidePane, MacPaneToggle(...))`.
struct MacPaneToggle {
    /// What the pane shows, for the menu item: `Requirements` makes `Show Requirements`.
    var title: String
    var isShown: Bool
    var toggle: @MainActor () -> Void
}

extension FocusedValues {
    /// View › Show/Hide <pane> (⌥⌘0).
    @Entry var macSidePane: MacPaneToggle?
    /// File › Export… (⌘E): the schedule's calendar export, the degree plan's PDF.
    @Entry var macExport: MacMenuAction?
    /// File › Print… (⌘P), where an area can print what it shows.
    @Entry var macPrint: MacMenuAction?
    /// Edit › Delete (⌫) for the selected rows: a course of a schedule, a watched section…
    @Entry var macDelete: MacMenuAction?
    /// View › Reload (⌘R): reloads what the area shows from the network.
    @Entry var macReload: MacMenuAction?
}
