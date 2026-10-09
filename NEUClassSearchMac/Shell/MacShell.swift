//
//  MacShell.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI

extension View {
    /// Window-wide pieces of the shell attached to the main window: the first-launch welcome,
    /// watchlist checks while the app runs, and the like.
    func macShell() -> some View {
        modifier(MacShellModifier())
    }
}

private struct MacShellModifier: ViewModifier {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MacWelcomeView.seenKey) private var hasSeenWelcome = false
    @State private var showsWelcome = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsWelcome) {
                MacWelcomeView()
            }
            .onChange(of: showsWelcome) { _, isShown in
                // However it was dismissed (Continue, Escape), it doesn't come back.
                if !isShown { hasSeenWelcome = true }
            }
            .task { start() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !MacShellRun.isSnapshot else { return }
                Task { await WatchlistService.shared.refreshIfStale() }
            }
    }

    /// Runs once per window: shows the welcome the first time, and starts the watchlist checks
    /// (shared by all windows, so a second window doesn't start a second timer).
    private func start() {
        #if DEBUG
        MacShellRun.printWindowSizesIfRequested()
        #endif
        guard !MacShellRun.isSnapshot else { return }
        if !hasSeenWelcome { showsWelcome = true }
        let catalog = catalog, userData = userData, navigator = navigator, openWindow = openWindow
        MacWatchlistMonitor.shared.start(catalog: catalog, userData: userData) { url in
            MacShellLinks.open(url, catalog: catalog, userData: userData, navigator: navigator, openWindow: openWindow)
        }
    }
}

/// What the app does with a `termorganize://` link that a seat alert carries.
@MainActor
enum MacShellLinks {
    /// `section/<term>/<crn>` opens the section's course in its own window; `watchlist` shows the
    /// watchlist; anything else goes to the navigator, like a link opened from outside the app.
    static func open(
        _ url: URL,
        catalog: CatalogStore,
        userData: UserDataStore,
        navigator: MacNavigator,
        openWindow: OpenWindowAction
    ) {
        let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        if parts.first == "section", parts.count >= 3 {
            let termCode = parts[1], crn = parts[2]
            let key = userData.watchlist.first { $0.termCode == termCode && $0.crn == crn }?.courseKey
                ?? catalog.cachedIndex(for: termCode)?.section(crn: crn)?.courseKey
            if let key {
                NSApp.activate()
                openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
                return
            }
            navigator.selection = .watchlist
        } else {
            navigator.handle(url: url)
        }
        MacShellWindows.showMain(openWindow: openWindow)
    }
}
