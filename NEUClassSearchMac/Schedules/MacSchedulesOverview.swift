//
//  MacSchedulesOverview.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The selected term's schedules, as cards with a thumbnail of their week or as a table, beside a
/// preview of the selected one in a pane the student resizes or closes. Double-click or press Return
/// to open a schedule; the context menu renames, duplicates, sets "My Schedule" and deletes.
struct MacSchedulesOverview: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator

    @State private var selection: UUID?
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    /// The width this screen has: until the student chooses, the preview shows when there is room for it.
    @State private var detailWidth: CGFloat = 1000
    @State private var manager = MacPlanManager()

    @AppStorage("mac.schedules.display") private var displayRaw = DisplayMode.cards.rawValue
    /// Whether the student showed or hid the preview; nil until they do.
    @AppStorage("mac.schedules.showsPreview") private var storedShowsPreview: Bool?

    /// How the schedules are listed.
    enum DisplayMode: String, CaseIterable, Identifiable {
        case cards
        case table

        var id: String { rawValue }
        var title: String { self == .cards ? "Cards" : "Table" }
        var symbol: String { self == .cards ? "square.grid.2x2" : "list.bullet" }
    }

    private var display: DisplayMode { DisplayMode(rawValue: displayRaw) ?? .cards }

    /// The preview pane: shown at first when the screen is wide enough for it next to the schedules.
    private var showsPreview: Binding<Bool> {
        Binding(
            get: { storedShowsPreview ?? (detailWidth >= 900) },
            set: { storedShowsPreview = $0 }
        )
    }

    private var termCode: String? { catalog.selectedTermCode }

    /// The selected term's index, once loaded (the schedules here always belong to it).
    private var index: CatalogIndex? { catalog.readyIndex }

    /// One schedule as a table row.
    struct Row: Identifiable {
        var plan: SchedulePlan
        var resolved: ResolvedPlan

        var id: UUID { plan.id }
        var name: String { plan.name }
        var courseCount: Int { plan.courses.count }
        var credits: Double { resolved.credits.max }
        var chosenCount: Int { resolved.entries.filter { !$0.selected.isEmpty }.count }
        var updatedAt: Date { plan.updatedAt }
    }

    // MARK: Body

    var body: some View {
        Group {
            if let termCode {
                let plans = userData.plans(in: termCode)
                if plans.isEmpty {
                    emptyState
                } else {
                    content(plans: plans, termCode: termCode)
                }
            } else {
                noTermState
            }
        }
        .navigationTitle("Schedules")
        .navigationSubtitle(catalog.selectedTerm?.name ?? "")
        .toolbar {
            // In the middle of the toolbar, like the switch between a schedule and its generator: in a
            // group with the buttons, a segmented picker keeps the window from getting narrow.
            ToolbarItem(placement: .principal) {
                Picker("Show schedules as", selection: $displayRaw) {
                    ForEach(DisplayMode.allCases) { mode in
                        Image(systemName: mode.symbol).accessibilityLabel(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show the schedules as cards with a picture of their week, or as a table")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    navigator.isNewSchedulePresented = true
                } label: {
                    Label("New Schedule", systemImage: "calendar.badge.plus")
                }
                .help("New Schedule (⌘N)")
                .disabled(termCode == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: showsPreview) {
                    Label("Preview", systemImage: "sidebar.trailing")
                }
                .help(showsPreview.wrappedValue ? "Hide the preview" : "Show a preview of the selected schedule")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        .macPlanDialogs(manager, userData: userData) { plan in
            if selection == plan.id { selection = nil }
            userData.deletePlan(id: plan.id)
        }
        .onChange(of: userData.plans.count) { _, _ in
            if let selection, userData.plan(id: selection) == nil { self.selection = nil }
        }
        .focusedSceneValue(\.macDelete, selection.flatMap { userData.plan(id: $0) }.map { plan in
            MacMenuAction(title: "Delete Schedule…") { manager.planToDelete = plan }
        })
        .focusedSceneValue(
            \.macSidePane,
            termCode.map { userData.plans(in: $0).isEmpty } == false
                ? MacPaneToggle(title: "Preview", isShown: showsPreview.wrappedValue) { showsPreview.wrappedValue.toggle() }
                : nil
        )
        // The preview always has a schedule to show: the one marked "My Schedule", else the newest.
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: termCode) { _, _ in
            selection = nil
            selectFirstIfNeeded()
        }
    }

    private func selectFirstIfNeeded() {
        guard selection == nil || selection.flatMap({ userData.plan(id: $0) }) == nil, let termCode else { return }
        selection = userData.plans(in: termCode).first?.id
    }

    // MARK: Table

    private func rows(for plans: [SchedulePlan]) -> [Row] {
        plans.map { Row(plan: $0, resolved: ResolvedPlan(plan: $0, index: index)) }
    }

    private func content(plans: [SchedulePlan], termCode: String) -> some View {
        // The schedules need little room as cards, more as a table. The preview takes a share of the
        // width (so it grows with the window), and floats over them in a window too narrow for both.
        MacSplitPane(
            storageKey: "mac.split.schedules",
            paneEdge: .trailing,
            defaultShare: 0.4,
            paneMinWidth: 320,
            primaryMinWidth: display == .table ? 500 : 300,
            maxShare: 0.65,
            isPaneShown: showsPreview
        ) {
            switch display {
            case .cards:
                MacScheduleCards(
                    rows: rows(for: plans),
                    selection: $selection,
                    showsWeekends: userData.preferences.showWeekends,
                    open: { navigator.selection = .schedule($0) },
                    delete: { id in
                        if let plan = userData.plan(id: id) { manager.planToDelete = plan }
                    },
                    menu: { id in AnyView(menu(for: [id])) }
                )
            case .table:
                scheduleTable(plans: plans)
            }
        } pane: {
            MacSchedulePreview(plan: selection.flatMap { userData.plan(id: $0) }, index: index)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            otherTermsBar(currentTermCode: termCode)
        }
    }

    private func scheduleTable(plans: [SchedulePlan]) -> some View {
        let rows = rows(for: plans)
        let sorted = rows.sorted(using: sortOrder)
        // A table adds about 17 points to every column. The minimums add up to what the narrowest window
        // leaves (500 points) and the ideals to a half-screen window, so nothing is cut off there. The
        // course count is part of "Sections" ("3 of 5"), so it has no column of its own.
        return Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                nameCell(row)
            }
            .width(min: 110, ideal: 170)
            TableColumn("Credits", value: \.credits) { row in
                Text(creditsText(row))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 54, ideal: 58, max: 72)
            TableColumn("Sections", value: \.chosenCount) { row in
                sectionsCell(row)
            }
            .width(min: 62, ideal: 68, max: 84)
            TableColumn("Alerts") { row in
                MacWarningLabels(warnings: row.resolved.warnings.filter { $0.severity != .neutral })
            }
            .width(min: 98, ideal: 135)
            TableColumn("Modified", value: \.updatedAt) { row in
                Text(row.updatedAt.macRelativeLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 66, ideal: 80, max: 120)
        }
        .alternatingRowBackgrounds(.disabled)
        // A table made after the window was resized can size its columns past the window's edge.
        .macFitsTableColumns(when: "schedules")
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { navigator.selection = .schedule(id) }
        }
        .onDeleteCommand {
            if let id = selection, let plan = userData.plan(id: id) { manager.planToDelete = plan }
        }
        .onKeyPress(.return) {
            guard let id = selection else { return .ignored }
            navigator.selection = .schedule(id)
            return .handled
        }
    }

    private func nameCell(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.plan.isPrimary ? "star.fill" : "calendar")
                .foregroundStyle(row.plan.isPrimary ? Color.orange : Color.secondary)
                .frame(width: 18)
                .accessibilityLabel(row.plan.isPrimary ? "My Schedule" : "Schedule")
            VStack(alignment: .leading, spacing: 1) {
                ScheduleNameLabel(name: row.plan.name, showsIcon: false)
                    .fontWeight(.medium)
                Text(courseCodes(of: row.plan))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// `20`, or `16–20` when the sections differ; the header says "Credits".
    private func creditsText(_ row: Row) -> String {
        let credits = row.resolved.credits
        guard row.resolved.hasCatalog, credits.max > 0 else { return "" }
        let min = CreditFormatter.number(credits.min)
        return credits.min == credits.max ? min : "\(min)–\(CreditFormatter.number(credits.max))"
    }

    private func courseCodes(of plan: SchedulePlan) -> String {
        guard !plan.courses.isEmpty else { return "No courses yet" }
        return plan.courses.map { $0.key.description }.joined(separator: " · ")
    }

    private func sectionsCell(_ row: Row) -> some View {
        Group {
            if row.courseCount == 0 || !row.resolved.hasCatalog {
                Text("")
            } else {
                Text("\(row.chosenCount) of \(row.courseCount)")
                    .foregroundStyle(row.chosenCount == row.courseCount ? Color.secondary : Color.orange)
                    .help("\(row.chosenCount) of \(row.courseCount) courses have a section chosen")
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func menu(for ids: Set<UUID>) -> some View {
        if let id = ids.first, let plan = userData.plan(id: id) {
            Button("Open", systemImage: "calendar") { navigator.selection = .schedule(id) }
            Divider()
            MacSchedulePlanMenu(plan: plan, manager: manager) { selection = $0.id }
        } else {
            Button("New Schedule", systemImage: "calendar.badge.plus") { navigator.isNewSchedulePresented = true }
        }
    }

    // MARK: Other terms

    /// Schedules of other terms stay reachable from here: a click switches to that term.
    @ViewBuilder
    private func otherTermsBar(currentTermCode: String) -> some View {
        let others = Dictionary(grouping: userData.plans.filter { $0.termCode != currentTermCode }, by: \.termCode)
        if !others.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Text("Other terms")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(others.keys.sorted(by: >), id: \.self) { code in
                        let count = others[code]?.count ?? 0
                        Button {
                            Task {
                                await catalog.select(termCode: code)
                                userData.preferences.selectedTermCode = code
                            }
                        } label: {
                            Text("\(termName(code)) · \(count == 1 ? "1 schedule" : "\(count) schedules")")
                        }
                        .controlSize(.small)
                        .help("Show the schedules of \(termName(code))")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    private func termName(_ code: String) -> String {
        catalog.terms.first { $0.code == code }?.name ?? code
    }

    // MARK: Empty and unavailable states

    /// The prompt to build a first schedule. When schedules exist for other terms, they stay reachable
    /// below it.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Build your schedule", systemImage: "calendar.badge.plus")
        } description: {
            Text("Pick the courses you want, and Term Organize finds every combination of sections that fits — no conflicts, no spreadsheets.")
        } actions: {
            Button("New Schedule") { navigator.isNewSchedulePresented = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let termCode { otherTermsBar(currentTermCode: termCode) }
        }
    }

    /// No term is selected: the catalog is still loading, failed, or hasn't been downloaded.
    @ViewBuilder
    private var noTermState: some View {
        switch catalog.loadState {
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t load courses", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .missing:
            ContentUnavailableView {
                Label("No course data yet", systemImage: "arrow.down.circle")
            } description: {
                Text("Download a term in Settings, then build your schedule here.")
            }
        default:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
