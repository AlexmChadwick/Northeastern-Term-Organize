//
//  ShellSupportTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The logic behind the watchlist, free rooms and settings screens that both apps share: when a
//  watched section raises an alert, how a watched section is described, which classrooms are
//  free and until when, and the wording around them.
//

import Foundation
import Testing
@testable import NEUClassSearch

private enum ShellFixtures {
    static let cs3000 = CourseKey(subject: "CS", number: "3000")

    static func watchItem(
        crn: String = "12345", seats: Int = 0, waitlist: Int = 0, capacity: Int = 40,
        notifyOnWaitlist: Bool = false, termCode: String = "202710"
    ) -> WatchItem {
        var item = WatchItem(
            termCode: termCode, crn: crn, courseKey: cs3000, courseTitle: "Algorithms and Data",
            sectionLabel: "Lecture · Section 02", lastSeatsRemaining: seats, lastWaitlistRemaining: waitlist,
            seatCapacity: capacity
        )
        item.notifyOnWaitlist = notifyOnWaitlist
        return item
    }

    static func section(crn: String = "12345", seats: Int, waitlist: Int = 0, capacity: Int = 40) -> CourseSection {
        CourseSection(
            crn: crn, subject: "CS", number: "3000", title: "Algorithms and Data", sectionNumber: "02",
            partOfTerm: "1", seatCapacity: capacity, seatsRemaining: seats, enrollment: capacity - seats,
            waitlistCapacity: 10, waitlistCount: 10 - waitlist, waitlistRemaining: waitlist, classType: "Lecture",
            honors: false, campus: "Boston", instructionMethod: "Traditional", meetings: [],
            instructors: [], crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil
        )
    }

    /// A booking on Tuesday (day 2) unless `days` says otherwise.
    static func booking(
        _ code: String, start: Int, end: Int, days: [Int] = [2], from: String? = nil, to: String? = nil
    ) -> RoomSchedule.Booking {
        RoomSchedule.Booking(
            crn: "1\(start)", course: CourseKey(string: code) ?? cs3000, days: DaySet(indices: days),
            start: start, end: end, startDate: from, endDate: to
        )
    }

    static func room(_ bookings: [RoomSchedule.Booking], number: String = "210", building: String = "WVH") -> RoomSchedule {
        RoomSchedule(buildingCode: building, buildingName: "West Village H", room: number, bookings: bookings)
    }
}

// MARK: - Watchlist

struct WatchlistLogicTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aSectionThatGainsSeatsRaisesOneAlert() throws {
        let item = ShellFixtures.watchItem(seats: 0)
        let outcome = WatchlistComparison.compare(
            items: [item], live: ["202710": [ShellFixtures.cs3000: [ShellFixtures.section(seats: 3)]]], now: now
        )
        let alert = try #require(outcome.alerts.first)
        #expect(outcome.alerts.count == 1)
        #expect(alert.kind == .seats)
        #expect(alert.title == "Seats open in CS 3000")
        #expect(alert.body == "3 of 40 seats in Lecture 02 (CRN 12345). Register soon!")
        #expect(alert.url?.absoluteString == "termorganize://section/202710/12345")
        // The stored numbers follow the registrar, and the alert is remembered.
        #expect(outcome.items[0].lastSeatsRemaining == 3)
        #expect(outcome.items[0].lastNotifiedAt == now)
        #expect(outcome.items[0].lastCheckedAt == now)
    }

    @Test func aSectionThatAlreadyHadSeatsRaisesNoAlert() {
        let outcome = WatchlistComparison.compare(
            items: [ShellFixtures.watchItem(seats: 2)],
            live: ["202710": [ShellFixtures.cs3000: [ShellFixtures.section(seats: 5)]]], now: now
        )
        #expect(outcome.alerts.isEmpty)
        #expect(outcome.items[0].lastSeatsRemaining == 5)
    }

    @Test func waitlistAlertsNeedTheOptIn() {
        let live = ["202710": [ShellFixtures.cs3000: [ShellFixtures.section(seats: 0, waitlist: 2)]]]
        let optedOut = WatchlistComparison.compare(items: [ShellFixtures.watchItem()], live: live, now: now)
        #expect(optedOut.alerts.isEmpty)
        let optedIn = WatchlistComparison.compare(items: [ShellFixtures.watchItem(notifyOnWaitlist: true)], live: live, now: now)
        #expect(optedIn.alerts.map(\.kind) == [.waitlist])
        #expect(optedIn.alerts.first?.body == "2 waitlist spots open in Lecture 02 (CRN 12345). Join soon!")
    }

    @Test func aSectionTheRegistrarNoLongerListsIsReportedMissing() {
        let item = ShellFixtures.watchItem(crn: "99999", seats: 1)
        let outcome = WatchlistComparison.compare(
            items: [item], live: ["202710": [ShellFixtures.cs3000: [ShellFixtures.section(seats: 3)]]], now: now
        )
        #expect(outcome.missingIDs == [item.id])
        #expect(outcome.alerts.isEmpty)
        #expect(outcome.items[0].lastSeatsRemaining == 1)
    }

    @Test func termsThatWereNotCheckedStayUntouched() {
        let other = ShellFixtures.watchItem(seats: 0, termCode: "202730")
        let outcome = WatchlistComparison.compare(
            items: [other], live: ["202710": [ShellFixtures.cs3000: [ShellFixtures.section(seats: 3)]]], now: now
        )
        #expect(outcome.items == [other])
        #expect(outcome.checkedTermCodes == ["202710"])
    }

    @Test func statusesDescribeTheLastCheck() {
        let open = ShellFixtures.watchItem(seats: 3)
        #expect(WatchlistStatus(item: open, isMissing: false) == .open)
        #expect(WatchlistStatus.open.detail(for: open) == "3 of 40 open")
        #expect(WatchlistStatus.open.spokenDetail(for: open) == "3 of 40 seats open")

        let noLimit = ShellFixtures.watchItem(seats: 1, capacity: 0)
        #expect(WatchlistStatus.open.detail(for: noLimit) == "1 open")
        #expect(WatchlistStatus.open.spokenDetail(for: noLimit) == "1 seat open")

        let waitlist = ShellFixtures.watchItem(seats: 0, waitlist: 1)
        #expect(WatchlistStatus(item: waitlist, isMissing: false) == .waitlist)
        #expect(WatchlistStatus.waitlist.detail(for: waitlist) == "Full · 1 waitlist spot open")

        let full = ShellFixtures.watchItem(seats: 0)
        #expect(WatchlistStatus(item: full, isMissing: false) == .full)
        #expect(WatchlistStatus.full.detail(for: full) == "Full")
        // Missing wins over whatever numbers were last seen.
        #expect(WatchlistStatus(item: open, isMissing: true) == .missing)
        #expect(WatchlistStatus.missing.detail(for: open) == "No longer listed")
    }

    @Test func agoWordingGrowsWithTheTime() {
        #expect(WatchlistFormat.ago(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(WatchlistFormat.ago(now.addingTimeInterval(-5 * 60), now: now) == "5 min ago")
        #expect(WatchlistFormat.ago(now.addingTimeInterval(-3 * 3_600), now: now) == "3 hr ago")
        #expect(WatchlistFormat.ago(now.addingTimeInterval(-30 * 3_600), now: now) == "yesterday")
        #expect(WatchlistFormat.ago(now.addingTimeInterval(-4 * 86_400), now: now) == "4 days ago")
        // A check "in the future" (clocks differ) still reads sensibly.
        #expect(WatchlistFormat.ago(now.addingTimeInterval(60), now: now) == "just now")
    }
}

// MARK: - Free rooms

struct RoomAvailabilityTests {
    private func status(_ bookings: [RoomSchedule.Booking], at minutes: Int, weekday: Int = 2) -> RoomAvailability.Status {
        RoomAvailability.status(of: ShellFixtures.room(bookings), at: RoomAvailability.Moment(weekday: weekday, minutes: minutes))
    }

    @Test func aClassOccupiesItsStartUpToButNotIncludingItsEnd() {
        let classes = [ShellFixtures.booking("CS 3000", start: 600, end: 665)]
        #expect(status(classes, at: 599) == .free(until: 600))
        #expect(status(classes, at: 600).isFree == false)
        #expect(status(classes, at: 664).isFree == false)
        #expect(status(classes, at: 665) == .free(until: nil))
        // Another weekday is not affected.
        #expect(status(classes, at: 620, weekday: 3) == .free(until: nil))
    }

    @Test func backToBackClassesAreOneStretchOfUse() throws {
        let classes = [
            ShellFixtures.booking("CS 3000", start: 600, end: 665),
            ShellFixtures.booking("MATH 1341", start: 665, end: 730),
        ]
        guard case .busy(let occupancy) = status(classes, at: 620) else {
            Issue.record("expected the room to be in use")
            return
        }
        #expect(occupancy.until == 730)
        #expect(occupancy.freeUntil == nil)
    }

    @Test func aGapBetweenClassesIsReported() throws {
        let classes = [
            ShellFixtures.booking("CS 3000", start: 600, end: 665),
            ShellFixtures.booking("MATH 1341", start: 720, end: 780),
        ]
        guard case .busy(let occupancy) = status(classes, at: 620) else {
            Issue.record("expected the room to be in use")
            return
        }
        #expect(occupancy.until == 665)
        #expect(occupancy.freeUntil == 720)
        #expect(status(classes, at: 670) == .free(until: 720))
    }

    @Test func statusesReadAsSentences() {
        #expect(RoomAvailability.Status.free(until: 600).summary == "Free until 10:00 AM")
        #expect(RoomAvailability.Status.free(until: nil).summary == "Free for the rest of the day")
        let classes = [ShellFixtures.booking("CS 3000", start: 600, end: 665)]
        #expect(status(classes, at: 620).summary == "In use until 11:05 AM")
        #expect(status(classes, at: 620).detailedSummary == "In use: CS 3000 until 11:05 AM")
    }

    @Test func aRoomFreeForUnderHalfAnHourIsOnlyBrieflyFree() {
        let classes = [ShellFixtures.booking("CS 3000", start: 600, end: 665)]
        let soon = RoomAvailability.Moment(weekday: 2, minutes: 580)
        let early = RoomAvailability.Moment(weekday: 2, minutes: 500)
        #expect(status(classes, at: 580).isFreeOnlyBriefly(at: soon))
        #expect(!status(classes, at: 500).isFreeOnlyBriefly(at: early))
    }

    @Test func shortSessionsOnlyCountOnTheirOwnDates() throws {
        let workshop = ShellFixtures.booking("CS 2500", start: 600, end: 665, from: "2026-09-15", to: "2026-09-16")
        let room = ShellFixtures.room([workshop])
        // A typical week leaves one-off sessions out.
        #expect(RoomAvailability.bookings(of: room, on: 2).isEmpty)
        // The date window is read in the device's calendar, so build the dates in it too.
        let calendar = Calendar.current
        let during = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 10, minute: 15)))
        let after = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10, minute: 15)))
        #expect(RoomAvailability.bookings(of: room, on: 2, date: during).count == 1)
        #expect(RoomAvailability.bookings(of: room, on: 2, date: after).isEmpty)
    }

    @Test func freeStretchesAreTheGapsBetweenClasses() {
        let day = [
            ShellFixtures.booking("CS 3000", start: 600, end: 665),
            ShellFixtures.booking("MATH 1341", start: 665, end: 730),
            ShellFixtures.booking("PHYS 1151", start: 780, end: 840),
        ]
        // Back-to-back classes leave no gap; the day outside classes is free.
        #expect(RoomAvailability.freeStretches(in: day, from: 420, to: 1_320) == [420..<600, 730..<780, 840..<1_320])
        // Classes outside the window clip to it.
        #expect(RoomAvailability.freeStretches(in: day, from: 620, to: 800) == [730..<780])
        #expect(RoomAvailability.freeStretches(in: day, from: 600, to: 730).isEmpty)
        // An empty room is free the whole time, and an empty window has no stretches.
        #expect(RoomAvailability.freeStretches(in: [], from: 420, to: 1_320) == [420..<1_320])
        #expect(RoomAvailability.freeStretches(in: [], from: 600, to: 600).isEmpty)
        // Overlapping classes count once.
        let overlapping = [
            ShellFixtures.booking("CS 3000", start: 600, end: 700),
            ShellFixtures.booking("CS 3001", start: 650, end: 680),
        ]
        #expect(RoomAvailability.freeStretches(in: overlapping, from: 600, to: 800) == [700..<800])
    }

    @Test func freeRoomCountsAreTheRoomsWithNoClassDuringTheWholeHour() {
        let busyMorning = ShellFixtures.room([
            ShellFixtures.booking("CS 3000", start: 9 * 60 + 50, end: 11 * 60 + 30),
        ], number: "210", building: "RY")
        let busyAfternoon = ShellFixtures.room([
            ShellFixtures.booking("MATH 1341", start: 13 * 60, end: 14 * 60),
        ], number: "300", building: "RY")
        let empty = ShellFixtures.room([], number: "400", building: "RY")
        let counts = RoomAvailability.freeRoomCounts(of: [busyMorning, busyAfternoon, empty], on: 2)
        // One entry for each hour from 7 AM to 10 PM.
        #expect(counts.count == 15)
        #expect(counts[0] == 3)        // 7-8 AM: nothing is scheduled
        #expect(counts[2] == 2)        // 9-10 AM: a class starts at 9:50
        #expect(counts[3] == 2)        // 10-11 AM
        #expect(counts[4] == 2)        // 11 AM-noon: the class ends at 11:30
        #expect(counts[5] == 3)        // noon-1 PM: free again, the other class starts at 1 PM sharp
        #expect(counts[6] == 2)        // 1-2 PM: the other room has a class
        #expect(counts[7] == 3)        // 2-3 PM: it ended at exactly 2 PM
        #expect(RoomAvailability.freeRoomCounts(of: [], on: 2) == Array(repeating: 0, count: 15))
        // A weekday without classes leaves every room free.
        #expect(RoomAvailability.freeRoomCounts(of: [busyMorning], on: 0) == Array(repeating: 1, count: 15))
    }

    @Test func searchMatchesBuildingsAndRoomsByTheirWords() {
        let ryder = BuildingSummary(code: "RY", name: "Ryder Hall", campusCode: "BOS", rooms: [
            ShellFixtures.room([], number: "210", building: "RY"), ShellFixtures.room([], number: "300", building: "RY"),
        ])
        let snell = BuildingSummary(code: "SL", name: "Snell Library", campusCode: "BOS", rooms: [
            ShellFixtures.room([], number: "210", building: "SL"),
        ])
        let moment = RoomAvailability.Moment(weekday: 2, minutes: 600)
        let all = RoomAvailability.availability(of: [ryder, snell], at: moment)

        #expect(RoomAvailability.filter(all, matching: "ry").map(\.building.code) == ["RY"])
        #expect(RoomAvailability.filter(all, matching: "snell").map(\.building.code) == ["SL"])
        // A building that matches on its own keeps all its rooms…
        #expect(RoomAvailability.filter(all, matching: "ryder").first?.free.count == 2)
        // …while a room number narrows to the rooms with it, in every building.
        let byRoom = RoomAvailability.filter(all, matching: "210")
        #expect(byRoom.map(\.building.code) == ["RY", "SL"])
        #expect(byRoom.first?.free.map(\.room.room) == ["210"])
        #expect(RoomAvailability.filter(all, matching: "  ").count == 2)
    }

    @Test func momentsStayWithinTheWeek() {
        let wrapped = RoomAvailability.Moment(weekday: 8, minutes: 99_999)
        #expect(wrapped.weekday == 1)
        #expect(wrapped.minutes == 24 * 60 - 1)
        #expect(RoomAvailability.Moment(weekday: 2, minutes: 600).isWithinClassHours)
        #expect(!RoomAvailability.Moment(weekday: 2, minutes: 6 * 60).isWithinClassHours)
        #expect(RoomAvailability.Moment(weekday: 2, minutes: 14 * 60 + 30).label == "Tuesday at 2:30 PM")
    }

    @Test func followUpNotesSayWhatComesNext() {
        let today = [
            ShellFixtures.booking("CS 3000", start: 600, end: 665),
            ShellFixtures.booking("MATH 1341", start: 720, end: 780),
        ]
        #expect(RoomsText.followUpNote(status: .free(until: 600), today: today) == "Next: CS 3000, 10:00 – 11:05 AM")
        #expect(RoomsText.followUpNote(status: .free(until: nil), today: today) == "No more classes today.")
        #expect(RoomsText.followUpNote(status: .free(until: nil), today: []) == "No classes are scheduled here today.")
        guard case .busy(let occupancy) = RoomAvailability.status(of: today, at: 620) else {
            Issue.record("expected the room to be in use")
            return
        }
        #expect(RoomsText.followUpNote(status: .busy(occupancy), today: today) == "Then free until 12:00 PM")
        #expect(RoomsText.freeSummary(free: 12, total: 40) == "12 of 40 rooms free")
        #expect(RoomsText.freeSummary(free: 1, total: 1) == "1 of 1 room free")
    }
}

// MARK: - Settings

struct SettingsSupportTests {
    @Test func hourLabelsUseTheTwelveHourClock() {
        #expect(SettingsFormat.hourLabel(0) == "12 AM")
        #expect(SettingsFormat.hourLabel(8) == "8 AM")
        #expect(SettingsFormat.hourLabel(12) == "12 PM")
        #expect(SettingsFormat.hourLabel(21) == "9 PM")
        // 24 is the midnight that ends the day.
        #expect(SettingsFormat.hourLabel(24) == "12 AM")
    }

    @Test func legalTextNamesTheLicenseAndWhereToReadIt() {
        #expect(LegalText.licenseURL.absoluteString == "https://www.gnu.org/licenses/agpl-3.0.html")
        #expect(LegalText.searchNEUSummary.contains("\(LegalText.platformName) adaptation of SearchNEU"))
    }
}
