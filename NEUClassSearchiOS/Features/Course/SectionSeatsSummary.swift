//
//  SectionSeatsSummary.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The big seat summary on the section page: open, total and enrolled counts,
/// a capacity meter, the waitlist and when the numbers were last refreshed.
struct SectionSeatsSummary: View {
    var section: CourseSection
    var lastUpdated: Date?
    var isRefreshing: Bool
    var refreshFailed: Bool
    var onRefresh: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasSeatData: Bool { section.seatCapacity > 0 || section.seatsRemaining > 0 }
    private var openSeats: Int { max(0, section.seatsRemaining) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Seats") {
                CourseRefreshButton(isRefreshing: isRefreshing, action: onRefresh)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if hasSeatData {
                    stats
                    SeatMeter(remaining: section.seatsRemaining, capacity: section.seatCapacity)
                    notes
                } else {
                    Label("No seat limit is listed for this section.", systemImage: "chair")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                footer
            }
            .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    // MARK: Pieces

    private var stats: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout {
            stat(value: openSeats, label: "open", color: Theme.seatColor(for: section))
            stat(value: section.seatCapacity, label: "total", color: .primary)
            stat(value: section.enrollment, label: "enrolled", color: .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.courseSeatsSpoken), \(section.enrollment) enrolled")
    }

    private func stat(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if section.seatsRemaining < 0 {
                Label("Over capacity by \(-section.seatsRemaining)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if section.hasWaitlist {
                Label(waitlistText, systemImage: "list.number")
                    .foregroundStyle(.secondary)
            } else if section.isFull {
                Label("No waitlist", systemImage: "list.number")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .labelStyle(CourseInfoLabelStyle())
    }

    private var waitlistText: String {
        let spots = CourseFormat.count(max(0, section.waitlistRemaining), "waitlist spot")
        return "Waitlist: \(section.waitlistCount) of \(section.waitlistCapacity) filled · \(spots) open"
    }

    @ViewBuilder
    private var footer: some View {
        if lastUpdated != nil || refreshFailed {
            VStack(alignment: .leading, spacing: 4) {
                if let lastUpdated {
                    CourseUpdatedLabel(date: lastUpdated)
                        .foregroundStyle(.secondary)
                }
                if refreshFailed {
                    Label("Couldn't refresh. Showing saved seat counts.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
        }
    }
}
