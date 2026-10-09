//
//  RootView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import Observation

/// Search state shared between the tab bar's search field and the search tab.
@MainActor
@Observable
final class SearchModel {
    var text = ""
    var filters = SearchFilters()
    var sort = SearchSort.relevance
    /// Whether the search field is focused/active.
    var isPresented = false

    var query: SearchQuery { SearchQuery(text: text, filters: filters, sort: sort) }
}

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(SearchModel.self) private var searchModel

    var body: some View {
        @Bindable var router = router
        @Bindable var searchModel = searchModel

        TabView(selection: $router.selectedTab) {
            Tab("Catalog", systemImage: "books.vertical", value: AppRouter.Tab.catalog) {
                NavigationStack(path: $router.catalogPath) {
                    CatalogHomeView()
                        .appDestinations()
                }
            }

            Tab("Schedule", systemImage: "calendar", value: AppRouter.Tab.schedule) {
                NavigationStack(path: $router.schedulePath) {
                    ScheduleTabView()
                        .appDestinations()
                }
            }

            Tab("Watchlist", systemImage: "bell", value: AppRouter.Tab.watchlist) {
                NavigationStack(path: $router.watchlistPath) {
                    WatchlistTabView()
                        .appDestinations()
                }
            }
            .badge(openWatchCount)

            Tab("Rooms", systemImage: "door.left.hand.open", value: AppRouter.Tab.rooms) {
                NavigationStack(path: $router.roomsPath) {
                    RoomsTabView()
                        .appDestinations()
                }
            }

            Tab(value: AppRouter.Tab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchTabView()
                        .appDestinations()
                }
                .searchable(text: $searchModel.text, isPresented: $searchModel.isPresented, prompt: "Courses, professors, CRNs")
                .onSubmit(of: .search) {
                    userData.recordSearch(searchModel.text)
                }
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewStyle(.sidebarAdaptable)
        .upNextAccessory(enabled: hasUpcomingClasses)
        .sheet(item: $router.addToPlanRequest) { request in
            AddToPlanSheet(request: request)
        }
        .sheet(isPresented: $router.isSettingsPresented) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $router.isOnboardingPresented) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .fileImporter(
            isPresented: $router.isDegreePlanImporterPresented,
            allowedContentTypes: DegreePlanImporter.contentTypes
        ) { result in
            if case .success(let url) = result { router.importDegreePlan(from: url) }
        }
        .sheet(item: $router.degreePlanImport) { request in
            DegreePlanImportSheet(request: request)
        }
        .sheet(isPresented: $router.isNewDegreePlanPresented) {
            NewDegreePlanSheet()
        }
        .onChange(of: router.pendingSearchText) { _, text in
            guard let text else { return }
            searchModel.text = text
            router.pendingSearchText = nil
        }
        .overlay(alignment: .top) {
            TransientErrorBanner()
        }
    }

    /// Watched sections that currently have open seats.
    private var openWatchCount: Int {
        userData.watchlist.filter { $0.lastSeatsRemaining > 0 }.count
    }

    /// The accessory is a shortcut to the schedule, so it's hidden on the Schedule
    /// tab itself (where it would also crowd the plan's pinned controls).
    private var hasUpcomingClasses: Bool {
        router.selectedTab != .schedule && userData.activePrimaryPlan() != nil
    }
}

private extension View {
    /// Shows the "Up Next" class accessory above the tab bar (iOS 26.1+ supports
    /// hiding it when there is nothing to show).
    @ViewBuilder
    func upNextAccessory(enabled: Bool) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled) {
                UpNextAccessory()
            }
        } else {
            self
        }
    }
}

/// A short-lived banner for refresh errors.
private struct TransientErrorBanner: View {
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        if let message = catalog.lastRefreshError {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .capsule)
                .padding(.horizontal)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation { catalog.lastRefreshError = nil }
                }
                .onTapGesture { withAnimation { catalog.lastRefreshError = nil } }
        }
    }
}
