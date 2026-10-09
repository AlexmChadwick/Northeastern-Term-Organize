//
//  DegreePetitionQuestionViews.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Asks whether a petition keeps the minimum course number of the requirement it takes courses
/// like ("Khoury electives start at CS 2500"), with one-tap answers.
struct DegreePetitionQuestionRow: View {
    var question: DegreePetitionQuestion
    var onAnswer: (CourseNumberLimit) -> Void
    /// Opens the petition, to enter a different minimum.
    var onOther: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(question.question)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(question.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.s) { answers }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) { answers }
            }
            .padding(.top, 2)
            Button("A different minimum…", action: onOther)
                .font(.subheadline)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var answers: some View {
        Button("Any course number") { onAnswer(.anyNumber) }
            .buttonStyle(.glassProminent)
        Button("Keep the minimum") { onAnswer(.sameAsRequirement) }
            .buttonStyle(.glass)
    }
}

/// A course of the plan that a short requirement's number limits keep out (CS 2386 for "CS 2500
/// or higher"), with a way to count it there when an adviser approved it.
struct DegreeNearMissRow: View {
    var miss: DegreeAudit.NearMiss
    var title: String?
    var onCount: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(miss.course.key.description) isn’t counted here")
                    .font(.subheadline.weight(.semibold))
                Text([title, miss.reason].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Count it", action: onCount)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityHint("Records that an adviser approved it for this requirement")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Count \(miss.course.key.description) here", onCount)
    }
}
