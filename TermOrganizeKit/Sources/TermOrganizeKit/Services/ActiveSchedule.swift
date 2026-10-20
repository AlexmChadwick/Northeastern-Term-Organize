//
//  ActiveSchedule.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

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
