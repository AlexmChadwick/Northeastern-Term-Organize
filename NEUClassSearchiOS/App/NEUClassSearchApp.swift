//
//  NEUClassSearchApp.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  An unofficial, on-device take on SearchNEU (https://github.com/sandboxnu/searchneu)
//  for iPhone and iPad. Course data comes from Northeastern's public Banner
//  class search, and degree requirements from its public academic catalog. With
//  iCloud sync on, the user's data also syncs through their own private iCloud
//  database; no other server is involved.
//

import CoreSpotlight
import SwiftUI

@main
struct NEUClassSearchApp: App {
    @UIApplicationDelegateAdaptor(CloudSyncAppDelegate.self) private var cloudSyncAppDelegate
    @State private var catalog = CatalogStore()
    @State private var userData: UserDataStore
    @State private var router = AppRouter()
    @State private var searchModel = SearchModel()
    @State private var programCatalog = ProgramCatalogStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let userData = UserDataStore()
        _userData = State(initialValue: userData)
        // Before UIKit finishes launching: iOS may start the app in the background just to
        // deliver a change from iCloud.
        CloudSyncController.shared.attach(to: userData)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                .environment(userData)
                .environment(router)
                .environment(searchModel)
                .environment(programCatalog)
                .environment(CloudSyncController.shared.status)
                .task {
                    #if DEBUG
                    IOSDegreeSamples.seedIfRequested(userData: userData, catalog: catalog, router: router)
                    #endif
                    if !userData.preferences.hasCompletedOnboarding {
                        router.isOnboardingPresented = true
                    }
                    WatchlistService.shared.configure(catalog: catalog, userData: userData, router: router)
                    userData.onPlansChanged = { [catalog, userData] in
                        WidgetBridge.update(catalog: catalog, userData: userData)
                    }
                    await catalog.bootstrap(preferredTermCode: userData.preferences.selectedTermCode)
                    WidgetBridge.update(catalog: catalog, userData: userData)
                }
                .onChange(of: catalog.readyIndex?.term.code) { _, _ in
                    // Keep Spotlight in sync with the term being browsed.
                    if let index = catalog.readyIndex { SpotlightIndexer.index(index) }
                }
                .onChange(of: catalog.indexVersion) { _, _ in
                    // Times or rooms may have changed after a sync or live refresh.
                    WidgetBridge.update(catalog: catalog, userData: userData)
                }
                .onOpenURL { router.handle(url: $0) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let course = SpotlightIndexer.course(for: activity) {
                        router.show(.course(termCode: course.termCode, key: course.key), in: .catalog)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                userData.flushNow()
                CloudSyncController.shared.appDidEnterBackground()
                WatchlistService.scheduleBackgroundRefresh(enabled: userData.preferences.backgroundRefreshEnabled && !userData.watchlist.isEmpty)
            case .active:
                userData.reloadExternalChanges()
                Task { await WatchlistService.shared.refreshIfStale() }
                CloudSyncController.shared.appDidBecomeActive()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(WatchlistService.backgroundTaskIdentifier)) {
            await WatchlistService.performBackgroundRefresh()
        }
    }
}
