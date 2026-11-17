//
//  AddCourseSearchTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import TermOrganizeKit

@Suite struct AddCourseSearchTests {
    private func result(_ subject: String, _ number: String, title: String, score: Double) -> SearchResult {
        let course = Course(
            subject: subject, number: number, title: title, description: "",
            minCredits: 4, maxCredits: 4, defaultCredits: 4, attributes: [],
            prereqs: nil, coreqs: nil, postreqs: [], specialTopics: false,
            college: nil, department: nil, detailsLoaded: true
        )
        return SearchResult(course: course, stats: CourseStats(), score: score, matchNote: nil)
    }

    @Test func mergeKeepsTheNewestCopy() {
        let newer = [result("CS", "3000", title: "New", score: 1)]
        let older = [result("CS", "3000", title: "Old", score: 5), result("CS", "3520", title: "PL", score: 1)]
        let merged = AddCourseSearch.merge([newer, older])
        #expect(merged.count == 2)
        #expect(merged.first { $0.course.number == "3000" }?.course.title == "New")
        #expect(merged.contains { $0.course.number == "3520" })
    }

    @Test func mergeOrdersByScoreThenNewestCatalog() {
        let newer = [result("CS", "1000", title: "A", score: 2)]
        let older = [result("CS", "2000", title: "B", score: 2), result("CS", "3000", title: "C", score: 9)]
        let merged = AddCourseSearch.merge([newer, older])
        #expect(merged.map(\.course.number) == ["3000", "1000", "2000"])
    }

    @Test func mergeOfNothingIsEmpty() {
        #expect(AddCourseSearch.merge([]).isEmpty)
        #expect(AddCourseSearch.merge([[], []]).isEmpty)
    }

    @Test func codeParsesWithOrWithoutSpace() {
        #expect(AddCourseSearch.codeKey(from: "CS 3520") == CourseKey(subject: "CS", number: "3520"))
        #expect(AddCourseSearch.codeKey(from: "  cs3520 ") == CourseKey(subject: "CS", number: "3520"))
        #expect(AddCourseSearch.codeKey(from: "cs-3520") == CourseKey(subject: "CS", number: "3520"))
    }

    @Test func codeRejectsTitlesAndNonNumericNumbers() {
        #expect(AddCourseSearch.codeKey(from: "") == nil)
        #expect(AddCourseSearch.codeKey(from: "algorithms") == nil)
        #expect(AddCourseSearch.codeKey(from: "CS") == nil)
        #expect(AddCourseSearch.codeKey(from: "CS 35X0") == nil)
        #expect(AddCourseSearch.codeKey(from: "CS ABC") == nil)
        #expect(AddCourseSearch.codeKey(from: "data structures") == nil)
    }
}
