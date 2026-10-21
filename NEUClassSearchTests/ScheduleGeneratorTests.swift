//
//  ScheduleGeneratorTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

struct ScheduleGeneratorTests {
    /// A section meeting on `days` (indices, 0 = Sunday) from `start` to `end` (hours).
    private func section(_ crn: String, _ subject: String, _ number: String, days: [Int], start: Double, end: Double,
                         seats: Int = 10, honors: Bool = false, campus: String = "Boston") -> CourseSection {
        let meeting = Meeting(days: DaySet(indices: days), start: Int(start * 60), end: Int(end * 60),
                              buildingCode: "WVH", building: "West Village H", room: "210", campusCode: "BOS",
                              kind: "Class", startDate: "2026-09-09", endDate: "2026-12-13")
        return CourseSection(crn: crn, subject: subject, number: number, title: "\(subject) \(number)", sectionNumber: "01",
                             partOfTerm: "1", seatCapacity: 40, seatsRemaining: seats, enrollment: 40 - seats,
                             waitlistCapacity: 0, waitlistCount: 0, waitlistRemaining: 0, classType: "Lecture",
                             honors: honors, campus: campus, instructionMethod: "Traditional", meetings: [meeting],
                             instructors: [], crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil)
    }

    private func course(_ subject: String, _ number: String, required: Bool = true, _ sections: [CourseSection]) -> ScheduleCourseInput {
        ScheduleCourseInput(key: CourseKey(subject: subject, number: number), isRequired: required, sections: sections)
    }

    @Test func slotMasksDetectOverlaps() {
        let a = ScheduleSlotMask(section: section("1", "CS", "1", days: [1, 3], start: 10, end: 11))
        let b = ScheduleSlotMask(section: section("2", "CS", "2", days: [3], start: 10.5, end: 12))
        let c = ScheduleSlotMask(section: section("3", "CS", "3", days: [1, 3], start: 11, end: 12))
        #expect(a.conflicts(with: b))
        #expect(!a.conflicts(with: c), "Back-to-back classes don't conflict")
        #expect(!a.conflicts(with: ScheduleSlotMask(section: section("4", "CS", "4", days: [2, 4], start: 10, end: 11))))
    }

    @Test func generatesOnlyConflictFreeCombinations() {
        let courses = [
            course("CS", "3000", [section("A1", "CS", "3000", days: [1, 3, 4], start: 9, end: 10),
                                  section("A2", "CS", "3000", days: [1, 3, 4], start: 13, end: 14)]),
            course("MATH", "2331", [section("B1", "MATH", "2331", days: [1, 3, 4], start: 9.5, end: 10.5),
                                    section("B2", "MATH", "2331", days: [2, 5], start: 9, end: 10.5)]),
        ]
        let result = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        // A1+B1 overlap; the other three pairs work.
        #expect(result.totalFound == 3)
        #expect(!result.schedules.contains { Set($0.crns) == ["A1", "B1"] })
        for schedule in result.schedules {
            let masks = schedule.sections.map(ScheduleSlotMask.init(section:))
            for i in masks.indices { for j in masks.indices where i < j { #expect(!masks[i].conflicts(with: masks[j])) } }
        }
    }

    @Test func respectsFilters() {
        let courses = [
            course("CS", "3000", [section("EARLY", "CS", "3000", days: [1, 3], start: 8, end: 9),
                                  section("FRI", "CS", "3000", days: [5], start: 12, end: 15),
                                  section("OK", "CS", "3000", days: [2, 4], start: 11, end: 12)]),
        ]
        var filters = ScheduleFilters()
        filters.earliestStart = 9 * 60
        filters.freeDays = [.friday]
        let result = ScheduleGenerator.generate(courses: courses, filters: filters)
        #expect(result.schedules.map(\.crns) == [["OK"]])
    }

    @Test func optionalCoursesFillInWhenTheyFit() {
        let courses = [
            course("CS", "3000", [section("R", "CS", "3000", days: [1, 3], start: 10, end: 11)]),
            course("ARTF", "1220", required: false, [section("O1", "ARTF", "1220", days: [1], start: 10.5, end: 12),
                                                     section("O2", "ARTF", "1220", days: [2], start: 10, end: 12)]),
        ]
        let result = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        // Only maximal combinations: the optional course fits via O2.
        #expect(result.schedules.map { Set($0.crns) } == [["R", "O2"]])

        var exactlyOne = ScheduleFilters()
        exactlyOne.courseCount = 1
        let single = ScheduleGenerator.generate(courses: courses, filters: exactlyOne)
        #expect(single.schedules.map(\.crns) == [["R"]])
    }

    @Test func realCatalogPlanGenerates() throws {
        let index = try #require(SearchEngineTests.index)
        let keys = [CourseKey(subject: "CS", number: "3000"), CourseKey(subject: "CS", number: "3001"),
                    CourseKey(subject: "MATH", number: "2331")]
        let courses = keys.map { ScheduleCourseInput(key: $0, isRequired: true, sections: index.sections(for: $0)) }
        let result = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        #expect(result.totalFound > 0)
        #expect(result.schedules.allSatisfy { $0.crns.count == 3 })
    }

    /// Two special-topics sections share CS 4973. The user pinned one CRN. Generation,
    /// including a run that would rather use the other section to dodge a conflict or a
    /// filter, may not substitute it.
    @Test func pinnedSpecialTopicsSectionIsNeverReplaced() {
        let pinned = section("11111", "CS", "4973", days: [1, 3], start: 8, end: 9)
        let other = section("22222", "CS", "4973", days: [1, 3], start: 14, end: 15)
        let math = section("33333", "MATH", "2331", days: [1, 3], start: 8, end: 9.5)
        let index = topicsIndex(pinned, other, math)
        var plan = SchedulePlan(name: "Topics", termCode: "202710")
        plan.courses = [
            PlanCourse(key: CourseKey(subject: "CS", number: "4973"), colorIndex: 0),
            PlanCourse(key: CourseKey(subject: "MATH", number: "2331"), colorIndex: 1),
        ]
        plan.selectedCRNs = ["11111"]

        let inputs = ScheduleCourseInput.inputs(for: plan, index: index)
        #expect(inputs.first { $0.key.number == "4973" }?.sections.map(\.crn) == ["11111"])

        let generated = ScheduleGenerator.generate(courses: inputs, filters: ScheduleFilters())
        #expect(generated.schedules.allSatisfy { $0.crns.contains("11111") })
        #expect(!generated.schedules.contains { $0.crns.contains("22222") })

        // 11111 overlaps MATH. 22222 does not. The conflict is not resolved by switching topics.
        #expect(generated.schedules.isEmpty)

        var filters = ScheduleFilters()
        filters.earliestStart = 9 * 60
        let filtered = ScheduleGenerator.generate(courses: inputs, filters: filters)
        #expect(filtered.schedules.isEmpty)
        #expect(!filtered.schedules.contains { $0.crns.contains("22222") })

        // With no pin, either topic may be chosen. 22222 is the one that fits with MATH.
        plan.selectedCRNs = []
        let open = ScheduleGenerator.generate(courses: ScheduleCourseInput.inputs(for: plan, index: index), filters: ScheduleFilters())
        #expect(open.schedules.map { Set($0.crns) } == [Set(["22222", "33333"])])
    }

    private func topicsIndex(_ sections: CourseSection...) -> CatalogIndex {
        let courses = [
            Course(subject: "CS", number: "4973", title: "Special Topics", description: "", minCredits: 4, maxCredits: 4,
                   attributes: [], prereqs: nil, coreqs: nil, postreqs: [], specialTopics: true, college: nil, department: nil, detailsLoaded: true),
            Course(subject: "MATH", number: "2331", title: "Linear Algebra", description: "", minCredits: 4, maxCredits: 4,
                   attributes: [], prereqs: nil, coreqs: nil, postreqs: [], specialTopics: false, college: nil, department: nil, detailsLoaded: true),
        ]
        return CatalogIndex.build(TermCatalog(
            term: Term(code: "202710", bannerDescription: "Fall 2026 Semester"),
            courses: courses, sections: sections, subjects: [], attributes: [], campuses: []
        ))
    }
}
