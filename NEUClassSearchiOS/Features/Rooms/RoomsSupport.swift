//
//  RoomsSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Rows

/// One classroom with its status: `RY 210` / `Free until 2:50 PM`.
struct RoomsRoomRow: View {
    var entry: RoomAvailability.Entry
    var moment: RoomAvailability.Moment
    /// Show `RY 210` instead of just `210`.
    var showsBuildingCode = true

    private var title: String { showsBuildingCode ? entry.room.label : entry.room.room }
    private var tint: Color { entry.status.roomsTint(at: moment) }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: entry.status.roomsSymbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(entry.status.summary)
                    .font(.subheadline)
                    // Free rooms are the point of this screen; rooms in use stay quiet.
                    .foregroundStyle(entry.status.isFree ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                if case .busy(let occupancy) = entry.status {
                    Text(occupancy.booking.course.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.room.buildingName) \(entry.room.room), \(entry.status.detailedSummary)")
    }
}

/// The tappable header above a building's rooms.
struct RoomsBuildingHeader: View {
    var item: RoomAvailability.BuildingAvailability
    var campusName: String?
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var subtitle: String {
        [item.building.code, campusName].compactMap { $0 }.joined(separator: " · ")
    }

    private var countTint: Color { item.freeCount == 0 ? .secondary : .green }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        titleBlock
                        countCapsule
                    }
                } else {
                    titleBlock
                    Spacer(minLength: Theme.Spacing.s)
                    countCapsule
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.building.name), \(RoomsText.freeSummary(free: item.freeCount, total: item.roomCount))")
        .accessibilityHint("Opens building")
        .accessibilityAddTraits([.isHeader, .isButton])
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.building.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var countCapsule: some View {
        Text(item.freeCount == 0 ? "None free" : "\(item.freeCount) free")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(countTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(countTint.opacity(0.14), in: .capsule)
    }
}

/// A calm inline notice used for the "typical week" and "outside class hours" messages.
struct RoomsNotice: View {
    var systemImage: String
    var text: String
    var tint: Color = .blue

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Catalog state

/// Shown instead of room data while the catalog is loading, missing or failed.
struct RoomsCatalogUnavailableView: View {
    @Environment(CatalogStore.self) private var catalog

    private var termName: String { catalog.selectedTerm?.name ?? "this term" }

    var body: some View {
        switch catalog.loadState {
        case .idle, .loading, .loaded:
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text("Loading rooms…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .missing:
            ContentUnavailableView {
                Label("No course data yet", systemImage: "arrow.down.circle")
            } description: {
                Text("Download \(termName) from Northeastern to see which rooms are free.")
            } actions: {
                if case .syncing(let progress) = catalog.syncState {
                    VStack(spacing: Theme.Spacing.s) {
                        ProgressView(value: progress.fraction)
                            .frame(maxWidth: 240)
                        Text(progress.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        catalog.syncSelectedTerm()
                    } label: {
                        Text("Download \(termName)").fontWeight(.semibold)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load course data", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button {
                    guard let code = catalog.selectedTermCode else { return }
                    Task { await catalog.select(termCode: code) }
                } label: {
                    Text("Try Again").fontWeight(.semibold)
                }
                .buttonStyle(.glass)
            }
        }
    }
}

/// The catalog index for `termCode`: the selected term's live index when it matches,
/// otherwise loaded on demand (a pushed screen can outlive a change of term).
struct RoomsIndexLoader<Content: View>: View {
    var termCode: String
    @ViewBuilder var content: (CatalogIndex) -> Content

    @Environment(CatalogStore.self) private var catalog
    @State private var loaded: CatalogIndex?
    @State private var didFinishLoading = false

    private var index: CatalogIndex? {
        if let current = catalog.index, current.term.code == termCode { return current }
        return loaded
    }

    var body: some View {
        Group {
            if let index {
                content(index)
            } else if didFinishLoading {
                ContentUnavailableView(
                    "Room data unavailable",
                    systemImage: "door.left.hand.closed",
                    description: Text("There is no course data on this device for that term.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: termCode) {
            if catalog.index?.term.code != termCode {
                loaded = await catalog.index(for: termCode)
            }
            didFinishLoading = true
        }
    }
}
