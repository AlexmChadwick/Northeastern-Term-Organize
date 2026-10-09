//
//  DegreePlansSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Degree plan cards plus import / new actions, embedded at the top of the Schedule tab.
///
/// A self-contained stack of cards: it works inside a `ScrollView` or in a List row
/// with a clear background (`.listRowBackground(Color.clear)`, hidden separator).
/// Cards are content (plain surfaces); only controls (the add button and the empty
/// state's buttons) use Liquid Glass.
struct DegreePlansSection: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    @ScaledMetric(relativeTo: .body) private var addButtonSize: CGFloat = 36

    @State private var planToDelete: DegreePlan?
    @State private var planToExport: DegreePlan?
    @State private var haptic = DegreePlanHaptic()

    var body: some View {
        let plans = userData.sortedDegreePlans
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            if plans.isEmpty {
                DegreePlansEmptyCard()
            } else {
                ForEach(plans) { plan in
                    DegreePlanSummaryCard(plan: plan)
                        .contextMenu { contextMenu(for: plan) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            planToDelete.map { "Delete “\($0.name)”?" } ?? "Delete plan?",
            isPresented: Binding(get: { planToDelete != nil }, set: { if !$0 { planToDelete = nil } }),
            titleVisibility: .visible,
            presenting: planToDelete
        ) { plan in
            Button("Delete plan", role: .destructive) { delete(plan) }
        } message: { _ in
            Text("The plan and its semesters will be deleted, and with iCloud sync on, from your other devices too. This can’t be undone.")
        }
        .sheet(item: $planToExport) { plan in
            DegreePlanExportSheet(planID: plan.id)
        }
        .degreePlanHaptic(haptic)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s) {
            Text("Degree plans")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.s)
            Menu {
                Button {
                    router.isDegreePlanImporterPresented = true
                } label: {
                    Label("Import from PDF…", systemImage: "square.and.arrow.down")
                }
                Button {
                    router.isNewDegreePlanPresented = true
                } label: {
                    Label("New degree plan…", systemImage: "plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: addButtonSize, height: addButtonSize)
                    .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Add degree plan")
            .accessibilityHint("Import a PDF or start a new plan")
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for plan: DegreePlan) -> some View {
        if !plan.isPrimary {
            Button {
                userData.setPrimaryDegreePlan(id: plan.id)
                haptic.fire(.success)
            } label: {
                Label("Use for prerequisite checks", systemImage: "star")
            }
        }
        Button {
            planToExport = plan
        } label: {
            Label("Export PDF…", systemImage: "square.and.arrow.up")
        }
        Button {
            duplicate(plan)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) {
            planToDelete = plan
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func duplicate(_ plan: DegreePlan) {
        let copy = DegreePlanEditing.duplicate(plan, existingNames: userData.degreePlans.map(\.name))
        withAnimation { _ = userData.addDegreePlan(copy) }
        haptic.fire(.success)
    }

    private func delete(_ plan: DegreePlan) {
        withAnimation { userData.deleteDegreePlan(id: plan.id) }
        haptic.fire(.warning)
    }
}

// MARK: - Plan card

/// One plan as a content card: name, program, credits, the next semester and a chip per semester.
struct DegreePlanSummaryCard: View {
    var plan: DegreePlan

    private static let chipLimit = 6

    var body: some View {
        let upcoming = plan.degreePlanUpcomingTerms()
        NavigationLink(value: AppRoute.degreePlan(id: plan.id)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s + 2) {
                header
                if plan.isPrimary {
                    TagLabel(text: "Used for prerequisite checks", systemImage: "star.fill", tint: .orange)
                }
                Label(plan.degreePlanCompletedLine, systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(plan.degreePlanNextLine(), systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !upcoming.isEmpty {
                    chips(upcoming)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.l)
            .cardBackground()
            .contentShape(.rect(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityLabel(accessibilitySummary(upcoming: upcoming))
        .accessibilityHint("Opens the plan")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let program = plan.program {
                    Text(program)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
    }

    private func chips(_ upcoming: [DegreePlanTerm]) -> some View {
        let shown = upcoming.prefix(Self.chipLimit)
        return DegreePlanFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(shown)) { term in
                Text("\(term.degreePlanChipName) · \(DegreePlanText.number(term.credits))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: .capsule)
                    .opacity(term.courses.isEmpty ? 0.55 : 1)
            }
            if upcoming.count > Self.chipLimit {
                Text("+\(upcoming.count - Self.chipLimit)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func accessibilitySummary(upcoming: [DegreePlanTerm]) -> String {
        var parts = [plan.name]
        if let program = plan.program { parts.append(program) }
        if plan.isPrimary { parts.append("Used for prerequisite checks") }
        parts.append(plan.degreePlanCompletedLine)
        parts.append(plan.degreePlanNextLine())
        if !upcoming.isEmpty { parts.append("\(DegreePlanText.semesters(upcoming.count)) planned") }
        return parts.joined(separator: ". ").replacingOccurrences(of: " · ", with: ", ")
    }
}

// MARK: - Empty state

/// Shown when there are no degree plans yet: how to get the PDF, and the two ways to start.
struct DegreePlansEmptyCard: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: "graduationcap.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import your degree audit plan")
                        .font(.headline)
                    Text("In the degree audit planner, open your plan, choose View Plan and save the PDF. Then import it here to check prerequisites and autofill schedules.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GlassEffectContainer(spacing: Theme.Spacing.m) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.m) {
                        importButton
                        newPlanButton
                    }
                    VStack(spacing: Theme.Spacing.m) {
                        importButton
                        newPlanButton
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .cardBackground()
    }

    private var importButton: some View {
        Button {
            router.isDegreePlanImporterPresented = true
        } label: {
            // Text only: inside a List row the row tint colors a Label's icon, which would
            // vanish against the prominent (tinted) glass.
            Text("Import PDF")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var newPlanButton: some View {
        Button {
            router.isNewDegreePlanPresented = true
        } label: {
            Text("Start a new plan")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}
