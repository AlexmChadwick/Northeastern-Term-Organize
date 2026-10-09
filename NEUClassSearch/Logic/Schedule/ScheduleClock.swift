//
//  ScheduleClock.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Converts between minutes after midnight (what preferences store) and the `Date`s time pickers use.
enum ScheduleClock {
    /// Today at `minutes` after midnight, for a `DatePicker` that shows only the time.
    static func date(forMinutes minutes: Int) -> Date {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        return Calendar.current.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: .now) ?? .now
    }

    static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
