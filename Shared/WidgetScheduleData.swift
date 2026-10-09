//
//  WidgetScheduleData.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Shared by the app (which writes it) and the widget extension (which reads
//  it) through the app group container.
//

import Foundation

/// The user's primary schedule, flattened into weekly meetings for widgets
/// and the "Up Next" accessory.
struct WidgetScheduleData: Codable, Hashable, Sendable {
    static let appGroupIdentifier = "group.com.alexchadwick.neuclasssearch"
    static let fileName = "WidgetSchedule.json"

    struct Meeting: Codable, Hashable, Sendable, Identifiable {
        /// Unique per weekly occurrence, e.g. `12345-1-630`.
        var id: String
        var crn: String
        /// e.g. `CS 3000`.
        var courseCode: String
        /// e.g. `Algorithms and Data`.
        var title: String
        /// e.g. `WVH 210` or `Online`.
        var location: String
        /// e.g. `Lecture`.
        var classType: String
        /// 0 = Sunday … 6 = Saturday.
        var weekday: Int
        /// Minutes after midnight.
        var start: Int
        var end: Int
        /// Index into `CourseColor.palette`.
        var colorIndex: Int
        /// ISO dates (yyyy-MM-dd) bounding when this meeting happens (half-term
        /// sections, one-off sessions). Nil means "the whole term".
        var startDate: String? = nil
        var endDate: String? = nil

        /// Whether the meeting happens on the calendar day containing `date`.
        func isActive(on date: Date, calendar: Calendar) -> Bool {
            guard startDate != nil || endDate != nil else { return true }
            let iso = WidgetScheduleData.isoDay(date, calendar: calendar)
            if let startDate, iso < startDate { return false }
            if let endDate, iso > endDate { return false }
            return true
        }
    }

    /// `yyyy-MM-dd` for the day containing `date`, always in the Gregorian
    /// calendar (Banner's dates are Gregorian) but in `calendar`'s time zone.
    static func isoDay(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// One concrete upcoming class.
    struct Occurrence: Hashable, Sendable, Identifiable {
        var meeting: Meeting
        var start: Date
        var end: Date
        var id: String { "\(meeting.id)-\(start.timeIntervalSince1970)" }
    }

    var generatedAt: Date
    var termCode: String
    var termName: String
    var planName: String
    /// First and last day classes meet (inclusive), if known.
    var classesStart: Date?
    var classesEnd: Date?
    var meetings: [Meeting]

    // MARK: Persistence

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    static func load() -> WidgetScheduleData? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetScheduleData.self, from: data)
    }

    func save() throws {
        guard let url = WidgetScheduleData.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Queries

    /// Upcoming (or in-progress) classes starting from `date`, in order.
    func occurrences(from date: Date, limit: Int = 10, calendar: Calendar = .current) -> [Occurrence] {
        guard !meetings.isEmpty else { return [] }
        var results: [Occurrence] = []
        let startOfToday = calendar.startOfDay(for: date)
        for dayOffset in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            if let classesEnd, day > calendar.startOfDay(for: classesEnd) { break }
            if let classesStart, day < calendar.startOfDay(for: classesStart) { continue }
            let weekday = calendar.component(.weekday, from: day) - 1
            for meeting in meetings.filter({ $0.weekday == weekday && $0.isActive(on: day, calendar: calendar) }).sorted(by: { $0.start < $1.start }) {
                let start = day.addingTimeInterval(TimeInterval(meeting.start * 60))
                let end = day.addingTimeInterval(TimeInterval(meeting.end * 60))
                guard end > date else { continue }
                results.append(Occurrence(meeting: meeting, start: start, end: end))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    /// Classes on the same calendar day as `date`.
    func classes(on date: Date, calendar: Calendar = .current) -> [Occurrence] {
        let day = calendar.startOfDay(for: date)
        if let classesStart, day < calendar.startOfDay(for: classesStart) { return [] }
        if let classesEnd, day > calendar.startOfDay(for: classesEnd) { return [] }
        let weekday = calendar.component(.weekday, from: day) - 1
        return meetings.filter { $0.weekday == weekday && $0.isActive(on: day, calendar: calendar) }.sorted { $0.start < $1.start }.map {
            Occurrence(meeting: $0, start: day.addingTimeInterval(TimeInterval($0.start * 60)), end: day.addingTimeInterval(TimeInterval($0.end * 60)))
        }
    }
}
