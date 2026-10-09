//
//  BrowseIndexReader.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Whether `BrowseIndexReader` has finished looking for the index of a term
/// other than the selected one. Lets `BrowseIndexUnavailable` end in a
/// terminal "not available" state instead of spinning forever.
private struct BrowseIndexLookupFinishedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var browseIndexLookupFinished: Bool {
        get { self[BrowseIndexLookupFinishedKey.self] }
        set { self[BrowseIndexLookupFinishedKey.self] = newValue }
    }
}

/// Resolves the `CatalogIndex` that belongs to a route's term and hands it to
/// `content` (or `nil` while it is unavailable).
///
/// A route carries its own term code, which can differ from the store's
/// selected term (for example after the term was switched in another tab while
/// this screen stayed on the stack), so this reads the index by that code
/// rather than using `CatalogStore.readyIndex`. The store's current index is
/// read live, so screens update after a sync; any other term is loaded once.
struct BrowseIndexReader<Content: View>: View {
    @Environment(CatalogStore.self) private var catalog
    var termCode: String
    @ViewBuilder var content: (CatalogIndex?) -> Content

    @State private var otherTermIndex: CatalogIndex?
    @State private var lookupFinished = false

    private struct LoadKey: Hashable {
        var termCode: String
        var currentIndexTerm: String?
    }

    private var resolvedIndex: CatalogIndex? {
        if let current = catalog.index, current.term.code == termCode { return current }
        return otherTermIndex
    }

    var body: some View {
        content(resolvedIndex)
            .environment(\.browseIndexLookupFinished, lookupFinished)
            .task(id: LoadKey(termCode: termCode, currentIndexTerm: catalog.index?.term.code)) {
                if catalog.index?.term.code == termCode {
                    otherTermIndex = nil
                    lookupFinished = true
                } else {
                    lookupFinished = false
                    otherTermIndex = await catalog.index(for: termCode)
                    lookupFinished = true
                }
            }
    }
}

/// Shown instead of a screen's content while the term's catalog is loading,
/// missing from the device, or failed to load.
struct BrowseIndexUnavailable: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.browseIndexLookupFinished) private var lookupFinished
    var termCode: String

    var body: some View {
        if termCode == catalog.selectedTermCode {
            switch catalog.loadState {
            case .missing:
                BrowseDownloadPrompt()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t load catalog", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") {
                        Task { await catalog.select(termCode: termCode) }
                    }
                    .buttonStyle(.glassProminent)
                }
            case .idle, .loading, .loaded:
                loading
            }
        } else if lookupFinished {
            ContentUnavailableView(
                "Catalog not available",
                systemImage: "tray",
                description: Text("This term’s catalog isn’t on this device. Switch to a downloaded term to browse it.")
            )
        } else {
            loading
        }
    }

    private var loading: some View {
        ProgressView {
            Text("Loading catalog…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A full-screen call to action for a term whose catalog is not on the device
/// yet, including download progress, cancel and retry.
struct BrowseDownloadPrompt: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var termName: String { catalog.selectedTerm?.name ?? "This term" }

    var body: some View {
        ContentUnavailableView {
            Label("\(termName) isn’t on this device", systemImage: "icloud.and.arrow.down")
        } description: {
            description
        } actions: {
            actions
        }
        .animation(reduceMotion ? nil : .default, value: catalog.syncState)
        .sensoryFeedback(trigger: catalog.syncState) { _, new in
            if case .failed = new { return .error }
            return nil
        }
    }

    @ViewBuilder
    private var description: some View {
        switch catalog.syncState {
        case .idle:
            Text("Download the course catalog to browse and search. It takes about 30 seconds on Wi-Fi.")
        case .syncing(let progress):
            Text(progress.label)
        case .failed(let message):
            Text(message)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch catalog.syncState {
        case .idle:
            Button("Download \(termName)") {
                catalog.syncSelectedTerm()
            }
            .buttonStyle(.glassProminent)
        case .syncing(let progress):
            VStack(spacing: Theme.Spacing.m) {
                ProgressView(value: progress.fraction)
                    .frame(maxWidth: 240)
                Button("Cancel") {
                    catalog.cancelSync()
                }
                .buttonStyle(.glass)
            }
        case .failed:
            HStack {
                Button("Try again") {
                    catalog.syncSelectedTerm()
                }
                .buttonStyle(.glassProminent)
                Button("Dismiss") {
                    catalog.dismissSyncError()
                }
                .buttonStyle(.glass)
            }
        }
    }
}
