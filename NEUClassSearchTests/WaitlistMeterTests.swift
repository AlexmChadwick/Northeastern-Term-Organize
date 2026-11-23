//
//  WaitlistMeterTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  How a section held by a waitlist is drawn: the seat meter, the seat color, the seat summary
//  number, the Mac picker's seat sort and the seats a new watch starts from.
//

import Foundation
import Testing
@testable import NEUClassSearch

@MainActor
struct WaitlistMeterTests {
    private static func section(
        crn: String = "39766", seats: Int, capacity: Int = 15, onWaitlist: Int = 0
    ) -> CourseSection {
        CourseSection(
            crn: crn, subject: "INAM", number: "1925", title: "Topics", sectionNumber: "01",
            partOfTerm: "1", seatCapacity: capacity, seatsRemaining: seats, enrollment: capacity - seats,
            waitlistCapacity: 10, waitlistCount: onWaitlist, waitlistRemaining: 10 - onWaitlist, classType: "Lecture",
            honors: false, campus: "Boston", instructionMethod: "Traditional", meetings: [],
            instructors: [], crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil
        )
    }

    // MARK: Meter

    @Test func aWaitlistHoldDrawsAFullOrangeBarNeverGreen() {
        let hold = Self.section(seats: 13, onWaitlist: 4)
        let held = SeatMeterAppearance.make(remaining: hold.openSeats, capacity: 15, isWaitlistHold: hold.isWaitlistHold)
        #expect(held == SeatMeterAppearance(fill: 1, tone: .orange))
        // The same numbers without a queue are plenty of room: a nearly empty green bar.
        let open = SeatMeterAppearance.make(remaining: 13, capacity: 15)
        #expect(open.tone == .green)
        #expect(open.fill < 0.2)
    }

    @Test func aFullQueuedSectionDrawsAFullRedBar() {
        let full = Self.section(seats: 0, onWaitlist: 7)
        let appearance = SeatMeterAppearance.make(remaining: full.openSeats, capacity: 15, isWaitlistHold: full.isWaitlistHold)
        #expect(appearance == SeatMeterAppearance(fill: 1, tone: .red))
    }

    @Test func meterFillAndToneForPlainSections() {
        #expect(SeatMeterAppearance.make(remaining: 2, capacity: 40) == SeatMeterAppearance(fill: 0.95, tone: .orange))
        #expect(SeatMeterAppearance.make(remaining: -3, capacity: 40) == SeatMeterAppearance(fill: 1, tone: .red))
        #expect(SeatMeterAppearance.make(remaining: 0, capacity: 0) == SeatMeterAppearance(fill: 1, tone: .red))
        #expect(SeatMeterAppearance.make(remaining: 5, capacity: 0) == SeatMeterAppearance(fill: 1, tone: .green))
    }

    @Test func theSectionMeterReadsOpenSeats() {
        let meter = SeatMeter(section: Self.section(seats: 13, onWaitlist: 4))
        #expect(meter.remaining == 0)
        #expect(meter.isWaitlistHold)
        #expect(SeatMeter(section: Self.section(seats: 13)).remaining == 13)
    }

    // MARK: Color

    @Test func seatToneForASectionHonorsTheWaitlistHold() {
        #expect(Theme.seatTone(for: Self.section(seats: 13, onWaitlist: 4)) == .orange)
        #expect(Theme.seatTone(for: Self.section(seats: 13)) == .green)
        #expect(Theme.seatTone(for: Self.section(seats: 0, onWaitlist: 7)) == .red)
        #expect(Theme.seatColor(for: Self.section(seats: 13, onWaitlist: 4)) == .orange)
    }

    // MARK: Seat summary

    @Test func theSeatSummaryNeverCountsHeldSeatsAsOpen() {
        #expect(SectionSeatsSummary.openCount(Self.section(seats: 13, onWaitlist: 4)) == 0)
        #expect(SectionSeatsSummary.openCount(Self.section(seats: 13)) == 13)
        #expect(SectionSeatsSummary.openCount(Self.section(seats: -2)) == 0)
        #expect(SectionSeatsSummary.hasSeatData(Self.section(seats: 0)))
        #expect(!SectionSeatsSummary.hasSeatData(Self.section(seats: 0, capacity: 0)))
    }

    // MARK: Mac section picker seat sort

    /// `MacSectionPicker.Row.seats` is `section.openSeats`; the Mac target is not in the test bundle, so this
    /// sorts by the same key. A queued section with free seats sorts as 0, below a truly open one.
    @Test func theSeatSortKeyPutsQueuedSectionsAmongTheFullOnes() {
        let sections = [
            Self.section(crn: "1", seats: 13, onWaitlist: 4),
            Self.section(crn: "2", seats: 3),
            Self.section(crn: "3", seats: 0),
        ]
        let ascending = sections.sorted { $0.openSeats < $1.openSeats }.map(\.crn)
        #expect(ascending.last == "2")
        #expect(Set(ascending.prefix(2)) == ["1", "3"])
    }

    // MARK: Watch seeding

    @Test func watchingAQueuedSectionStartsFromZeroOpenSeats() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("WaitlistMeterTests-\(UUID().uuidString).json")
        let store = UserDataStore(fileURL: file)
        defer {
            store.flushNow()
            try? FileManager.default.removeItem(at: file)
        }
        store.watch(Self.section(crn: "1", seats: 13, onWaitlist: 4), courseTitle: "Topics", termCode: "202730")
        store.watch(Self.section(crn: "2", seats: 3), courseTitle: "Topics", termCode: "202730")
        let seeded = Dictionary(uniqueKeysWithValues: store.watchlist.map { ($0.crn, $0.lastSeatsRemaining) })
        #expect(seeded["1"] == 0)
        #expect(seeded["2"] == 3)
    }
}
