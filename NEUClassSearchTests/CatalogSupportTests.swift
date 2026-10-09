//
//  CatalogSupportTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// The logic of the catalog screens (search, subjects, saved courses, professors, the course page) that
/// the iPhone, iPad and Mac interfaces share.
@MainActor
struct CatalogSupportTests {
    private static var index: CatalogIndex? { SearchEngineTests.index }

    // MARK: Search filters

    @Test func dayPresetsDescribeTheirDays() {
        #expect(SearchDayPreset.selection(for: nil) == .any)
        #expect(SearchDayPreset.selection(for: [.monday, .tuesday, .wednesday, .thursday]) == .noFridays)
        #expect(SearchDayPreset.selection(for: [.tuesday, .friday]) == .tf)
        // A set no preset describes reads as custom, which is never matched by `matching`.
        #expect(SearchDayPreset.selection(for: [.monday, .friday]) == .custom)
        #expect(SearchDayPreset.matching([.monday, .friday]) == nil)
        for preset in SearchDayPreset.allCases where preset != .custom {
            #expect(SearchDayPreset.selection(for: preset.days) == preset)
        }
    }

    @Test func filterChipTitles() {
        #expect(SearchFilterTitles.days(nil) == "Days")
        #expect(SearchFilterTitles.days([.monday, .tuesday, .wednesday, .thursday]) == "No Fridays")
        #expect(SearchFilterTitles.days([.monday, .friday]) == "MF only")
        #expect(SearchFilterTitles.days([]) == "No set days")
        #expect(SearchFilterTitles.subjects([]) == "Subject")
        #expect(SearchFilterTitles.subjects(["CS"]) == "CS")
        #expect(SearchFilterTitles.subjects(["CS", "DS", "MATH"]) == "3 subjects")
        #expect(SearchFilterTitles.nupaths([.fq, .wi]) == "FQ, WI")
        #expect(SearchFilterTitles.nupaths([.fq, .wi, .ce]) == "NUpath · 3")
        #expect(SearchFilterTitles.level(0) == "Under 1000")
        #expect(SearchFilterTitles.level(3) == "3000")
    }

    @Test func timeOfDayConversionRoundTrips() {
        for minutes in [0, 9 * 60, 12 * 60 + 35, 17 * 60, 23 * 60 + 59] {
            #expect(SearchTimeOfDay.minutes(from: SearchTimeOfDay.date(fromMinutes: minutes)) == minutes)
        }
        // Out-of-range values are clamped to the day.
        #expect(SearchTimeOfDay.minutes(from: SearchTimeOfDay.date(fromMinutes: -30)) == 0)
        #expect(SearchTimeOfDay.minutes(from: SearchTimeOfDay.date(fromMinutes: 5_000)) == 24 * 60 - 1)
    }

    @Test func quickSearchesApplyExactlyOneFilter() {
        for preset in HomeQuickSearch.allCases {
            #expect(preset.filters.activeCount == 1, "\(preset.title)")
            #expect(!preset.symbol.isEmpty)
        }
        #expect(HomeQuickSearch.openSeats.filters.openSeatsOnly)
        #expect(HomeQuickSearch.honors.filters.honorsOnly)
        #expect(HomeQuickSearch.online.filters.instruction == .online)
        #expect(HomeQuickSearch.noFridays.filters.allowedDays == [.monday, .tuesday, .wednesday, .thursday])
        #expect(HomeQuickSearch.firstYear.filters.levels == [1])
    }

    @Test func quickSearchesFindCourses() throws {
        let index = try #require(Self.index)
        for preset in HomeQuickSearch.allCases {
            let response = SearchEngine.search(SearchQuery(text: "", filters: preset.filters), in: index)
            #expect(!response.results.isEmpty, "\(preset.title) found nothing in the bundled catalog")
        }
    }

    // MARK: Lists of courses

    @Test func browseSummaryLines() {
        #expect(browseSummaryText(shown: 42, total: 42, open: 0) == "42 courses")
        #expect(browseSummaryText(shown: 1, total: 1, open: 0) == "1 course")
        #expect(browseSummaryText(shown: 12, total: 42, open: 9) == "12 of 42 courses · 9 with open seats")
        // "Open seats only" already says that every course shown has some.
        #expect(browseSummaryText(shown: 9, total: 42, open: 9, openOnly: true) == "9 of 42 courses")
        #expect(browseSummaryText(shown: 2, total: 2, open: 0, noun: "professor") == "2 professors")
        #expect(browseLevelTitle(1) == "1000-level")
        #expect(browseLevelTitle(0) == "Under 1000")
        #expect(browseLevelNoun(3) == "3000-level courses")
        #expect(browseLevelNoun(0) == "courses under 1000")
    }

    @Test func popularSubjectsAreTheBusiest() throws {
        let index = try #require(Self.index)
        let popular = index.popularSubjects(limit: 12)
        #expect(popular.count == 12)
        let counts = popular.map { index.courseCountBySubject[$0.code] ?? 0 }
        #expect(counts == counts.sorted(by: >))
        // Nothing busier was left out.
        let busiestOutside = index.activeSubjects
            .filter { subject in !popular.contains { $0.code == subject.code } }
            .map { index.courseCountBySubject[$0.code] ?? 0 }
            .max() ?? 0
        #expect((counts.last ?? 0) >= busiestOutside)
        #expect(index.popularSubjects(limit: 3).map(\.code) == Array(popular.prefix(3)).map(\.code))
    }

    @Test func searchExamplesAllFindSomething() throws {
        let index = try #require(Self.index)
        let examples = SearchExampleCache.examples(for: index)
        #expect(examples.count >= 3)
        for example in examples {
            let response = SearchEngine.search(SearchQuery(text: example.title), in: index)
            let found = !response.results.isEmpty || response.crnMatch != nil || !response.instructors.isEmpty
            #expect(found, "“\(example.title)” (\(example.caption)) found nothing")
        }
    }

    // MARK: Professors

    @Test func professorPageOrdersSectionsAndGivesEachCourseItsOwnColor() throws {
        let index = try #require(Self.index)
        let summary = try #require(index.instructors.first { $0.courseKeys.count >= 3 })
        let sections = ProfessorPage.sections(of: summary, in: index)
        #expect(sections.count == summary.crns.count)
        for (earlier, later) in zip(sections, sections.dropFirst()) {
            #expect(earlier.courseKey <= later.courseKey)
        }

        let keys = Array(summary.courseKeys.prefix(CourseColor.palette.count))
        let colors = ProfessorPage.courseColors(for: keys)
        #expect(colors.count == keys.count)
        #expect(Set(colors.values).count == keys.count, "two of the courses share a color")
        // The color is stable: the same keys give the same colors.
        #expect(ProfessorPage.courseColors(for: keys) == colors)
    }

    @Test func professorPageTexts() {
        let a = CourseKey(subject: "CS", number: "3000")
        let b = CourseKey(subject: "CS", number: "3001")
        func section(_ key: CourseKey, _ number: String) -> CourseSection {
            CourseSection(
                crn: "\(key.number)\(number)", subject: key.subject, number: key.number, title: "T", sectionNumber: number,
                partOfTerm: "1", seatCapacity: 10, seatsRemaining: 5, enrollment: 5, waitlistCapacity: 0, waitlistCount: 0,
                waitlistRemaining: 0, classType: "Lecture", honors: false, campus: "Boston", instructionMethod: nil,
                meetings: [], instructors: nil, crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil
            )
        }
        let sections = [section(a, "01"), section(a, "04"), section(b, "02")]
        #expect(ProfessorPage.summaryText(for: sections) == "Teaches 3 sections across 2 courses")
        #expect(ProfessorPage.summaryText(for: [sections[2]]) == "Teaches 1 section across 1 course")
        #expect(ProfessorPage.sectionNote(for: a, in: sections) == "Sections 01, 04")
        #expect(ProfessorPage.sectionNote(for: b, in: sections) == "Section 02")
        #expect(ProfessorPage.rateMyProfessorsURL(for: "Jane Doe")?.absoluteString
                == "https://www.ratemyprofessors.com/search/professors/696?q=Jane%20Doe")
        #expect(ProfessorPage.rateMyProfessorsURL(for: "José O'Neil-Smith")?.absoluteString.contains("q=Jos%C3%A9%20O%27Neil-Smith") == true)
    }

    // MARK: The course page

    @Test func degreePlanStandingTexts() {
        let plan = UUID()
        let completed = CourseDegreePlanStanding(planID: plan, kind: .completed(via: nil))
        #expect(completed.text == "Completed")
        #expect(completed.symbol == "checkmark.circle.fill")
        #expect(completed.spokenText == "Completed, in your degree plan")
        let via = CourseDegreePlanStanding(planID: plan, kind: .completed(via: CourseKey(subject: "CS", number: "2510")))
        #expect(via.text == "Completed via CS 2510")
        let planned = CourseDegreePlanStanding(planID: plan, kind: .planned("Spring 2027", via: nil))
        #expect(planned.text == "Planned · Spring 2027")
        #expect(planned.symbol == "calendar")
        let plannedVia = CourseDegreePlanStanding(planID: plan, kind: .planned("Spring 2027", via: CourseKey(subject: "CS", number: "2510")))
        #expect(plannedVia.text == "Planned via CS 2510 · Spring 2027")
        #expect(plannedVia.spokenText == "Planned via CS 2510 for Spring 2027 in your degree plan")
    }

    @Test func courseIsInScheduleCountsOnlyThePlansOfTheTerm() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogSupportTests-\(UUID().uuidString).json")
        let store = UserDataStore(fileURL: file)
        // Write now (a save is pending after each change) so nothing lands after the file is removed.
        defer {
            store.flushNow()
            try? FileManager.default.removeItem(at: file)
        }
        let key = CourseKey(subject: "CS", number: "3000")
        #expect(!store.courseIsInSchedule(termCode: "202710", key: key))

        let plan = store.createPlan(name: "Plan A", termCode: "202710")
        store.addCourse(key, toPlan: plan.id)
        #expect(store.courseIsInSchedule(termCode: "202710", key: key))
        // Another term's plans don't count.
        #expect(!store.courseIsInSchedule(termCode: "202630", key: key))
        // A section counts once the plan has chosen it.
        #expect(!store.courseIsInSchedule(termCode: "202710", key: key, crn: "12726"))
        store.updatePlan(id: plan.id) { $0.selectedCRNs.append("12726") }
        #expect(store.courseIsInSchedule(termCode: "202710", key: key, crn: "12726"))
    }
}
