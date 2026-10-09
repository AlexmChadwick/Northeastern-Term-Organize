//
//  ScheduleCarouselLayout.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Hour range and day columns shared by every page so the grid stays put while swiping.
struct ScheduleCarouselLayout: Equatable {
    var hours: ClosedRange<Int> = 8...17
    var days: [Int] = [1, 2, 3, 4, 5]

    init() {}

    init(schedules: [GeneratedSchedule], preferences: AppPreferences) {
        var earliest = Int.max, latest = 0
        var weekdays = Set<Int>()
        for schedule in schedules {
            if let start = schedule.earliestStart { earliest = min(earliest, start) }
            if let end = schedule.latestEnd { latest = max(latest, end) }
            for section in schedule.sections {
                for meeting in section.weeklyMeetings { weekdays.formUnion(meeting.days.indices) }
            }
        }
        if earliest == Int.max {
            hours = max(0, preferences.calendarStartHour)...max(preferences.calendarStartHour + 5, min(24, preferences.calendarEndHour))
        } else {
            let lower = max(0, earliest / 60)
            let upper = min(24, max(Int((Double(latest) / 60).rounded(.up)), lower + 5))
            hours = lower...upper
        }
        var columns = [1, 2, 3, 4, 5]
        if preferences.showWeekends || weekdays.contains(6) { columns.append(6) }
        if preferences.showWeekends || weekdays.contains(0) { columns.insert(0, at: 0) }
        days = columns
    }
}
