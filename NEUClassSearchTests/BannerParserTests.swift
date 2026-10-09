//
//  BannerParserTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

struct BannerParserTests {
    private let subjects = BannerParsers.SubjectLookup([
        Subject(code: "CS", name: "Computer Science"),
        Subject(code: "DS", name: "Data Science"),
        Subject(code: "MATH", name: "Mathematics"),
        Subject(code: "EECE", name: "Electrical and Comp Engineerng"),
    ])

    /// One row of Banner's prerequisite table:
    /// And/Or | ( | Test | Score | Subject | Course Number | Level | Grade | )
    private func row(_ andOr: String = "", open: Bool = false, test: String = "", score: String = "",
                     subject: String = "", number: String = "", close: Bool = false) -> String {
        "<tr><td>\(andOr)</td><td>\(open ? "(" : "")</td><td>\(test)</td><td>\(score)</td><td>\(subject)</td><td>\(number)</td><td>Undergraduate</td><td>D-</td><td>\(close ? ")" : "")</td></tr>"
    }

    private func table(_ rows: [String]) -> String {
        "<section><table class=\"basePreqTable\"><thead><tr><th>And/Or</th></tr></thead><tbody>\(rows.joined())</tbody></table></section>"
    }

    @Test func parsesNestedPrerequisites() throws {
        // Mirrors CS 3000 (Fall 2026): ((CS 2100 or CS 201M or CS 2510 or DS 2500) and
        // (CS 1800 or MATH 209M or EECE 2160)) or CS 2700
        let html = table([
            row(open: true),
            row(open: true, subject: "Computer Science", number: "2100"),
            row("Or", subject: "Computer Science - MMC", number: "201M"),
            row("Or", subject: "Computer Science", number: "2510"),
            row("Or", subject: "Data Science", number: "2500", close: true),
            row("And", open: true, subject: "Computer Science", number: "1800"),
            row("Or", subject: "Mathematics", number: "209M"),
            row("Or", subject: "Electrical and Comp Engineerng", number: "2160", close: true),
            row(close: true),
            row("Or", subject: "Computer Science", number: "2700"),
        ])
        let requisite = try #require(BannerParsers.prerequisites(fromHTML: html, subjects: subjects))
        guard case .or(let top) = requisite else {
            Issue.record("Expected an OR at the top level, got \(requisite)")
            return
        }
        #expect(top.count == 2)
        #expect(top.last == .course(CourseKey(subject: "CS", number: "2700")))
        guard case .and(let groups) = top.first else {
            Issue.record("Expected an AND group")
            return
        }
        #expect(groups.count == 2)
        #expect(requisite.referencedCourses.contains(CourseKey(subject: "EECE", number: "2160")))
        // Campus listings ("Computer Science - MMC") resolve to the main subject's code.
        #expect(requisite.referencedCourses.contains(CourseKey(subject: "CS", number: "201M")))
    }

    @Test func parsesSingleCourseAndTests() throws {
        let single = table([row(subject: "Computer Science", number: "2100")])
        #expect(BannerParsers.prerequisites(fromHTML: single, subjects: subjects) == .course(CourseKey(subject: "CS", number: "2100")))

        let withTest = table([
            row(subject: "Mathematics", number: "1341"),
            row("Or", test: "Graduate Admission"),
        ])
        let parsed = try #require(BannerParsers.prerequisites(fromHTML: withTest, subjects: subjects))
        #expect(parsed == .or([.course(CourseKey(subject: "MATH", number: "1341")), .test(name: "Graduate Admission", score: nil)]))
    }

    @Test func emptyPrerequisitesAreNil() {
        let html = "<section aria-labelledby=\"preReqs\"><h3>Catalog Prerequisites</h3> No prerequisite information available.</section>"
        #expect(BannerParsers.prerequisites(fromHTML: html, subjects: subjects) == nil)
    }

    @Test func parsesCorequisites() {
        let html = """
        <section><table class="basePreqTable"><thead><tr><th>Subject</th></tr></thead><tbody>
        <tr><td>Computer Science</td><td>3001</td><td>Recitation for CS 3000</td></tr>
        </tbody></table></section>
        """
        #expect(BannerParsers.corequisites(fromHTML: html, subjects: subjects) == .course(CourseKey(subject: "CS", number: "3001")))
    }

    @Test func parsesDescriptionAndCatalogDetails() {
        let description = """
        <section aria-labelledby="courseDescription">
            <!--display course description-->
            Covers the derivative &amp; integration.<br/>
        </section>
        """
        #expect(BannerParsers.description(fromHTML: description) == "Covers the derivative & integration.")

        let details = """
        <section aria-labelledby="catalog">
         <span class="status-bold">Title:</span>Algorithms and Data<br/>
         <span class="status-bold">College:</span>
         <span>Khoury Coll of Comp Sciences CS</span><br/>
         <span class="status-bold">Department:</span>
         <span>Computer Science CS</span><br/>
        </section>
        """
        let parsed = BannerParsers.catalogDetails(fromHTML: details)
        #expect(parsed.title == "Algorithms and Data")
        #expect(parsed.college == "Khoury College of Computer Sciences")
        #expect(parsed.department == "Computer Science")
    }

    @Test func decodesEntities() {
        #expect(HTMLText.decodeEntities("Fin Accounting &amp; Reporting") == "Fin Accounting & Reporting")
        #expect(HTMLText.decodeEntities("O&#39;Brien &#x2014; &quot;Hi&quot;") == "O'Brien — \"Hi\"")
        #expect(HTMLText.decodeEntities("AT&T") == "AT&T")
    }

    @Test func convertsBannerMeetingTimes() {
        let banner = BannerMeetingTime(
            beginTime: "0800", endTime: "0905", building: "DG", buildingDescription: "Dodge Hall", room: "070",
            campus: "BOS", campusDescription: "Boston", startDate: "09/09/2026", endDate: "12/13/2026",
            meetingType: "CLAS", meetingTypeDescription: "Class",
            monday: true, tuesday: false, wednesday: true, thursday: true, friday: false, saturday: false, sunday: false
        )
        let meeting = banner.toMeeting()
        #expect(meeting.start == 480)
        #expect(meeting.end == 545)
        #expect(meeting.days.compactLabel == "MWR")
        #expect(meeting.locationLabel == "DG 070")
        #expect(meeting.startDate == "2026-09-09")
        #expect(!meeting.isFinalExam)
    }
}
