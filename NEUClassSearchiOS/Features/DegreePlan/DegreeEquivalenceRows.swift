//
//  DegreeEquivalenceRows.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Rows

/// A question about courses counting as one another, with two one-tap answers: the equivalence
/// suggestions (Confirm, Dismiss) and a substitution that may be a renumbering.
struct DegreeSuggestionRow: View {
    var question: String
    var detail: String
    var confirmTitle: String
    var confirmLabel: String
    var dismissTitle: String
    var dismissLabel: String
    var onConfirm: () -> Void
    var onDismiss: () -> Void
    /// Sits under the substitute it asks about, in line with it.
    var isIndented = false

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 18

    /// The most a row under a substitute is indented, so large text keeps its width.
    static let maxIndent: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "equal.circle")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(question)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.l) { answers }
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) { answers }
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, isIndented ? min(indent, Self.maxIndent) : 0)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var answers: some View {
        Button(confirmTitle, action: onConfirm)
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel(confirmLabel)
        Button(dismissTitle, action: onDismiss)
            .font(.subheadline)
            .tint(.secondary)
            .accessibilityLabel(dismissLabel)
    }
}

/// A suggested equivalence: the question, why it's suggested, and Confirm or Dismiss.
struct DegreeEquivalencePromptRow: View {
    var prompt: DegreeEquivalencePrompt
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        DegreeSuggestionRow(
            question: prompt.question,
            detail: prompt.evidence,
            confirmTitle: "Confirm",
            confirmLabel: "Confirm that \(prompt.course.description) counts as \(prompt.countsAs.description)",
            dismissTitle: "Dismiss",
            dismissLabel: "Dismiss this suggestion",
            onConfirm: onConfirm,
            onDismiss: onDismiss
        )
    }
}

/// A substitution that is most likely a renumbering ("Is CS 3484 the new number of IS 4800?"),
/// asked the way equivalence suggestions are: one tap makes it the same course under a new number
/// (shown like any renumbered course), the other keeps the substitution.
struct DegreeRenumberingPromptRow: View {
    var prompt: DegreeSubstitutionEditing.LikelyRenumbering
    /// Sits under the substitute it asks about, in line with it.
    var isIndented = false
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        DegreeSuggestionRow(
            question: prompt.question,
            detail: prompt.explanation,
            confirmTitle: "Same course, new number",
            confirmLabel: "\(prompt.course.description) is the same course as \(prompt.countsAs.description), under a new number",
            dismissTitle: "Keep as substitution",
            dismissLabel: "Keep \(prompt.course.description) as a substitution",
            onConfirm: onConfirm,
            onDismiss: onDismiss,
            isIndented: isIndented
        )
    }
}

/// A declared equivalence: `CS 2510 counts as CS 2100`, and its note.
struct DegreeEquivalenceRow: View {
    var equivalence: CourseEquivalence

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(equivalence.course.description) counts as \(equivalence.countsAs.description)")
                .foregroundStyle(Color.primary)
            if let note = equivalence.note.nilIfBlank {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits the equivalence")
    }
}

/// The plan's course equivalences: suggestions to confirm, the ones declared, and a way to add
/// one. Shows nothing until there is something to show (adding one is also in the plan's menu
/// and in each course's context menu).
struct DegreePlanEquivalencesSection: View {
    var plan: DegreePlan
    var prompts: [DegreeEquivalencePrompt]
    var onConfirm: (DegreeEquivalencePrompt) -> Void
    var onDismiss: (DegreeEquivalencePrompt) -> Void
    var onEdit: (CourseEquivalence) -> Void
    var onDelete: (CourseEquivalence) -> Void
    var onAdd: () -> Void

    var body: some View {
        if !plan.courseEquivalences.isEmpty || !prompts.isEmpty {
            Section {
                ForEach(prompts) { prompt in
                    DegreeEquivalencePromptRow(prompt: prompt, onConfirm: { onConfirm(prompt) }, onDismiss: { onDismiss(prompt) })
                }
                ForEach(plan.courseEquivalences) { equivalence in
                    Button {
                        onEdit(equivalence)
                    } label: {
                        DegreeEquivalenceRow(equivalence: equivalence)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDelete(equivalence)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                Button(action: onAdd) {
                    Label("Add course equivalence", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                }
            } header: {
                Text("Course equivalences")
            } footer: {
                Text("Courses that count as one another, like a renumbered course and its new number. Prerequisite checks and degree requirements use them.")
            }
        }
    }
}
