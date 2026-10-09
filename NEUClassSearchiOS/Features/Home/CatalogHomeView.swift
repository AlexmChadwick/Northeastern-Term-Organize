//
//  CatalogHomeView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Root of the Catalog tab: data status, recently viewed and saved courses,
/// directories, and quick searches.
struct CatalogHomeView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppRouter.self) private var router

    var body: some View {
        let index = catalog.readyIndex
        List {
            Section {
                HomeStatusCard()
            }

            if let termCode = catalog.selectedTermCode {
                if let index {
                    HomeRecentsSection(termCode: termCode, index: index)
                    HomeSavedSection(termCode: termCode, index: index)
                }
                HomeBrowseSection(termCode: termCode, index: index)
            }

            HomeQuickSearchSection(showsShortcuts: index != nil)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Catalog")
        .navigationSubtitle(catalog.selectedTerm?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TermMenu()
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .refreshable {
            // Starts the download in the background (progress shows in the status
            // card). Never sync while the selected term is still loading: the
            // store would refresh whatever term it is holding.
            if catalog.readyIndex != nil || catalog.loadState == .missing {
                catalog.syncSelectedTerm()
            }
        }
    }
}
