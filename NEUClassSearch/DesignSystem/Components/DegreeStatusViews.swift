//
//  DegreeStatusViews.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Status icon

/// A requirement's status: green check (complete), blue calendar (planned), orange half circle
/// (partly done), empty circle (missing), gray minus (waived).
struct DegreeStatusIcon: View {
    var status: DegreeAudit.Status

    var body: some View {
        Image(systemName: status.degreeSymbol)
            .foregroundStyle(status.degreeColor)
            .accessibilityHidden(true)
    }
}

// MARK: - Credits bar

/// Credits done (green) and planned (blue) out of the program's total.
struct DegreeCreditsBar: View {
    var done: Double
    var planned: Double
    var total: Double?

    var body: some View {
        GeometryReader { proxy in
            let whole = max(total ?? 0, done + planned, 1)
            let doneFraction = min(1, max(0, done) / whole)
            let plannedFraction = min(1 - doneFraction, max(0, planned) / whole)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: proxy.size.width * doneFraction)
                    Rectangle()
                        .fill(Color.blue.opacity(0.55))
                        .frame(width: proxy.size.width * plannedFraction)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Status chip

/// A small capsule in the status column: `Completed`, `Planned · Spring 2027`, `Not in plan`…
/// Prominent chips (in the status color) mark courses that count toward the requirement shown.
struct DegreeStatusChip: View {
    var text: String
    var color: Color
    var isProminent: Bool
    /// Shows that tapping opens a menu.
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            if showsMenuIndicator {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(isProminent ? color : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((isProminent ? color : Color.secondary).opacity(isProminent ? 0.15 : 0.1), in: .capsule)
        .fixedSize()
    }
}

// MARK: - Summary

/// How a plan measures up: program and catalog, a credits bar, how many requirements the plan
/// covers, when it finishes, and (on the plan's card) the first few requirements still open.
struct DegreeRequirementsSummary: View {
    var context: DegreeRequirementsContext
    var audit: DegreeAudit
    /// How many open requirements to list by name (0 for none).
    var openItemLimit = 0
    /// Replaces the green “On track…” line when a semester at or before the finish can't be taken.
    var blockedFinish: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.programTitle)
                    .font(.headline)
                if !context.catalogLine.isEmpty {
                    Text(context.catalogLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            DegreeCreditsBar(done: audit.completedHours, planned: audit.plannedHours, total: audit.requiredHours)
            VStack(alignment: .leading, spacing: 3) {
                Text(DegreeRequirementText.coverageLine(audit))
                    .font(.subheadline.weight(.semibold))
                Text(DegreeRequirementText.creditsLine(audit))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let blockedFinish {
                    Label(blockedFinish, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let milestone = context.milestone {
                    Label(milestone.summaryLine, systemImage: "graduationcap.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            if audit.needsConcentration {
                Label("Choose a concentration to check its requirements", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if openItemLimit > 0 {
                openItems
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// A requirement, or a checked catalog sentence (NUpath…), the plan doesn't meet yet.
    private struct OpenItem: Identifiable {
        var id: String
        var title: String
        var status: DegreeAudit.Status
        var remaining: String?
    }

    /// The open requirements in catalog order, then the open checked sentences: both count.
    private var open: [OpenItem] {
        context.openResults.map { result in
            OpenItem(id: result.id, title: context.name(ofRule: result.rule.id, fallback: result.rule.displayLabel),
                     status: result.status, remaining: DegreeRequirementText.remaining(result))
        }
        + context.openChecks.map { check in
            OpenItem(id: check.id, title: check.title, status: check.status, remaining: check.detail)
        }
    }

    @ViewBuilder
    private var openItems: some View {
        let open = open
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(open.prefix(openItemLimit)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        DegreeStatusIcon(status: item.status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.footnote.weight(.medium))
                            if let remaining = item.remaining {
                                Text(remaining)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(([item.title, item.status.degreeLabel] + [item.remaining].compactMap { $0 }).joined(separator: ", "))
                }
                if open.count > openItemLimit {
                    Text("and \(open.count - openItemLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Milestone

/// A calm note that the plan meets every degree requirement: with the courses done so far, or
/// after a planned semester.
struct DegreeMilestoneBanner: View {
    var milestone: DegreeMilestone
    /// Semesters come after the milestone (they're optional).
    var hasLaterSemesters: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: "graduationcap.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch milestone {
        case .completed: "You’ve completed all degree requirements"
        case .after(_, let name): "All degree requirements met after \(name)"
        }
    }

    private var detail: String? {
        switch milestone {
        case .completed:
            hasLaterSemesters ? "Counting courses in progress. Planned semesters are optional." : "Counting courses in progress."
        case .after:
            hasLaterSemesters ? "Later semesters are optional" : nil
        }
    }
}
