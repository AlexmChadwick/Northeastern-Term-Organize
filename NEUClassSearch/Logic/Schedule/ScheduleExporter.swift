//
//  ScheduleExporter.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import EventKit
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Export model

/// A class meeting (weekly) or final exam (single) ready to be written to a calendar.
struct ScheduleExportEvent: Hashable, Sendable {
    var uid: String
    var title: String
    var location: String?
    var notes: String
    /// The first day the event happens, in America/New_York.
    var firstDate: DateComponents
    /// Minutes after midnight; nil makes an all-day event.
    var startMinute: Int?
    var endMinute: Int?
    /// Weekdays (0 = Sunday) the event repeats on; empty for a single event.
    var weekdays: [Int] = []
    /// The last day of the repetition, inclusive.
    var lastDate: DateComponents?
    var isFinalExam = false

    var isRecurring: Bool { !weekdays.isEmpty && lastDate != nil }
}

/// What an export contains, for display before the user commits.
struct ScheduleExportSummary: Hashable, Sendable {
    var classCount = 0
    var weeklyMeetings = 0
    var finalExams = 0
    var skippedMeetings = 0
    /// Midnight, in New York, of the last day anything repeats or happens. Format it
    /// in `ScheduleDates.newYork` so it reads as the right day everywhere.
    var lastClassDay: Date?
}

enum ScheduleExportError: LocalizedError {
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .nothingToExport: "There are no scheduled classes to export yet."
        }
    }
}

/// Outcome of adding a schedule to the Calendar app.
enum ScheduleCalendarOutcome: Equatable {
    case added(Int)
    case nothingToAdd
    case denied
    case failed(String)
}

// MARK: - Exporter

enum ScheduleExporter {
    // MARK: Events

    /// One event per weekly meeting of every chosen section, plus final exams.
    static func events(for plan: SchedulePlan, index: CatalogIndex) -> (events: [ScheduleExportEvent], summary: ScheduleExportSummary) {
        let resolved = ResolvedPlan(plan: plan, index: index)
        let calendar = ScheduleDates.newYorkCalendar
        var events: [ScheduleExportEvent] = []
        var summary = ScheduleExportSummary()
        var lastDay: Date?

        for entry in resolved.entries {
            for section in entry.selected {
                summary.classCount += 1
                let code = section.courseKey.description
                let instructors = ScheduleFormat.instructors(of: section)
                var notes = [entry.title.isEmpty ? section.title : entry.title,
                             "CRN \(section.crn) · \(ScheduleFormat.sectionTitle(section))"]
                if let instructors { notes.append("Instructor: \(instructors)") }
                notes.append("Added from Term Organize")

                for (number, meeting) in section.weeklyMeetings.enumerated() {
                    guard let start = meeting.start, let end = meeting.end,
                          let startParts = ScheduleDates.components(fromISO: meeting.startDate),
                          let endParts = ScheduleDates.components(fromISO: meeting.endDate),
                          let startDay = calendar.date(from: startParts),
                          let endDay = calendar.date(from: endParts) else {
                        summary.skippedMeetings += 1
                        continue
                    }
                    let weekdays = meeting.days.indices
                    guard let first = firstDay(onOrAfter: startDay, weekdays: weekdays, calendar: calendar), first <= endDay else {
                        summary.skippedMeetings += 1
                        continue
                    }
                    summary.weeklyMeetings += 1
                    lastDay = max(lastDay ?? endDay, endDay)
                    events.append(ScheduleExportEvent(
                        uid: "\(plan.id.uuidString.lowercased())-\(section.crn)-\(number)@neuclasssearch",
                        title: "\(code) \(section.classType)",
                        location: location(for: meeting, section: section),
                        notes: notes.joined(separator: "\n"),
                        firstDate: calendar.dateComponents([.year, .month, .day], from: first),
                        startMinute: start,
                        endMinute: end,
                        weekdays: weekdays,
                        lastDate: endParts
                    ))
                }

                if let exam = section.finalExam, let examParts = ScheduleDates.components(fromISO: exam.startDate) {
                    summary.finalExams += 1
                    var examNotes = notes
                    examNotes.insert("Final exam", at: 0)
                    let timed = exam.start != nil && exam.end != nil
                    events.append(ScheduleExportEvent(
                        uid: "\(plan.id.uuidString.lowercased())-\(section.crn)-final@neuclasssearch",
                        title: "\(code) Final Exam",
                        location: location(for: exam, section: section),
                        notes: examNotes.joined(separator: "\n"),
                        firstDate: examParts,
                        startMinute: timed ? exam.start : nil,
                        endMinute: timed ? exam.end : nil,
                        isFinalExam: true
                    ))
                    if let day = calendar.date(from: examParts) { lastDay = max(lastDay ?? day, day) }
                }
            }
        }
        summary.lastClassDay = lastDay
        return (events, summary)
    }

    private static func firstDay(onOrAfter start: Date, weekdays: [Int], calendar: Calendar) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        var day = start
        for _ in 0..<7 {
            let weekday = calendar.component(.weekday, from: day) - 1
            if weekdays.contains(weekday) { return day }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    private static func location(for meeting: Meeting, section: CourseSection) -> String? {
        if meeting.isOnline || section.isOnline { return "Online" }
        let label = meeting.longLocationLabel
        return label == "Location TBA" ? nil : label
    }

    // MARK: ICS

    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    /// An RFC 5545 calendar with a VTIMEZONE for America/New_York.
    static func icsString(events: [ScheduleExportEvent], calendarName: String, now: Date = .now) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Term Organize//Schedule//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escape(calendarName))",
            "X-WR-TIMEZONE:America/New_York",
            "BEGIN:VTIMEZONE",
            "TZID:America/New_York",
            "X-LIC-LOCATION:America/New_York",
            "BEGIN:DAYLIGHT",
            "TZOFFSETFROM:-0500",
            "TZOFFSETTO:-0400",
            "TZNAME:EDT",
            "DTSTART:19700308T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
            "END:DAYLIGHT",
            "BEGIN:STANDARD",
            "TZOFFSETFROM:-0400",
            "TZOFFSETTO:-0500",
            "TZNAME:EST",
            "DTSTART:19701101T020000",
            "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
            "END:STANDARD",
            "END:VTIMEZONE",
        ]

        let stamp = utcStamp(now)
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.uid)")
            lines.append("DTSTAMP:\(stamp)")
            if let start = event.startMinute, let end = event.endMinute {
                lines.append("DTSTART;TZID=America/New_York:\(localStamp(event.firstDate, minute: start))")
                lines.append("DTEND;TZID=America/New_York:\(localStamp(event.firstDate, minute: end))")
            } else {
                lines.append("DTSTART;VALUE=DATE:\(dateStamp(event.firstDate))")
                lines.append("DTEND;VALUE=DATE:\(dateStamp(event.firstDate, addingDays: 1))")
            }
            if event.isRecurring, let last = event.lastDate {
                let days = event.weekdays.map { weekdayCodes[$0] }.joined(separator: ",")
                lines.append("RRULE:FREQ=WEEKLY;BYDAY=\(days);UNTIL=\(untilStamp(last))")
            }
            lines.append("SUMMARY:\(escape(event.title))")
            if let location = event.location { lines.append("LOCATION:\(escape(location))") }
            lines.append("DESCRIPTION:\(escape(event.notes))")
            lines.append("TRANSP:OPAQUE")
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Writes the plan's calendar to a temporary `.ics` file.
    static func writeICS(for plan: SchedulePlan, index: CatalogIndex) throws -> URL {
        let (events, _) = events(for: plan, index: index)
        guard !events.isEmpty else { throw ScheduleExportError.nothingToExport }
        let name = "\(plan.name) – \(index.term.name)"
        let text = icsString(events: events, calendarName: name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(name, extension: "ics"))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func fileName(_ name: String, extension ext: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Schedule" : cleaned).\(ext)"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Folds a content line to at most 75 octets per physical line.
    private static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var result = ""
        var current = ""
        var bytes = 0
        var limit = 75
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > limit {
                result += current + "\r\n "
                current = ""
                bytes = 0
                limit = 74
            }
            current.unicodeScalars.append(scalar)
            bytes += size
        }
        return result + current
    }

    private static func dateStamp(_ parts: DateComponents, addingDays days: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ScheduleDates.newYork
        var date = calendar.date(from: parts) ?? .now
        if days != 0 { date = calendar.date(byAdding: .day, value: days, to: date) ?? date }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    private static func localStamp(_ parts: DateComponents, minute: Int) -> String {
        String(format: "%@T%02d%02d00", dateStamp(parts), minute / 60, minute % 60)
    }

    private static func utcStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The end of the last day (23:59:59 in New York) expressed in UTC, as RFC 5545 requires
    /// for a recurrence that starts at a zoned local time.
    private static func untilStamp(_ lastDay: DateComponents) -> String {
        var parts = lastDay
        parts.hour = 23
        parts.minute = 59
        parts.second = 59
        let end = ScheduleDates.newYorkCalendar.date(from: parts) ?? .now
        return utcStamp(end)
    }

    // MARK: Calendar app

    /// Adds the events to the default calendar using write-only access (the app
    /// never reads the user's calendars).
    @MainActor
    static func addToCalendar(_ events: [ScheduleExportEvent]) async -> ScheduleCalendarOutcome {
        guard !events.isEmpty else { return .nothingToAdd }
        let store = EKEventStore()
        do {
            guard try await store.requestWriteOnlyAccessToEvents() else { return .denied }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failed("No calendar is available for new events. Check Calendar settings.")
        }

        let zone = ScheduleDates.newYork
        let newYork = ScheduleDates.newYorkCalendar
        var added = 0
        do {
            for event in events {
                guard let day = newYork.date(from: event.firstDate) else { continue }
                let item = EKEvent(eventStore: store)
                item.calendar = calendar
                item.title = event.title
                item.location = event.location
                item.notes = event.notes
                item.timeZone = zone
                if let start = event.startMinute, let end = event.endMinute,
                   let startDate = newYork.date(bySettingHour: start / 60, minute: start % 60, second: 0, of: day),
                   let endDate = newYork.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: day) {
                    item.startDate = startDate
                    item.endDate = endDate
                } else {
                    // All-day events float: they belong to a date, not a time zone. Read the
                    // date with the Gregorian calendar, never the user's own.
                    item.isAllDay = true
                    item.timeZone = nil
                    let localDay = ScheduleDates.gregorian().date(from: event.firstDate) ?? day
                    item.startDate = localDay
                    item.endDate = localDay
                }
                if event.isRecurring, let last = event.lastDate {
                    var endParts = last
                    endParts.hour = 23
                    endParts.minute = 59
                    endParts.second = 59
                    let weekdays = event.weekdays.compactMap { EKWeekday(rawValue: $0 + 1) }.map { EKRecurrenceDayOfWeek($0) }
                    let end = newYork.date(from: endParts).map { EKRecurrenceEnd(end: $0) }
                    let rule = EKRecurrenceRule(
                        recurrenceWith: .weekly, interval: 1, daysOfTheWeek: weekdays,
                        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                        daysOfTheYear: nil, setPositions: nil, end: end
                    )
                    item.addRecurrenceRule(rule)
                }
                try store.save(item, span: .futureEvents, commit: false)
                added += 1
            }
            try store.commit()
        } catch {
            store.reset()
            return .failed(error.localizedDescription)
        }
        return .added(added)
    }

    // MARK: Image

    /// Renders the schedule picture (3x) as a bitmap. `ImageRenderer` is bound to the main
    /// actor, so this is the one step that has to run there.
    @MainActor
    static func renderCGImage(plan: SchedulePlan, index: CatalogIndex) -> CGImage? {
        imageRenderer(plan: plan, index: index).cgImage
    }

    @MainActor
    private static func imageRenderer(plan: SchedulePlan, index: CatalogIndex) -> ImageRenderer<ScheduleShareImageView> {
        let resolved = ResolvedPlan(plan: plan, index: index)
        let renderer = ImageRenderer(content: ScheduleShareImageView(resolved: resolved, termName: index.term.name))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer
    }

    /// The bitmap as PNG data.
    nonisolated static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

#if canImport(UIKit)
    /// Renders the schedule as an image (3x). `ImageRenderer` is bound to the main
    /// actor, so this is the one step that has to run there.
    @MainActor
    static func renderImage(plan: SchedulePlan, index: CatalogIndex) -> UIImage? {
        imageRenderer(plan: plan, index: index).uiImage
    }

    /// Renders the picture and writes it to a temporary PNG. Only the render itself
    /// touches the main actor; encoding and file I/O run on a background task.
    @MainActor
    static func renderImageFile(plan: SchedulePlan, index: CatalogIndex, name: String) async -> (image: UIImage, url: URL)? {
        guard let image = renderImage(plan: plan, index: index) else { return nil }
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            try? writePNG(image, name: name)
        }.value
        guard let url else { return nil }
        return (image, url)
    }

    nonisolated static func writePNG(_ image: UIImage, name: String) throws -> URL {
        guard let data = image.pngData() else { throw ScheduleExportError.nothingToExport }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(name, extension: "png"))
        try data.write(to: url, options: .atomic)
        return url
    }
#endif
}

// MARK: - Share image

/// The picture shared by "Share as Image": the week plus a legend of every section.
struct ScheduleShareImageView: View {
    var resolved: ResolvedPlan
    var termName: String

    private var showsWeekend: Bool {
        resolved.events.contains { $0.day == 0 || $0.day == 6 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(resolved.plan.name)
                    .font(.title2.weight(.bold))
                Text("\(termName) · \(resolved.creditsLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            WeekCalendarView(
                events: resolved.events,
                showWeekends: showsWeekend,
                hourHeight: 40,
                showsNowIndicator: false
            )

            VStack(alignment: .leading, spacing: 10) {
                ForEach(resolved.entries.filter { !$0.selected.isEmpty }) { entry in
                    ForEach(entry.selected, id: \.crn) { section in
                        legendRow(entry: entry, section: section)
                    }
                }
            }

            Text("Made with Term Organize")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
        .background(Color(red: 0.98, green: 0.98, blue: 0.99))
        .environment(\.colorScheme, .light)
    }

    private func legendRow(entry: ResolvedPlan.Entry, section: CourseSection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.color.stroke)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(section.courseKey.description)
                        .font(.subheadline.weight(.bold))
                    Text(entry.title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                Text("\(ScheduleFormat.sectionTitle(section)) · CRN \(section.crn)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(section.scheduleSummary + (ScheduleFormat.location(of: section).map { " · \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let instructors = ScheduleFormat.instructors(of: section) {
                    Text(instructors)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
