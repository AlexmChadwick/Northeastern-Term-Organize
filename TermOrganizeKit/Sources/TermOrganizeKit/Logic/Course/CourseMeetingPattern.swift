//
//  CourseMeetingPattern.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Banner lists some sections as dozens of single-day meeting rows. These
//  helpers fold rows with the same days, times and room into one pattern so the
//  UI (and the calendar, which needs unique event ids) stays readable.
//

import Foundation

/// A distinct weekly meeting pattern of a section.
struct CourseMeetingPattern: Identifiable, Hashable {
    var days: DaySet
    var start: Int?
    var end: Int?
    var buildingCode: String?
    var building: String?
    var room: String?
    var campusCode: String?
    /// Banner meeting type, e.g. `Class`, `Lab`, `Final Exam`.
    var kind: String
    var startDate: String?
    var endDate: String?
    /// Number of Banner meeting rows folded into this pattern.
    var occurrences: Int
    /// True when every folded row was a single dated session (an irregular schedule).
    var isDatedList: Bool

    var id: String {
        "\(days.rawValue)|\(start ?? -1)|\(end ?? -1)|\(buildingCode ?? "")|\(room ?? "")|\(kind)"
    }

    init(_ meeting: Meeting) {
        days = meeting.days
        start = meeting.start
        end = meeting.end
        buildingCode = meeting.buildingCode
        building = meeting.building
        room = meeting.room
        campusCode = meeting.campusCode
        kind = meeting.kind
        startDate = meeting.startDate
        endDate = meeting.endDate
        occurrences = 1
        isDatedList = meeting.startDate != nil && meeting.startDate == meeting.endDate
    }

    mutating func absorb(_ meeting: Meeting) {
        occurrences += 1
        isDatedList = isDatedList && meeting.startDate != nil && meeting.startDate == meeting.endDate
        if let date = meeting.startDate, startDate.map({ date < $0 }) ?? true { startDate = date }
        if let date = meeting.endDate, endDate.map({ date > $0 }) ?? true { endDate = date }
    }

    /// The pattern as a single Banner meeting.
    var meeting: Meeting {
        Meeting(
            days: days,
            start: start,
            end: end,
            buildingCode: buildingCode,
            building: building,
            room: room,
            campusCode: campusCode,
            kind: kind,
            startDate: startDate,
            endDate: endDate
        )
    }

    var hasTime: Bool { start != nil && end != nil && !days.isEmpty }
    var isOnline: Bool { meeting.isOnline }
    var isFinalExam: Bool { meeting.isFinalExam }

    /// `10:30 – 11:35 AM`, or `Time TBA`.
    var timeLabel: String { meeting.timeLabel }

    /// `Cargill Hall 097` (or the short code), `Online`, or `Location TBA`.
    func locationLabel(long: Bool) -> String {
        if isOnline { return "Online" }
        return long ? meeting.longLocationLabel : meeting.locationLabel
    }

    /// `Sep 9 – Dec 13`, or `6 meetings · Sep 14 – Oct 19` for irregular schedules.
    var datesLabel: String? {
        let range = CourseFormat.dateRange(start: startDate, end: endDate)
        guard isDatedList else { return range }
        return [CourseFormat.count(occurrences, "meeting"), range].compactMap { $0 }.joined(separator: " · ")
    }

    /// The building code and room when both are known and the meeting is not online;
    /// `nil` for online, to-be-announced or building-only locations.
    var roomReference: (buildingCode: String, room: String)? {
        guard !isOnline,
              let buildingCode, !buildingCode.trimmingCharacters(in: .whitespaces).isEmpty,
              let room, !room.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (buildingCode, room)
    }

    /// `Monday, Wednesday, Thursday, 10:30 AM to 11:35 AM, Lab` (no location).
    var spokenSchedule: String {
        var parts: [String] = []
        if !days.isEmpty { parts.append(days.indices.map { DaySet.fullNames[$0] }.joined(separator: ", ")) }
        if let start, let end {
            parts.append("\(TimeOfDay.label(start)) to \(TimeOfDay.label(end))")
        } else {
            parts.append("time to be announced")
        }
        if !kind.isEmpty, kind.caseInsensitiveCompare("Class") != .orderedSame { parts.append(kind) }
        return parts.joined(separator: ", ")
    }

    /// `Monday, Wednesday, Thursday, 10:30 AM to 11:35 AM, Cargill Hall 097`.
    func spokenDescription(longLocation: Bool = true) -> String {
        "\(spokenSchedule), \(locationLabel(long: longLocation))"
    }
}

extension CourseSection {
    /// Weekly (non-final) meeting patterns, folded and sorted Monday first.
    var courseMeetingPatterns: [CourseMeetingPattern] {
        var order: [String] = []
        var patterns: [String: CourseMeetingPattern] = [:]
        for meeting in meetings where !meeting.isFinalExam && (!meeting.days.isEmpty || meeting.start != nil) {
            let pattern = CourseMeetingPattern(meeting)
            if var existing = patterns[pattern.id] {
                existing.absorb(meeting)
                patterns[pattern.id] = existing
            } else {
                patterns[pattern.id] = pattern
                order.append(pattern.id)
            }
        }
        return order.compactMap { patterns[$0] }.sorted { lhs, rhs in
            let l = lhs.days.indices.map { ($0 + 6) % 7 }.min() ?? 9
            let r = rhs.days.indices.map { ($0 + 6) % 7 }.min() ?? 9
            if l != r { return l < r }
            return (lhs.start ?? Int.max) < (rhs.start ?? Int.max)
        }
    }

    /// One line for list rows: `MWR 10:30 – 11:35 AM · F 1:00 – 2:00 PM`, or why there is no time.
    var courseScheduleLine: String {
        let timed = courseMeetingPatterns.filter(\.hasTime)
        guard !timed.isEmpty else {
            if isOnline { return "Online · asynchronous" }
            return meetings.isEmpty ? "No scheduled meetings" : "Times to be announced"
        }
        return timed.map { "\($0.days.compactLabel) \($0.timeLabel)" }.joined(separator: " · ")
    }

    /// `courseScheduleLine` as VoiceOver should read it (day names, "to" between times).
    var courseSpokenScheduleLine: String {
        let timed = courseMeetingPatterns.filter(\.hasTime)
        guard !timed.isEmpty else { return courseScheduleLine }
        return timed.map(\.spokenSchedule).joined(separator: "; ")
    }

    /// The final exam, when Banner lists one.
    var courseFinalExamPattern: CourseMeetingPattern? {
        finalExam.map(CourseMeetingPattern.init)
    }
}
