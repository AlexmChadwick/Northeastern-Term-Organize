//
//  TermCalendar.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Approximate class dates for Northeastern terms, used to decide which term
/// is in session without loading any catalog.
enum TermCalendar {
    static let newYork = TimeZone(identifier: "America/New_York") ?? .current

    /// First and last day of classes, approximately (inclusive).
    static func approximateWindow(for termCode: String) -> ClosedRange<Date>? {
        let term = Term(code: termCode, bannerDescription: "")
        let year = term.calendarYear
        let (start, end): ((Int, Int), (Int, Int))
        switch term.season {
        case .fall: (start, end) = ((9, 1), (12, 23))
        case .winter: (start, end) = ((1, 1), (3, 31))
        case .spring: (start, end) = ((1, 3), (4, 30))
        case .summer1: (start, end) = ((5, 1), (6, 30))
        case .summerFull: (start, end) = ((5, 1), (8, 20))
        case .summer2: (start, end) = ((6, 25), (8, 20))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        guard let first = calendar.date(from: DateComponents(year: year, month: start.0, day: start.1)),
              let lastDay = calendar.date(from: DateComponents(year: year, month: end.0, day: end.1)),
              let last = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: lastDay) else { return nil }
        return first...last
    }
}
