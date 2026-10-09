//
//  TodayScheduleWidget.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import WidgetKit

/// Today's classes as an agenda (falls forward to the next class day when
/// today is done).
struct TodayScheduleWidget: Widget {
    let kind = "TodaySchedule"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleTimelineProvider()) { entry in
            TodayScheduleWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "termorganize://schedule"))
        }
        .configurationDisplayName("Class Agenda")
        .description("Today's classes at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TodayScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ScheduleEntry

    /// The day to show: today if classes remain, otherwise the next class day.
    private var agenda: (label: String, items: [WidgetScheduleData.Occurrence]) {
        if !entry.remainingToday.isEmpty {
            return ("Today", entry.today)
        }
        guard let next = entry.upcoming.first else { return ("Today", []) }
        let items = entry.data?.classes(on: next.start) ?? []
        return (WidgetFormat.dayLabel(next.start, relativeTo: entry.date), items)
    }

    var body: some View {
        if entry.data == nil {
            EmptyScheduleView(family: family)
        } else {
            let agenda = agenda
            let limit = family == .systemLarge ? 7 : 3
            VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agenda.label)
                        .font(.headline)
                        .widgetAccentable()
                    Spacer()
                    Text(entry.data?.planName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if agenda.items.isEmpty {
                    Spacer()
                    Label("No classes coming up", systemImage: "sun.max")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(Array(agenda.items.prefix(limit))) { item in
                        AgendaRow(occurrence: item, now: entry.date)
                    }
                    if agenda.items.count > limit {
                        Text("+\(agenda.items.count - limit) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
