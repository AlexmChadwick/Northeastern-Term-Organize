//
//  DegreePlanPreview.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What a plan contains, as rows for a list or form: a summary of the completed
/// courses and one row per semester with its credits and course codes. Used by the
/// import review and the new-plan preview.
struct DegreePlanPreviewRows: View {
    var plan: DegreePlan

    var body: some View {
        LabeledContent {
            Text("\(DegreePlanText.courses(plan.completed.count)) · \(DegreePlanText.credits(plan.completedCredits))")
                .monospacedDigit()
        } label: {
            Label("Completed", systemImage: "checkmark.seal")
        }
        .accessibilityElement(children: .combine)

        if plan.terms.isEmpty {
            Label("No semesters planned yet", systemImage: "calendar")
                .foregroundStyle(.secondary)
        } else {
            ForEach(plan.terms) { term in
                semesterRow(term)
            }
        }
    }

    private func semesterRow(_ term: DegreePlanTerm) -> some View {
        let codes = term.courses.map { $0.key?.description ?? $0.label }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(term.name)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: Theme.Spacing.s)
                Text(DegreePlanText.credits(term.credits))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(codes.isEmpty ? "No courses yet" : codes.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
