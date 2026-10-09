//
//  MacDegreeRenumberingViews.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Asks whether a substituted course is really the required course under a new number ("Is
/// CS 3484 the new number of IS 4800?"): a course that a requirement still names but that
/// isn't offered anymore, replaced in the plan by a course approved as a substitution. One click
/// turns the substitution into an equivalence, so the course counts as the old one everywhere
/// (prerequisites included), like any other renumbered course; the other keeps the substitution.
struct MacDegreeRenumberingPromptRow: View {
    var prompt: DegreeSubstitutionEditing.LikelyRenumbering
    var onConvert: () -> Void
    var onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "equal.circle.fill")
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
                Text(prompt.question)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(prompt.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            // The answers side by side when there is room, else stacked (the pane can be narrow).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { answers }
                VStack(alignment: .leading, spacing: 6) { answers }
            }
            .controlSize(.small)
            .padding(.leading, 24)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var answers: some View {
        Button("Same Course, New Number", action: onConvert)
            .buttonStyle(.borderedProminent)
            .help("Count \(prompt.course.description) as \(prompt.countsAs.description) everywhere, like other renumbered courses")
        Button("Keep as Substitution", action: onKeep)
            .help("Leave it as a substitution, and stop asking")
    }
}

extension DegreeSubstitutionEditing.LikelyRenumbering {
    /// A list row's identity, apart from the petition rows that share the substitution's id.
    var rowID: String { "renumber-\(substitution.id.uuidString)" }
}

/// The note in the substitution sheet that offers the same: shown when the substituted course
/// is the required course under a new number.
struct MacDegreeRenumberingNote: View {
    var equivalence: CourseEquivalence
    /// The course isn't offered anymore, so renumbering is the likelier story.
    var isRetired: Bool
    var onConvert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(isRetired
                     ? "\(equivalence.countsAs.description) isn’t offered anymore. Is \(equivalence.course.description) its new number?"
                     : "Is \(equivalence.course.description) the new number of \(equivalence.countsAs.description)?")
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "equal.circle.fill")
                    .foregroundStyle(Color.orange)
            }
            Text("If it’s the same course under a new number, it counts as \(equivalence.countsAs.description) everywhere, prerequisites included, like other renumbered courses, instead of as a substitution.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Same Course, New Number", action: onConvert)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
