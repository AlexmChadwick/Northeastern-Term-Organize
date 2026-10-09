//
//  DegreePlanTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// A synthetic degree audit "View Plan" export, as PDFKit extracts it (collapsed
/// spaces, dash bullets on their own lines). The student details are fake.
private let sampleExport = """
Printed: 10/03/2026 12:42
Student: SAMPLE STUDENT
StudentID: 000000000
Degree Audit Plan Name: New Plan
Program: CS-B-CSCI-BSCS
-
Completed Courses:
-
CS 1800 (4.0 Hours) Discrete Structures
-
CS 1802 (1.0 Hour) Seminar for CS 1800
-
NO AP CREDIT (0.0 Hours) No description
-
CS 2510 (4.0 Hours) Fundamentals of Computer Sci
-
CS 3500 (4.0 Hours) Object-Oriented Design
-
CS 3000 (4.0 Hours) Algorithms & Data
-
-
-------------------------------------------------------------------------------------------------------------------
Spring 2027 (9.0 Hours)
-
CS 3650 (4.0 Hours) Computer Systems
-
CS 4530 (4.0 Hours) Fundamentals of Software Engin
-
CS 2963 (1.0 Hour) Topics
-------------------------------------------------------------------------------------------------------------------
Summer Session A 2027 (4.0 Hours)
-
CS 4500 (4.0 Hours) Software Development
-------------------------------------------------------------------------------------------------------------------
Summer Session B 2027 (0.0 Hours)
-------------------------------------------------------------------------------------------------------------------
Fall 2027 (0.0 Hours)
"""

struct DegreePlanTests {
    @Test func parsesTheExport() throws {
        let result = try DegreePlanFormat.parse(text: sampleExport, fileName: "view-plan.pdf")
        let plan = result.plan
        #expect(plan.name == "New Plan")
        #expect(plan.program == "CS-B-CSCI-BSCS")
        #expect(plan.studentName == "SAMPLE STUDENT")
        #expect(plan.importedFrom == "view-plan.pdf")
        #expect(plan.printedAt != nil)
        #expect(plan.completed.count == 6)
        #expect(plan.completed[1].credits == 1)
        #expect(plan.completed[2].key == nil)
        #expect(plan.completed[2].label == "NO AP CREDIT")
        #expect(plan.completed[0].key == CourseKey(subject: "CS", number: "1800"))
        let names = plan.terms.map { $0.name }
        #expect(names == ["Spring 2027", "Summer Session A 2027", "Summer Session B 2027", "Fall 2027"])
        #expect(plan.terms[0].courses.count == 3)
        #expect(plan.terms[0].credits == 9)
        #expect(plan.terms[2].courses.isEmpty)
        #expect(result.skippedLines.isEmpty)
    }

    @Test func parsesRawPaddedLines() throws {
        // The PDF's own text uses padded subjects, tabs and double spaces.
        let raw = "Degree Audit Plan Name:\tMy Plan\nProgram:\t\tCS-B\nCompleted Courses:  \n" +
            "GAME1110 (4.0 Hours) Introduction to Video Game De\nCS  2500 (4.0 Hours) Fundamentals of Computer Sci \n" +
            String(repeating: "-", count: 115) + "\nSpring  2027 (4.0 Hours) \nCS  3484 (4.0 Hours) GUI Programming\n"
        let plan = try DegreePlanFormat.parse(text: raw).plan
        #expect(plan.name == "My Plan")
        #expect(plan.completed.map { $0.label } == ["GAME 1110", "CS 2500"])
        #expect(plan.completed[1].title == "Fundamentals of Computer Sci")
        #expect(plan.terms.first?.season == .spring)
        #expect(plan.terms.first?.courses.first?.key == CourseKey(subject: "CS", number: "3484"))
    }

    @Test func rejectsOtherDocuments() {
        #expect(throws: DegreePlanFormat.ImportError.notADegreePlan) {
            try DegreePlanFormat.parse(text: "Hello world\nThis is a receipt\nTotal $4.00")
        }
    }

    /// PDFKit returns NUL for the spaces in the bold header and sometimes glues a dash
    /// bullet to the line after it.
    @Test func cleansUpExtractionArtifacts() throws {
        let text = """
        Degree Audit Plan Name:\u{0}New Plan
        Program:\u{0}\u{0}CS-B-CSCI-BSCS
        Student:\u{0}\u{0}SAMPLE STUDENT
        Completed Courses:
        -ENGW3302 (4.0 Hours) Advanced Writing in Tech Prof
        - CS 1800 (4.0 Hours) Discrete\u{200B} Structures
        \(DegreePlanFormat.separator)
        -Spring 2027 (4.0 Hours)
        CS\u{00A0}3484 (4.0 Hours) GUI Programming
        """
        let plan = try DegreePlanFormat.parse(text: text).plan
        #expect(plan.name == "New Plan")
        #expect(plan.program == "CS-B-CSCI-BSCS")
        #expect(plan.studentName == "SAMPLE STUDENT")
        #expect(plan.completed.map { $0.label } == ["ENGW 3302", "CS 1800"])
        #expect(plan.completed[1].title == "Discrete Structures")
        #expect(plan.terms.count == 1)
        #expect(plan.terms.first?.courses.map { $0.label } == ["CS 3484"])
    }

    @Test func formatsLikeTheAudit() throws {
        let plan = try DegreePlanFormat.parse(text: sampleExport).plan
        #expect(DegreePlanFormat.courseLine(plan.completed[0]) == "CS  1800 (4.0 Hours) Discrete Structures")
        #expect(DegreePlanFormat.courseLine(plan.completed[1]) == "CS  1802 (1.0 Hour) Seminar for CS 1800")
        #expect(DegreePlanFormat.courseLine(plan.completed[2]) == "NO AP CREDIT (0.0 Hours) No description")
        #expect(DegreePlanFormat.termHeader(plan.terms[0]) == "Spring  2027 (9.0 Hours) ")
        #expect(DegreePlanFormat.termHeader(plan.terms[1]) == "Summer Session A 2027 (4.0 Hours) ")
        #expect(DegreePlanFormat.separator.count == 115)
        let text = DegreePlanFormat.text(for: plan, includeStudent: false)
        #expect(!text.contains("StudentID"))
        #expect(text.contains("Degree Audit Plan Name:\tNew Plan"))
        #expect(text.contains("Program:\t\tCS-B-CSCI-BSCS"))
    }

    @Test func pdfRoundTrip() throws {
        let original = try DegreePlanFormat.parse(text: sampleExport).plan
        let pdf = DegreePlanPDFRenderer.render(original, includeStudent: true)
        let text = try #require(DegreePlanImporter.textFromPDF(data: pdf))
        let parsed = try DegreePlanFormat.parse(text: text).plan
        #expect(parsed.name == original.name)
        #expect(parsed.program == original.program)
        #expect(parsed.studentName == original.studentName)
        #expect(parsed.completed.map { $0.label } == original.completed.map { $0.label })
        #expect(parsed.completed.map { $0.credits } == original.completed.map { $0.credits })
        #expect(parsed.terms.map { $0.name } == original.terms.map { $0.name })
        #expect(parsed.terms.map { $0.courses.map { $0.label } } == original.terms.map { $0.courses.map { $0.label } })
    }

    @Test func longPlansSpanPages() throws {
        var plan = try DegreePlanFormat.parse(text: sampleExport).plan
        plan.completed = (0..<60).map { DegreePlanCourse(key: CourseKey(subject: "CS", number: "\(1000 + $0)"), title: "Course \($0)", credits: 4) }
        let pdf = DegreePlanPDFRenderer.render(plan, includeStudent: false)
        let text = try #require(DegreePlanImporter.textFromPDF(data: pdf))
        let parsed = try DegreePlanFormat.parse(text: text).plan
        #expect(parsed.completed.count == 60)
        #expect(parsed.terms.count == plan.terms.count)
    }

    @Test func prerequisiteChecks() {
        let cs2100 = CourseKey(subject: "CS", number: "2100")
        let cs2510 = CourseKey(subject: "CS", number: "2510")
        let cs1800 = CourseKey(subject: "CS", number: "1800")
        let requisite = Requisite.and([.or([.course(cs2100), .course(cs2510)]), .course(cs1800)])
        #expect(DegreePlanAnalysis.status(of: requisite, satisfiedBy: [cs2510, cs1800]) == .met)
        #expect(DegreePlanAnalysis.status(of: requisite, satisfiedBy: [cs2510]) == .missing("CS 1800"))
        #expect(DegreePlanAnalysis.status(of: requisite, satisfiedBy: [cs1800]) == .missing("CS 2100 or CS 2510"))
        #expect(DegreePlanAnalysis.status(of: requisite, satisfiedBy: []) == .missing("(CS 2100 or CS 2510) and CS 1800"))
        #expect(DegreePlanAnalysis.status(of: nil, satisfiedBy: []) == .met)
        #expect(DegreePlanAnalysis.status(of: .or([.test(name: "Placement", score: nil), .course(cs2100)]), satisfiedBy: []) == .met)
    }

    /// Status lines stay short however large the requisite is.
    @Test func unmetSummariesAreShort() {
        func key(_ code: String) -> Requisite {
            let parts = code.split(separator: " ")
            return .course(CourseKey(subject: String(parts[0]), number: String(parts[1])))
        }
        // CS 3000 (Fall 2026): ((CS 2100 or CS 201M or CS 2510 or DS 2500) and
        // (CS 1800 or MATH 209M or EECE 2160)) or CS 2700
        let programming = Requisite.or([key("CS 2100"), key("CS 201M"), key("CS 2510"), key("DS 2500")])
        let discrete = Requisite.or([key("CS 1800"), key("MATH 209M"), key("EECE 2160")])
        let cs3000 = Requisite.or([.and([programming, discrete]), key("CS 2700")])
        #expect(DegreePlanAnalysis.unmetSummary(programming, satisfied: []) == "CS 2100, CS 201M or 2 others")
        #expect(DegreePlanAnalysis.unmetSummary(discrete, satisfied: []) == "CS 1800 or MATH 209M or EECE 2160")
        // Nothing done: CS 2700 alone is the shortest path.
        #expect(DegreePlanAnalysis.unmetSummary(cs3000, satisfied: []) == "CS 2700 or another option")
        // With CS 1800 done, both options need one course; the usual path comes first.
        let cs1800: Set<CourseKey> = [CourseKey(subject: "CS", number: "1800")]
        #expect(DegreePlanAnalysis.unmetSummary(cs3000, satisfied: cs1800) == "(CS 2100, CS 201M or 2 others) or another option")
        #expect(DegreePlanAnalysis.missingCount(cs3000, satisfied: []) == 1)
        #expect(DegreePlanAnalysis.unmetSummary(cs3000, satisfied: cs1800.union([CourseKey(subject: "CS", number: "2510")])) == nil)

        // Long lists of required courses, and alternatives Banner repeats.
        let nursing = Requisite.and(["NRSG 3344", "NRSG 3345", "NRSG 3400", "NRSG 3401", "NRSG 3420"].map { .or([key($0), key($0), key($0)]) })
        #expect(DegreePlanAnalysis.unmetSummary(nursing, satisfied: []) == "NRSG 3344, NRSG 3345 and 3 more")
        #expect(DegreePlanAnalysis.unmetSummary(.and([nursing, key("CS 1800")]), satisfied: []) == "(NRSG 3344, NRSG 3345 and 3 more) and CS 1800")
    }

    @Test func coursesBeforeATermIncludeEarlierTerms() throws {
        let plan = try DegreePlanFormat.parse(text: sampleExport).plan
        let beforeSummer = DegreePlanAnalysis.coursesBefore(termIndex: 1, in: plan)
        #expect(beforeSummer.contains(CourseKey(subject: "CS", number: "3650")))   // Spring 2027
        #expect(beforeSummer.contains(CourseKey(subject: "CS", number: "1800")))   // completed
        #expect(!beforeSummer.contains(CourseKey(subject: "CS", number: "4500")))  // Summer A itself
    }

    @Test func autofillPrefersTheExactTermThenTheClosest() throws {
        var plan = try DegreePlanFormat.parse(text: sampleExport).plan
        plan.isPrimary = true
        let spring = Term(code: "202730", bannerDescription: "Spring 2027 Semester")
        let exact = DegreePlanAutofill.scheduleSuggestions(for: spring, degreePlans: [plan], schedulePlans: [], index: nil)
        #expect(exact.first?.isExactTerm == true)
        #expect(exact.first?.courses.count == 3)

        // Fall 2026 isn't in the plan; the closest planned semester (Spring 2027) is offered.
        let fall = Term(code: "202710", bannerDescription: "Fall 2026 Semester")
        let closest = DegreePlanAutofill.scheduleSuggestions(for: fall, degreePlans: [plan], schedulePlans: [], index: nil)
        #expect(closest.first?.isExactTerm == false)
        #expect(closest.first?.title.contains("Spring 2027") == true)

        // Already-added courses aren't suggested again.
        let partial = DegreePlanAutofill.scheduleSuggestions(
            for: spring, degreePlans: [plan], schedulePlans: [],
            alreadyInPlan: [CourseKey(subject: "CS", number: "3650")], index: nil
        )
        #expect(partial.first?.courses.count == 2)
    }

    @Test func autofillMarksCoursesNotOfferedThisTerm() throws {
        let index = try #require(SearchEngineTests.index)  // bundled Fall 2026 catalog
        var plan = DegreePlan(name: "Test")
        plan.terms = [DegreePlanTerm(season: .fall, year: 2026, courses: [
            DegreePlanCourse(key: CourseKey(subject: "CS", number: "3000"), title: "Algorithms", credits: 4),
            DegreePlanCourse(key: CourseKey(subject: "CS", number: "9999"), title: "Nope", credits: 4),
        ])]
        let suggestions = DegreePlanAutofill.scheduleSuggestions(for: index.term, degreePlans: [plan], schedulePlans: [], index: index)
        #expect(suggestions.first?.courses == [CourseKey(subject: "CS", number: "3000")])
        #expect(suggestions.first?.unavailable == [CourseKey(subject: "CS", number: "9999")])
    }

    @Test func newPlanDraftCopiesTheLatestPlanAndAddsSchedules() throws {
        let source = try DegreePlanFormat.parse(text: sampleExport).plan
        var schedule = SchedulePlan(name: "Plan A", termCode: "202730")
        schedule.isPrimary = true
        schedule.courses = [
            PlanCourse(key: CourseKey(subject: "CS", number: "3650"), colorIndex: 0),  // already planned
            PlanCourse(key: CourseKey(subject: "MATH", number: "2331"), colorIndex: 1),
        ]
        let now = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let draft = DegreePlanAutofill.newDegreePlanDraft(name: "Draft", basedOn: source, schedulePlans: [schedule], catalogIndex: { _ in nil }, now: now)
        #expect(draft.completed.count == source.completed.count)
        #expect(draft.completed.first?.id != source.completed.first?.id)
        let spring = try #require(draft.terms.first { $0.season == .spring && $0.year == 2027 })
        #expect(spring.courses.map { $0.label } == ["CS 3650", "CS 4530", "CS 2963", "MATH 2331"])
    }

    @Test func termMatching() {
        let summerA = DegreePlanTerm(season: .summerA, year: 2027)
        #expect(summerA.matches(Term(code: "202740", bannerDescription: "")))
        #expect(summerA.matches(Term(code: "202750", bannerDescription: "")))   // combined summer term
        #expect(!summerA.matches(Term(code: "202760", bannerDescription: "")))
        #expect(DegreePlanTerm(season: .fall, year: 2026).matches(Term(code: "202710", bannerDescription: "")))
    }

    @MainActor
    @Test func storeKeepsOnePrimaryPlan() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UserData-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UserDataStore(fileURL: url)
        let first = store.addDegreePlan(DegreePlan(name: "A"))
        let second = store.addDegreePlan(DegreePlan(name: "B"))
        #expect(store.degreePlan(id: first.id)?.isPrimary == true)
        #expect(store.degreePlan(id: second.id)?.isPrimary == false)
        store.setPrimaryDegreePlan(id: second.id)
        #expect(store.primaryDegreePlan?.id == second.id)
        store.deleteDegreePlan(id: second.id)
        #expect(store.primaryDegreePlan?.id == first.id)
        #expect(store.degreePlan(id: first.id)?.isPrimary == true)
    }
}
