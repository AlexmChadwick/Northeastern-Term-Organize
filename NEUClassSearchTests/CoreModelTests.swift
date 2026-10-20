//
//  CoreModelTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

struct CoreModelTests {
    @Test func termNames() {
        #expect(Term(code: "202710", bannerDescription: "Fall 2026 Semester").name == "Fall 2026")
        #expect(Term(code: "202630", bannerDescription: "Spring 2026 Semester (View Only)").name == "Spring 2026")
        let cps = Term(code: "202635", bannerDescription: "Spring 2026 CPS Quarter (View Only)")
        #expect(cps.name == "Spring 2026 · CPS Quarter")
        #expect(cps.shortName == "Spring 2026")
        #expect(cps.college == .cps)
        #expect(cps.isViewOnly)
        #expect(Term(code: "202710", bannerDescription: "").season == .fall)
        #expect(Term(code: "202710", bannerDescription: "").calendarYear == 2026)
        #expect(Term(code: "202630", bannerDescription: "").calendarYear == 2026)
    }

    @Test func courseKeyParsing() {
        #expect(CourseKey(string: "CS 3000") == CourseKey(subject: "CS", number: "3000"))
        #expect(CourseKey(string: "cs3000") == CourseKey(subject: "CS", number: "3000"))
        #expect(CourseKey(string: "math-209m") == CourseKey(subject: "MATH", number: "209M"))
        #expect(CourseKey(string: "3000") == nil)
        #expect(CourseKey(subject: "CS", number: "3000").level == 3)
        #expect(CourseKey(subject: "CS", number: "2100") < CourseKey(subject: "CS", number: "3000"))
        #expect(CourseKey(subject: "CS", number: "900") < CourseKey(subject: "CS", number: "1800"))
    }

    @Test func daySets() {
        let mwr = DaySet(indices: [1, 3, 4])
        #expect(mwr.compactLabel == "MWR")
        #expect(mwr.contains(day: 3))
        #expect(!mwr.contains(day: 2))
        #expect(mwr.count == 3)
        #expect(mwr.isSubset(of: .weekdays))
        #expect(!DaySet(day: 6).isSubset(of: .weekdays))
    }

    @Test func timeFormatting() {
        #expect(TimeOfDay.minutes(fromHHMM: 1435) == 875)
        #expect(TimeOfDay.label(875) == "2:35 PM")
        #expect(TimeOfDay.label(0) == "12:00 AM")
        #expect(TimeOfDay.rangeLabel(start: 630, end: 695) == "10:30 – 11:35 AM")
        #expect(TimeOfDay.rangeLabel(start: 705, end: 805) == "11:45 AM – 1:25 PM")
        #expect(CreditFormatter.label(min: 4, max: 4) == "4 credits")
        #expect(CreditFormatter.label(min: 1, max: 1) == "1 credit")
        #expect(CreditFormatter.label(min: 1, max: 4) == "1–4 credits")
    }

    @Test func requisiteHelpers() {
        let a = CourseKey(subject: "CS", number: "2100")
        let b = CourseKey(subject: "CS", number: "2510")
        let c = CourseKey(subject: "CS", number: "1800")
        let nested = Requisite.and([.or([.course(a), .or([.course(b)])]), .and([.course(c)])])
        let simplified = nested.simplified()
        #expect(simplified == .and([.or([.course(a), .course(b)]), .course(c)]))
        #expect(nested.referencedCourses == [a, b, c])
        #expect(simplified?.summary == "(CS 2100 or CS 2510) and CS 1800")
        #expect(simplified?.isSatisfied(by: [a, c]) == true)
        #expect(simplified?.isSatisfied(by: [a]) == false)
    }

    @Test func instructorNames() {
        #expect(Instructor(name: "Ptitsyna, Natalia", primary: true).displayName == "Natalia Ptitsyna")
        #expect(Instructor(name: "Staff", primary: false).displayName == "Staff")
    }

    @Test func instructorEmailsStayOnNortheasternDomains() {
        func faculty(_ email: String) -> BannerFaculty {
            BannerFaculty(displayName: "Ada, Lovelace", emailAddress: email, primaryIndicator: true)
        }
        #expect(faculty("a.lovelace@northeastern.edu").toInstructor()?.email == "a.lovelace@northeastern.edu")
        #expect(faculty("Ada@NEU.edu").toInstructor()?.email == "Ada@NEU.edu")
        #expect(faculty("  ada@northeastern.edu  ").toInstructor()?.email == "ada@northeastern.edu")
        #expect(faculty("Ada Lovelace <ada@northeastern.edu>").toInstructor()?.email == "ada@northeastern.edu")
        // Subdomains are not the institutional domains, and husky.neu.edu is a student domain.
        #expect(faculty("ada@husky.neu.edu").toInstructor()?.email == nil)
        #expect(faculty("ada@coe.neu.edu").toInstructor()?.email == nil)
        #expect(faculty("ada@ece.northeastern.edu").toInstructor()?.email == nil)
        #expect(faculty("ada@gmail.com").toInstructor()?.email == nil)
        #expect(faculty("not-an-email").toInstructor()?.email == nil)
        #expect(faculty("   ").toInstructor()?.email == nil)
        #expect(faculty("ada@gmail.com").toInstructor()?.name == "Ada, Lovelace")
    }

    @Test func catalogArchiveRoundTrip() throws {
        let term = Term(code: "202710", bannerDescription: "Fall 2026 Semester")
        let course = Course(subject: "CS", number: "3000", title: "Algorithms and Data", description: "Introduces…",
                            minCredits: 4, maxCredits: 4, attributes: ["NCFQ"], prereqs: .course(CourseKey(subject: "CS", number: "2100")),
                            coreqs: nil, postreqs: [], specialTopics: false, college: nil, department: nil, detailsLoaded: true)
        var catalog = TermCatalog(term: term, courses: [course], sections: [], subjects: [], attributes: [], campuses: [])
        catalog.recomputePostreqs()
        let data = try CatalogArchive.encode(catalog)
        let decoded = try CatalogArchive.decode(data)
        #expect(decoded.courses.first?.title == "Algorithms and Data")
        #expect(decoded.courses.first?.nupaths == [.fq])
        #expect(decoded.courses.first?.prereqs == .course(CourseKey(subject: "CS", number: "2100")))
        #expect(CatalogArchive.termCode(fromFileName: "term-202710.catalog") == "202710")
    }

    @Test func widgetOccurrencesSkipFinishedClasses() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Wednesday 2026-09-16 at 10:00.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 10)))
        let meetings = [
            WidgetScheduleData.Meeting(id: "a", crn: "1", courseCode: "CS 3000", title: "Algo", location: "WVH 210",
                                       classType: "Lecture", weekday: 3, start: 9 * 60, end: 9 * 60 + 65, colorIndex: 0),
            WidgetScheduleData.Meeting(id: "b", crn: "2", courseCode: "MATH 2331", title: "LinAlg", location: "RI 300",
                                       classType: "Lecture", weekday: 3, start: 13 * 60, end: 14 * 60 + 5, colorIndex: 1),
        ]
        let data = WidgetScheduleData(generatedAt: now, termCode: "202710", termName: "Fall 2026", planName: "Plan",
                                      classesStart: nil, classesEnd: nil, meetings: meetings)
        // At 10:00 the 9:00–10:05 class is still in progress, so it comes first.
        let duringFirst = data.occurrences(from: now, limit: 3, calendar: calendar)
        #expect(duringFirst.first?.meeting.courseCode == "CS 3000")
        #expect(duringFirst.count == 3) // next week's classes follow
        // Once it ends, the afternoon class is next.
        let afterFirst = data.occurrences(from: now.addingTimeInterval(30 * 60), limit: 1, calendar: calendar)
        #expect(afterFirst.first?.meeting.courseCode == "MATH 2331")
        #expect(data.classes(on: now, calendar: calendar).count == 2)
    }
}
