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
        var seen = Set<CourseKey>()
        let keys = semester.courses.compactMap(\.key).filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return nil }
        if let existing = plans(in: termCode).first(where: { Set($0.courses.map(\.key)) == Set(keys) }) {
            return (existing, false, keys.count)
        }
        let name = DegreePlanEditing.scheduleName(for: semester, existing: plans(in: termCode).map(\.name))
        let schedule = createPlan(name: name, termCode: termCode)
        for key in keys {
            addCourse(key, toPlan: schedule.id)
        }
        return (plan(id: schedule.id) ?? schedule, true, keys.count)
    }
}
