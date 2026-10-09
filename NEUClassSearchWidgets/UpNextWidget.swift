//
//  UpNextWidget.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import WidgetKit

/// Shows the next (or current) class from "My Schedule".
struct UpNextWidget: Widget {
    let kind = "UpNext"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleTimelineProvider()) { entry in
            UpNextWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "termorganize://schedule"))
        }
        .configurationDisplayName("Up Next")
        .description("Your next class, where it is, and when it starts.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ScheduleEntry

    var body: some View {
        if entry.data == nil {
            EmptyScheduleView(family: family)
        } else if let next = entry.next {
            switch family {
            case .accessoryInline:
                Text("\(next.meeting.courseCode) \(entry.isInProgress(next) ? "until" : "at") \(WidgetFormat.time(entry.isInProgress(next) ? next.end : next.start))")
            case .accessoryCircular:
                AccessoryCircularView(entry: entry, occurrence: next)
            case .accessoryRectangular:
                AccessoryRectangularView(entry: entry, occurrence: next)
            case .systemMedium:
                MediumUpNextView(entry: entry, occurrence: next)
            default:
                SmallUpNextView(entry: entry, occurrence: next)
            }
        } else {
            NoUpcomingClassesView(family: family, entry: entry)
        }
    }
}

// MARK: - Families

private struct SmallUpNextView: View {
    var entry: ScheduleEntry
    var occurrence: WidgetScheduleData.Occurrence

    var body: some View {
        let color = CourseColor.at(occurrence.meeting.colorIndex)
        VStack(alignment: .leading, spacing: 4) {
            StatusLabel(entry: entry, occurrence: occurrence)
            Spacer(minLength: 0)
            Text(occurrence.meeting.courseCode)
                .font(.title2.weight(.bold))
                .foregroundStyle(color.stroke)
                .widgetAccentable()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(occurrence.meeting.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            Label(occurrence.meeting.location, systemImage: "mappin.and.ellipse")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(WidgetFormat.range(occurrence))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct MediumUpNextView: View {
    var entry: ScheduleEntry
    var occurrence: WidgetScheduleData.Occurrence

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SmallUpNextView(entry: entry, occurrence: occurrence)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                let later = entry.upcoming.dropFirst().prefix(3)
                Text(later.isEmpty ? "Nothing else soon" : "Later")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(later)) { item in
                    AgendaRow(occurrence: item, now: entry.date, showsDay: !Calendar.current.isDate(item.start, inSameDayAs: entry.date))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccessoryRectangularView: View {
    var entry: ScheduleEntry
    var occurrence: WidgetScheduleData.Occurrence

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.isInProgress(occurrence) ? "Now" : "Up Next · \(WidgetFormat.dayLabel(occurrence.start, relativeTo: entry.date))")
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            Text(occurrence.meeting.courseCode)
                .font(.headline)
                .lineLimit(1)
            Text("\(WidgetFormat.time(occurrence.start)) · \(occurrence.meeting.location)")
                .font(.caption)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccessoryCircularView: View {
    var entry: ScheduleEntry
    var occurrence: WidgetScheduleData.Occurrence

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text(occurrence.meeting.courseCode.split(separator: " ").first.map(String.init) ?? "")
                    .font(.system(size: 10, weight: .semibold))
                    .widgetAccentable()
                Text(occurrence.start, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            }
        }
    }
}

// MARK: - Shared pieces

struct StatusLabel: View {
    var entry: ScheduleEntry
    var occurrence: WidgetScheduleData.Occurrence

    var body: some View {
        Group {
            if entry.isInProgress(occurrence) {
                Text("Now · ends \(WidgetFormat.time(occurrence.end))")
            } else if Calendar.current.isDate(occurrence.start, inSameDayAs: entry.date) {
                Text("Up Next · \(WidgetFormat.time(occurrence.start))")
            } else {
                Text("\(WidgetFormat.dayLabel(occurrence.start, relativeTo: entry.date)) · \(WidgetFormat.time(occurrence.start))")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

struct AgendaRow: View {
    var occurrence: WidgetScheduleData.Occurrence
    var now: Date
    var showsDay = false

    var body: some View {
        let color = CourseColor.at(occurrence.meeting.colorIndex)
        let isPast = occurrence.end <= now
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.stroke)
                .frame(width: 4)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(occurrence.meeting.courseCode).font(.caption.weight(.bold))
                    Text(occurrence.meeting.classType).font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text("\(showsDay ? WidgetFormat.dayLabel(occurrence.start, relativeTo: now) + " " : "")\(WidgetFormat.time(occurrence.start)) · \(occurrence.meeting.location)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(isPast ? 0.45 : 1)
    }
}

struct EmptyScheduleView: View {
    var family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("No schedule set")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "calendar.badge.plus")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Term Organize").font(.headline).widgetAccentable()
                Text("Choose My Schedule in the app").font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "calendar.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text("No schedule yet").font(.headline)
                Text("Build a schedule in Term Organize and mark it as My Schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct NoUpcomingClassesView: View {
    var family: WidgetFamily
    var entry: ScheduleEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("No upcoming classes")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "checkmark")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("No upcoming classes").font(.headline)
                Text(entry.data?.termName ?? "").font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sun.max")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text("No upcoming classes").font(.headline)
                Text(entry.data.map { "\($0.planName) · \($0.termName)" } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
