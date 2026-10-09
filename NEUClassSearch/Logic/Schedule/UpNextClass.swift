//
//  UpNextClass.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Next class

/// Finds the class to show in the accessory (pure, so it is easy to test).
enum UpNextClass {
    enum Result {
        case `class`(Item)
        /// The term's last class day has passed.
        case termEnded
        /// The primary schedule has no classes with fixed times.
        case noClasses
        /// No primary schedule or catalog yet.
        case unavailable
    }

    struct Item {
        var meeting: WidgetScheduleData.Meeting
        var start: Date
        var end: Date
        var now: Date

        var isInProgress: Bool { start <= now && now < end }

        private var startMinutes: Int { meeting.start }

        /// Whole days from `now` to the class: 0 today, 1 tomorrow…
        private var daysAway: Int {
            let calendar = Calendar.current
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        }

        /// `Tomorrow`, `Mon`, `Sep 9`; nil when the class is today.
        private var dayLabel: String? {
            switch daysAway {
            case ..<1: nil
            case 1: "Tomorrow"
            case 2...6: start.formatted(.dateTime.weekday(.abbreviated))
            default: start.formatted(.dateTime.month(.abbreviated).day())
            }
        }

        private var locationText: String? {
            meeting.location.isEmpty || meeting.location == "Location TBA" ? nil : meeting.location
        }

        /// How much of the sentence to show: `Up next · CS 3000 · 10:30 AM · WVH 210`,
        /// then `CS 3000 · 10:30 AM · WVH 210`, then `CS 3000 · 10:30 AM`.
        enum TextLevel {
            case full, withoutPrefix, compact
        }

        func expandedText(_ level: TextLevel) -> String {
            var parts: [String] = []
            if level == .full { parts.append(isInProgress ? "In class" : "Up next") }
            parts.append(meeting.courseCode)
            parts.append(isInProgress ? "until \(TimeOfDay.label(meeting.end))" : TimeOfDay.label(startMinutes))
            if level != .compact, let locationText { parts.append(locationText) }
            return parts.joined(separator: " · ")
        }

        /// `CS 3000 · 10:30` (or `now`).
        var inlineText: String {
            "\(meeting.courseCode) · \(isInProgress ? "now" : TimeOfDay.label(startMinutes, includePeriod: false))"
        }

        /// `in 25 min`, `in 2h 10m`, `now`, `Tomorrow`, `Mon`, `Sep 9`.
        var relativeText: String {
            let seconds = start.timeIntervalSince(now)
            if seconds <= 0 { return "now" }
            if let dayLabel { return dayLabel }
            let minutes = Int((seconds / 60).rounded(.up))
            if minutes < 60 { return "in \(minutes) min" }
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
        }

        var accessibilityText: String {
            var text = isInProgress ? "In class: " : "Up next: "
            text += "\(meeting.courseCode) \(meeting.classType)"
            text += isInProgress ? ", until \(TimeOfDay.label(meeting.end))" : ", at \(TimeOfDay.label(startMinutes))"
            if let locationText { text += ", \(locationText)" }
            if !isInProgress, let dayLabel { text += ", \(dayLabel)" } else if !isInProgress { text += ", \(relativeText)" }
            return text
        }
    }

    static func find(plan: SchedulePlan?, index: CatalogIndex?, now: Date) -> Result {
        guard let plan, let index, index.term.code == plan.termCode else { return .unavailable }
        let data = ScheduleWidgetBuilder.make(plan: plan, index: index, now: now)
        guard !data.meetings.isEmpty else { return .noClasses }

        let calendar = Calendar.current
        if let end = data.classesEnd, calendar.startOfDay(for: now) > calendar.startOfDay(for: end) {
            return .termEnded
        }
        // Before the term starts, show its first class.
        var anchor = now
        if let start = data.classesStart, start > now { anchor = start }
        guard let next = data.occurrences(from: anchor, limit: 1, calendar: calendar).first else {
            return .noClasses
        }
        return .class(Item(meeting: next.meeting, start: next.start, end: next.end, now: now))
    }
}
