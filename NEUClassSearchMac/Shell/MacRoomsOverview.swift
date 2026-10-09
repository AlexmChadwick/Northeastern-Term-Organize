//
//  MacRoomsOverview.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the details pane of Free Rooms shows while no room is selected: how many of the rooms in the
/// list are free during each hour of the day, and the free rooms that stay free the longest, so the
/// pane has something to offer before a room is picked.
struct MacRoomsOverview: View {
    /// The building, or `All Buildings`.
    var title: String
    /// `15 of 71 rooms free`.
    var summary: String
    /// `Right now · Tuesday at 10:15 AM`.
    var when: String
    /// Every room the list covers, free or in use, for the chart.
    var rooms: [RoomSchedule]
    /// The free rooms that stay free the longest, best first.
    var longest: [MacRoomRow]
    var moment: RoomAvailability.Moment
    /// Whether the rooms are from several buildings, so that the rows name theirs.
    var showsBuilding: Bool
    var onSelect: (MacRoomRow.ID) -> Void

    @State private var counts: [Int] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !rooms.isEmpty {
                    chart
                }
                if !longest.isEmpty {
                    longestRooms
                }
                Text("Select a room in the list to see its classes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: chartKey) {
            let rooms = rooms, weekday = moment.weekday, date = moment.date
            let computed = await Task.detached(priority: .userInitiated) {
                RoomAvailability.freeRoomCounts(of: rooms, on: weekday, date: date)
            }.value
            guard !Task.isCancelled else { return }
            counts = computed
        }
    }

    /// What decides whether the chart has to be worked out again: the rooms and the day (the date
    /// only matters for which classes are running that day).
    private var chartKey: Int {
        var hasher = Hasher()
        for room in rooms { hasher.combine(room.id) }
        hasher.combine(moment.weekday)
        hasher.combine(moment.date.map { Calendar.current.startOfDay(for: $0) })
        return hasher.finalize()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(summary)
                .font(.headline)
                .foregroundStyle(.green)
                .monospacedDigit()
            Text(when)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Chart

    private var currentSlot: Int? {
        guard moment.isWithinClassHours else { return nil }
        return (moment.minutes - RoomAvailability.firstClassMinute) / 60
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free Rooms by Hour")
                .font(.headline)
            MacRoomsHourChart(counts: counts, total: rooms.count, currentSlot: currentSlot)
            HStack(spacing: 14) {
                legend(Color.green.opacity(0.5), outlined: false, "Rooms with no class all hour")
                if currentSlot != nil {
                    legend(Color.green, outlined: true, "Hour in the list")
                }
            }
        }
    }

    private func legend(_ color: Color, outlined: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.2)
                    }
                }
                .frame(width: 9, height: 9)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    // MARK: Longest free

    private var longestRooms: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Free the Longest")
                .font(.headline)
            VStack(spacing: 2) {
                ForEach(longest) { row in
                    MacRoomsLongestRow(row: row, showsBuilding: showsBuilding) { onSelect(row.id) }
                }
            }
        }
    }
}

/// A bar for each hour of the school day: how many rooms are free for all of it.
private struct MacRoomsHourChart: View {
    /// One count for each hour from 7 AM; empty until they are worked out.
    var counts: [Int]
    var total: Int
    /// The hour of the time on screen, when it is within class hours.
    var currentSlot: Int?

    private let barHeight: CGFloat = 96
    private let firstHour = RoomAvailability.firstClassMinute / 60
    private let hours = (RoomAvailability.lastClassMinute - RoomAvailability.firstClassMinute) / 60

    private var shown: [Int] { counts.isEmpty ? Array(repeating: 0, count: hours) : counts }

    var body: some View {
        let peak = max(1, shown.max() ?? 1)
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(shown.indices, id: \.self) { slot in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(slot == currentSlot ? Color.green : Color.green.opacity(0.5))
                        .overlay {
                            if slot == currentSlot {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.5)
                            }
                        }
                        .frame(height: max(2, barHeight * CGFloat(shown[slot]) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .help(tooltip(slot))
                }
            }
            .frame(height: barHeight, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
            }
            HStack(spacing: 3) {
                ForEach(shown.indices, id: \.self) { slot in
                    Text(slot % 2 == 0 ? TimeOfDay.hourAxisLabel(firstHour + slot) : "")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func tooltip(_ slot: Int) -> String {
        let hour = firstHour + slot
        let span = TimeOfDay.rangeLabel(start: hour * 60, end: (hour + 1) * 60)
        return counts.isEmpty ? span : "\(RoomsText.freeSummary(free: shown[slot], total: total)), \(span)"
    }

    private var accessibilitySummary: String {
        guard let peak = shown.max(), peak > 0, let slot = shown.firstIndex(of: peak) else {
            return "Free rooms by hour: none"
        }
        return "Free rooms by hour. Most are free from \(TimeOfDay.rangeLabel(start: (firstHour + slot) * 60, end: (firstHour + slot + 1) * 60)): \(peak) of \(total)."
    }
}

/// A free room in the list of those that stay free the longest: its name, how long it is free, and a
/// click to select it.
private struct MacRoomsLongestRow: View {
    var row: MacRoomRow
    var showsBuilding: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: row.entry.status.roomsSymbol)
                    .foregroundStyle(row.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if showsBuilding {
                        Text(row.buildingName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(row.durationText)
                    .monospacedDigit()
                    .foregroundStyle(row.tint)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHovering ? Color.primary.opacity(0.07) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.room.buildingName) \(row.room.room), \(row.entry.status.detailedSummary)")
        .accessibilityHint("Shows the room's classes")
        .accessibilityAddTraits(.isButton)
    }
}
