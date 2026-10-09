//
//  MacDegreePlanPreview.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What a plan contains, as rows for a form: a summary of the completed courses and one row
/// per semester with its credits and course codes. Used by the import review and the
/// new-plan sheet.
struct MacDegreePlanPreviewRows: View {
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
        MacDegreeSemesterLine(term: term)
    }
}

/// One planned semester in a summary: its name and credits, and the codes of its courses.
struct MacDegreeSemesterLine: View {
    var term: DegreePlanTerm

    var body: some View {
        let codes = term.courses.map { $0.key?.description ?? $0.label }
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(term.name)
                    .fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(DegreePlanText.credits(term.credits))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(codes.isEmpty ? "No courses yet" : codes.joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
