//
//  CourseSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A set of weekdays. Bit 0 is Sunday through bit 6 Saturday, matching
/// `Calendar.component(.weekday) - 1`.
struct DaySet: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) { self.rawValue = rawValue & 0x7F }

    static let sunday = DaySet(rawValue: 1 << 0)
    static let monday = DaySet(rawValue: 1 << 1)
    static let tuesday = DaySet(rawValue: 1 << 2)
    static let wednesday = DaySet(rawValue: 1 << 3)
    static let thursday = DaySet(rawValue: 1 << 4)
    static let friday = DaySet(rawValue: 1 << 5)
    static let saturday = DaySet(rawValue: 1 << 6)

    static let weekdays: DaySet = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let all = DaySet(rawValue: 0x7F)

    /// Creates a set from day indices where 0 = Sunday ... 6 = Saturday.
    init(indices: some Sequence<Int>) {
        var raw: UInt8 = 0
        for i in indices where (0...6).contains(i) { raw |= 1 << UInt8(i) }
        self.init(rawValue: raw)
    }

    init(day index: Int) { self.init(indices: [index]) }

    func contains(day index: Int) -> Bool {
        (0...6).contains(index) && rawValue & (1 << UInt8(index)) != 0
    }

    /// Day indices (0 = Sunday) in calendar order.
    var indices: [Int] { (0...6).filter { contains(day: $0) } }

    var count: Int { rawValue.nonzeroBitCount }

    /// Compact registrar-style label, e.g. `MWR`, `TF`.
    var compactLabel: String {
        indices.map { DaySet.letters[$0] }.joined()
    }

    /// e.g. `Mon, Wed, Thu`.
    var shortLabel: String {
        indices.map { DaySet.shortNames[$0] }.joined(separator: ", ")
    }

    static let letters = ["U", "M", "T", "W", "R", "F", "S"]
    static let shortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let fullNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    // Encode compactly as the raw bit mask.
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UInt8.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One meeting pattern of a section (e.g. MWR 10:30–11:35 in WVH 210).
struct Meeting: Codable, Hashable, Sendable {
    var days: DaySet
    /// Minutes after midnight, nil when the time is TBA.
    var start: Int?
    /// Minutes after midnight, nil when the time is TBA.
    var end: Int?
    /// Building code, e.g. `WVH`.
    var buildingCode: String?
    /// Building name, e.g. `West Village H`.
    var building: String?
    var room: String?
    /// Campus code, e.g. `BOS`.
    var campusCode: String?
    /// Banner meeting type, e.g. `Class` or `Final Exam`.
    var kind: String
    /// ISO date (yyyy-MM-dd) of the first meeting.
    var startDate: String?
    /// ISO date (yyyy-MM-dd) of the last meeting.
    var endDate: String?

    var isFinalExam: Bool { kind.localizedCaseInsensitiveContains("final") }
    var hasTime: Bool { start != nil && end != nil && !days.isEmpty }

    /// `10:30 – 11:35 AM`.
    var timeLabel: String {
        guard let start, let end else { return "Time TBA" }
        return TimeOfDay.rangeLabel(start: start, end: end)
    }

    /// `WVH 210` or the building name, or `Location TBA`.
    var locationLabel: String {
        let b = buildingCode ?? building
        switch (b, room) {
        case let (b?, r?): return "\(b) \(r)"
        case let (b?, nil): return b
        default: return "Location TBA"
        }
    }

    /// `West Village H 210`.
    var longLocationLabel: String {
        let b = building ?? buildingCode
        switch (b, room) {
        case let (b?, r?): return "\(b) \(r)"
        case let (b?, nil): return b
        default: return "Location TBA"
        }
    }

    var isOnline: Bool {
        let b = (building ?? "") + (buildingCode ?? "")
        return b.localizedCaseInsensitiveContains("online") || campusCode == "VTL"
    }

    var duration: Int? {
        guard let start, let end else { return nil }
        return end - start
    }
}

/// An instructor as listed by Banner.
struct Instructor: Codable, Hashable, Sendable {
    /// Banner display name, usually `Last, First`.
    var name: String
    var primary: Bool
    var email: String?

    /// `First Last`.
    var displayName: String { Instructor.displayName(from: name) }

    static func displayName(from raw: String) -> String {
        let parts = raw.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[1].isEmpty else { return raw.trimmingCharacters(in: .whitespaces) }
        return "\(parts[1]) \(parts[0])"
    }
}

/// A single section (CRN) of a course in a term.
struct CourseSection: Codable, Hashable, Identifiable, Sendable {
    var crn: String
    var subject: String
    var number: String
    /// Section title; equals the course title except for special topics.
    var title: String
    /// Banner sequence number, e.g. `01`.
    var sectionNumber: String
    /// Banner part of term code, e.g. `1` (full term) or `A`.
    var partOfTerm: String
    var seatCapacity: Int
    var seatsRemaining: Int
    var enrollment: Int
    var waitlistCapacity: Int
    var waitlistCount: Int
    var waitlistRemaining: Int
    /// e.g. `Lecture`, `Lab`, `Recitation/Discussion`.
    var classType: String
    var honors: Bool
    /// Campus name, e.g. `Boston` or `Online`.
    var campus: String
    /// e.g. `Traditional`, `Online`, `Hybrid`.
    var instructionMethod: String?
    var meetings: [Meeting]
    /// Nil until faculty has been fetched; empty means TBA.
    var instructors: [Instructor]?
    /// CRNs of other sections cross-listed with this one.
    var crossListCRNs: [String]
    var attributes: [String]
    /// Only set for special topics sections.
    var description: String?
    var prereqs: Requisite?
    var coreqs: Requisite?
    /// Section credit range from Banner. Nil on sections saved before it was kept.
    var creditLow: Double? = nil
    var creditHigh: Double? = nil
    /// Banner's `creditHours` default for this section.
    var creditHours: Double? = nil
    var creditHourIndicator: String? = nil
    /// Nil until `getRestrictions` has been read. An empty list was read and has no restrictions.
    var restrictions: [SectionRestriction]? = nil

    var id: String { crn }

    /// Nil when this section was saved before credit fields were stored.
    var creditSpan: CreditSpan? {
        guard creditLow != nil || creditHigh != nil || creditHours != nil else { return nil }
        let low = creditLow ?? creditHours ?? 0
        let high = creditHigh ?? low
        return CreditSpan(low: low, high: high, bannerDefault: creditHours)
    }

    var isVariableCredit: Bool { creditSpan?.isVariable == true }
    var courseKey: CourseKey { CourseKey(subject: subject, number: number) }

    var isOpen: Bool { seatsRemaining > 0 }
    var hasWaitlist: Bool { waitlistCapacity > 0 }
    var isFull: Bool { seatsRemaining <= 0 }

    /// Fraction of seats taken (0...1).
    var fillFraction: Double {
        guard seatCapacity > 0 else { return 1 }
        return min(1, max(0, Double(seatCapacity - seatsRemaining) / Double(seatCapacity)))
    }

    var isOnline: Bool {
        campus.localizedCaseInsensitiveContains("online")
            || (instructionMethod?.localizedCaseInsensitiveContains("online") ?? false)
    }

    /// Meetings that occur weekly (excludes final exams and TBA times).
    var weeklyMeetings: [Meeting] { meetings.filter { !$0.isFinalExam && $0.hasTime } }

    var finalExam: Meeting? { meetings.first { $0.isFinalExam } }

    /// Every day the section meets weekly.
    var meetingDays: DaySet {
        weeklyMeetings.reduce(into: DaySet()) { $0.formUnion($1.days) }
    }

    /// Instructor names for display, or `TBA`.
    var instructorLabel: String {
        guard let instructors else { return "Instructor unavailable" }
        guard !instructors.isEmpty else { return "TBA" }
        return instructors.sorted { $0.primary && !$1.primary }.map(\.displayName).joined(separator: ", ")
    }

    /// e.g. `MWR 10:30–11:35 AM`, or `Asynchronous` / `TBA`.
    var scheduleSummary: String {
        let weekly = weeklyMeetings
        guard !weekly.isEmpty else { return isOnline ? "Asynchronous / online" : "Times TBA" }
        return weekly.map { "\($0.days.compactLabel) \($0.timeLabel)" }.joined(separator: " · ")
    }

    /// e.g. `12 of 40 seats`.
    var seatsLabel: String {
        "\(max(0, seatsRemaining)) of \(seatCapacity) seats"
    }
}

/// Helpers for minutes-after-midnight values.
enum TimeOfDay {
    /// Converts Banner `HHMM` (e.g. `1435`) to minutes after midnight.
    static func minutes(fromHHMM value: Int) -> Int {
        (value / 100) * 60 + value % 100
    }

    static func hhmm(fromMinutes minutes: Int) -> Int {
        (minutes / 60) * 100 + minutes % 60
    }

    /// `10:30 AM`.
    static func label(_ minutes: Int, includePeriod: Bool = true) -> String {
        let h24 = (minutes / 60) % 24
        let m = minutes % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        let period = h24 < 12 ? "AM" : "PM"
        let base = String(format: "%d:%02d", h12, m)
        return includePeriod ? "\(base) \(period)" : base
    }

    /// `10:30 – 11:35 AM` or `11:45 AM – 1:25 PM`.
    static func rangeLabel(start: Int, end: Int) -> String {
        let samePeriod = (start / 60 < 12) == (end / 60 < 12)
        return "\(label(start, includePeriod: !samePeriod)) – \(label(end))"
    }

    /// `9a`, `12p`, `3p` for compact calendar axes.
    static func hourAxisLabel(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12)\(hour < 12 || hour == 24 ? "a" : "p")"
    }
}

// MARK: - Overlap

extension Meeting {
    /// Whether two meetings share a weekday, overlapping times, and overlapping
    /// date windows. Half-term sections (e.g. Sep–Oct vs Nov–Dec) at the same
    /// time therefore don't conflict.
    func overlaps(with other: Meeting) -> Bool {
        guard let start, let end, let otherStart = other.start, let otherEnd = other.end else { return false }
        guard !days.intersection(other.days).isEmpty, start < otherEnd, otherStart < end else { return false }
        return Meeting.dateWindowsOverlap(startDate, endDate, other.startDate, other.endDate)
    }

    /// ISO (yyyy-MM-dd) date windows intersect; a missing bound is open-ended.
    static func dateWindowsOverlap(_ aStart: String?, _ aEnd: String?, _ bStart: String?, _ bEnd: String?) -> Bool {
        (aStart ?? "0000-00-00") <= (bEnd ?? "9999-99-99") && (bStart ?? "0000-00-00") <= (aEnd ?? "9999-99-99")
    }
}

extension CourseSection {
    /// Whether any weekly meeting of the two sections overlaps (see `Meeting.overlaps(with:)`).
    func conflicts(with other: CourseSection) -> Bool {
        let mine = weeklyMeetings
        let theirs = other.weeklyMeetings
        return mine.contains { a in theirs.contains { a.overlaps(with: $0) } }
    }
}
