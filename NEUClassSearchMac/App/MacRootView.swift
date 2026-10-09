//
//  MacRootView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UniformTypeIdentifiers

/// The main window: a sidebar of areas, schedules and degree plans, and the selected area.
struct MacRootView: View {
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            MacSidebar(selection: $navigator.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            MacDetailView(item: navigator.selection)
        }
        .onOpenURL(perform: open)
        // Drop a degree audit PDF anywhere on the window to import it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            navigator.pendingDegreePlanFile = pdf
            navigator.selection = .degreePlans
            return true
        }
        // Menu commands work from any area, so their sheets live here.
        .sheet(isPresented: $navigator.isNewSchedulePresented) {
            MacNewScheduleSheet()
        }
        .sheet(isPresented: $navigator.isNewDegreePlanPresented) {
            MacNewDegreePlanSheet()
        }
        .fileImporter(isPresented: $navigator.isDegreePlanImporterPresented, allowedContentTypes: DegreePlanImporter.contentTypes) { result in
            guard case .success(let url) = result else { return }
            navigator.pendingDegreePlanFile = url
            navigator.selection = .degreePlans
        }
        .sheet(isPresented: Binding(
            get: { navigator.pendingDegreePlanFile != nil },
            set: { if !$0 { navigator.pendingDegreePlanFile = nil } }
        )) {
            if let url = navigator.pendingDegreePlanFile {
                MacDegreePlanImportSheet(url: url)
            }
        }
        .macShell()
    }

    /// Course links open a course window; everything else goes to the navigator.
    private func open(_ url: URL) {
        let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        if AppLink.isAppLink(url), parts.first == "course", parts.count >= 4 {
            let key = CourseKey(subject: parts[2].uppercased(), number: parts[3].uppercased())
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: parts[1], key: key))
        } else {
            navigator.handle(url: url)
        }
    }
}

/// The area for a sidebar selection.
struct MacDetailView: View {
    var item: MacSidebarItem?

    var body: some View {
        switch item {
        case .search, nil: MacSearchView()
        case .subjects: MacSubjectsView()
        case .saved: MacSavedView()
        case .professors: MacProfessorsView()
        case .rooms: MacRoomsView()
        case .schedules: MacSchedulesOverview()
        case .schedule(let id): MacScheduleView(planID: id)
        case .degreePlans: MacDegreePlansOverview()
        case .degreePlan(let id): MacDegreePlanView(planID: id)
        case .degreeRequirements(let id): MacDegreeRequirementsView(planID: id)
        case .watchlist: MacWatchlistView()
        }
    }
}
