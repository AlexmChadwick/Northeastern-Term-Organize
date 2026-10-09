//
//  ScheduleTimelineProvider.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import WidgetKit

/// A moment in the user's schedule: the next/current class and today's agenda.
struct ScheduleEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has not shared a schedule yet.
    let data: WidgetScheduleData?
    /// Classes that haven't ended yet, starting at `date`.
    let upcoming: [WidgetScheduleData.Occurrence]
    /// All classes on the day of `date`.
    let today: [WidgetScheduleData.Occurrence]

    init(date: Date, data: WidgetScheduleData?) {
        self.date = date
        self.data = data
        upcoming = data?.occurrences(from: date, limit: 8) ?? []
        today = data?.classes(on: date) ?? []
    }

    var next: WidgetScheduleData.Occurrence? { upcoming.first }

    /// Today's classes that haven't ended yet.
    var remainingToday: [WidgetScheduleData.Occurrence] {
        today.filter { $0.end > date }
    }

    func isInProgress(_ occurrence: WidgetScheduleData.Occurrence) -> Bool {
        occurrence.start <= date && occurrence.end > date
    }

    static var sample: ScheduleEntry {
        let calendar = Calendar.current
        let now = Date.now
        let weekday = calendar.component(.weekday, from: now) - 1
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        func meeting(_ code: String, _ title: String, _ location: String, _ type: String, _ offset: Int, _ length: Int, _ color: Int) -> WidgetScheduleData.Meeting {
            let start = min(23 * 60 - length, max(8 * 60, minutes + offset))
            return .init(id: "\(code)-\(offset)", crn: "1234\(color)", courseCode: code, title: title, location: location,
                         classType: type, weekday: weekday, start: start, end: start + length, colorIndex: color)
        }
        let data = WidgetScheduleData(
            generatedAt: now,
            termCode: "202710",
            termName: "Fall 2026",
            planName: "My Schedule",
            classesStart: nil,
            classesEnd: nil,
            meetings: [
                meeting("CS 3000", "Algorithms and Data", "WVH 210", "Lecture", 25, 65, 0),
                meeting("MATH 2331", "Linear Algebra", "RI 300", "Lecture", 110, 65, 1),
                meeting("CS 3001", "Recitation for CS 3000", "SH 125", "Recitation", 195, 65, 2),
            ]
        )
        return ScheduleEntry(date: now, data: data)
    }
}

struct ScheduleTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        if context.isPreview, WidgetScheduleData.load() == nil {
            completion(.sample)
        } else {
            completion(ScheduleEntry(date: .now, data: WidgetScheduleData.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let now = Date.now
        let data = WidgetScheduleData.load()
        let calendar = Calendar.current

        // Refresh at every class boundary so "Up Next" advances, and at midnight.
        var dates: Set<Date> = [now]
        for occurrence in data?.occurrences(from: now, limit: 16) ?? [] {
            if occurrence.start > now { dates.insert(occurrence.start) }
            dates.insert(occurrence.end)
        }
        for dayOffset in 1...2 {
            if let midnight = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) {
                dates.insert(midnight)
            }
        }
        let entries = dates.sorted().prefix(40).map { ScheduleEntry(date: $0, data: data) }
        let reload = entries.last?.date ?? now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: Array(entries), policy: .after(reload)))
    }
}

// MARK: - Formatting helpers

enum WidgetFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func range(_ occurrence: WidgetScheduleData.Occurrence) -> String {
        "\(time(occurrence.start)) – \(time(occurrence.end))"
    }

    /// "Today", "Tomorrow" or a weekday name.
    static func dayLabel(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.wide))
    }
}
