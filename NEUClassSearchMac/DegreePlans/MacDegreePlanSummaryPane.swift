//
//  MacDegreePlanSummaryPane.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The selected degree plan in full, beside the list of plans: its credits, how it measures up
/// against its degree requirements (progress, when it finishes, what's still open), and its
/// semesters with their courses. A way to open it sits on top.
struct MacDegreePlanSummaryPane: View {
    /// The plan selected; nil when none or several are.
    var plan: DegreePlan?
    /// How many plans are selected, when it isn't one.
    var selectionCount = 0
    var onOpen: (DegreePlan) -> Void
    var onShowRequirements: (DegreePlan) -> Void
    var onSetUp: (DegreePlan) -> Void

    var body: some View {
        if let plan {
            MacDegreePlanSummary(planID: plan.id, onOpen: onOpen, onShowRequirements: onShowRequirements, onSetUp: onSetUp)
                // Another plan is another summary: what it loaded starts over.
                .id(plan.id)
        } else {
            ContentUnavailableView {
                Label(selectionCount > 1 ? "\(selectionCount) Plans Selected" : "No Plan Selected", systemImage: "graduationcap")
            } description: {
                Text("Select a plan to see its credits, requirements and semesters.")
            }
        }
    }
}

private struct MacDegreePlanSummary: View {
    var planID: UUID
    var onOpen: (DegreePlan) -> Void
    var onShowRequirements: (DegreePlan) -> Void
    var onSetUp: (DegreePlan) -> Void

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog

    /// Remembers the requirements audit and finish milestone between updates.
    @State private var cache = DegreeRequirementsCache()

    /// Banner's course catalog: equivalences, and the NUpath attributes the requirements check.
    private var info: CourseInfoStore { .shared }

    var body: some View {
        if let plan = userData.degreePlan(id: planID) {
            content(plan)
        }
    }

    private func requirementsKey(_ plan: DegreePlan) -> String {
        "\(plan.catalogYear ?? 0)|\(plan.catalogProgramPath ?? "")"
    }

    private struct CourseInfoKey: Hashable {
        var updatedAt: Date?
        var termCodes: [String]
    }

    private func courseInfoKey(_ plan: DegreePlan) -> CourseInfoKey {
        CourseInfoKey(updatedAt: plan.updatedAt, termCodes: catalog.degreePlanSnapshot().indexes.map(\.term.code))
    }

    private func content(_ plan: DegreePlan) -> some View {
        // The same requirements the plan's own page shows, so the two never disagree.
        let requirements = programCatalog.degreeRequirementsContext(
            for: plan, cache: cache, equivalences: info.equivalences(for: plan), includesMilestone: true
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(plan)
                MacDegreeStatTrio(plan: plan)
                MacDegreeRequirementsCard(
                    requirements: requirements,
                    onSetUp: { onSetUp(plan) },
                    onOpen: { onShowRequirements(plan) },
                    onRetry: { Task { await programCatalog.loadRequirements(for: plan, forceRefresh: true) } },
                    openItemLimit: 5
                )
                semesters(plan)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: requirementsKey(plan)) {
            await catalog.degreePlanLoadLocalCatalogs(for: plan)
            if plan.catalogProgramPath != nil {
                await programCatalog.loadRequirements(for: plan)
            }
        }
        .task(id: courseInfoKey(plan)) {
            await info.degreePlanLoad(plan, indexes: catalog.degreePlanSnapshot().indexes)
        }
    }

    // MARK: Header

    private func header(_ plan: DegreePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.name)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.degreePlanSourceLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if plan.isPrimary {
                    TagLabel(text: "Used for prerequisite checks", systemImage: "star.fill", tint: .orange)
                        .fixedSize()
                }
            }
            Button("Open Plan") { onOpen(plan) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 2)
        }
    }

    // MARK: Semesters

    private func semesters(_ plan: DegreePlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Semesters")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                LabeledContent {
                    Text("\(DegreePlanText.courses(plan.completed.count)) · \(DegreePlanText.credits(plan.completedCredits))")
                        .monospacedDigit()
                } label: {
                    Label("Completed", systemImage: "checkmark.seal")
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                ForEach(plan.terms) { term in
                    Divider()
                    MacDegreeSemesterLine(term: term)
                        .padding(.vertical, 8)
                }
                if plan.terms.isEmpty {
                    Divider()
                    Label("No semesters planned yet", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}
