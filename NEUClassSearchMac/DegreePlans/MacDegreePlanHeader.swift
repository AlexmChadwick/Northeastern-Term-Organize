//
//  MacDegreePlanHeader.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The top of a degree plan: where it came from, the credit totals, whether the plan's
/// prerequisites hold up, whether it's the plan used for prerequisite checks, and next to it
/// how the plan measures up against its degree requirements (unless the requirements are shown
/// beside the plan, where their own pane says it).
struct MacDegreePlanHeader: View {
    var plan: DegreePlan
    var review: DegreePlanReview
    var requirements: DegreeRequirementsContext
    /// The requirements are shown beside the plan, so the card that summarizes them is left out.
    var requirementsAreBeside = false
    /// Notes under the checks: course data still loading, semesters Banner hasn't posted…
    var notes: [String] = []
    var isLoadingCourseData = false
    var onUsePlan: () -> Void
    var onRetryChecks: () -> Void
    var onSetUpRequirements: () -> Void
    var onOpenRequirements: () -> Void
    var onRetryRequirements: () -> Void

    var body: some View {
        Group {
            if requirementsAreBeside {
                // The card alone: in a wide list it sets its two halves side by side.
                planCard(allowsColumns: true)
            } else {
                // Side by side when there is room (the ideal widths decide), else one above the other.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        planCard(allowsColumns: false)
                            .frame(minWidth: 380, idealWidth: 480, maxWidth: .infinity)
                        requirementsCard
                            .frame(width: 340)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        planCard(allowsColumns: false)
                        requirementsCard
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Plan card

    /// - Parameter allowsColumns: when the card is wide, the plan's credits sit beside its checks
    ///   rather than above them.
    private func planCard(allowsColumns: Bool) -> some View {
        Group {
            if allowsColumns {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        planIdentity
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: .infinity, alignment: .leading)
                        Divider()
                        planHealth
                            .frame(minWidth: 300, idealWidth: 340, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        planIdentity
                        planHealth
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    planIdentity
                    planHealth
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.cardFill, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5) }
    }

    /// Where the plan came from and its credits.
    private var planIdentity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.degreePlanSourceLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MacDegreeStatTrio(plan: plan)
        }
    }

    /// Whether the prerequisites hold up, whether the plan serves the checks, and the notes.
    private var planHealth: some View {
        VStack(alignment: .leading, spacing: 12) {
            checks
            primaryRow
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLoadingCourseData {
                Label("Loading course data for prerequisite checks…", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Checks

    @ViewBuilder
    private var checks: some View {
        if review.hasCatalog, review.plannedCourseCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                prerequisiteHeadline
                // Why some courses weren't checked (unless the headline says they're being
                // checked), and a retry when Banner couldn't be reached.
                if review.uncheckedCount > 0, review.missingCount > 0 || review.checkingCount < review.uncheckedCount {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(uncheckedLines, id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if review.failedCount > 0 {
                        Button("Try Again", action: onRetryChecks)
                            .controlSize(.small)
                            .accessibilityLabel("Check prerequisites again")
                    }
                }
                if review.retiredCount > 0 {
                    warning(
                        review.retiredCount == 1
                            ? "1 planned course is no longer offered"
                            : "\(review.retiredCount) planned courses are no longer offered",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                }
                if review.duplicateCount > 0 {
                    warning(
                        review.duplicateCount == 1
                            ? "1 course appears more than once in this plan"
                            : "\(review.duplicateCount) courses appear more than once in this plan",
                        systemImage: "square.on.square"
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func warning(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Missing prerequisites, all good, still checking, or nothing missing among those checked.
    @ViewBuilder
    private var prerequisiteHeadline: some View {
        if review.missingCount > 0 {
            warning(
                review.missingCount == 1
                    ? "1 planned course is missing a prerequisite"
                    : "\(review.missingCount) planned courses are missing prerequisites",
                systemImage: "exclamationmark.triangle.fill"
            )
        } else if review.uncheckedCount == 0 {
            Label("Prerequisites look good", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        } else if review.checkingCount == review.uncheckedCount {
            Label {
                Text("Checking prerequisites…")
            } icon: {
                ProgressView()
                    .controlSize(.small)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
        } else {
            Label("No missing prerequisites", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
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

    // MARK: Primary

    @ViewBuilder
    private var primaryRow: some View {
        if plan.isPrimary {
            VStack(alignment: .leading, spacing: 2) {
                Label("Used for prerequisite checks", systemImage: "star.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Term Organize uses this plan’s completed courses and semesters to check prerequisites and fill in schedules.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            Button(action: onUsePlan) {
                Label("Use for Prerequisite Checks", systemImage: "star")
            }
            .controlSize(.small)
        }
    }

    // MARK: Requirements card

    private var requirementsCard: some View {
        MacDegreeRequirementsCard(
            requirements: requirements,
            onSetUp: onSetUpRequirements,
            onOpen: onOpenRequirements,
            onRetry: onRetryRequirements
        )
    }
}

/// The plan's completed, planned and total credits, as three figures.
struct MacDegreeStatTrio: View {
    var plan: DegreePlan

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            stat(plan.completedCredits, "completed")
            Divider().frame(height: 34)
            stat(plan.plannedCredits, "planned")
            Divider().frame(height: 34)
            stat(plan.completedCredits + plan.plannedCredits, "total")
        }
    }

    private func stat(_ value: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(DegreePlanText.number(value))
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DegreePlanText.number(value)) credits \(label)")
    }
}

/// How a plan measures up against its degree requirements, in a card: a small invitation to set
/// the requirements up, a loading or error state, or a summary (progress, when the plan finishes,
/// what's still open) that opens the full requirements.
struct MacDegreeRequirementsCard: View {
    var requirements: DegreeRequirementsContext
    var onSetUp: () -> Void
    var onOpen: () -> Void
    var onRetry: () -> Void
    /// How many open requirements the summary names.
    var openItemLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if requirements.isSetUp {
                if let audit = requirements.audit {
                    DegreeRequirementsSummary(context: requirements, audit: audit, openItemLimit: openItemLimit)
                    Button("Show Requirements", action: onOpen)
                        .controlSize(.small)
                        .accessibilityHint("Shows every requirement beside the plan")
                } else if let failure = requirements.failure {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(requirements.programTitle)
                            .font(.headline)
                        Label(failure, systemImage: "wifi.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 12) {
                        Button("Try Again", action: onRetry)
                        Button("Change Program or Year…", action: onSetUp)
                    }
                    .controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(requirements.programTitle)
                                .font(.headline)
                            Text("Loading requirements…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Check your degree requirements")
                            .font(.headline)
                        Text("Requirements come from Northeastern’s academic catalog for the year you started. Set them up to see when you’ll finish.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Button("Set Up…", action: onSetUp)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.cardFill, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5) }
    }
}

/// A calm note that the plan meets every degree requirement: with the courses done so far, or
/// after a planned semester. A green band in the plan's list.
struct MacDegreeMilestoneRow: View {
    var milestone: DegreeMilestone
    /// Semesters come after the milestone (they're optional).
    var hasLaterSemesters: Bool

    var body: some View {
        DegreeMilestoneBanner(milestone: milestone, hasLaterSemesters: hasLaterSemesters)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
    }
}
