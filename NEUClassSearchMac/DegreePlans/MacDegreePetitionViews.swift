//
//  MacDegreePetitionViews.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Asks whether a petition keeps the minimum course number of the requirement it takes courses
/// like ("Khoury electives start at CS 2500"), with one-click answers.
struct MacDegreePetitionQuestionRow: View {
    var question: DegreePetitionQuestion
    var onAnswer: (CourseNumberLimit) -> Void
    /// Opens the petition, to enter a different minimum.
    var onOther: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
                Text(question.question)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(question.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            // The answers side by side when there is room, else stacked (the inspector is narrow).
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
        Button("Any Course Number") { onAnswer(.anyNumber) }
            .buttonStyle(.borderedProminent)
        Button("Keep the Minimum") { onAnswer(.sameAsRequirement) }
        Button("A Different Minimum…", action: onOther)
            .buttonStyle(.link)
    }
}

/// A course of the plan that a short requirement's number limits keep out (CS 2386 for "CS 2500
/// or higher"), with a way to count it there when an adviser approved it.
struct MacDegreeNearMissRow: View {
    var miss: DegreeAudit.NearMiss
    var title: String?
    var onCount: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(miss.course.key.description) isn’t counted here")
                    .fontWeight(.semibold)
                Text([title, miss.reason].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Count It Here…", action: onCount)
                .controlSize(.small)
                .help("Records that an adviser approved \(miss.course.key.description) for this requirement")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Count \(miss.course.key.description) here", onCount)
    }
}
