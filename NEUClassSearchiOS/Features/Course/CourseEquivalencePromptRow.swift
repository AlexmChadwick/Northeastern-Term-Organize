//
//  CourseEquivalencePromptRow.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  How the iPhone and iPad draw a question under a requirement. (The questions themselves are chosen
//  and answered by `CourseEquivalencePrompts`, in Logic/Course, shared with the Mac app.)
//

import SwiftUI

extension CourseEquivalencePrompts where Row == CourseEquivalencePromptRow {
    /// The questions for a requirement, drawn as `CourseEquivalencePromptRow`s.
    init(requisite: Requisite) {
        self.init(requisite: requisite) { prompt, confirm, dismiss in
            CourseEquivalencePromptRow(prompt: prompt, onConfirm: confirm, onDismiss: dismiss)
        }
    }
}

/// One question, with the reason it is asked, a button to confirm and a quiet "Dismiss" that
/// turns the guess down for good.
struct CourseEquivalencePromptRow: View {
    var prompt: EquivalencePrompt
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Spacing.m))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("Did \(prompt.taken.description) count as \(prompt.required.description)?")
                    .font(.subheadline.weight(.semibold))
                Text(prompt.evidence)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            if !stacked {
                Spacer(minLength: 0)
            }
            actions(stacked: stacked)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12, style: .continuous))
    }

    /// "Confirm" over "Dismiss" beside the text, so the row stays as short as the question; side by
    /// side under the text once the text is large.
    @ViewBuilder
    private func actions(stacked: Bool) -> some View {
        let confirm = Button("Confirm", action: onConfirm)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Confirm that \(prompt.taken.description) counts as \(prompt.required.description)")
            .accessibilityHint("Saves this to your degree plan")
        let notNow = Button(action: onDismiss) {
            Text("Dismiss")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .accessibilityLabel("Dismiss")
        .accessibilityHint("\(prompt.taken.description) won't be suggested as \(prompt.required.description) again")
        if stacked {
            CourseFlowLayout(spacing: Theme.Spacing.l, lineSpacing: 4) {
                confirm
                notNow
            }
        } else {
            VStack(spacing: 0) {
                confirm
                notNow
            }
        }
    }
}
