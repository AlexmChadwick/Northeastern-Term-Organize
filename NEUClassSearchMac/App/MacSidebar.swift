//
//  MacSidebar.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The main window's sidebar: browsing areas, the term's schedules, degree plans and the
/// watchlist. The term picker sits in the toolbar above it.
struct MacSidebar: View {
    @Binding var selection: MacSidebarItem?

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    /// Rename, duplicate, "My Schedule" and delete for the schedule rows' context menus.
    @State private var planManager = MacPlanManager()

    var body: some View {
        List(selection: $selection) {
            Section("Browse") {
                Label("Search", systemImage: "magnifyingglass").tag(MacSidebarItem.search)
                Label("Subjects", systemImage: "square.grid.2x2").tag(MacSidebarItem.subjects)
                Label("Saved", systemImage: "bookmark").tag(MacSidebarItem.saved)
                Label("Professors", systemImage: "person.2").tag(MacSidebarItem.professors)
                Label("Free Rooms", systemImage: "door.left.hand.open").tag(MacSidebarItem.rooms)
            }

            Section(catalog.selectedTerm.map { "Schedules · \($0.shortName)" } ?? "Schedules") {
                Label("All Schedules", systemImage: "calendar").tag(MacSidebarItem.schedules)
                ForEach(schedules) { plan in
                    Label {
                        ScheduleNameLabel(name: plan.name, showsIcon: false)
                    } icon: {
                        Image(systemName: plan.isPrimary ? "star.fill" : "calendar")
                    }
                    .tag(MacSidebarItem.schedule(plan.id))
                    .contextMenu { MacSchedulePlanMenu(plan: plan, manager: planManager) }
                }
            }

            Section("Degree Plans") {
                Label("All Degree Plans", systemImage: "graduationcap").tag(MacSidebarItem.degreePlans)
                ForEach(userData.sortedDegreePlans) { plan in
                    Label(plan.name, systemImage: plan.isPrimary ? "star.fill" : "graduationcap")
                        .tag(MacSidebarItem.degreePlan(plan.id))
                }
            }

            Section("Alerts") {
                Label("Watchlist", systemImage: "bell")
                    .badge(userData.watchlist.count)
                    .tag(MacSidebarItem.watchlist)
            }
        }
        .listStyle(.sidebar)
        .macPlanDialogs(planManager, userData: userData) { plan in
            if selection == .schedule(plan.id) { selection = .schedules }
            userData.deletePlan(id: plan.id)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TermMenu()
            }
        }
    }

    private var schedules: [SchedulePlan] {
        guard let code = catalog.selectedTerm?.code else { return [] }
        return userData.plans(in: code)
    }
}

/// Schedule names can end in " (edited in app)". A single-line tail truncation
/// hides that suffix, so the copy looks like the original plan. Middle
/// truncation keeps the suffix in view, and the badge stays put when the row
/// is narrower than the name.
struct ScheduleNameLabel: View {
    var name: String
    var showsIcon: Bool = true
    var systemImage: String? = nil

    private var isAppEdit: Bool {
        name.contains(UserDataPlanMerge.editedInAppSuffix)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsIcon, let systemImage {
                Image(systemName: systemImage)
            }
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if isAppEdit {
                Text("App edit")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .layoutPriority(1)
                    .accessibilityLabel("Edited in app")
            }
        }
    }
}
