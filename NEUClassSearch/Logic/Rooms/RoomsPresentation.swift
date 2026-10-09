//
//  RoomsPresentation.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  How the free-rooms screens describe availability: colors, symbols, wording and the
//  class dates of a term. Shared by the iPhone/iPad and the Mac interfaces.
//

import SwiftUI

// MARK: - Presentation of availability

extension RoomAvailability.Status {
    /// Green for a room that stays free, orange when it is about to be taken, red when in use.
    func roomsTint(at moment: RoomAvailability.Moment) -> Color {
        switch self {
        case .busy: .red
        case .free: isFreeOnlyBriefly(at: moment) ? .orange : .green
        }
    }

    var roomsSymbol: String {
        isFree ? "door.left.hand.open" : "door.left.hand.closed"
    }
}

enum RoomsText {
    static let disclaimer = "Based on scheduled classes only — rooms may be locked or reserved."

    static let outsideHours = "This is outside regular class hours (7 AM – 10 PM). Most buildings are locked then, so these rooms may not be open to you."

    /// `Fall 2026 classes run Sep 9 – Dec 13. Showing a typical week.`
    static func classDatesMessage(termName: String, dates: RoomAvailability.ClassDates) -> String {
        let format = Date.FormatStyle().month(.abbreviated).day()
        return "\(termName) classes run \(dates.start.formatted(format)) – \(dates.end.formatted(format)). Showing a typical week."
    }

    /// `12 of 40 rooms free`.
    static func freeSummary(free: Int, total: Int) -> String {
        "\(free) of \(total) \(total == 1 ? "room" : "rooms") free"
    }

    /// What happens next: the following class for a free room, or when a busy room frees up.
    /// - Parameter today: the room's bookings on the day, sorted by start time.
    static func followUpNote(status: RoomAvailability.Status, today: [RoomSchedule.Booking]) -> String? {
        switch status {
        case .free(let until):
            guard let until, let next = today.first(where: { $0.start == until }) else {
                return today.isEmpty ? "No classes are scheduled here today." : "No more classes today."
            }
            return "Next: \(next.course.description), \(TimeOfDay.rangeLabel(start: next.start, end: next.end))"
        case .busy(let occupancy):
            if let freeUntil = occupancy.freeUntil {
                return "Then free until \(TimeOfDay.label(freeUntil))"
            }
            return "Then free for the rest of the day"
        }
    }
}

extension RoomSchedule {
    /// The room's weekly bookings as calendar blocks. One-off sessions don't meet every week, so
    /// they are drawn tentative.
    func calendarEvents(in index: CatalogIndex) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        for (position, booking) in bookings.enumerated() where booking.end > booking.start {
            let section = index.section(crn: booking.crn)
            for day in booking.days.indices {
                events.append(CalendarEvent(
                    id: "\(booking.crn)-\(day)-\(booking.start)-\(position)",
                    title: booking.course.description,
                    subtitle: nil,
                    detail: section?.classType,
                    day: day,
                    start: booking.start,
                    end: booking.end,
                    color: CourseColor.forCourse(booking.course),
                    isGhost: booking.isShortSession,
                    payload: booking.crn
                ))
            }
        }
        return events
    }
}

extension CatalogIndex {
    /// `Boston` for the code `BOS`, falling back to the code itself.
    func roomsCampusName(forCode code: String?) -> String? {
        guard let code else { return nil }
        return catalog.campuses.first { $0.code == code }?.name ?? code
    }

    /// Changes whenever the index is replaced by newer data.
    var roomsIdentity: String {
        "\(term.code)|\(catalog.sectionsUpdatedAt.timeIntervalSince1970)"
    }
}

extension View {
    /// Works out when classes start and end for the index's term, off the main actor,
    /// and keeps `dates` up to date as the index changes.
    func roomsClassDates(_ dates: Binding<RoomAvailability.ClassDates?>, in index: CatalogIndex?) -> some View {
        task(id: index?.roomsIdentity ?? "none") {
            guard let index else {
                dates.wrappedValue = nil
                return
            }
            let sections = index.catalog.sections
            let derived = await Task.detached(priority: .utility) {
                RoomAvailability.ClassDates.derive(from: sections)
            }.value
            guard !Task.isCancelled else { return }
            dates.wrappedValue = derived
        }
    }
}
