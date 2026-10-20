//
//  DegreePlanHeaderViews.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The top of a degree plan: where it came from, the credit totals, whether the plan's
/// prerequisites hold up, and whether it's the plan used for prerequisite checks.
struct DegreePlanHeaderCard: View {
    var plan: DegreePlan
    var review: DegreePlanReview
    var onUsePlan: () -> Void
    /// Looks up again the courses whose lookup failed.
    var onRetryChecks: (() -> Void)?
    /// A semester can't be taken as planned. Shown with a way to reorganize the plan.
    var termWarning: String? = nil
    var onReorganize: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(plan.degreePlanSourceLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            totals
            checks
            termWarningRow
            primaryRow
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: Totals

    private var totals: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Credits")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Spacing.l) {
                    stat(plan.completedCredits, "completed")
                    Divider()
                    stat(plan.plannedCredits, "planned")
                    Divider()
                    stat(plan.completedCredits + plan.plannedCredits, "total")
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    stat(plan.completedCredits, "completed")
                    stat(plan.plannedCredits, "planned")
                    stat(plan.completedCredits + plan.plannedCredits, "total")
                }
            }
        }
    }

    private func stat(_ value: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(DegreePlanText.number(value))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DegreePlanText.number(value)) credits \(label)")
    }

    // MARK: Checks

    @ViewBuilder
    private var checks: some View {
        if review.hasCatalog, review.plannedCourseCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                prerequisiteHeadline
                // Why some courses weren't checked (unless the headline says they're being
                // checked), and a retry when Banner couldn't be reached.
                if review.uncheckedCount > 0, review.missingCount > 0 || review.checkingCount < review.uncheckedCount {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(uncheckedLines, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if review.failedCount > 0, let onRetryChecks {
                        Button("Try again", action: onRetryChecks)
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Check prerequisites again")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if review.retiredCount > 0 {
                Label(
                    review.retiredCount == 1
                        ? "1 planned course is no longer offered"
                        : "\(review.retiredCount) planned courses are no longer offered",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if review.duplicateCount > 0 {
                Label(
                    review.duplicateCount == 1
                        ? "1 course appears more than once in this plan"
                        : "\(review.duplicateCount) courses appear more than once in this plan",
                    systemImage: "square.on.square"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Missing prerequisites, all good, still checking, or nothing missing among those checked.
    @ViewBuilder
    private var prerequisiteHeadline: some View {
        if review.missingCount > 0 {
            Label(
                review.missingCount == 1
                    ? "1 planned course is missing a prerequisite"
                    : "\(review.missingCount) planned courses are missing prerequisites",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)
        } else if review.uncheckedCount == 0 {
            Label("Prerequisites look good", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        } else if review.checkingCount == review.uncheckedCount {
            Label {
                Text("Checking prerequisites…")
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        } else {
            Label("No missing prerequisites", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    /// Why some courses weren't checked: still being looked up, Banner unreachable, or not in
    /// Banner's catalog.
    private var uncheckedLines: [String] {
        let notListed = review.uncheckedCount - review.checkingCount - review.failedCount
        var lines: [String] = []
        if review.checkingCount > 0 {
            lines.append(review.checkingCount == 1
                         ? "Checking 1 more course in Banner’s course catalog…"
                         : "Checking \(review.checkingCount) more courses in Banner’s course catalog…")
        }
        if review.failedCount > 0 {
            lines.append(review.failedCount == 1
                         ? "1 course couldn’t be checked because Banner couldn’t be reached."
                         : "\(review.failedCount) courses couldn’t be checked because Banner couldn’t be reached.")
        }
        if notListed > 0 {
            lines.append(notListed == 1
                         ? "1 course couldn’t be checked because Banner’s catalog doesn’t list it."
                         : "\(notListed) courses couldn’t be checked because Banner’s catalog doesn’t list them.")
        }
        return lines
    }

    @ViewBuilder
    private var termWarningRow: some View {
        if let termWarning, let onReorganize {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label(termWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onReorganize) {
                    Label(DegreePlanReorganizeCopy.action, systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: Primary

    @ViewBuilder
    private var primaryRow: some View {
        if plan.isPrimary {
            VStack(alignment: .leading, spacing: 2) {
                Label("Used for prerequisite checks", systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Term Organize uses this plan’s completed courses and semesters to check prerequisites and fill in schedules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            Button(action: onUsePlan) {
                Label("Use for prerequisite checks", systemImage: "star")
            }
            .buttonStyle(.glass)
        }
    }
}

/// The student's name and a masked ID, with a way to remove both. They're only kept so
/// exported PDFs match the degree audit's header.
struct DegreePlanStudentSection: View {
    var plan: DegreePlan
    var onRemove: () -> Void

    @State private var showsID = false

    private static let mask = "•••••••••"

    var body: some View {
        Section {
            if let name = plan.studentName {
                LabeledContent("Name") {
                    Text(name)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let id = plan.studentID {
                LabeledContent("Student ID") {
                    HStack(spacing: Theme.Spacing.m) {
                        Text(showsID ? id : Self.mask)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .accessibilityLabel(showsID ? id : "Hidden")
                        Button(showsID ? "Hide" : "Show") {
                            showsID.toggle()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsID ? "Hide student ID" : "Show student ID")
                    }
                }
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove student info", systemImage: "person.crop.circle.badge.minus")
            }
        } header: {
            Text("Student")
        } footer: {
            Text("Your name and ID are only kept so exported PDFs match your degree audit. They stay on this device and are never uploaded.")
        }
    }
}
