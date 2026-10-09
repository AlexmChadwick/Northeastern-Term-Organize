//
//  SchedulePreferencesContext.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// An instructor teaching one of the plan's courses, for the "prefer or avoid" list.
struct ScheduleInstructorOption: Identifiable, Hashable, Sendable {
    /// Banner's name (`Last, First`): what preferences store.
    var name: String
    /// `First Last`.
    var displayName: String
    /// The plan's courses they teach.
    var courses: [CourseKey]

    var id: String { name }
}

/// What the survey needs to know about the schedule it belongs to: campuses to choose from, the
/// instructors of its courses, and how many credits its courses add up to.
struct SchedulePreferencesContext: Sendable {
    var campusNames: [String] = []
    var instructors: [ScheduleInstructorOption] = []
    /// Credits only matter when some courses are optional.
    var optionalCourseCount = 0
    /// What the required courses are worth at least, and what every course is worth at most.
    var requiredCredits = 0
    var totalCredits = 0

    init() {}

    init(plan: SchedulePlan, index: CatalogIndex?) {
        guard let index else { return }
        campusNames = index.campusNames.filter {
            !$0.localizedCaseInsensitiveContains("online") && !$0.localizedCaseInsensitiveContains("no campus")
        }
        var byName: [String: ScheduleInstructorOption] = [:]
        for planCourse in plan.courses {
            let course = index.course(planCourse.key)
            let least = Int((course?.minCredits ?? 0).rounded(.up))
            let most = Int((course?.maxCredits ?? 0).rounded(.up))
            if planCourse.isRequired { requiredCredits += least } else { optionalCourseCount += 1 }
            totalCredits += max(least, most)
            for section in index.sections(for: planCourse.key) where !planCourse.excludedCRNs.contains(section.crn) {
                for instructor in section.instructors ?? [] {
                    var option = byName[instructor.name]
                        ?? ScheduleInstructorOption(name: instructor.name, displayName: instructor.displayName, courses: [])
                    if !option.courses.contains(planCourse.key) { option.courses.append(planCourse.key) }
                    byName[instructor.name] = option
                }
            }
        }
        instructors = byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
