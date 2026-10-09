//
//  ScheduleNoResultsView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - View

/// Explains why no schedule fits and offers one-tap ways out: work without a blocking course, move it
/// to another semester of the degree plan, or loosen a rule.
struct ScheduleNoResultsView: View {
    var diagnostics: ScheduleDiagnostics
    /// Nil while the analysis is still running.
    var noResults: ScheduleNoResults?
    var termName: String
    var reorder: ScheduleReorderState
    var onApply: (ScheduleRelaxation) -> Void
    var onMakeOptional: ([CourseKey]) -> Void
    var onApplyReorder: (ScheduleReorderOption) -> Void

    @State private var pendingReorder: ScheduleReorderOption?

    private var blockers: ScheduleBlockerAnalysis? { noResults?.blockers }
    private var suggestions: [ScheduleSuggestion] { noResults?.suggestions ?? [] }

    var body: some View {
        List {
            heroSection
            worksWithoutSection
            reorderSection
            reasonsSection
            loosenSection
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            "Change your degree plan?",
            isPresented: Binding(get: { pendingReorder != nil }, set: { if !$0 { pendingReorder = nil } }),
            titleVisibility: .visible,
            presenting: pendingReorder
        ) { option in
            Button("Apply to degree plan") { onApplyReorder(option) }
            Button("Cancel", role: .cancel) {}
        } message: { option in
            Text("\(option.title). \(option.scheduleEffect) You can undo it right after.")
        }
    }

    // MARK: Hero

    private var title: String { ScheduleNoResultsText.title(for: diagnostics) }

    private var headline: String { ScheduleNoResultsText.headline(for: diagnostics, blockers: blockers) }

    private var heroSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Works without

    @ViewBuilder
    private var worksWithoutSection: some View {
        if let blockers, !blockers.options.isEmpty {
            Section {
                ForEach(blockers.options.prefix(4)) { option in
                    optionRow(option, blockers: blockers)
                }
            } header: {
                Text("Works without")
            } footer: {
                Text("An optional course is only added when it fits.")
            }
        }
    }

    private func optionRow(_ option: ScheduleBlockerOption, blockers: ScheduleBlockerAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Works without \(ScheduleNoResultsText.list(option.courses))")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(ScheduleNoResultsText.detail(of: option, blockers: blockers, termName: termName))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(option.courses.count == 1 ? "Make optional" : "Make all optional") {
                onMakeOptional(option.courses)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(.top, 2)
            .accessibilityLabel("Make \(ScheduleNoResultsText.list(option.courses)) optional")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    // MARK: Reorder the degree plan

    @ViewBuilder
    private var reorderSection: some View {
        switch reorder {
        case .unavailable(.noDegreePlan):
            if let blockers, !blockers.options.isEmpty {
                Section {
                    Label("Import a degree plan to get suggestions for moving a course to another semester.", systemImage: "graduationcap")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable(.notApplicable):
            EmptyView()
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking when these courses are usually offered…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Rearrange your degree plan")
            }
        case .ready(let result):
            if !result.options.isEmpty {
                Section {
                    ForEach(result.options) { option in
                        reorderCard(option)
                    }
                } header: {
                    Text("Rearrange your degree plan")
                } footer: {
                    if !result.historyKnown {
                        Text("Couldn’t check when these courses are usually offered, so the suggestions can’t take that into account.")
                    } else {
                        Text("Based on when these courses have been offered before.")
                    }
                }
            }
        }
    }

    private func reorderCard(_ option: ScheduleReorderOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(option.reasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: ScheduleNoResultsText.isUncertain(reason) ? "questionmark.circle" : "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                if option.addsSemester {
                    Label("Adds a semester to your degree plan", systemImage: "plus.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Button {
                pendingReorder = option
            } label: {
                Text("Apply to degree plan")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: What's in the way

    @ViewBuilder
    private var reasonsSection: some View {
        let items = ScheduleNoResultsText.reasons(for: diagnostics, termName: termName)
        if !items.isEmpty {
            Section("What’s in the way") {
                ForEach(items, id: \.title) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: reason.symbol)
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.title)
                                .font(.subheadline.weight(.semibold))
                            if let detail = reason.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Loosen a rule

    @ViewBuilder
    private var loosenSection: some View {
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions.prefix(5)) { suggestion in
                    Button {
                        onApply(suggestion.relaxation)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: suggestion.relaxation.symbol)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.relaxation.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(ScheduleNoResultsText.countText(suggestion))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.uturn.backward.circle")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(blockers?.options.isEmpty == false ? "Or loosen a rule" : "Try this")
            } footer: {
                Text("Each change on its own would give you schedules.")
            }
        }
    }
}
