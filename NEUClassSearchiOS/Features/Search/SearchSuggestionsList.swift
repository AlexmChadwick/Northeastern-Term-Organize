//
//  SearchSuggestionsList.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the search tab shows before anything is typed: recent searches,
/// examples of what can be searched, and the busiest subjects.
struct SearchSuggestionsList: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(SearchModel.self) private var searchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var index: CatalogIndex
    var popularSubjects: [Subject]

    private var examples: [SearchExample] { SearchExampleCache.examples(for: index) }

    var body: some View {
        let history = userData.searchHistory
        List {
            if !history.isEmpty {
                Section {
                    ForEach(history, id: \.self) { term in
                        Button {
                            searchModel.text = term
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    HomeSectionHeader(
                        title: "Recent searches",
                        actionTitle: "Clear",
                        actionAccessibilityLabel: "Clear recent searches"
                    ) {
                        withAnimation(.browseSnappy(reduceMotion: reduceMotion)) { userData.clearSearchHistory() }
                    }
                }
            }

            Section {
                ForEach(examples) { example in
                    Button {
                        searchModel.text = example.title
                    } label: {
                        SearchExampleRow(title: example.title, caption: example.caption, symbol: example.symbol)
                    }
                }
            } header: {
                HomeSectionHeader(title: "Try searching for")
            }

            if !popularSubjects.isEmpty {
                Section {
                    GlassEffectContainer(spacing: Theme.Spacing.s) {
                        SearchFlowLayout(spacing: Theme.Spacing.s) {
                            ForEach(popularSubjects) { subject in
                                GlassChip(title: subject.code, isOn: false) {
                                    searchModel.filters.subjects = [subject.code]
                                }
                                .accessibilityLabel(subject.name)
                                .accessibilityHint("Shows courses in this subject")
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    HomeSectionHeader(title: "Popular subjects")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct SearchExampleRow: View {
    var title: String
    var caption: String
    var symbol: String

    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: tileSize, height: tileSize)
                .background(.tint.opacity(0.14), in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption): \(title)")
        .accessibilityHint("Searches for this")
    }
}

/// Lays children out left to right and wraps them onto new lines.
struct SearchFlowLayout: Layout {
    var spacing: CGFloat = 8

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (positions, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, maxWidth: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let point = CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y)
            subview.place(at: point, proposal: .unspecified)
        }
    }
}
