//
//  CourseDescriptionSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The course description, expandable when long, with loading and empty states.
struct CourseDescriptionSection: View {
    var course: Course
    var status: CourseDetailsStatus
    var onRetry: () -> Void

    private var text: String {
        course.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Description")
            content
                .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading where text.isEmpty:
            Text("Loading the course description from Northeastern. This only takes a moment while the details download for the first time.")
                .font(.body)
                .courseShimmer(isActive: true)
        case .unavailable where text.isEmpty:
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("The description couldn't be loaded.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .font(.subheadline.weight(.semibold))
            }
        default:
            if text.isEmpty {
                Text("No description available.")
                    .foregroundStyle(.secondary)
            } else {
                CourseExpandableText(text: text)
            }
        }
    }
}

/// Body text clamped to a few lines with a "More" / "Less" toggle that only
/// appears when the text actually overflows.
///
/// Whether the text overflows is decided by comparing the height an unclamped,
/// invisible copy needs with the height of `collapsedLineCount` lines, so the
/// decision does not depend on the clamped text's own (possibly transient) layout.
struct CourseExpandableText: View {
    var text: String
    var collapsedLineCount = 5

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var lineHeight: CGFloat = 0

    private var isTruncated: Bool {
        lineHeight > 0 && fullHeight > lineHeight * CGFloat(collapsedLineCount) + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .lineLimit(isExpanded ? nil : collapsedLineCount)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) {
                    // Invisible copies measure what the text needs and what one line costs.
                    ZStack(alignment: .topLeading) {
                        Text(text)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CourseFullTextHeightKey.self, value: proxy.size.height)
                            })
                        Text("Mg")
                            .font(.body)
                            .lineLimit(1)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CourseLineHeightKey.self, value: proxy.size.height)
                            })
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(CourseFullTextHeightKey.self) { fullHeight = $0 }
                .onPreferenceChange(CourseLineHeightKey.self) { lineHeight = $0 }
            if isTruncated || isExpanded {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Less" : "More")
                        .font(.subheadline.weight(.semibold))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(isExpanded ? "Show less of the description" : "Show more of the description")
            }
        }
    }
}

private struct CourseFullTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CourseLineHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
