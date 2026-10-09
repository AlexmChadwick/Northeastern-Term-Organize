//
//  HomeComponents.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A bold section header with an optional trailing action ("See all").
struct HomeSectionHeader: View {
    var title: String
    var actionTitle: String?
    /// What VoiceOver announces for the action, e.g. "See all saved courses".
    var actionAccessibilityLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.s)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(actionAccessibilityLabel ?? actionTitle)
            }
        }
        .textCase(nil)
    }
}

/// A list row with a colored symbol tile, a title and an optional trailing
/// detail (a count). Navigation affordances come from the enclosing link.
/// At accessibility text sizes the detail moves under the title so neither
/// gets squeezed.
struct HomeBrowseRow: View {
    var title: String
    var systemImage: String
    var tint: Color
    var detail: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30

    private var tile: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: tileSize, height: tileSize)
            .background(tint.gradient, in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    tile
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(.primary)
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: Theme.Spacing.m) {
                    tile
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer(minLength: Theme.Spacing.s)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A "Jump back in" card for a recently viewed course.
struct HomeRecentCard: View {
    var termCode: String
    var course: Course
    var stats: CourseStats

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledWidth: CGFloat = 176

    /// Grows with text size, but never past what two cards can show on a phone.
    private var cardWidth: CGFloat { min(scaledWidth, 260) }

    private var availabilityColor: Color {
        if stats.sectionCount == 0 { return .secondary }
        if stats.openSectionCount == 0 { return .red }
        return stats.seatsRemaining <= 5 ? .orange : .green
    }

    private var availabilityText: String {
        if stats.sectionCount == 0 { return "No sections" }
        if stats.openSectionCount == 0 { return "Full" }
        return "\(stats.openSectionCount) of \(stats.sectionCount) open"
    }

    var body: some View {
        NavigationLink(value: AppRoute.course(termCode: termCode, key: course.key)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(course.code)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tint)
                    .monospacedDigit()
                Text(course.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? 5 : 2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(availabilityColor)
                        .frame(width: 7, height: 7)
                    Text(availabilityText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .monospacedDigit()
                }
            }
            .padding(Theme.Spacing.m)
            .frame(width: cardWidth, alignment: .topLeading)
            .cardBackground(cornerRadius: 18)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the course")
    }
}
