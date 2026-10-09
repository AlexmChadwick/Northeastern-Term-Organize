//
//  ScheduleLogicTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

struct ScheduleLogicTests {
    private func meeting(days: [Int], start: Int, end: Int, from: String?, to: String?) -> Meeting {
        Meeting(days: DaySet(indices: days), start: start, end: end, buildingCode: "RI", building: "Richards Hall",
                room: "300", campusCode: "BOS", kind: "Class", startDate: from, endDate: to)
    }

    @Test func halfTermSectionsDoNotConflict() {
        let firstHalf = meeting(days: [1, 3], start: 600, end: 665, from: "2026-09-09", to: "2026-10-27")
        let secondHalf = meeting(days: [1, 3], start: 600, end: 665, from: "2026-10-28", to: "2026-12-13")
        let fullTerm = meeting(days: [3], start: 630, end: 700, from: "2026-09-09", to: "2026-12-13")
        #expect(!firstHalf.overlaps(with: secondHalf))
        #expect(firstHalf.overlaps(with: fullTerm))
        #expect(secondHalf.overlaps(with: fullTerm))
        // Missing dates are open-ended.
        #expect(firstHalf.overlaps(with: meeting(days: [1], start: 640, end: 700, from: nil, to: nil)))
    }

    @Test func calendarConflictsRespectDates() {
        let color = CourseColor.at(0)
        let a = CalendarEvent(id: "a", title: "A", day: 1, start: 600, end: 665, color: color, payload: "1",
                              startDate: "2026-09-09", endDate: "2026-10-27")
        let b = CalendarEvent(id: "b", title: "B", day: 1, start: 600, end: 665, color: color, payload: "2",
                              startDate: "2026-10-28", endDate: "2026-12-13")
        let c = CalendarEvent(id: "c", title: "C", day: 1, start: 630, end: 700, color: color, payload: "3")
        let allConflict = CalendarEvent.markingConflicts([a, b, c]).allSatisfy { $0.isConflict }
        #expect(allConflict)                                  // each overlaps the open-ended C
        let anyConflict = CalendarEvent.markingConflicts([a, b]).contains { $0.isConflict }
        #expect(!anyConflict)                                 // halves alone don't conflict
    }

    @Test func widgetMeetingsHonorDateWindows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Monday 2026-11-02, 9:00.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        let early = WidgetScheduleData.Meeting(id: "a", crn: "1", courseCode: "ARTF 1220", title: "A", location: "RY 200",
                                               classType: "Lecture", weekday: 1, start: 600, end: 665, colorIndex: 0,
                                               startDate: "2026-09-09", endDate: "2026-10-27")
        let late = WidgetScheduleData.Meeting(id: "b", crn: "2", courseCode: "ARTF 1221", title: "B", location: "RY 200",
                                              classType: "Lecture", weekday: 1, start: 600, end: 665, colorIndex: 1,
                                              startDate: "2026-10-28", endDate: "2026-12-13")
        let data = WidgetScheduleData(generatedAt: now, termCode: "202710", termName: "Fall 2026", planName: "Plan",
                                      classesStart: nil, classesEnd: nil, meetings: [early, late])
        let today = data.classes(on: now, calendar: calendar).map { $0.meeting.courseCode }
        #expect(today == ["ARTF 1221"])
        #expect(data.occurrences(from: now, limit: 1, calendar: calendar).first?.meeting.courseCode == "ARTF 1221")
    }

    @Test func termWindowsAreSensible() throws {
        let fall = try #require(TermCalendar.approximateWindow(for: "202710"))
        let spring = try #require(TermCalendar.approximateWindow(for: "202730"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TermCalendar.newYork
        #expect(calendar.component(.year, from: fall.lowerBound) == 2026)
        #expect(calendar.component(.month, from: fall.lowerBound) == 9)
        #expect(calendar.component(.year, from: spring.lowerBound) == 2027)
        #expect(fall.upperBound < spring.lowerBound)
    }

    @MainActor
    @Test func activePlanFollowsTheTermInSession() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UserData-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UserDataStore(fileURL: url)
        let fall = store.createPlan(name: "Fall", termCode: "202710")
        let spring = store.createPlan(name: "Spring", termCode: "202730")
        store.updatePlan(id: fall.id) { $0.selectedCRNs = ["10001"] }
        store.updatePlan(id: spring.id) { $0.selectedCRNs = ["20001"] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TermCalendar.newYork
        let midFall = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15)))
        let winterBreak = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 28)))
        let longAfter = try #require(calendar.date(from: DateComponents(year: 2027, month: 7, day: 1)))

        // Browsing/planning Spring must not hide Fall while Fall is in session.
        #expect(store.activePrimaryPlan(now: midFall)?.id == fall.id)
        // Between terms, the next term to start wins.
        #expect(store.activePrimaryPlan(now: winterBreak)?.id == spring.id)
        // Long after both ended, nothing is shown.
        #expect(store.activePrimaryPlan(now: longAfter) == nil)
    }
}
