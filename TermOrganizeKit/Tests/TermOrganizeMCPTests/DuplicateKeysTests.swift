//
//  DuplicateKeysTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Testing
@testable import TermOrganizeKit

/// The same cases as `DegreeRequirementsTests.distinctCRNsCountSeparately`, without the
/// catalog HTML that test also audits.
struct DuplicateKeysTests {
    private let seminar = CourseKey(subject: "CS", number: "4973")

    private func row(_ title: String, key: CourseKey? = nil, crn: String? = nil) -> DegreePlanCourse {
        DegreePlanCourse(key: key ?? seminar, title: title, credits: 4, crn: crn)
    }

    @Test func distinctCompletedCRNsAreNotDuplicates() {
        var plan = DegreePlan(name: "Seminars")
        plan.completed = [row("Seminar", crn: "11111"), row("Seminar", crn: "22222")]
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan).isEmpty)
    }

    @Test func twoCompletedSeminarsWithoutCRNsAreDuplicates() {
        var plan = DegreePlan(name: "Seminars")
        plan.completed = [row("Seminar"), row("Seminar")]
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan) == [seminar])
    }

    @Test func theSameCompletedCRNTwiceIsADuplicate() {
        var plan = DegreePlan(name: "Seminars")
        plan.completed = [row("Seminar", crn: "11111"), row("Seminar", crn: "11111")]
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan) == [seminar])
    }

    @Test func aTopicsTitleTakenAgainIsNotADuplicate() {
        var plan = DegreePlan(name: "Topics")
        plan.completed = [row("Topics in Computer Science")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [row("Topics in Computer Science")]
        plan.terms = [spring]
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan).isEmpty)
    }

    @Test func aPlannedRepeatOfACompletedCourseIsStillFlagged() {
        let marketing = CourseKey(subject: "MKTG", number: "2602")
        var plan = DegreePlan(name: "Repeat")
        plan.completed = [row("Marketing Management", key: marketing)]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [row("Marketing Management", key: marketing)]
        plan.terms = [spring]
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan) == [marketing])
    }
}
