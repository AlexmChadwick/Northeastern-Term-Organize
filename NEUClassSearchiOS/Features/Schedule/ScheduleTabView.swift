//
//  ScheduleTabView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Root of the Schedule tab: the degree plans on top, then every plan of the selected
/// term as a card with a week thumbnail, the plan's courses and anything that needs attention.
struct ScheduleTabView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    @State private var isCreating = false
    @State private var renamingPlanID: UUID?
    @State private var draftName = ""
    @State private var planToDelete: SchedulePlan?
    @State private var toast: PlanToast?
    @State private var haptic = PlanHaptic()

    private var termCode: String? { catalog.selectedTermCode }

    /// The selected term's index, once loaded (plans of this tab always belong to it).
    private var index: CatalogIndex? { catalog.readyIndex }

    var body: some View {
        Group {
            if let termCode {
                let plans = userData.plans(in: termCode)
                if plans.isEmpty {
                    emptyState(termCode: termCode)
                } else {
                    planList(plans, termCode: termCode)
                }
            } else {
                noTermState
            }
        }
        .navigationTitle("Schedule")
        .navigationSubtitle(catalog.selectedTerm?.name ?? "")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TermMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                addMenu
            }
        }
        .alert("New Schedule", isPresented: $isCreating) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createPlan(named: draftName) }
        } message: {
            Text("Name your schedule, like “Plan A”. You can build several and compare them.")
        }
        .alert(
            "Rename Schedule",
            isPresented: Binding(get: { renamingPlanID != nil }, set: { if !$0 { renamingPlanID = nil } }),
            presenting: renamingPlanID
        ) { id in
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renamePlan(id: id, to: draftName) }
        }
        .confirmationDialog(
            planToDelete.map { "Delete “\($0.name)”?" } ?? "Delete schedule?",
            isPresented: Binding(get: { planToDelete != nil }, set: { if !$0 { planToDelete = nil } }),
            titleVisibility: .visible,
            presenting: planToDelete
        ) { plan in
            Button("Delete Schedule", role: .destructive) {
                userData.deletePlan(id: plan.id)
                haptic.fire(.warning)
            }
        } message: { _ in
            Text("The schedule and its saved combinations will be removed. This can’t be undone.")
        }
        .planToast($toast)
        .planHaptic(haptic)
    }

    // MARK: Toolbar

    /// "+": a new schedule, or a new / imported degree plan.
    private var addMenu: some View {
        Menu {
            Button {
                startCreating()
            } label: {
                Label("New schedule", systemImage: "calendar.badge.plus")
            }
            .disabled(termCode == nil)
            Button {
                router.isNewDegreePlanPresented = true
            } label: {
                Label("New degree plan…", systemImage: "graduationcap")
            }
            Button {
                router.isDegreePlanImporterPresented = true
            } label: {
                Label("Import degree plan (PDF)…", systemImage: "square.and.arrow.down")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    // MARK: Degree plans

    /// The degree plans at the top of the tab, in every state of it. `DegreePlansSection`
    /// lays out its own cards, so its row has no background, insets or separators.
    private var degreePlansSection: some View {
        Section {
            DegreePlansSection()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Empty and unavailable states

    /// The prompt to build a first schedule below the degree plans. When schedules exist for
    /// other terms, they stay reachable below it.
    private func emptyState(termCode: String) -> some View {
        List {
            degreePlansSection
            placeholderSection { emptyStatePrompt }
            otherTermsSection(currentTermCode: termCode)
        }
        .listStyle(.insetGrouped)
    }

    /// No term is selected: the catalog is still loading, failed, or hasn't been downloaded.
    /// Degree plans don't need course data, so they stay reachable in the last two.
    @ViewBuilder
    private var noTermState: some View {
        switch catalog.loadState {
        case .failed(let message):
            messageList {
                ContentUnavailableView {
                    Label("Couldn’t load courses", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            }
        case .missing:
            messageList {
                ContentUnavailableView {
                    Label("No course data yet", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download a term from the Catalog tab or Settings, then build your schedule here.")
                }
            }
        default:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The degree plans with a message (not a card) below them.
    private func messageList<Content: View>(@ViewBuilder _ message: () -> Content) -> some View {
        List {
            degreePlansSection
            placeholderSection(message)
        }
        .listStyle(.insetGrouped)
    }

    /// A message as a list row: no background or separator.
    private func placeholderSection<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Section {
            content()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var emptyStatePrompt: some View {
        ContentUnavailableView {
            Label("Build your schedule", systemImage: "calendar.badge.plus")
        } description: {
            Text("Pick the courses you want, and Term Organize finds every combination of sections that fits — no conflicts, no spreadsheets.")
        } actions: {
            Button {
                startCreating()
            } label: {
                Text("New Schedule")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    // MARK: List

    private func planList(_ plans: [SchedulePlan], termCode: String) -> some View {
        let preferences = userData.preferences
        return List {
            degreePlansSection

            Section {
                ForEach(plans) { plan in
                    NavigationLink(value: AppRoute.plan(id: plan.id)) {
                        PlanCard(
                            plan: plan,
                            resolved: ResolvedPlan(plan: plan, index: index),
                            preferences: preferences,
                            isLoadingCatalog: catalog.loadState == .loading
                        )
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if !plan.isPrimary {
                            Button {
                                setPrimary(plan)
                            } label: {
                                Label("My Schedule", systemImage: "star.fill")
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            planToDelete = plan
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            duplicate(plan)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.indigo)
                        Button {
                            startRenaming(plan)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            startRenaming(plan)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            duplicate(plan)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        if !plan.isPrimary {
                            Button {
                                setPrimary(plan)
                            } label: {
                                Label("Set as My Schedule", systemImage: "star")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            planToDelete = plan
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            otherTermsSection(currentTermCode: termCode)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func otherTermsSection(currentTermCode: String) -> some View {
        let others = Dictionary(grouping: userData.plans.filter { $0.termCode != currentTermCode }, by: \.termCode)
        if !others.isEmpty {
            Section("Other terms") {
                ForEach(others.keys.sorted(by: >), id: \.self) { code in
                    Button {
                        Task {
                            await catalog.select(termCode: code)
                            userData.preferences.selectedTermCode = code
                        }
                    } label: {
                        HStack {
                            Text(termName(code))
                                .foregroundStyle(.primary)
                            Spacer()
                            let count = others[code]?.count ?? 0
                            Text(count == 1 ? "1 schedule" : "\(count) schedules")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func termName(_ code: String) -> String {
        catalog.terms.first { $0.code == code }?.name ?? code
    }

    // MARK: Actions

    private func startCreating() {
        guard let termCode else { return }
        draftName = PlanEditing.nextPlanName(existing: userData.plans(in: termCode).map(\.name))
        isCreating = true
    }

    private func createPlan(named name: String) {
        guard let termCode else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? PlanEditing.nextPlanName(existing: userData.plans(in: termCode).map(\.name)) : trimmed
        let plan = userData.createPlan(name: finalName, termCode: termCode)
        haptic.fire(.success)
        router.show(.plan(id: plan.id), in: .schedule)
    }

    private func startRenaming(_ plan: SchedulePlan) {
        draftName = plan.name
        renamingPlanID = plan.id
    }

    private func renamePlan(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userData.updatePlan(id: id) { $0.name = trimmed }
        haptic.fire(.success)
    }

    private func duplicate(_ plan: SchedulePlan) {
        guard let copy = userData.duplicatePlan(id: plan.id) else { return }
        haptic.fire(.success)
        toast = PlanToast(text: "Created “\(copy.name)”", systemImage: "plus.square.on.square")
    }

    private func setPrimary(_ plan: SchedulePlan) {
        userData.setPrimary(id: plan.id)
        haptic.fire(.success)
        toast = PlanToast(text: "\(plan.name) is now My Schedule", systemImage: "star.fill")
    }
}

// MARK: - Plan card

/// A plan as a content card: name, week thumbnail, course chips and warnings.
private struct PlanCard: View {
    var plan: SchedulePlan
    var resolved: ResolvedPlan
    var preferences: AppPreferences
    var isLoadingCatalog = false

    private let thumbnailHeight: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            thumbnail
            if !plan.courses.isEmpty {
                chips
            }
            warnings
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if plan.isPrimary {
                TagLabel(text: "My Schedule", systemImage: "star.fill", tint: .orange)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
    }

    private var subtitle: String {
        let count = plan.courses.count
        var parts = [count == 1 ? "1 course" : "\(count) courses"]
        if resolved.hasCatalog, resolved.credits.max > 0 { parts.append(resolved.creditsLabel) }
        return parts.joined(separator: " · ")
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        let events = resolved.events
        let hours: ClosedRange<Int> = {
            guard !events.isEmpty else { return 8...17 }
            let lower = min(9, events.map(\.start).min()! / 60)
            let upper = max(15, Int((Double(events.map(\.end).max()!) / 60).rounded(.up)))
            return lower...min(24, upper)
        }()
        return WeekCalendarView(
            events: events,
            showWeekends: preferences.showWeekends,
            startHour: hours.lowerBound,
            endHour: hours.upperBound,
            hourHeight: PlanCalendarSupport.hourHeight(fitting: thumbnailHeight, range: hours),
            compact: true,
            showsNowIndicator: false
        )
        .frame(height: thumbnailHeight)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .overlay {
            if events.isEmpty {
                Text(emptyHint)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemGroupedBackground).opacity(0.92), in: .capsule)
            }
        }
        .accessibilityHidden(true)
    }

    private var emptyHint: String {
        if plan.courses.isEmpty { return "No courses yet" }
        if !resolved.hasCatalog { return isLoadingCatalog ? "Loading courses…" : "Open to view" }
        return resolved.hasSelection ? "No fixed meeting times" : "Choose sections"
    }

    // MARK: Chips

    private var chips: some View {
        let limit = 8
        let entries = resolved.entries
        return PlanFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(entries.prefix(limit)) { entry in
                PlanCourseChip(
                    key: entry.key,
                    colorIndex: entry.planCourse.colorIndex,
                    isRequired: entry.planCourse.isRequired,
                    hasSection: entry.chosen != nil || !resolved.hasCatalog
                )
            }
            if entries.count > limit {
                Text("+\(entries.count - limit)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    // MARK: Warnings

    private struct Warning: Identifiable {
        var id: String { text }
        var text: String
        var symbol: String
        var color: Color
    }

    private var warningItems: [Warning] {
        resolved.warnings.map { warning in
            let color: Color = switch warning.severity {
            case .error: .red
            case .warning: .orange
            case .neutral: .secondary
            }
            return Warning(text: warning.text, symbol: warning.symbol, color: color)
        }
    }

    @ViewBuilder
    private var warnings: some View {
        let items = warningItems
        if !items.isEmpty {
            PlanFlowLayout(spacing: 12, lineSpacing: 4) {
                ForEach(items) { item in
                    Label(item.text, systemImage: item.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.color)
                }
            }
        }
    }

    private var accessibilitySummary: String {
        var parts = [plan.name]
        if plan.isPrimary { parts.append("My Schedule") }
        parts.append(subtitle)
        parts.append(contentsOf: warningItems.map(\.text))
        return parts.joined(separator: ", ")
    }
}
