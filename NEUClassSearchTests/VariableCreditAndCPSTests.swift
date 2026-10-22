//
//  VariableCreditAndCPSTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

@Suite struct VariableCreditTests {
    private func readings() -> Course {
        Course(
            subject: "CS", number: "8982", title: "Readings", description: "",
            minCredits: 1, maxCredits: 8, defaultCredits: 4, attributes: [],
            prereqs: nil, coreqs: nil, postreqs: [], specialTopics: false,
            college: nil, department: nil, detailsLoaded: true
        )
    }

    @Test func defaultIsBannerHoursWhenInsideTheRange() {
        let span = CreditSpan(low: 1, high: 8, bannerDefault: 4)
        #expect(span.isVariable)
        #expect(span.defaultChoice() == 4)
        #expect(span.resolve(stored: nil) == 4)
        #expect(span.choiceLabel(4) == "Credits: 4 (1 to 8)")
    }

    @Test func defaultFallsBackToLowWhenBannerHoursAreOutside() {
        let span = CreditSpan(low: 1, high: 8, bannerDefault: 9)
        #expect(span.defaultChoice() == 1)
    }

    @Test func fixedSectionHasNoRange() {
        let span = CreditSpan.banner(section(hours: 4, low: nil, high: nil, indicator: nil))
        #expect(!span.isVariable)
        #expect(span.defaultChoice() == 4)
    }

    @Test func clampKeepsAnInRangeChoiceAndDoesNotResetItToTheDefault() {
        let widened = CreditSpan(low: 2, high: 8, bannerDefault: 4)
        #expect(widened.resolve(stored: 6) == 6)
        let narrowed = CreditSpan(low: 1, high: 3, bannerDefault: 4)
        #expect(narrowed.resolve(stored: 6) == 3)
        let shifted = CreditSpan(low: 2, high: 5, bannerDefault: 4)
        #expect(shifted.resolve(stored: 6) == 5)
    }

    @Test func wholeNumbersOnly() {
        let span = CreditSpan(low: 1.5, high: 4.5, bannerDefault: 4)
        #expect(span.integerBounds == 2...4)
        #expect(span.clamp(1.6) == 2)
        #expect(span.clamp(4.4) == 4)
    }

    @Test func catalogKeepsLowHighAndDefaultAcrossRefresh() throws {
        let first = try sectionsJSON(hours: 4, low: 1, high: 8, indicator: "TO", number: "8982", crn: "10001")
        let term = Term(code: "202730", bannerDescription: "Spring 2027 Semester")
        let catalog = CatalogBuilder.merge(existing: nil, fresh: first, term: term, subjects: nil, campuses: nil, attributes: nil)
        let course = try #require(catalog.courses.first { $0.key == CourseKey(subject: "CS", number: "8982") })
        #expect(course.minCredits == 1)
        #expect(course.maxCredits == 8)
        #expect(course.defaultCredits == 4)
        #expect(course.isVariableCredit)
        let section = try #require(catalog.sections.first)
        #expect(section.creditLow == 1)
        #expect(section.creditHigh == 8)
        #expect(section.creditHourIndicator == "TO")

        let narrowed = try sectionsJSON(hours: 4, low: 1, high: 3, indicator: "TO", number: "8982", crn: "10001")
        var refreshed = catalog
        CatalogBuilder.applyCourseRefresh(&refreshed, course: course.key, banner: narrowed)
        let updated = try #require(refreshed.courses.first { $0.key == course.key })
        #expect(updated.minCredits == 1)
        #expect(updated.maxCredits == 3)
        #expect(updated.defaultCredits == 4)

        var plan = SchedulePlan(name: "Plan", termCode: "202730")
        plan.courses = [PlanCourse(key: course.key, colorIndex: 0, credits: 6)]
        let index = CatalogIndex.build(refreshed)
        #expect(ChosenCreditReconcile.reconcile(&plan, index: index))
        #expect(plan.courses[0].credits == 3)
    }

    @Test func missingCreditsDecodeAndFillTheDefault() throws {
        let json = """
        {"key":{"subject":"CS","number":"8982"},"isRequired":true,"excludedCRNs":[],"colorIndex":0}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(PlanCourse.self, from: json)
        #expect(row.credits == nil)
        let span = CreditSpan(low: 1, high: 8, bannerDefault: 4)
        #expect(span.resolve(stored: row.credits) == 4)

        let course = readings()
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(course)) as! [String: Any]
        payload.removeValue(forKey: "defaultCredits")
        let decoded = try JSONDecoder().decode(Course.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(decoded.defaultCredits == nil)
        #expect(decoded.minCredits == 1)
        #expect(decoded.maxCredits == 8)
    }

    @Test func duplicateCopiesKeepDifferentCreditsAndBothCount() {
        let first = DegreePlanCourse(key: CourseKey(subject: "CS", number: "4973"), title: "Seminar", credits: 2)
        let second = DegreePlanCourse(key: CourseKey(subject: "CS", number: "4973"), title: "Seminar", credits: 6)
        var plan = DegreePlan(name: "Plan")
        plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: [first, second])]
        #expect(plan.terms[0].courses.count == 2)
        #expect(plan.terms[0].credits == 8)
        #expect(plan.plannedCredits == 8)
        #expect(DegreePlanLogic.duplicateKeys(in: plan).contains(CourseKey(subject: "CS", number: "4973")))
    }

    @Test func syncCopiesCreditsBothWaysWithoutMergingRows() {
        let key = CourseKey(subject: "CS", number: "8982")
        let first = DegreePlanCourse(key: key, title: "Readings", credits: 3)
        let second = DegreePlanCourse(key: key, title: "Readings", credits: 6)
        var schedule = SchedulePlan(name: "Plan", termCode: "202730")
        schedule.courses = [
            PlanCourse(key: key, colorIndex: 0, credits: 1),
            PlanCourse(key: key, colorIndex: 1, instance: 2, credits: 1),
        ]
        #expect(CreditSync.apply(degree: [first, second], to: &schedule))
        #expect(schedule.courses.map(\.credits) == [3, 6])
        #expect(schedule.courses.count == 2)

        let identity = CreditSync.scheduleIdentity(schedule.courses[1], among: schedule.courses)
        var degreeCourses = [first, second]
        #expect(CreditSync.apply(scheduleCredits: 5, identity: identity, to: &degreeCourses))
        #expect(degreeCourses.map(\.credits) == [3, 5])
        #expect(!CreditSync.apply(scheduleCredits: nil, identity: identity, to: &degreeCourses))
        #expect(degreeCourses[1].credits == 5)
    }

    @Test func scheduleTotalsUseTheChosenValue() throws {
        let course = readings()
        let term = Term(code: "202730", bannerDescription: "Spring 2027 Semester")
        let index = CatalogIndex.build(TermCatalog(
            term: term, courses: [course], sections: [], subjects: [], attributes: [], campuses: []
        ))
        var plan = SchedulePlan(name: "Plan", termCode: term.code)
        plan.courses = [
            PlanCourse(key: course.key, colorIndex: 0, credits: 16),
            PlanCourse(key: CourseKey(subject: "CS", number: "2500"), isRequired: true, colorIndex: 1, credits: 4),
        ]
        let fixed = Course(
            subject: "CS", number: "2500", title: "Fundamentals", description: "",
            minCredits: 4, maxCredits: 4, attributes: [], prereqs: nil, coreqs: nil, postreqs: [],
            specialTopics: false, college: nil, department: nil, detailsLoaded: true
        )
        let withFixed = CatalogIndex.build(TermCatalog(
            term: term, courses: [course, fixed], sections: [], subjects: [], attributes: [], campuses: []
        ))
        let resolved = ResolvedPlan(plan: plan, index: withFixed)
        #expect(resolved.credits.min == 20)
        #expect(resolved.credits.max == 20)
        #expect(resolved.isOverCreditLimit)

        let inputs = ScheduleCourseInput.inputs(for: plan, index: index)
        let readingsInput = try #require(inputs.first { $0.key == course.key })
        #expect(readingsInput.minCredits == 16)
        #expect(readingsInput.maxCredits == 16)
        _ = withFixed
    }

    private func section(hours: Double?, low: Double?, high: Double?, indicator: String?) -> BannerSection {
        let json: [String: Any?] = [
            "courseReferenceNumber": "1",
            "courseNumber": "1000",
            "subject": "CS",
            "creditHours": hours,
            "creditHourLow": low,
            "creditHourHigh": high,
            "creditHourIndicator": indicator,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(BannerSection.self, from: data)
    }

    private func sectionsJSON(hours: Double, low: Double, high: Double, indicator: String, number: String, crn: String) throws -> [BannerSection] {
        let json: [String: Any] = [
            "courseReferenceNumber": crn,
            "courseNumber": number,
            "subject": "CS",
            "courseTitle": "Readings",
            "creditHours": hours,
            "creditHourLow": low,
            "creditHourHigh": high,
            "creditHourIndicator": indicator,
        ]
        let data = try JSONSerialization.data(withJSONObject: [json])
        return try JSONDecoder().decode([BannerSection].self, from: data)
    }
}

@Suite struct CPSAndLevelFilterTests {
    @Test func cpsDetection() {
        let onlyUC = RestrictionParser.parse("""
        <div>Must be enrolled in one of the following Levels:<br>CPS - Undergraduate Semester (UC)</div>
        """)
        #expect(CPSNote.isCPSOnly(onlyUC) == true)

        let mixed = RestrictionParser.parse("""
        Must be enrolled in one of the following Levels:
        <br>Graduate
        <br>CPS - Undergraduate Semester (UC)
        <br>Undergraduate
        """)
        #expect(CPSNote.isCPSOnly(mixed) == false)

        let college = RestrictionParser.parse("""
        <p>Must be enrolled in one of the following Colleges:</p><ul><li>College of Professional Studies</li></ul>
        """)
        #expect(CPSNote.isCPSOnly(college) == true)

        let cannot = RestrictionParser.parse("""
        Cannot be enrolled in one of the following Levels:<br>CPS - Undergraduate Semester (UC)
        """)
        #expect(CPSNote.isCPSOnly(cannot) == false)
        #expect(cannot.first?.kind == .cannot)

        #expect(CPSNote.isCPSOnly(nil) == nil)
        #expect(CPSNote.isCPSOnly([]) == false)
    }

    @Test func courseCaptionIsSomeOrAll() {
        let cps = section("34087", restrictions: [
            SectionRestriction(kind: .must, category: "Levels", values: ["CPS - Undergraduate Semester (UC)"]),
        ])
        let open = section("34629", restrictions: [
            SectionRestriction(kind: .must, category: "Levels", values: ["Graduate", "CPS - Undergraduate Semester (UC)", "Undergraduate"]),
        ])
        let unknown = section("1", restrictions: nil)
        #expect(CPSNote.courseCaption(sections: [cps, cps]) == CPSNote.only)
        #expect(CPSNote.courseCaption(sections: [cps, open]) == CPSNote.some)
        #expect(CPSNote.courseCaption(sections: [cps, unknown]) == CPSNote.some)
        #expect(CPSNote.courseCaption(sections: [unknown, unknown]) == nil)
        #expect(CPSNote.courseCaption(sections: [open]) == nil)
    }

    @Test func levelFilterBoundariesAndPrerequisites() {
        let under = sample("4999", prereqs: nil, detailsLoaded: true)
        let grad = sample("5000", prereqs: nil, detailsLoaded: true)
        let gradWithPrereq = sample("5200", prereqs: .course(CourseKey(subject: "CS", number: "5000")), detailsLoaded: true)
        let stub = sample("1800", prereqs: nil, detailsLoaded: false)
        let index = CatalogIndex.build(TermCatalog(
            term: Term(code: "202730", bannerDescription: "Spring 2027 Semester"),
            courses: [under, grad, gradWithPrereq, stub],
            sections: [],
            subjects: [Subject(code: "CS", name: "Computer Science")],
            attributes: [],
            campuses: []
        ))

        var undergrad = SearchFilters()
        undergrad.degreeLevel = .undergrad
        let underCodes = SearchEngine.search(SearchQuery(text: "", filters: undergrad), in: index).results.map(\.course.code).sorted()
        #expect(underCodes == ["CS 1800", "CS 4999"])

        var graduate = SearchFilters()
        graduate.degreeLevel = .grad
        graduate.noPrerequisites = true
        let gradCodes = SearchEngine.search(SearchQuery(text: "", filters: graduate), in: index).results.map(\.course.code)
        #expect(gradCodes == ["CS 5000"])
        #expect(graduate.activeCount == 2)

        var all = SearchFilters()
        #expect(all.activeCount == 0)
        #expect((all.degreeLevel ?? .all) == .all)
    }

    private func section(_ crn: String, restrictions: [SectionRestriction]?) -> CourseSection {
        CourseSection(
            crn: crn, subject: "ITC", number: "1000", title: "Intro", sectionNumber: "01",
            partOfTerm: "1", seatCapacity: 20, seatsRemaining: 5, enrollment: 15,
            waitlistCapacity: 0, waitlistCount: 0, waitlistRemaining: 0, classType: "Lecture",
            honors: false, campus: "Boston", instructionMethod: nil, meetings: [],
            instructors: [], crossListCRNs: [], attributes: [], restrictions: restrictions
        )
    }

    private func sample(_ number: String, prereqs: Requisite?, detailsLoaded: Bool) -> Course {
        Course(
            subject: "CS", number: number, title: "Sample", description: "",
            minCredits: 4, maxCredits: 4, attributes: [],
            prereqs: prereqs, coreqs: nil, postreqs: [],
            specialTopics: false, college: nil, department: nil, detailsLoaded: detailsLoaded
        )
    }
}
