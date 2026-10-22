//
//  DegreePlanReorganizeSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Wording shared by the plan screen and the review sheet.
enum DegreePlanReorganizeCopy {
    static var action: String {
        #if os(macOS)
        "Reorganize Plan"
        #else
        "Reorganize plan"
        #endif
    }

    static var title: String {
        #if os(macOS)
        "Reorganize Plan"
        #else
        "Reorganize plan"
        #endif
    }
}

/// The problems on one semester, and the action that proposes a new arrangement.
struct DegreePlanTermWarning: View {
    var report: DegreePlanFeasibility.TermReport
    var onReorganize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(report.problems) { problem in
                Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                    .font(noteFont)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onReorganize) {
                Label(DegreePlanReorganizeCopy.action, systemImage: "arrow.triangle.2.circlepath")
            }
            .font(noteFont.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }

    private var noteFont: Font {
        #if os(macOS)
        .callout
        #else
        .footnote
        #endif
    }
}

/// A review of a whole-plan rearrangement. Nothing in the plan changes until the user accepts
/// the moves they kept.
struct DegreePlanReorganizeSheet: View {
    var plan: DegreePlan
    /// The plan already has a semester the screen knows can't be taken.
    var hasKnownProblem: Bool
    var load: @MainActor () async -> DegreePlanReorganization.Proposal?
    var onAccept: @MainActor ([DegreePlanReorganization.Change]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var selected: Set<String> = []

    private enum Phase {
        case loading
        case proposal(DegreePlanReorganization.Proposal)
        case alreadyWorks
        case unavailable
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    loading
                case .proposal(let proposal):
                    review(proposal)
                case .alreadyWorks:
                    unavailable(
                        title: "These semesters can be taken as planned",
                        systemImage: "checkmark.circle",
                        message: "Nothing needs to move."
                    )
                case .unavailable:
                    unavailable(
                        title: "No arrangement found",
                        systemImage: "exclamationmark.triangle",
                        message: "No rearrangement keeps the degree requirements. Move a course by hand, or add a semester."
                    )
                }
            }
            .navigationTitle(DegreePlanReorganizeCopy.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task { await loadProposal() }
    }

    // MARK: Loading and empty

    private var loading: some View {
        VStack(spacing: Theme.Spacing.m) {
            ProgressView()
            Text("Looking for a way to keep your finish date…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }

    private func unavailable(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }

    // MARK: Review

    private func review(_ proposal: DegreePlanReorganization.Proposal) -> some View {
        let preview = DegreePlanReorganization.applying(selected: selected, of: proposal, to: plan)
        let columns = DegreePlanReorganization.diffs(from: plan, to: preview)
        return List {
            Section {
                outcome(proposal)
            }
            Section {
                ForEach(proposal.changes) { change in
                    Toggle(isOn: binding(for: change.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.headline)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text(change.reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Changes")
            } footer: {
                Text("Turn off a change to leave that course where it is. Nothing changes until you accept.")
            }
            if !columns.isEmpty {
                Section {
                    ForEach(columns) { column in
                        diff(column)
                    }
                } header: {
                    Text("Semesters")
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    private func outcome(_ proposal: DegreePlanReorganization.Proposal) -> some View {
        let delayed = proposal.delaysFinish
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(proposal.outcomeTitle, systemImage: delayed ? "exclamationmark.triangle.fill" : "graduationcap.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(delayed ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = proposal.outcomeDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func diff(_ column: DegreePlanReorganization.TermColumn) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(column.name)
                .font(.headline)
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                courseColumn("Now", column.before, struck: Set(column.before).subtracting(column.after))
                courseColumn("After", column.after, struck: [])
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func courseColumn(_ title: String, _ codes: [String], struck: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if codes.isEmpty {
                Text("No courses")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(codes.enumerated()), id: \.offset) { _, code in
                    Text(code)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(struck.contains(code) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .strikethrough(struck.contains(code))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding {
            selected.contains(id)
        } set: { isOn in
            if isOn { selected.insert(id) } else { selected.remove(id) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(currentAcceptTitle) { acceptCurrent() }
                .disabled(!canAccept)
        }
    }

    private var canAccept: Bool {
        guard case .proposal = phase else { return false }
        return !selected.isEmpty
    }

    private var currentAcceptTitle: String {
        guard case .proposal(let proposal) = phase else { return "Accept" }
        return acceptTitle(proposal)
    }

    private func acceptCurrent() {
        guard case .proposal(let proposal) = phase else { return }
        accept(proposal)
    }

    private func acceptTitle(_ proposal: DegreePlanReorganization.Proposal) -> String {
        if selected.count == proposal.changes.count { return "Accept All" }
        return "Accept \(selected.count)"
    }

    private func accept(_ proposal: DegreePlanReorganization.Proposal) {
        let changes = proposal.changes.filter { selected.contains($0.id) }
        guard !changes.isEmpty else { return }
        onAccept(changes)
        dismiss()
    }

    private func loadProposal() async {
        let proposal = await load()
        if Task.isCancelled { return }
        if let proposal {
            selected = Set(proposal.changes.map(\.id))
            phase = .proposal(proposal)
        } else {
            phase = hasKnownProblem ? .unavailable : .alreadyWorks
        }
    }
}
