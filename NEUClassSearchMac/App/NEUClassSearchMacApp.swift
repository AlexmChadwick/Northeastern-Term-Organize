//
//  NEUClassSearchMacApp.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The Mac app: the same catalog, schedules, degree plans and sync as the iPhone and iPad
//  app (everything under NEUClassSearch/ except its UI), with a Mac interface — a sidebar
//  window, course windows, menu commands, a Settings window and a menu bar extra.
//

import SwiftUI

@main
struct NEUClassSearchMacApp: App {
    @NSApplicationDelegateAdaptor(CloudSyncAppDelegate.self) private var cloudSyncAppDelegate
    @State private var catalog = CatalogStore()
    @State private var userData: UserDataStore
    @State private var programCatalog = ProgramCatalogStore()
    @State private var navigator = MacNavigator()
    /// Settings › General › "Show Up Next in the menu bar" (this Mac only).
    @AppStorage("mac.showsMenuBarExtra") private var showsMenuBarExtra = true
    /// Whether Up Next is in the menu bar now: the setting, unless it was dragged out of the menu
    /// bar this session. State rather than the setting itself: `MenuBarExtra` writes its binding
    /// back on every update, and each write to UserDefaults would update the app again, without end.
    @State private var isMenuBarExtraInserted: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before any scene: a tap on a seat alert that launches the app is queued, not lost.
        WatchlistNotificationDelegate.installOnce()
        if !Self.indexesSpotlight { SpotlightIndexer.removeAll() }
        _isMenuBarExtraInserted = State(initialValue: UserDefaults.standard.object(forKey: "mac.showsMenuBarExtra") as? Bool ?? true)
        #if DEBUG
        // Snapshot runs on sample data use their own store and never sync.
        if let sample = MacSnapshot.sampleUserDataStore() {
            _userData = State(initialValue: sample)
            return
        }
        #endif
        let userData = UserDataStore()
        _userData = State(initialValue: userData)
        CloudSyncController.shared.attach(to: userData)
    }

    /// Local builds (`*.localbuild`, from command-line scripts and snapshot runs) stay out of
    /// Spotlight, and remove what they put there: next to the real app's, every course would show
    /// up twice, and a click could open the wrong build.
    private static var indexesSpotlight: Bool { !(Bundle.main.bundleIdentifier ?? "").hasSuffix(".localbuild") }

    /// Settings › General › "Show Up Next in the menu bar"; never during snapshot runs.
    private var menuBarExtraInserted: Binding<Bool> {
        #if DEBUG
        if MacSnapshot.isRequested { return .constant(false) }
        #endif
        return $isMenuBarExtraInserted
    }

    var body: some Scene {
        WindowGroup("Term Organize", id: MacWindowID.main) {
            MacRootView()
                .macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
                .task {
                    #if DEBUG
                    if MacSnapshot.isRequested {
                        Task { await MacSnapshot.runIfRequested(navigator: navigator, catalog: catalog, userData: userData, programCatalog: programCatalog) }
                    }
                    #endif
                    await catalog.bootstrap(preferredTermCode: userData.preferences.selectedTermCode)
                }
                .onChange(of: catalog.readyIndex?.term.code) { _, _ in
                    if Self.indexesSpotlight, let index = catalog.readyIndex { SpotlightIndexer.index(index) }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            MacCommands(navigator: navigator)
            MacScheduleCommands()
            MacDegreePlanCommands()
            MacCatalogCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                userData.flushNow()
                CloudSyncController.shared.appDidEnterBackground()
            case .active:
                CloudSyncController.shared.appDidBecomeActive()
            @unknown default:
                break
            }
        }

        WindowGroup("Course", id: MacWindowID.course, for: CourseWindowValue.self) { $value in
            Group {
                if let value {
                    MacCourseWindow(value: value)
                } else {
                    ContentUnavailableView("No course", systemImage: "book.closed")
                }
            }
            .macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
        }
        .defaultSize(width: 760, height: 820)

        WindowGroup("Professor", id: MacWindowID.professor, for: ProfessorWindowValue.self) { $value in
            Group {
                if let value {
                    MacProfessorWindow(value: value)
                } else {
                    ContentUnavailableView("No professor", systemImage: "person")
                }
            }
            .macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
        }
        .defaultSize(width: 760, height: 700)

        Settings {
            MacSettingsView()
                .macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
        }

        MenuBarExtra("Up Next", systemImage: "calendar.badge.clock", isInserted: menuBarExtraInserted) {
            MacUpNextMenu()
                .macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: showsMenuBarExtra) { _, shows in
            if isMenuBarExtraInserted != shows { isMenuBarExtraInserted = shows }
        }
    }
}

extension View {
    /// The shared stores every Mac scene reads.
    func macEnvironment(catalog: CatalogStore, userData: UserDataStore, programCatalog: ProgramCatalogStore, navigator: MacNavigator) -> some View {
        environment(catalog)
            .environment(userData)
            .environment(programCatalog)
            .environment(navigator)
            .environment(CloudSyncController.shared.status)
    }
}
