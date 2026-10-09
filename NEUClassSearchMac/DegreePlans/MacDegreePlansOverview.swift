//
//  MacDegreePlansOverview.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Degree plans, as cards or as a table (the one used for prerequisite checks marked with a
/// star), beside a preview of the selected plan in a pane the student resizes or closes: its
/// credits, how it measures up against its degree requirements, and its semesters. Double-click
/// or press Return to open a plan; New (⇧⌘N), Import (⌘O, or drop a PDF on the window), and a
/// context menu to open, rename, duplicate, export, star or delete a plan.
struct MacDegreePlansOverview: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(MacNavigator.self) private var navigator

    @State private var selection: Set<UUID> = []
    /// Empty until a column header is clicked: then the plans are in the store's order, the
    /// starred plan first and the latest edit next.
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @State private var plansToDelete: [DegreePlan] = []
    @State private var planToRename: DegreePlan?
    @State private var planToExport: DegreePlan?
    @State private var planToSetUp: DegreePlan?
    /// The width this screen has: until the student chooses, the preview shows when there is room for it.
    @State private var detailWidth: CGFloat = 1000
    /// The semester hours each plan's program requires, by plan, once its requirements have loaded.
    @State private var requiredHours: [UUID: Double] = [:]

    @AppStorage("mac.degreePlans.display") private var displayRaw = DisplayMode.cards.rawValue
    /// Whether the student showed or hid the preview; nil until they do.
    @AppStorage("mac.degreePlans.showsPreview") private var storedShowsPreview: Bool?
    /// Whether a plan shows its requirements beside it (the plan's own toggle).
    @AppStorage(MacDegreePlanPane.showsRequirementsKey) private var showsRequirements = true

    /// How the plans are listed.
    enum DisplayMode: String, CaseIterable, Identifiable {
        case cards
        case table

        var id: String { rawValue }
        var title: String { self == .cards ? "Cards" : "Table" }
        var symbol: String { self == .cards ? "square.grid.2x2" : "list.bullet" }
    }

    private var display: DisplayMode { DisplayMode(rawValue: displayRaw) ?? .cards }

    /// The preview pane: shown at first when the screen is wide enough for it next to the plans.
    private var showsPreview: Binding<Bool> {
        Binding(
            get: { storedShowsPreview ?? (detailWidth >= 900) },
            set: { storedShowsPreview = $0 }
        )
    }

    /// A plan as a table row, with the values its columns sort by.
    struct Row: Identifiable {
        var plan: DegreePlan

        var id: UUID { plan.id }
        var name: String { plan.name }
        var program: String { plan.program ?? "" }
        var completedCredits: Double { plan.completedCredits }
        var plannedCredits: Double { plan.plannedCredits }
        /// Orders plans by the semester that comes next; plans with none go last.
        var nextOrder: Int { plan.degreePlanNextTerm()?.sortKey ?? Int.max }
        var updatedAt: Date { plan.updatedAt }
    }

    private var rows: [Row] {
        let rows = userData.sortedDegreePlans.map(Row.init)
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    private var selectedPlans: [DegreePlan] {
        userData.sortedDegreePlans.filter { selection.contains($0.id) }
    }

    /// What loading the requirements depends on: which plans have a program chosen, and which.
    private var requirementsKey: [String] {
        userData.sortedDegreePlans.map { "\($0.id)|\($0.catalogYear ?? 0)|\($0.catalogProgramPath ?? "")" }
    }

    // MARK: Body

    var body: some View {
        Group {
            if userData.degreePlans.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("Degree Plans")
        .navigationSubtitle(subtitle)
        .toolbar {
            // In the middle of the toolbar, as in Schedules: in a group with the buttons, a segmented
            // picker keeps the window from getting narrow.
            ToolbarItem(placement: .principal) {
                Picker("Show plans as", selection: $displayRaw) {
                    ForEach(DisplayMode.allCases) { mode in
                        Image(systemName: mode.symbol).accessibilityLabel(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show the plans as cards, or as a table")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navigator.isNewDegreePlanPresented = true
                } label: {
                    Label("New Degree Plan", systemImage: "plus")
                }
                .help("Start a new degree plan (⇧⌘N)")
                Button {
                    navigator.isDegreePlanImporterPresented = true
                } label: {
                    Label("Import PDF…", systemImage: "square.and.arrow.down")
                }
                .help("Import a degree audit plan PDF (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: showsPreview) {
                    Label("Preview", systemImage: "sidebar.trailing")
                }
                .help(showsPreview.wrappedValue ? "Hide the preview" : "Show a preview of the selected plan")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        .sheet(item: $planToRename) { plan in
            MacDegreePlanDetailsSheet(planID: plan.id)
        }
        .sheet(item: $planToExport) { plan in
            MacDegreePlanExportSheet(planID: plan.id)
        }
        .sheet(item: $planToSetUp) { plan in
            MacDegreeRequirementsSetupSheet(planID: plan.id)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !plansToDelete.isEmpty }, set: { if !$0 { plansToDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button(plansToDelete.count == 1 ? "Delete Plan" : "Delete \(plansToDelete.count) Plans", role: .destructive) {
                delete(plansToDelete)
            }
        } message: {
            Text("The plan and its semesters will be deleted, and with iCloud sync on, from your other devices too. This can’t be undone.")
        }
        // The preview always has a plan to show: the starred one, else the latest.
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: userData.degreePlans.count) { _, _ in
            selection = selection.filter { userData.degreePlan(id: $0) != nil }
            selectFirstIfNeeded()
        }
        // What each plan's program requires, for the bars: the saved copy of its requirements.
        .task(id: requirementsKey) { await loadRequiredHours() }
        .onDeleteCommand {
            if !selectedPlans.isEmpty { plansToDelete = selectedPlans }
        }
        .focusedSceneValue(\.macSidePane, userData.degreePlans.isEmpty
            ? nil
            : MacPaneToggle(title: "Preview", isShown: showsPreview.wrappedValue) { showsPreview.wrappedValue.toggle() })
        .focusedSceneValue(\.macDelete, selection.isEmpty ? nil : MacMenuAction(title: selection.count == 1 ? "Delete Plan…" : "Delete Plans…") {
            plansToDelete = selectedPlans
        })
        .focusedSceneValue(\.macExport, selectedPlans.count == 1 ? MacMenuAction(title: "Export Degree Plan as PDF…") {
            planToExport = selectedPlans.first
        } : nil)
        .focusedSceneValue(\.macPrint, selectedPlans.count == 1 ? MacMenuAction(title: "Print Degree Plan…") {
            if let plan = selectedPlans.first { MacDegreePlanPrinting.print(plan) }
        } : nil)
    }

    private var subtitle: String {
        let count = userData.degreePlans.count
        return count == 0 ? "" : (count == 1 ? "1 plan" : "\(count) plans")
    }

    private var deleteTitle: String {
        plansToDelete.count == 1 ? "Delete “\(plansToDelete[0].name)”?" : "Delete \(plansToDelete.count) plans?"
    }

    private func selectFirstIfNeeded() {
        guard selection.isEmpty, let first = userData.sortedDegreePlans.first else { return }
        selection = [first.id]
    }

    /// Reads the saved requirements of the plans that have a program (the catalog is asked only for
    /// one that has none saved yet), for the semester hours their bars measure against.
    private func loadRequiredHours() async {
        for plan in userData.sortedDegreePlans where plan.catalogProgramPath != nil {
            await programCatalog.loadRequirements(for: plan)
        }
        var hours: [UUID: Double] = [:]
        for plan in userData.sortedDegreePlans {
            if plan.catalogProgramPath != nil, let total = programCatalog.requirements(for: plan)?.totalHours {
                hours[plan.id] = total
            }
        }
        if hours != requiredHours { requiredHours = hours }
    }

    // MARK: Plans

    /// The plans take little room as cards, more as a table. The preview takes a share of the width
    /// (so it grows with the window), and floats over them in a window too narrow for both.
    private var content: some View {
        MacSplitPane(
            storageKey: "mac.split.degreePlans",
            paneEdge: .trailing,
            defaultShare: 0.4,
            paneMinWidth: 330,
            primaryMinWidth: display == .table ? 570 : 300,
            maxShare: 0.65,
            isPaneShown: showsPreview
        ) {
            switch display {
            case .cards:
                MacDegreePlanCards(
                    plans: userData.sortedDegreePlans,
                    requiredHours: requiredHours,
                    selection: $selection,
                    open: { open($0) },
                    menu: { id in AnyView(contextMenu(for: [id])) }
                )
            case .table:
                table
            }
        } pane: {
            MacDegreePlanSummaryPane(
                plan: selectedPlans.count == 1 ? selectedPlans.first : nil,
                selectionCount: selection.count,
                onOpen: { open($0.id) },
                onShowRequirements: { showRequirements(of: $0.id) },
                onSetUp: { planToSetUp = $0 }
            )
        }
    }

    // MARK: Table

    /// A table adds about 17 points to every column and 15 to the table. The minimums add up to what the
    /// narrowest window leaves (570 points beside the sidebar), and the ideals to a half-screen window.
    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.plan.isPrimary ? "star.fill" : "graduationcap")
                        .foregroundStyle(row.plan.isPrimary ? Color.orange : Color.secondary)
                        .frame(width: 16)
                        .help(row.plan.isPrimary ? "Used for prerequisite checks" : "")
                        .accessibilityLabel(row.plan.isPrimary ? "Used for prerequisite checks" : "Degree plan")
                    Text(row.plan.name)
                        .lineLimit(1)
                }
            }
            .width(min: 110, ideal: 200)
            TableColumn("Program", value: \.program) { row in
                Text(row.plan.program ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 72, ideal: 130)
            TableColumn("Completed", value: \.completedCredits) { row in
                Text(DegreePlanText.credits(row.plan.completedCredits))
                    .monospacedDigit()
            }
            .width(min: 62, ideal: 96)
            TableColumn("Planned", value: \.plannedCredits) { row in
                Text(DegreePlanText.credits(row.plan.plannedCredits))
                    .monospacedDigit()
            }
            .width(min: 58, ideal: 90)
            TableColumn("Next Semester", value: \.nextOrder) { row in
                Text(row.plan.degreePlanNextSummary() ?? row.plan.degreePlanNextLine())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 240)
            TableColumn("Updated", value: \.updatedAt) { row in
                Text(row.plan.updatedAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 56, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // A table made after the window was resized can size its columns past the window's edge.
        .macFitsTableColumns(when: "degreePlans")
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Import your degree audit plan", systemImage: "graduationcap")
        } description: {
            Text("In the degree audit planner, open your plan, choose View Plan and save the PDF. Then import it here, or drop the PDF on this window, to check prerequisites and autofill schedules.")
        } actions: {
            HStack {
                Button("Import PDF…") {
                    navigator.isDegreePlanImporterPresented = true
                }
                .buttonStyle(.borderedProminent)
                Button("Start a New Plan") {
                    navigator.isNewDegreePlanPresented = true
                }
            }
            .controlSize(.large)
        }
    }

    // MARK: Menu and actions

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let plans = userData.sortedDegreePlans.filter { ids.contains($0.id) }
        if plans.count == 1, let plan = plans.first {
            Button("Open Plan") { open(plan.id) }
            Button("Open with Requirements") { showRequirements(of: plan.id) }
            Divider()
            if !plan.isPrimary {
                Button("Use for Prerequisite Checks", systemImage: "star") {
                    userData.setPrimaryDegreePlan(id: plan.id)
                }
            }
            Button("Rename or Edit Program…") { planToRename = plan }
            Button("Duplicate") { duplicate(plan) }
            Button("Export as PDF…") { planToExport = plan }
            Divider()
            Button("Delete…", role: .destructive) { plansToDelete = [plan] }
        } else if !plans.isEmpty {
            Button("Delete \(plans.count) Plans…", role: .destructive) { plansToDelete = plans }
        }
    }

    private func open(_ id: UUID) {
        navigator.selection = .degreePlan(id)
    }

    /// Opens a plan with the requirements beside it, shown even if they were hidden.
    private func showRequirements(of id: UUID) {
        showsRequirements = true
        navigator.selection = .degreePlan(id)
    }

    private func duplicate(_ plan: DegreePlan) {
        let copy = DegreePlanEditing.duplicate(plan, existingNames: userData.degreePlans.map(\.name))
        let stored = userData.addDegreePlan(copy)
        selection = [stored.id]
    }

    private func delete(_ plans: [DegreePlan]) {
        for plan in plans { userData.deleteDegreePlan(id: plan.id) }
        selection.subtract(plans.map(\.id))
        plansToDelete = []
    }
}
