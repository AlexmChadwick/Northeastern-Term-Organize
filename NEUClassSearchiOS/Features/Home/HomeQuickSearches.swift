//
//  HomeQuickSearches.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Tappable shortcuts that start a search with filters applied, plus the data
/// attribution footer.
struct HomeQuickSearchSection: View {
    @Environment(SearchModel.self) private var searchModel
    @Environment(AppRouter.self) private var router

    /// False while the catalog is unavailable: only the attribution footer remains.
    var showsShortcuts = true

    private var disclaimer: some View {
        Text("Course data from Northeastern University’s public registration system. Not affiliated with Northeastern University or Sandbox.")
            .font(.footnote)
    }

    var body: some View {
        if showsShortcuts {
            Section {
                shortcuts
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                HomeSectionHeader(title: "Quick searches")
            } footer: {
                disclaimer
                    .padding(.top, Theme.Spacing.s)
            }
        } else {
            // Without a catalog there is nothing to search; keep the attribution.
            Section {
                disclaimer
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GlassChipBar {
                ForEach(HomeQuickSearch.allCases) { preset in
                    GlassChip(title: preset.title, systemImage: preset.symbol, isOn: false) {
                        open(preset.filters)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("NUpath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.l)
                    .accessibilityAddTraits(.isHeader)
                GlassChipBar {
                    ForEach(NUPath.allCases) { nupath in
                        GlassChip(title: nupath.short, systemImage: nupath.symbol, isOn: false) {
                            var filters = SearchFilters()
                            filters.nupaths = [nupath]
                            open(filters)
                        }
                        .accessibilityLabel("NUpath \(nupath.name)")
                    }
                }
            }
        }
    }

    /// Replaces the current search with `filters` and switches to the search tab.
    private func open(_ filters: SearchFilters) {
        searchModel.text = ""
        searchModel.filters = filters
        searchModel.sort = .relevance
        router.popToRoot(.search)
        router.selectedTab = .search
    }
}
