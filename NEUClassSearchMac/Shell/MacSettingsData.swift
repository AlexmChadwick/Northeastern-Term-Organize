//
//  MacSettingsData.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Settings › Data: the course data downloaded from Northeastern, and erasing what the user saved.
struct MacDataSettingsPane: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(CloudSyncStatus.self) private var cloudSync

    @State private var confirmsClearingData = false
    @State private var confirmsErasingUserData = false

    var body: some View {
        Form {
            courseDataSection
            yourDataSection
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Course data

    private var termName: String {
        catalog.selectedTerm?.name ?? "term"
    }

    private var courseDataSection: some View {
        Section {
            LabeledContent("Last updated") {
                if let date = catalog.sectionsUpdatedAt {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .wide))
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
            syncRows
            LabeledContent("Downloaded data") {
                Button("Clear…", role: .destructive) {
                    confirmsClearingData = true
                }
                .disabled(catalog.isSyncing)
                .confirmationDialog(
                    "Clear downloaded data?",
                    isPresented: $confirmsClearingData,
                    titleVisibility: .visible
                ) {
                    Button("Clear Downloaded Data", role: .destructive) {
                        Task { await catalog.clearDownloadedData() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes course data and seat updates downloaded to this Mac. The snapshot that ships with the app stays, so everything keeps working offline.")
                }
            }
        } header: {
            Text("Course Data")
        } footer: {
            Text("Data is downloaded directly from Northeastern's public registration system (nubanner.neu.edu). A snapshot ships with the app so it works offline.")
        }
    }

    @ViewBuilder
    private var syncRows: some View {
        switch catalog.syncState {
        case .idle:
            LabeledContent("Refresh \(termName)") {
                Button("Refresh Now") {
                    catalog.syncSelectedTerm()
                }
                .disabled(catalog.selectedTermCode == nil)
            }
        case .syncing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text("Refreshing \(termName)…")
                ProgressView(value: progress.fraction)
                HStack {
                    Text(progress.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel Refresh") {
                        catalog.cancelSync()
                    }
                    .controlSize(.small)
                }
            }
            .accessibilityElement(children: .contain)
        case .failed(let message):
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Try Again") {
                    catalog.dismissSyncError()
                    catalog.syncSelectedTerm()
                }
                Button("Dismiss") {
                    catalog.dismissSyncError()
                }
            }
        }
    }

    // MARK: Your data

    private var yourDataSection: some View {
        Section {
            LabeledContent("Schedules, watchlist & bookmarks") {
                Button("Erase…", role: .destructive) {
                    confirmsErasingUserData = true
                }
            }
            .confirmationDialog(
                "Erase all schedules, watchlist & bookmarks?",
                isPresented: $confirmsErasingUserData,
                titleVisibility: .visible
            ) {
                Button("Erase Everything", role: .destructive, action: eraseUserData)
                Button("Cancel", role: .cancel) {}
            } message: {
                if cloudSync.erasesICloudData {
                    Text("This removes your schedules, degree plans, watchlist and bookmarks from this Mac and from iCloud, so they're also removed from your other devices. Recent courses and search history on this Mac are cleared too. Your settings are kept. This can't be undone.")
                } else {
                    Text("This removes your schedules, degree plans, watchlist, bookmarks, recent courses and search history from this Mac. Your settings are kept. This can't be undone.")
                }
            }
        } header: {
            Text("Your Data")
        } footer: {
            Text(cloudSync.erasesICloudData
                 ? "Removes everything you saved, on this Mac and in iCloud. Course data isn't affected."
                 : "Removes everything you saved on this Mac. Course data isn't affected.")
        }
    }

    private func eraseUserData() {
        userData.resetAll(keepingPreferences: true)
        // Save now; with iCloud sync on, this also queues the deletions for iCloud right away.
        userData.flushNow()
        WatchlistService.shared.didEraseWatchlist()
    }
}
