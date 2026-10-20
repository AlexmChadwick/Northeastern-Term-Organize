//
//  RoomAvailability.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The "find a free classroom" idea follows SearchNEU's rooms page
//  (https://github.com/sandboxnu/searchneu). The availability rules below are
//  written from scratch for this app.
//

import Foundation

/// Pure helpers that decide whether a classroom is free, and until when, from
/// its weekly bookings. Nothing here touches the UI, the clock or the catalog
/// store, so every function can be reasoned about (and tested) in isolation.
///
/// A booking occupies `start ..< end`: a class ending at 10:05 leaves the room
/// free at 10:05, a class starting at 10:05 makes it busy at 10:05.
enum RoomAvailability {

    // MARK: Moments

    /// A point in a typical week.
    struct Moment: Hashable, Sendable {
        /// 0 = Sunday ... 6 = Saturday.
        var weekday: Int
        /// Minutes after midnight.
        var minutes: Int
        /// The concrete day, when the moment comes from a real date ("Now"). Bookings
        /// are then limited to those whose date window covers it; without a date the
        /// moment describes a typical week and short one-off sessions are ignored.
        var date: Date?

        init(weekday: Int, minutes: Int) {
            self.weekday = ((weekday % 7) + 7) % 7
            self.minutes = min(max(minutes, 0), 24 * 60 - 1)
        }

        init(date: Date, calendar: Calendar = .current) {
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            self.init(weekday: (parts.weekday ?? 1) - 1, minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            self.date = date
        }

        /// Classes are scheduled between 7 AM and 10 PM; outside that buildings are usually locked.
        var isWithinClassHours: Bool {
            minutes >= RoomAvailability.firstClassMinute && minutes < RoomAvailability.lastClassMinute
        }

        /// `Tuesday at 2:30 PM`.
        var label: String {
            "\(DaySet.fullNames[weekday]) at \(TimeOfDay.label(minutes))"
        }
    }

    static let firstClassMinute = 7 * 60
    static let lastClassMinute = 22 * 60

    // MARK: Status

    /// A class that is in progress.
    struct Occupancy: Hashable, Sendable {
        var booking: RoomSchedule.Booking
        /// When the room empties. Back-to-back and overlapping classes are merged.
        var until: Int
        /// When the next class after that starts; nil means free for the rest of the day.
        var freeUntil: Int?
    }

    enum Status: Hashable, Sendable {
        /// No class right now. `until` is when the next class starts today; nil means free for the rest of the day.
        case free(until: Int?)
        case busy(Occupancy)

        var isFree: Bool {
            if case .free = self { return true }
            return false
        }

        /// Minutes from `moment` until the status changes (the rest of the day when free all day).
        func minutesRemaining(at moment: Moment) -> Int {
            switch self {
            case .free(let until): return (until ?? 24 * 60) - moment.minutes
            case .busy(let occupancy): return occupancy.until - moment.minutes
            }
        }

        /// A free room that will be taken within half an hour isn't much use.
        func isFreeOnlyBriefly(at moment: Moment) -> Bool {
            isFree && minutesRemaining(at: moment) < 30
        }

        /// `Free until 2:50 PM`, `Free for the rest of the day` or `In use until 11:35 AM`.
        var summary: String {
            switch self {
            case .free(let until?): "Free until \(TimeOfDay.label(until))"
            case .free(nil): "Free for the rest of the day"
            case .busy(let occupancy): "In use until \(TimeOfDay.label(occupancy.until))"
            }
        }

        /// `In use: CS 3000 until 11:35 AM`, or the same as `summary` for a free room.
        var detailedSummary: String {
            switch self {
            case .free: summary
            case .busy(let occupancy): "In use: \(occupancy.booking.course.description) until \(TimeOfDay.label(occupancy.until))"
            }
        }
    }

    /// A room together with its status at one moment.
    struct Entry: Hashable, Identifiable, Sendable {
        var room: RoomSchedule
        var status: Status
        var id: String { room.id }
    }

    /// Bookings that fall on `weekday`, ordered by start time. Zero-length bookings are ignored.
    /// With a concrete `date`, only bookings whose date window covers it count; otherwise
    /// short one-off sessions (which don't meet every week) are left out.
    static func bookings(of room: RoomSchedule, on weekday: Int, date: Date? = nil) -> [RoomSchedule.Booking] {
        room.bookings
            .filter { $0.days.contains(day: weekday) && $0.end > $0.start }
            .filter { booking in
                if let date { return booking.isActive(on: date) }
                return !booking.isShortSession
            }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func status(of room: RoomSchedule, at moment: Moment) -> Status {
        status(of: bookings(of: room, on: moment.weekday, date: moment.date), at: moment.minutes)
    }

    /// - Parameter day: one weekday's bookings, sorted by start time.
    static func status(of day: [RoomSchedule.Booking], at minutes: Int) -> Status {
        guard let current = day.first(where: { $0.start <= minutes && minutes < $0.end }) else {
            return .free(until: day.first { $0.start > minutes }?.start)
        }
        // Merge classes that run back to back (or overlap) into one stretch of use.
        var until = current.end
        for booking in day where booking.start <= until && booking.end > until {
            until = booking.end
        }
        return .busy(Occupancy(booking: current, until: until, freeUntil: day.first { $0.start >= until }?.start))
    }

    // MARK: Free stretches

    /// The stretches of a day without a class between `start` and `end` (minutes after midnight),
    /// from one weekday's bookings, in order. Back-to-back and overlapping classes leave no gap.
    /// A timeline of the day draws these as the room's free time.
    static func freeStretches(in day: [RoomSchedule.Booking], from start: Int, to end: Int) -> [Range<Int>] {
        guard start < end else { return [] }
        var stretches: [Range<Int>] = []
        var cursor = start
        for booking in day.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if booking.start >= end { break }
            if booking.start > cursor { stretches.append(cursor..<booking.start) }
            cursor = max(cursor, booking.end)
            if cursor >= end { return stretches }
        }
        if cursor < end { stretches.append(cursor..<end) }
        return stretches
    }

    /// How many of `rooms` have no class at all during each whole hour of the school day (7 AM to
    /// 10 PM): `result[0]` is for 7-8 AM, `result[1]` for 8-9 AM and so on. A chart of these shows
    /// when a building is quiet.
    static func freeRoomCounts(of rooms: [RoomSchedule], on weekday: Int, date: Date? = nil) -> [Int] {
        let hours = (lastClassMinute - firstClassMinute) / 60
        var counts = [Int](repeating: 0, count: hours)
        for room in rooms {
            let day = bookings(of: room, on: weekday, date: date)
            for hour in 0..<hours {
                let start = firstClassMinute + hour * 60
                let end = start + 60
                if !day.contains(where: { $0.start < end && $0.end > start }) { counts[hour] += 1 }
            }
        }
        return counts
    }

    // MARK: Buildings

    struct BuildingAvailability: Hashable, Identifiable, Sendable {
        var building: BuildingSummary
        /// Free rooms, longest free stretch first.
        var free: [Entry]
        /// Rooms in use, soonest to empty first.
        var busy: [Entry]
        /// Totals for the whole building, unaffected by search filtering of `free` and `busy`.
        var freeCount: Int
        var roomCount: Int
        var id: String { building.id }

        var busyCount: Int { roomCount - freeCount }
    }

    static func availability(of building: BuildingSummary, at moment: Moment) -> BuildingAvailability {
        var free: [(entry: Entry, order: Int)] = []
        var busy: [(entry: Entry, order: Int)] = []
        for (order, room) in building.rooms.enumerated() {
            let entry = Entry(room: room, status: status(of: room, at: moment))
            if entry.status.isFree { free.append((entry, order)) } else { busy.append((entry, order)) }
        }
        // `building.rooms` is already in natural room-number order, so a room's original
        // position breaks ties without comparing strings (this runs for every room, every minute).
        free.sort { lhs, rhs in
            let l = lhs.entry.status.minutesRemaining(at: moment), r = rhs.entry.status.minutesRemaining(at: moment)
            return l != r ? l > r : lhs.order < rhs.order
        }
        busy.sort { lhs, rhs in
            let l = lhs.entry.status.minutesRemaining(at: moment), r = rhs.entry.status.minutesRemaining(at: moment)
            return l != r ? l < r : lhs.order < rhs.order
        }
        return BuildingAvailability(
            building: building,
            free: free.map(\.entry),
            busy: busy.map(\.entry),
            freeCount: free.count,
            roomCount: building.rooms.count
        )
    }

    static func availability(of buildings: [BuildingSummary], at moment: Moment) -> [BuildingAvailability] {
        buildings.map { availability(of: $0, at: moment) }
    }

    enum BuildingSort: String, CaseIterable, Identifiable, Sendable {
        case mostFree
        case name

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mostFree: "Most Free Rooms"
            case .name: "Name"
            }
        }
    }

    static func sorted(_ items: [BuildingAvailability], by sort: BuildingSort) -> [BuildingAvailability] {
        items.sorted { lhs, rhs in
            switch sort {
            case .mostFree:
                if lhs.freeCount != rhs.freeCount { return lhs.freeCount > rhs.freeCount }
            case .name:
                break
            }
            return lhs.building.name.localizedStandardCompare(rhs.building.name) == .orderedAscending
        }
    }

    // MARK: Searching

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Keeps buildings that match every word of `query` through their name or code,
    /// or that contain rooms matching the remaining words (`ry 210`, `snell`, `210`).
    /// Words match the start of a building's code or of a word in its name ("ry" finds
    /// Ryder Hall but not Snell Library), or anywhere in the name once they have three
    /// letters. When a building matches on its own, all of its rooms stay.
    static func filter(_ items: [BuildingAvailability], matching query: String) -> [BuildingAvailability] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { fold(String($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return items }

        return items.compactMap { item in
            let name = fold(item.building.name)
            let code = fold(item.building.code)
            let nameWords = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let buildingHits = tokens.map { token in
                code.hasPrefix(token)
                    || nameWords.contains { $0.hasPrefix(token) }
                    || (token.count >= 3 && name.contains(token))
            }
            if !buildingHits.contains(false) { return item }

            func matches(_ entry: Entry) -> Bool {
                let number = fold(entry.room.room)
                return tokens.indices.allSatisfy { i in
                    buildingHits[i] || number.hasPrefix(tokens[i]) || (tokens[i].count >= 2 && number.contains(tokens[i]))
                }
            }
            var result = item
            result.free = item.free.filter(matches)
            result.busy = item.busy.filter(matches)
            return result.free.isEmpty && result.busy.isEmpty ? nil : result
        }
    }

    // MARK: Class dates

    /// The stretch of the term during which in-person classes meet.
    struct ClassDates: Hashable, Sendable {
        var start: Date
        var end: Date

        /// Finds the dates most recurring in-person weekly meetings begin and end on.
        /// Banner also lists one-off sessions and half-term sections, so the most
        /// common dates describe the term better than the earliest and latest ones.
        static func derive(from sections: [CourseSection], calendar: Calendar = .current) -> ClassDates? {
            var starts: [String: Int] = [:]
            var ends: [String: Int] = [:]
            for section in sections {
                for meeting in section.weeklyMeetings where !meeting.isOnline {
                    // ISO dates compare correctly as strings; recurring meetings end after they start.
                    guard let first = meeting.startDate, let last = meeting.endDate, first < last else { continue }
                    starts[first, default: 0] += 1
                    ends[last, default: 0] += 1
                }
            }
            func mostCommon(_ counts: [String: Int]) -> String? {
                counts.max { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
                }?.key
            }
            guard let first = mostCommon(starts).flatMap({ date(fromISO: $0, calendar: calendar) }),
                  let last = mostCommon(ends).flatMap({ date(fromISO: $0, calendar: calendar) }),
                  first <= last else { return nil }
            return ClassDates(start: first, end: last)
        }

        /// Whether `date` falls on or between the first and last class day.
        func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
            let day = calendar.startOfDay(for: date)
            return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
        }

        private static func date(fromISO text: String, calendar: Calendar) -> Date? {
            let parts = text.split(separator: "-")
            guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
    }
}
