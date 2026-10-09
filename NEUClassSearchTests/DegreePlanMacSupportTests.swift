//
//  DegreePlanMacSupportTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// The shared degree plan logic the Mac interface drives: dropping a course between two others,
/// building a schedule from a semester, the plan summary lines, and how a requirement is laid
/// out like the catalog's page.
struct DegreePlanMacSupportTests {
    private func course(_ code: String, _ credits: Double = 4) -> DegreePlanCourse {
        DegreePlanCourse(key: CourseKey(string: code), title: code, credits: credits)
    }

    private func codes(_ term: DegreePlanTerm) -> [String] {
        term.courses.map { $0.key?.description ?? $0.label }
    }

    /// Spring 2027: A (CS 3000), B (CS 3500), C (CS 3650); Fall 2027: D (CS 4400).
    private func plan() -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.terms = [
            DegreePlanTerm(season: .spring, year: 2027, courses: [course("CS 3000"), course("CS 3500"), course("CS 3650")]),
            DegreePlanTerm(season: .fall, year: 2027, courses: [course("CS 4400")]),
        ]
        return plan
    }

    // MARK: Dropping a course at a position

    @Test func reordersWithinASemester() {
        var plan = plan()
        let spring = plan.terms[0]
        let a = spring.courses[0].id, b = spring.courses[1].id, c = spring.courses[2].id

        // To the end, then between two courses, then to the top.
        DegreePlanEditing.move(a, toTerm: spring.id, at: 3, in: &plan)
        #expect(codes(plan.terms[0]) == ["CS 3500", "CS 3650", "CS 3000"])
        DegreePlanEditing.move(a, toTerm: spring.id, at: 1, in: &plan)
        #expect(codes(plan.terms[0]) == ["CS 3500", "CS 3000", "CS 3650"])
        DegreePlanEditing.move(c, toTerm: spring.id, at: 0, in: &plan)
        #expect(codes(plan.terms[0]) == ["CS 3650", "CS 3500", "CS 3000"])

        // Dropped back where it is (above or below itself): nothing changes.
        DegreePlanEditing.move(b, toTerm: spring.id, at: 1, in: &plan)
        #expect(codes(plan.terms[0]) == ["CS 3650", "CS 3500", "CS 3000"])
        DegreePlanEditing.move(b, toTerm: spring.id, at: 2, in: &plan)
        #expect(codes(plan.terms[0]) == ["CS 3650", "CS 3500", "CS 3000"])
    }

    @Test func movesToAPositionInAnotherSemester() {
        var plan = plan()
        let spring = plan.terms[0], fall = plan.terms[1]
        let b = spring.courses[1].id

        DegreePlanEditing.move(b, toTerm: fall.id, at: 0, in: &plan)
        #expect(codes(plan.terms[0]) == ["CS 3000", "CS 3650"])
        #expect(codes(plan.terms[1]) == ["CS 3500", "CS 4400"])

        // A position past the end puts it last; a negative one first.
        let a = plan.terms[0].courses[0].id
        DegreePlanEditing.move(a, toTerm: fall.id, at: 99, in: &plan)
        #expect(codes(plan.terms[1]) == ["CS 3500", "CS 4400", "CS 3000"])
        let c = plan.terms[0].courses[0].id
        DegreePlanEditing.move(c, toTerm: fall.id, at: -5, in: &plan)
        #expect(codes(plan.terms[1]) == ["CS 3650", "CS 3500", "CS 4400", "CS 3000"])
        #expect(plan.terms[0].courses.isEmpty)
    }

    /// How the Mac plan page adds a course dragged from the requirements onto a semester: appended,
    /// then moved to the position it was dropped at.
    @Test func addsADraggedCourseAtAPosition() {
        var plan = plan()
        let spring = plan.terms[0]
        func drop(_ code: String, at position: Int) -> UUID {
            let added = course(code)
            DegreePlanEditing.add(added, toTerm: spring.id, in: &plan)
            DegreePlanEditing.move(added.id, toTerm: spring.id, at: position, in: &plan)
            return added.id
        }

        _ = drop("CS 4500", at: 1)
        #expect(codes(plan.terms[0]) == ["CS 3000", "CS 4500", "CS 3500", "CS 3650"])
        _ = drop("CS 4530", at: 0)
        #expect(codes(plan.terms[0]) == ["CS 4530", "CS 3000", "CS 4500", "CS 3500", "CS 3650"])
        // Dropped on the semester itself, at its end.
        _ = drop("CS 4535", at: plan.terms[0].courses.count)
        #expect(codes(plan.terms[0]) == ["CS 4530", "CS 3000", "CS 4500", "CS 3500", "CS 3650", "CS 4535"])
        // The other semester is untouched.
        #expect(codes(plan.terms[1]) == ["CS 4400"])
    }

    @Test func ignoresACourseOrSemesterThatIsGone() {
        var plan = plan()
        let before = plan
        DegreePlanEditing.move(UUID(), toTerm: plan.terms[1].id, at: 0, in: &plan)
        DegreePlanEditing.move(plan.terms[0].courses[0].id, toTerm: UUID(), at: 0, in: &plan)
        #expect(plan == before)
    }

    // MARK: Schedules from a semester

    @MainActor
    @Test func buildsAScheduleFromASemesterOnce() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UserData-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UserDataStore(fileURL: url)
        let semester = plan().terms[0]

        let first = store.scheduleForDegreePlan(semester, termCode: "202730")
        #expect(first?.isNew == true)
        #expect(first?.courseCount == 3)
        #expect(first?.plan.name == "Spring 2027 plan")
        #expect(store.plan(id: first?.plan.id ?? UUID())?.courses.map(\.key.description) == ["CS 3000", "CS 3500", "CS 3650"])

        // The same courses again open the schedule that has them.
        let again = store.scheduleForDegreePlan(semester, termCode: "202730")
        #expect(again?.isNew == false)
        #expect(again?.plan.id == first?.plan.id)
        #expect(store.plans.count == 1)

        // A semester without catalog courses has nothing to build.
        let empty = DegreePlanTerm(season: .summerA, year: 2027, courses: [DegreePlanCourse(key: nil, label: "NO AP CREDIT", title: "", credits: 0)])
        #expect(store.scheduleForDegreePlan(empty, termCode: "202740") == nil)
    }

    // MARK: Summary lines

    @Test func summarizesAPlanForTheOverview() {
        var plan = DegreePlan(name: "Plan")
        #expect(plan.degreePlanCompletedLine == "No completed courses yet")
        #expect(plan.degreePlanNextLine() == "No semesters planned yet")

        plan.completed = [course("CS 1800"), course("CS 1802", 1)]
        #expect(plan.degreePlanCompletedLine == "5 credits completed")

        // A semester that is over isn't next; one far ahead is.
        plan.terms = [DegreePlanTerm(season: .fall, year: 2001, courses: [course("CS 1800")])]
        #expect(plan.degreePlanNextLine() == "No upcoming semesters")
        plan.terms.append(DegreePlanTerm(season: .spring, year: 2099))
        #expect(plan.degreePlanNextLine() == "No courses planned yet")
        plan.terms[1].courses = [course("CS 3000"), course("CS 3500", 5)]
        #expect(plan.degreePlanNextSummary() == "Spring 2099 · 9 credits · 2 courses")
        #expect(plan.degreePlanNextLine() == "Next: Spring 2099 · 9 credits · 2 courses")
    }

    // MARK: Requirements laid out like the catalog

    @Test func laysRequirementsOutLikeTheCatalog() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let audit = DegreeAudit.run(plan: DegreeRequirementsTests.plan(), requirements: requirements)

        // Required courses are plain rows; lists of options and hour requirements get a heading.
        let either = try #require(audit.ruleResults.first { $0.rule.label == "CS 4500 or CS 4530" })
        #expect(!DegreeRequirementsListing.hasHeaderRow(either))
        #expect(!DegreeRequirementsListing.isReplaced(either))
        guard case .required(let option) = either.rule.kind else { Issue.record("not a required course"); return }
        let alternatives = DegreeRequirementsListing.entries(alternativesOf: option)
        #expect(alternatives.map(\.courses) == [[CourseKey(subject: "CS", number: "4500")], [CourseKey(subject: "CS", number: "4530")]])

        let security = try #require(audit.ruleResults.first { $0.rule.label.hasPrefix("Complete one of the following") })
        #expect(DegreeRequirementsListing.hasHeaderRow(security))
        let (options, ranges) = DegreeRequirementsListing.listing(of: security.rule)
        #expect(options.count == 2 && ranges.isEmpty)

        let science = try #require(audit.ruleResults.first { $0.rule.label.hasPrefix("Complete two courses") })
        let listed = Set(DegreeRequirementsListing.listing(of: science.rule).options.flatMap(\.allCourses))
        let entries = DegreeRequirementsListing.entries(options: DegreeRequirementsListing.listing(of: science.rule).options, of: science.rule, subjectName: { _ in nil })
        // The catalog's own subheaders come before the first option of each category.
        #expect(entries.compactMap { entry in entry.category.map { "\(entry.id) \($0)" } } == ["0 Biology", "1 Mathematics"])
        let counted = DegreeAudit.CourseUse(key: CourseKey(subject: "BIOL", number: "1112"), title: "", credits: 1, order: 0)
        #expect(DegreeRequirementsListing.isShown(counted, listed: listed))
        let other = DegreeAudit.CourseUse(key: CourseKey(subject: "CS", number: "4973"), title: "", credits: 4, order: 1)
        #expect(!DegreeRequirementsListing.isShown(other, listed: listed))
    }

    @Test func longListsKeepTheOptionsThatMatter() {
        func entry(_ id: Int) -> DegreeListEntry {
            DegreeListEntry(id: id, alternatives: [[CourseKey(subject: "CS", number: "\(4000 + id)")]])
        }
        let entries = (0..<10).map(entry)
        // Entries 2 and 7 are in the plan; an open requirement shows three more, in catalog order.
        let relevant: (DegreeListEntry) -> Bool = { [2, 7].contains($0.id) }
        #expect(DegreeRequirementsListing.collapsed(entries, extra: 3, isRelevant: relevant).map(\.id) == [0, 1, 2, 3, 7])
        #expect(DegreeRequirementsListing.collapsed(entries, extra: 0, isRelevant: relevant).map(\.id) == [2, 7])
    }

    // MARK: Picking a plan course

    @Test func findsPlanCoursesByCodeOrTitle() {
        let choices = [
            DegreePlanCourseChoice(key: CourseKey(subject: "CS", number: "3000"), title: "Algorithms and Data", credits: 4),
            DegreePlanCourseChoice(key: CourseKey(subject: "MATH", number: "1341"), title: "Calculus 1", credits: 4, semester: "Spring 2027", semesterShortName: "Spring 2027"),
        ]
        #expect(DegreeSubstitutionEditing.matching(choices, query: "").count == 2)
        #expect(DegreeSubstitutionEditing.matching(choices, query: "cs 3000").map(\.key.description) == ["CS 3000"])
        #expect(DegreeSubstitutionEditing.matching(choices, query: "math1341").map(\.key.description) == ["MATH 1341"])
        #expect(DegreeSubstitutionEditing.matching(choices, query: "calculus").map(\.key.description) == ["MATH 1341"])
        #expect(DegreeSubstitutionEditing.matching(choices, query: "chemistry").isEmpty)
    }
}
