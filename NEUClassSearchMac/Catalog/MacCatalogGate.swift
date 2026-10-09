//
//  MacCatalogGate.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Shows its content once the selected term's catalog is ready, and what is going on otherwise:
/// still loading, not on this Mac yet (with a download button), or failed.
struct MacCatalogGate<Content: View>: View {
    @Environment(CatalogStore.self) private var catalog
    @ViewBuilder var content: (CatalogIndex) -> Content

    var body: some View {
        if let index = catalog.readyIndex {
            content(index)
        } else {
            MacCatalogUnavailable()
        }
    }
}

/// The selected term's catalog isn't available (yet).
struct MacCatalogUnavailable: View {
    @Environment(CatalogStore.self) private var catalog

    private var termName: String { catalog.selectedTerm?.name ?? "This term" }

    var body: some View {
        switch catalog.loadState {
        case .missing:
            download
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load the Catalog", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let code = catalog.selectedTermCode {
                    Button("Try Again") { Task { await catalog.select(termCode: code) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .idle where catalog.selectedTermCode == nil && !catalog.terms.isEmpty:
            ContentUnavailableView {
                Label("Choose a Term", systemImage: "calendar")
            } description: {
                Text("Pick a term to browse and search its courses.")
            } actions: {
                TermMenu()
            }
        case .idle, .loading, .loaded:
            ProgressView(catalog.terms.isEmpty && catalog.selectedTermCode == nil ? "Looking for terms…" : "Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The term's catalog has to be downloaded first; this also shows the download's progress.
    private var download: some View {
        ContentUnavailableView {
            Label("\(termName) Isn't on This Mac", systemImage: "icloud.and.arrow.down")
        } description: {
            switch catalog.syncState {
            case .idle:
                Text("Download the course catalog to browse and search it. This takes about 30 seconds.")
            case .syncing(let progress):
                Text(progress.label)
            case .failed(let message):
                Text(message)
            }
        } actions: {
            switch catalog.syncState {
            case .idle:
                Button("Download \(termName)") { catalog.syncSelectedTerm() }
                    .buttonStyle(.borderedProminent)
            case .syncing(let progress):
                VStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 240)
                    Button("Cancel") { catalog.cancelSync() }
                }
            case .failed:
                HStack {
                    Button("Try Again") { catalog.syncSelectedTerm() }
                        .buttonStyle(.borderedProminent)
                    Button("Dismiss") { catalog.dismissSyncError() }
                }
            }
        }
    }
}

/// The strip under a table: a count on the left, the state of the seat data on the right, and the
/// progress of an update while one runs.
struct MacCatalogStatusBar: View {
    var summary: String
    var showsFreshness = true

    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 12)
            switch catalog.syncState {
            case .syncing(let progress):
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                Text(progress.label)
                    .lineLimit(1)
                Button("Cancel") { catalog.cancelSync() }
                    .buttonStyle(.link)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Button("Dismiss") { catalog.dismissSyncError() }
                    .buttonStyle(.link)
            case .idle:
                if showsFreshness, let updated = catalog.sectionsUpdatedAt {
                    MacCatalogRelativeDateText(date: updated, prefix: "Seats updated")
                        .lineLimit(1)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
