//
//  DegreePlanReorganizationTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// Whole-plan feasibility and reorganization. Plans use the sample-student pattern: no real
/// names or IDs, just a plan called "Plan".
struct DegreePlanReorganizationTests {
    /// June 2025, so Fall 2026 and later are still upcoming no matter when the suite runs.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let allTerms = ["202710", "202650", "202630", "202610", "202550", "202530", "202510"]
    private let fall = ["202710", "202610", "202510"]
    private let spring = ["202630", "202530"]
    private let summer = ["202650", "202550"]

    // MARK: - Feasibility

    @Test func aCourseMissingFromHistoryIsAPrediction() {
        let plan = plan([semester(.spring, 2027, ["CS 3386"]), semester(.fall, 2027, ["CS 4100"])])
        let report = DegreePlanFeasibility.assess(
            plan: plan, history: history(["CS 3386": fall, "CS 4100": fall]), sections: { _ in nil }, now: now
        )
        let spring = report.report(for: plan.terms[0].id)
        #expect(spring?.isInfeasible == true)
        #expect(spring?.isPredicted == true)
        #expect(spring?.problems.first?.text.hasPrefix("Predicted: CS 3386") == true)
        #expect(spring?.coursesToMove == [plan.terms[0].courses[0].id])
        #expect(report.report(for: plan.terms[1].id)?.isInfeasible == false)

        let milestone = DegreeMilestone.after(termID: plan.terms[1].id, name: plan.terms[1].shortName)
        #expect(report.blockedFinishLine(milestone: milestone, plan: plan, now: now) == "Spring 2027 can’t be taken as planned")
    }

    @Test func aLoadedCatalogOverridesOfferingHistory() {
        let plan = plan([semester(.spring, 2027, ["CS 3386"])])
        // History says spring is typical. The loaded term has no section, so it isn't offered,
        // and the wording is not a prediction.
        let report = DegreePlanFeasibility.assess(
            plan: plan,
            history: history(["CS 3386": spring]),
            sections: { term in
                term.season == .spring ? DegreePlanFeasibility.TermSections(byCourse: [key("CS 3386"): []]) : nil
            },
            now: now
        )
        let problem = report.terms.first?.problems.first
        #expect(problem?.kind == .notOffered(.catalog))
        #expect(problem?.isPrediction == false)
        #expect(problem?.text == "CS 3386 isn’t offered in Spring 2027")
    }

    @Test func overlappingSectionsMakeTheTermInfeasible() {
        let plan = plan([
            semester(.spring, 2027, ["CS 3000", "MATH 2331"]),
            semester(.fall, 2027, ["CS 4100"]),
        ])
        let sections = DegreePlanFeasibility.TermSections(byCourse: [
            key("CS 3000"): [section("1", "CS", "3000", days: [1], start: 10, end: 11)],
            key("MATH 2331"): [section("2", "MATH", "2331", days: [1], start: 10, end: 11)],
        ])
        let report = DegreePlanFeasibility.assess(
            plan: plan, history: history([:]), sections: { $0.season == .spring ? sections : nil }, now: now
        )
        let spring = report.report(for: plan.terms[0].id)
        #expect(spring?.isInfeasible == true)
        #expect(spring?.problems.contains { $0.kind == .timeClash } == true)
        #expect(spring?.problems.first { $0.kind == .timeClash }?.text == "No conflict-free schedule: CS 3000 overlaps MATH 2331")
        // The first course in plan order is the one to move.
        #expect(spring?.coursesToMove == [plan.terms[0].courses[0].id])
    }

    @Test func sectionsOnDifferentDaysAreFeasible() {
        let plan = plan([semester(.spring, 2027, ["CS 3000", "MATH 2331"])])
        let sections = DegreePlanFeasibility.TermSections(byCourse: [
            key("CS 3000"): [section("1", "CS", "3000", days: [1], start: 10, end: 11)],
            key("MATH 2331"): [section("2", "MATH", "2331", days: [2], start: 10, end: 11)],
        ])
        let report = DegreePlanFeasibility.assess(
            plan: plan, history: history([:]), sections: { _ in sections }, now: now
        )
        #expect(report.infeasibleTerms.isEmpty)
    }

    @Test func aSemesterAfterTheFinishDoesNotBlockTheOnTrackLine() {
        let plan = plan([semester(.spring, 2027, ["CS 4100"]), semester(.fall, 2027, ["CS 3500"])])
        let report = DegreePlanFeasibility.assess(
            plan: plan, history: history(["CS 3500": spring, "CS 4100": spring + fall]), sections: { _ in nil }, now: now
        )
        let milestone = DegreeMilestone.after(termID: plan.terms[0].id, name: plan.terms[0].shortName)
        #expect(report.report(for: plan.terms[1].id)?.isInfeasible == true)
        #expect(report.blockedFinishLine(milestone: milestone, plan: plan, now: now) == nil)
    }

    @Test func aCoopTermOverTheClassCapIsInfeasible() {
        let term = DegreePlanTerm(season: .spring, year: 2027, courses: [
            planned("COOP 3946", 0, title: "Co-op Work Experience"),
            planned("CS 4100"),
            planned("CS 3386"),
        ])
        let plan = plan([term])
        let report = DegreePlanFeasibility.assess(
            plan: plan, history: history(["CS 4100": spring, "CS 3386": spring]), sections: { _ in nil }, now: now
        )
        #expect(report.terms.first?.problems.contains { $0.kind == .coopLoad } == true)
        #expect(report.terms.first?.coursesToMove == [term.courses[2].id])
    }

    // MARK: - Reorganization

    @Test func aFallOnlyCourseMovesToFallAndSaysWhy() throws {
        let original = plan([semester(.spring, 2027, ["CS 3386"]), semester(.fall, 2027, ["CS 4100"])])
        let proposal = propose(original, history: history(["CS 3386": fall, "CS 4100": fall]), requirements: required("CS 3386", "CS 4100"))

        let found = try #require(proposal)
        #expect(found.delaysFinish == false)
        #expect(found.outcomeTitle == "Finishes after Fall 2027, the same as now.")
        #expect(codes(found.proposed, .spring, 2027).isEmpty == true)
        #expect(codes(found.proposed, .fall, 2027) == ["CS 4100", "CS 3386"])
        #expect(found.changes.first?.reason == "CS 3386 has only been offered in fall, so it moved to Fall 2027")
        // The search does not edit the plan it was given.
        #expect(codes(original, .spring, 2027) == ["CS 3386"])
    }

    @Test func aTimeClashMovesTheFirstCourse() throws {
        let original = plan([
            semester(.spring, 2027, ["CS 3000", "MATH 2331"]),
            semester(.fall, 2027, ["CS 4100"]),
        ])
        let proposal = propose(
            original,
            history: history(["CS 3000": spring + fall, "MATH 2331": spring + fall, "CS 4100": fall]),
            catalogs: ["spring-2027": [
                "CS 3000": [section("1", "CS", "3000", days: [1], start: 10, end: 11)],
                "MATH 2331": [section("2", "MATH", "2331", days: [1], start: 10, end: 11)],
            ]]
        )
        let found = try #require(proposal)
        #expect(found.delaysFinish == false)
        #expect(codes(found.proposed, .spring, 2027) == ["MATH 2331"])
        #expect(codes(found.proposed, .fall, 2027) == ["CS 4100", "CS 3000"])
        #expect(found.changes.first?.reason == "CS 3000 overlaps MATH 2331 in Spring 2027, so it moved to Fall 2027")
    }

    @Test func aPrerequisiteChainCascadesAndAPartialAcceptLeavesTheRest() throws {
        let original = plan([
            semester(.fall, 2026, ["CS 3500"]),
            semester(.spring, 2027, ["CS 4500"]),
            semester(.fall, 2027, ["CS 4100"]),
        ])
        let proposal = propose(
            original,
            history: history(["CS 3500": spring, "CS 4500": spring + fall, "CS 4100": fall]),
            prerequisites: ["CS 4500": "CS 3500"],
            requirements: required("CS 3500", "CS 4500", "CS 4100")
        )
        let found = try #require(proposal)
        #expect(found.delaysFinish == false)
        #expect(codes(found.proposed, .fall, 2026).isEmpty == true)
        #expect(codes(found.proposed, .spring, 2027) == ["CS 3500"])
        #expect(codes(found.proposed, .fall, 2027) == ["CS 4100", "CS 4500"])
        let cascade = found.changes.first { $0.course == key("CS 4500") }
        #expect(cascade?.reason == "CS 3500 moved, so CS 4500 moved to Fall 2027 to come after it")

        let onlyPrerequisite = found.changes.filter { $0.course == key("CS 3500") }
        let partial = DegreePlanReorganization.applying(onlyPrerequisite, to: original)
        #expect(codes(partial, .spring, 2027).contains("CS 3500"))
        #expect(codes(partial, .spring, 2027).contains("CS 4500"))
        #expect(codes(partial, .fall, 2027) == ["CS 4100"])
    }

    @Test func aCoopTermKeepsOneClassAndMovesTheOther() throws {
        var term = semester(.spring, 2027, ["CS 4100", "CS 3386"])
        term.courses.insert(planned("COOP 3946", 0, title: "Co-op Work Experience"), at: 0)
        let original = plan([term, semester(.fall, 2027, ["CS 4500"])])
        let proposal = propose(
            original,
            history: history(["CS 4100": spring + fall, "CS 3386": spring + fall, "CS 4500": fall]),
            requirements: required("CS 4100", "CS 3386", "CS 4500")
        )
        let found = try #require(proposal)
        #expect(found.delaysFinish == false)
        let springCourses = codes(found.proposed, .spring, 2027)
        #expect(springCourses.contains("COOP 3946"))
        #expect(springCourses.contains("CS 4100"))
        #expect(!springCourses.contains("CS 3386"))
        #expect(codes(found.proposed, .fall, 2027) == ["CS 4500", "CS 3386"])
        let springTerm = found.proposed.terms.first { $0.season == .spring }
        #expect(springTerm.map { DegreePlanLoad.classCredits(in: $0) } == Optional(4.0))
        #expect(found.changes.first?.reason == "Spring 2027 is a co-op term, so CS 3386 moved to Fall 2027")
    }

    @Test func anElectiveSwapKeepsTheFinishWhenNoEarlierTermFits() throws {
        let original = plan([semester(.spring, 2027, ["CY 2550"])])
        let proposal = propose(
            original,
            history: history(["CY 2550": fall, "CY 3740": spring]),
            requirements: chooseOne(title: "Security Course", "CY 2550", "CY 3740")
        )
        let found = try #require(proposal)
        #expect(found.delaysFinish == false)
        #expect(found.outcomeTitle == "Finishes after Spring 2027, the same as now.")
        #expect(codes(found.proposed, .spring, 2027) == ["CY 3740"])
        #expect(codes(found.proposed, .fall, 2027).isEmpty == true)
        #expect(found.changes.first?.reason == "CY 3740 also counts toward Security Course and can be taken in the spring, so it replaces CY 2550")
    }

    @Test func aSummerTermKeepsTheFinishForASummerOnlyCourse() throws {
        let original = plan([semester(.spring, 2027, ["CS 3386"]), semester(.fall, 2027, ["CS 4100"])])
        let proposal = propose(
            original,
            history: history(["CS 3386": summer, "CS 4100": fall]),
            requirements: required("CS 3386", "CS 4100")
        )
        let found = try #require(proposal)
        #expect(found.delaysFinish == false)
        #expect(found.outcomeTitle == "Finishes after Fall 2027, the same as now.")
        #expect(codes(found.proposed, .spring, 2027).isEmpty == true)
        #expect(codes(found.proposed, .summerA, 2027) == ["CS 3386"])
        #expect(codes(found.proposed, .fall, 2027) == ["CS 4100"])
    }

    @Test func noOnTimePlanExplainsTheDelay() throws {
        let original = plan([semester(.spring, 2027, ["CS 3500", "CS 4500"])])
        let proposal = propose(
            original,
            history: history(["CS 3500": spring, "CS 4500": fall]),
            prerequisites: ["CS 4500": "CS 3500"],
            requirements: required("CS 3500", "CS 4500")
        )
        let found = try #require(proposal)
        #expect(found.delaysFinish == true)
        #expect(found.outcomeTitle == "Finishes after Fall 2027 instead of Spring 2027.")
        #expect(codes(found.proposed, .spring, 2027) == ["CS 3500"])
        #expect(codes(found.proposed, .fall, 2027) == ["CS 4500"])
        #expect(found.delay?.because == "CS 4500 needs CS 3500, and CS 3500 has only been offered in spring, so the earliest finish is Fall 2027.")
    }

    @Test func aPlanThatAlreadyWorksIsLeftAlone() {
        let original = plan([semester(.spring, 2027, ["CS 3500"]), semester(.fall, 2027, ["CS 4100"])])
        let proposal = propose(original, history: history(["CS 3500": spring, "CS 4100": fall]))
        #expect(proposal == nil)
    }

    // MARK: - Fixtures

    private func planned(_ code: String, _ credits: Double = 4, title: String? = nil) -> DegreePlanCourse {
        DegreePlanCourse(key: key(code), title: title ?? code, credits: credits)
    }

    private func semester(_ season: PlanSeason, _ year: Int, _ codes: [String], credits: Double = 4) -> DegreePlanTerm {
        DegreePlanTerm(season: season, year: year, courses: codes.map { planned($0, credits) })
    }

    private func plan(_ terms: [DegreePlanTerm]) -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.terms = terms
        plan.sortTerms()
        return plan
    }

    private func history(_ offered: [String: [String]]) -> OfferingHistory {
        OfferingHistory(
            checkedTerms: allTerms,
            offered: Dictionary(uniqueKeysWithValues: offered.map { (key($0.key), Set($0.value)) }),
            checkedKeys: Set(offered.keys.map(key))
        )
    }

    private func propose(
        _ plan: DegreePlan,
        history: OfferingHistory,
        prerequisites: [String: String] = [:],
        catalogs: [String: [String: [CourseSection]]] = [:],
        requirements: ProgramRequirements? = nil
    ) -> DegreePlanReorganization.Proposal? {
        var knowledge: [CourseKey: DegreePlanReorganization.RequisiteKnowledge] = [:]
        for (course, needs) in prerequisites {
            knowledge[key(course)] = .needs(.course(key(needs)))
        }
        let sections = catalogs.mapValues { courses in
            Dictionary(uniqueKeysWithValues: courses.map { (key($0.key), $0.value) })
        }
        let context = DegreePlanReorganization.Context(
            plan: plan,
            history: history,
            prerequisites: knowledge,
            corequisites: [:],
            equivalences: .none,
            requirements: requirements,
            attributes: .none,
            catalogs: sections,
            candidates: [],
            now: now
        )
        return DegreePlanReorganization.propose(context)
    }

    private func codes(_ plan: DegreePlan?, _ season: PlanSeason, _ year: Int) -> [String] {
        plan?.terms.first { $0.season == season && $0.year == year }?.courses.compactMap { $0.key?.description } ?? []
    }

    private func required(_ codes: String...) -> ProgramRequirements {
        let rules = codes.enumerated().map { index, code in
            RequirementRule(
                id: "req-\(index)",
                kind: .required(CourseOption(alternatives: [[key(code)]])),
                label: code,
                hours: 4,
                notes: []
            )
        }
        return requirements(rules, groupTitle: "Required")
    }

    private func chooseOne(title: String, _ first: String, _ second: String) -> ProgramRequirements {
        let rule = RequirementRule(
            id: "choose",
            kind: .choose(count: 1, hours: nil, options: [
                CourseOption(alternatives: [[key(first)]]),
                CourseOption(alternatives: [[key(second)]]),
            ], ranges: []),
            label: "Complete one of the following:",
            hours: 4,
            notes: []
        )
        return requirements([rule], groupTitle: title)
    }

    private func requirements(_ rules: [RequirementRule], groupTitle: String) -> ProgramRequirements {
        let group = RequirementGroup(id: "group", title: groupTitle, rules: rules, notes: [])
        let section = RequirementSection(id: "section", title: "Requirements", isConcentration: false, groups: [group], notes: [])
        return ProgramRequirements(
            year: CatalogYear(startYear: 2025),
            program: CatalogProgram(title: "Computer Science, BSCS", path: "undergraduate/computer-science/bscs/"),
            sections: [section],
            totalHours: nil,
            fetchedAt: .distantPast
        )
    }

    /// A section meeting on `days` (0 = Sunday) from `start` to `end` hours.
    private func section(_ crn: String, _ subject: String, _ number: String, days: [Int], start: Double, end: Double) -> CourseSection {
        let meeting = Meeting(
            days: DaySet(indices: days), start: Int(start * 60), end: Int(end * 60),
            buildingCode: "WVH", building: "West Village H", room: "210", campusCode: "BOS",
            kind: "Class", startDate: "2027-01-11", endDate: "2027-04-28"
        )
        return CourseSection(
            crn: crn, subject: subject, number: number, title: "\(subject) \(number)", sectionNumber: "01",
            partOfTerm: "1", seatCapacity: 40, seatsRemaining: 10, enrollment: 30,
            waitlistCapacity: 0, waitlistCount: 0, waitlistRemaining: 0, classType: "Lecture",
            honors: false, campus: "Boston", instructionMethod: "Traditional", meetings: [meeting],
            instructors: [], crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil
        )
    }

    private func key(_ code: String) -> CourseKey {
        guard let key = CourseKey(string: code) else { preconditionFailure("bad course code \(code)") }
        return key
    }
}
