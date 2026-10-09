//
//  MacScheduleNoResults.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Explains why no schedule fits and offers one-click ways out: work without a blocking course, move
/// it to another semester of the degree plan, or loosen a rule.
struct MacScheduleNoResultsView: View {
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
        Form {
            heroSection
            worksWithoutSection
            reorderSection
            reasonsSection
            loosenSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            "Change your degree plan?",
            isPresented: Binding(get: { pendingReorder != nil }, set: { if !$0 { pendingReorder = nil } }),
            titleVisibility: .visible,
            presenting: pendingReorder
        ) { option in
            Button("Apply to Degree Plan") { onApplyReorder(option) }
            Button("Cancel", role: .cancel) {}
        } message: { option in
            Text("\(option.title). \(option.scheduleEffect) You can undo it right after.")
        }
    }

    // MARK: Hero

    private var heroSection: some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text(ScheduleNoResultsText.title(for: diagnostics))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(ScheduleNoResultsText.headline(for: diagnostics, blockers: blockers))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Works without \(ScheduleNoResultsText.list(option.courses))")
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ScheduleNoResultsText.detail(of: option, blockers: blockers, termName: termName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(option.courses.count == 1 ? "Make Optional" : "Make All Optional") {
                onMakeOptional(option.courses)
            }
            .accessibilityLabel("Make \(ScheduleNoResultsText.list(option.courses)) optional")
        }
        .padding(.vertical, 2)
    }

    // MARK: Reorder the degree plan

    @ViewBuilder
    private var reorderSection: some View {
        switch reorder {
        case .unavailable(.noDegreePlan):
            if let blockers, !blockers.options.isEmpty {
                Section {
                    Label("Import a degree plan to get suggestions for moving a course to another semester.", systemImage: "graduationcap")
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable(.notApplicable):
            EmptyView()
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking when these courses are usually offered…")
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
                        reorderRow(option)
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

    private func reorderRow(_ option: ScheduleReorderOption) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(option.reasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: ScheduleNoResultsText.isUncertain(reason) ? "questionmark.circle" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if option.addsSemester {
                    Label("Adds a semester to your degree plan", systemImage: "plus.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button("Apply to Degree Plan…") { pendingReorder = option }
        }
        .padding(.vertical, 2)
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
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.title).fontWeight(.semibold)
                            if let detail = reason.detail {
                                Text(detail)
                                    .font(.callout)
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
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.relaxation.title)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                Text(ScheduleNoResultsText.countText(suggestion))
                                    .font(.callout)
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
