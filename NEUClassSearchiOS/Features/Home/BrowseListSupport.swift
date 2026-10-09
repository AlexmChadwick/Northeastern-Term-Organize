//
//  BrowseListSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A quiet count line at the top of a course list ("42 courses · 31 with open seats").
struct BrowseSummaryRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

extension Animation {
    /// The snappy animation used for filter changes; none under Reduce Motion.
    static func browseSnappy(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy
    }
}

/// The chip that toggles "open seats only" in browse lists.
struct BrowseOpenSeatsChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isOn: Bool

    var body: some View {
        GlassChip(title: "Open seats", systemImage: "chair", isOn: isOn) {
            withAnimation(.browseSnappy(reduceMotion: reduceMotion)) { isOn.toggle() }
        }
    }
}

/// Shown over a browse list when the active filters hide every course.
struct BrowseNoMatchesView: View {
    var title = "No matching courses"
    var message: String
    var showsClear: Bool
    var onClear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(message)
        } actions: {
            if showsClear {
                Button("Clear filters", action: onClear)
                    .buttonStyle(.glass)
            }
        }
    }
}

/// A subject's code and name side by side, with an optional detail line under
/// the name. At accessibility text sizes the code stacks above the name so
/// neither gets squeezed.
struct BrowseSubjectLabel: View {
    var subject: Subject
    var detail: String?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var codeWidth: CGFloat = 64

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.m))
        layout {
            Text(subject.code)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: stacked ? nil : codeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(subject.name)
                    .foregroundStyle(.primary)
                    .lineLimit(stacked ? nil : 2)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
