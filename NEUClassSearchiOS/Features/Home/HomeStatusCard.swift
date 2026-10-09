//
//  HomeStatusCard.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The data status card at the top of the catalog home screen: what is on the
/// device, how fresh the seat data is, and the refresh / download controls.
///
/// It adapts to the store's `loadState` and `syncState`: placeholders while
/// loading, a prominent download call to action when the term is missing,
/// progress with cancel while syncing, and retry / dismiss after a failure.
struct HomeStatusCard: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 38
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var termName: String { catalog.selectedTerm?.name ?? "This term" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            content
        }
        .padding(.vertical, Theme.Spacing.xs)
        .animation(reduceMotion ? nil : .default, value: catalog.syncState)
        .animation(reduceMotion ? nil : .default, value: catalog.loadState)
        .sensoryFeedback(trigger: catalog.syncState) { _, new in
            if case .failed = new { return .error }
            return nil
        }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch catalog.syncState {
        case .syncing(let progress):
            syncing(progress)
        case .failed(let message):
            syncFailed(message)
        case .idle:
            idle
        }
    }

    @ViewBuilder
    private var idle: some View {
        switch catalog.loadState {
        case .loaded:
            if let index = catalog.readyIndex {
                loaded(index)
            } else {
                placeholder
            }
        case .loading:
            placeholder
        case .idle:
            if catalog.selectedTermCode == nil { noTerm } else { placeholder }
        case .missing:
            missing
        case .failed(let message):
            loadFailed(message)
        }
    }

    private func loaded(_ index: CatalogIndex) -> some View {
        let term = index.term
        let counts = "\(index.courses.count.formatted()) courses · \(index.catalog.sections.count.formatted()) sections"
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(
                symbol: "books.vertical.fill",
                tint: .accentColor,
                title: term.name,
                subtitle: counts,
                tag: term.isViewOnly ? "View only" : nil
            )
            // One line beside the button when it fits; stacked otherwise, and
            // always stacked at accessibility text sizes.
            TimelineView(.everyMinute) { context in
                let stacked = VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    updatedLabel(index.catalog.sectionsUpdatedAt, now: context.date, isViewOnly: term.isViewOnly)
                    refreshButton
                }
                if dynamicTypeSize.isAccessibilitySize {
                    stacked
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: Theme.Spacing.s) {
                            updatedLabel(index.catalog.sectionsUpdatedAt, now: context.date, isViewOnly: term.isViewOnly)
                                .lineLimit(1)
                            Spacer(minLength: Theme.Spacing.s)
                            refreshButton
                        }
                        stacked
                    }
                }
            }
        }
    }

    private var missing: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(
                symbol: "icloud.and.arrow.down.fill",
                tint: .accentColor,
                title: "\(termName) isn’t on this device",
                subtitle: "Download the course catalog to browse and search. It takes about 30 seconds on Wi-Fi."
            )
            Button {
                catalog.syncSelectedTerm()
            } label: {
                Text("Download \(termName)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private func syncing(_ progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(
                symbol: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                title: "Updating \(termName)",
                subtitle: progress.label,
                isAnimating: true
            )
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("Update progress")
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") {
                    catalog.cancelSync()
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func syncFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Couldn’t update \(termName)",
                subtitle: message
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.s) {
                    retryButton
                    dismissButton
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    retryButton
                    dismissButton
                }
            }
        }
    }

    private func loadFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Couldn’t load the catalog",
                subtitle: message
            )
            if let code = catalog.selectedTermCode {
                Button("Try again") {
                    Task { await catalog.select(termCode: code) }
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var noTerm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if catalog.terms.isEmpty {
                header(
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .gray,
                    title: "Looking for terms…",
                    subtitle: "Checking which terms are available."
                )
                ProgressView()
            } else {
                header(
                    symbol: "calendar",
                    tint: .accentColor,
                    title: "Choose a term",
                    subtitle: "Pick a term to browse its courses."
                )
                TermMenu()
            }
        }
    }

    /// Redacted stand-in while the catalog loads.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header(
                symbol: "books.vertical.fill",
                tint: .gray,
                title: "Fall 2026",
                subtitle: "0,000 courses · 0,000 sections"
            )
            Text("Seats updated recently")
                .font(.subheadline)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading catalog")
    }

    // MARK: Pieces

    private func header(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        tag: String? = nil,
        isAnimating: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .symbolEffect(.pulse, isActive: isAnimating && !reduceMotion)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(title)
                        .font(.headline)
                    if let tag {
                        TagLabel(text: tag, systemImage: "lock.fill")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Seat counts older than a day are flagged so a refresh feels worthwhile.
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    private func updatedLabel(_ date: Date, now: Date, isViewOnly: Bool) -> some View {
        let updated = min(date, now)
        let isStale = !isViewOnly && now.timeIntervalSince(updated) > Self.staleAfter
        return Label {
            Text("Seats updated \(updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
        } icon: {
            if isStale {
                Image(systemName: "clock.badge.exclamationmark")
            }
        }
        .font(.subheadline)
        .foregroundStyle(isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private var refreshButton: some View {
        Button {
            catalog.syncSelectedTerm()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.glass)
        .accessibilityHint("Downloads the latest seat counts")
    }

    private var retryButton: some View {
        Button("Retry") {
            catalog.syncSelectedTerm()
        }
        .buttonStyle(.glassProminent)
    }

    private var dismissButton: some View {
        Button("Dismiss") {
            catalog.dismissSyncError()
        }
        .buttonStyle(.glass)
    }
}
