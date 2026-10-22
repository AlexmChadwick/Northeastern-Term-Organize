//
//  DegreePlanSchedule.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

extension UserDataStore {
    /// The schedule to open for a degree plan's semester in a Banner term: a schedule of that
    /// term that already holds exactly the semester's courses, else a new one named like the
    /// semester (`Spring 2027 plan`) with them added. Nil when the semester has no catalog courses.
    func scheduleForDegreePlan(_ semester: DegreePlanTerm, termCode: String) -> (plan: SchedulePlan, isNew: Bool, courseCount: Int)? {
        let rows = Self.scheduleRows(for: semester)
        guard !rows.isEmpty else { return nil }
        let wanted = rows.map { ScheduleRowSignature(key: $0.key.description, crn: $0.crn, instance: $0.instance) }.sorted()
        if let existing = plans(in: termCode).first(where: { Self.signature(of: $0) == wanted }) {
            updatePlan(id: existing.id) { plan in
                _ = CreditSync.apply(degree: semester.courses, to: &plan)
            }
            return (plan(id: existing.id) ?? existing, false, rows.count)
        }
        let name = DegreePlanEditing.scheduleName(for: semester, existing: plans(in: termCode).map(\.name))
        let schedule = createPlan(name: name, termCode: termCode)
        updatePlan(id: schedule.id) { plan in
            for row in rows {
                var course = PlanCourse(key: row.key, colorIndex: plan.courses.count, pinnedCRN: row.crn, credits: row.credits)
                course.instance = row.instance
                plan.courses.append(course)
            }
        }
        return (plan(id: schedule.id) ?? schedule, true, rows.count)
    }

    /// One schedule row per degree-plan row. A second copy with no CRN gets `instance`
    /// so its id is not the same as the first row's.
    private static func scheduleRows(for semester: DegreePlanTerm) -> [(key: CourseKey, crn: String?, instance: Int?, credits: Double)] {
        var seen = [CourseKey: Int]()
        var rows: [(key: CourseKey, crn: String?, instance: Int?, credits: Double)] = []
        for course in semester.courses {
            guard let key = course.key else { continue }
            let trimmed = course.crn?.trimmingCharacters(in: .whitespacesAndNewlines)
            let crn = (trimmed?.isEmpty == false) ? trimmed : nil
            var instance: Int? = nil
            if crn == nil {
                let count = (seen[key] ?? 0) + 1
                seen[key] = count
                if count > 1 { instance = count }
            }
            rows.append((key, crn, instance, course.credits))
        }
        return rows
    }

    private static func signature(of plan: SchedulePlan) -> [ScheduleRowSignature] {
        plan.courses.map { ScheduleRowSignature(key: $0.key.description, crn: $0.pinnedCRN, instance: $0.instance) }.sorted()
    }
}

/// Identity of one schedule row when a degree-plan semester is opened again.
private struct ScheduleRowSignature: Equatable, Comparable {
    var key: String
    var crn: String?
    var instance: Int?

    static func < (lhs: ScheduleRowSignature, rhs: ScheduleRowSignature) -> Bool {
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        if lhs.crn != rhs.crn { return (lhs.crn ?? "") < (rhs.crn ?? "") }
        return (lhs.instance ?? 0) < (rhs.instance ?? 0)
    }
}
