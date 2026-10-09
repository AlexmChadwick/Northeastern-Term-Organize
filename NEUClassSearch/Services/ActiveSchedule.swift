//
//  ActiveSchedule.swift
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

extension UserDataStore {
    /// The "My Schedule" plan to use for Up Next and widgets: the one for the term
    /// in session, else the next term to start, else one that ended in the last
    /// two weeks. Independent of the term being browsed, so planning next
    /// semester never hides today's classes. Plans without sections are skipped.
    func activePrimaryPlan(now: Date = .now) -> SchedulePlan? {
        let candidates: [(plan: SchedulePlan, window: ClosedRange<Date>)] = plans.compactMap { plan in
            guard plan.isPrimary, !plan.selectedCRNs.isEmpty,
                  let window = TermCalendar.approximateWindow(for: plan.termCode) else { return nil }
            return (plan, window)
        }
        if let current = candidates.filter({ $0.window.contains(now) })
            .max(by: { $0.plan.selectedCRNs.count < $1.plan.selectedCRNs.count }) {
            return current.plan
        }
        if let next = candidates.filter({ $0.window.lowerBound > now }).min(by: { $0.window.lowerBound < $1.window.lowerBound }) {
            return next.plan
        }
        let recentCutoff = now.addingTimeInterval(-14 * 24 * 3600)
        return candidates.filter { $0.window.upperBound >= recentCutoff }
            .max { $0.window.upperBound < $1.window.upperBound }?.plan
    }
}
