//
//  WatchlistTabView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// Root of the Watchlist tab: sections the user wants seat alerts for.
struct WatchlistTabView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    private let service = WatchlistService.shared

    var body: some View {
        content
            .navigationTitle("Watchlist")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .task { await prepare() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if userData.watchlist.isEmpty {
            emptyState
        } else {
            watchList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Watch full sections", systemImage: "bell.badge")
        } description: {
            Text("Tap the bell on any section to watch it. You'll get a notification on this device when a seat or waitlist spot opens up. No account or phone number needed.")
        } actions: {
            Button {
                router.selectedTab = .search
            } label: {
                Text("Find a Course")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private var watchList: some View {
        List {
            if showsPermissionCard {
                Section {
                    WatchlistPermissionCard(
                        status: service.authorizationStatus,
                        requestAction: { Task { await service.requestAuthorization() } },
                        openSettingsAction: openSystemSettings
                    )
                }
            }

            if let error = service.lastError {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn't check seats")
                                .font(.subheadline.weight(.semibold))
                            Text(Self.errorDetail(error))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(for: item)
                    }
                } header: {
                    WatchlistGroupHeader(
                        key: group.key,
                        title: group.title,
                        termName: hasMultipleTerms ? termName(for: group.termCode) : nil
                    ) {
                        router.show(.course(termCode: group.termCode, key: group.key), in: .watchlist)
                    }
                }
            }

            Section {
            } footer: {
                Text("Checks run in the background about every 30 minutes when iOS allows. Keep the app installed and notifications on.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await service.refresh(force: true) }
        .animation(.default, value: userData.watchlist.map(\.id))
        // A little tap when a check finds that more watched sections have seats than before.
        .sensoryFeedback(.success, trigger: openItemCount) { old, new in new > old }
    }

    private func row(for item: WatchItem) -> some View {
        NavigationLink(value: AppRoute.section(termCode: item.termCode, crn: item.crn)) {
            WatchlistRow(item: item, isMissing: service.missingItemIDs.contains(item.id))
        }
        .accessibilityHint("Opens section details")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                stopWatching(item)
            } label: {
                Label("Stop Watching", systemImage: "bell.slash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                setWaitlistAlerts(!item.notifyOnWaitlist, for: item)
            } label: {
                Label(item.notifyOnWaitlist ? "Seats Only" : "Waitlist Alerts", systemImage: "list.bullet.clipboard")
            }
            .tint(.orange)
        }
        .contextMenu {
            Toggle(isOn: Binding(
                get: { item.notifyOnWaitlist },
                set: { setWaitlistAlerts($0, for: item) }
            )) {
                Label("Notify for waitlist spots", systemImage: "list.bullet.clipboard")
            }
            Button {
                router.show(.section(termCode: item.termCode, crn: item.crn), in: .watchlist)
            } label: {
                Label("View Section", systemImage: "info.circle")
            }
            Button {
                router.show(.course(termCode: item.termCode, key: item.courseKey), in: .watchlist)
            } label: {
                Label("View Course", systemImage: "book.closed")
            }
            Divider()
            Button(role: .destructive) {
                stopWatching(item)
            } label: {
                Label("Stop Watching", systemImage: "bell.slash")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !userData.watchlist.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                if service.isRefreshing {
                    ProgressView()
                        .accessibilityLabel("Checking seats")
                } else {
                    Button {
                        Task { await service.refresh(force: true) }
                    } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    // MARK: Data

    private struct WatchGroup: Identifiable {
        var termCode: String
        var key: CourseKey
        var title: String
        var items: [WatchItem]
        var id: String { "\(termCode)|\(key)" }
    }

    /// Watched sections grouped by term and course. The selected term comes first.
    private var groups: [WatchGroup] {
        var order: [String] = []
        var byID: [String: WatchGroup] = [:]
        for item in userData.watchlist {
            let id = "\(item.termCode)|\(item.courseKey)"
            if byID[id] == nil {
                order.append(id)
                byID[id] = WatchGroup(termCode: item.termCode, key: item.courseKey, title: item.courseTitle, items: [])
            }
            byID[id]?.items.append(item)
        }
        let selected = catalog.selectedTermCode
        return order.compactMap { byID[$0] }
            .map { group in
                var sorted = group
                sorted.items.sort { lhs, rhs in
                    let l = Self.sectionRank(lhs.sectionLabel), r = Self.sectionRank(rhs.sectionLabel)
                    if l != r { return l < r }
                    return lhs.sectionLabel.localizedStandardCompare(rhs.sectionLabel) == .orderedAscending
                }
                return sorted
            }
            .sorted { lhs, rhs in
                if lhs.termCode != rhs.termCode {
                    if lhs.termCode == selected { return true }
                    if rhs.termCode == selected { return false }
                    return lhs.termCode > rhs.termCode
                }
                return lhs.key < rhs.key
            }
    }

    private static func sectionRank(_ label: String) -> Int {
        if label.hasPrefix("Lecture") { return 0 }
        if label.hasPrefix("Lab") { return 1 }
        if label.hasPrefix("Recitation") { return 2 }
        return 3
    }

    private var hasMultipleTerms: Bool {
        Set(userData.watchlist.map(\.termCode)).count > 1
    }

    private func termName(for code: String) -> String {
        if let term = catalog.terms.first(where: { $0.code == code }) { return term.shortName }
        if let term = catalog.index?.term, term.code == code { return term.shortName }
        return "Term \(code)"
    }

    private var subtitle: String {
        let items = userData.watchlist
        guard !items.isEmpty else { return "" }
        let open = items.filter { $0.lastSeatsRemaining > 0 && !service.missingItemIDs.contains($0.id) }.count
        let watching = "\(items.count) \(items.count == 1 ? "section" : "sections")"
        return open > 0 ? "\(watching) · \(open) open" : watching
    }

    /// The error's own sentence followed by what the user is looking at instead.
    private static func errorDetail(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Showing the last known numbers." }
        let sentence = ".!?".contains(last) ? trimmed : trimmed + "."
        return "\(sentence) Showing the last known numbers."
    }

    private var openItemCount: Int {
        userData.watchlist.filter { $0.lastSeatsRemaining > 0 }.count
    }

    private var showsPermissionCard: Bool {
        guard service.hasLoadedAuthorization else { return false }
        return service.authorizationStatus == .notDetermined || service.authorizationStatus == .denied
    }

    // MARK: Actions

    private func stopWatching(_ item: WatchItem) {
        withAnimation {
            userData.unwatch(crn: item.crn, termCode: item.termCode)
        }
    }

    private func setWaitlistAlerts(_ isOn: Bool, for item: WatchItem) {
        // Start from the stored item: a check may have updated its numbers since this row was drawn.
        guard var current = userData.watchlist.first(where: { $0.id == item.id }) else { return }
        current.notifyOnWaitlist = isOn
        userData.updateWatchItem(current)
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private func prepare() async {
        if !userData.watchlist.isEmpty {
            // The first time something is watched, ask once. Never at launch.
            await service.requestAuthorizationIfNeeded()
        } else {
            await service.refreshAuthorizationStatus()
        }
        await service.refreshIfStale()
    }
}
