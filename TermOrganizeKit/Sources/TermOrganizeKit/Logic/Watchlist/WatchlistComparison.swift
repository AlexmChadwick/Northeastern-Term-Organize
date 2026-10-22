//
//  WatchlistComparison.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The "a seat just opened" rules mirror SearchNEU's section updater
//  (https://github.com/sandboxnu/searchneu, packages/scraper/src/update/main.ts,
//  Copyright (C) Sandbox at Northeastern University and the SearchNEU contributors,
//  licensed under the GNU Affero General Public License v3): a section raises a
//  seat alert when it goes from no seats to some, a waitlist alert when a full
//  waitlist gains room, and a stored CRN that Banner no longer lists is reported
//  as missing.
//  Modified 2026-10-03: reimplemented in Swift as a pure function that feeds
//  on-device notifications instead of SMS messages.
//

import Foundation

/// Something worth telling the user about: a watched section gained a seat or a
/// waitlist spot. Pure data; `WatchlistNotifier` turns it into a notification.
struct WatchlistAlert: Hashable, Sendable {
    enum Kind: String, Sendable {
        case seats
        case waitlist
    }

    var kind: Kind
    var termCode: String
    var crn: String
    var courseKey: CourseKey
    var courseTitle: String
    /// e.g. `Lecture 02`.
    var sectionName: String
    var seatsRemaining: Int
    var seatCapacity: Int
    var waitlistRemaining: Int

    /// `Seats open in CS 3000` / `Waitlist spot open in CS 3000`.
    var title: String {
        switch kind {
        case .seats: "Seats open in \(courseKey.description)"
        case .waitlist: "Waitlist spot open in \(courseKey.description)"
        }
    }

    /// `3 of 40 seats in Lecture 02 (CRN 12345). Register soon!`
    var body: String {
        switch kind {
        case .seats:
            let seats: String
            if seatCapacity > 0 {
                seats = "\(seatsRemaining) of \(seatCapacity) seats"
            } else {
                seats = seatsRemaining == 1 ? "1 seat" : "\(seatsRemaining) seats"
            }
            return "\(seats) in \(sectionName) (CRN \(crn)). Register soon!"
        case .waitlist:
            let spots = waitlistRemaining == 1 ? "1 waitlist spot" : "\(waitlistRemaining) waitlist spots"
            return "\(spots) open in \(sectionName) (CRN \(crn)). Join soon!"
        }
    }

    /// One delivered notification per section and kind; a repeat replaces the earlier banner.
    var identifier: String { "watch-\(kind.rawValue)-\(termCode)-\(crn)" }

    /// Groups a course's alerts together in Notification Center.
    var threadIdentifier: String { "course-\(termCode)-\(courseKey.description)" }

    /// Deep link handled by `AppRouter.handle(url:)`.
    var url: URL? { AppLink.url("section/\(termCode)/\(crn)") }
}

/// Compares the watchlist with freshly fetched sections.
enum WatchlistComparison {
    struct Outcome: Sendable {
        /// The watchlist with updated seat numbers and check times.
        var items: [WatchItem]
        var alerts: [WatchlistAlert]
        /// Items whose CRN is no longer listed by Banner (the section was removed).
        var missingIDs: Set<String>
        /// Terms for which fresh data was available.
        var checkedTermCodes: Set<String>
    }

    /// - Parameters:
    ///   - items: the current watchlist.
    ///   - live: fresh sections as `termCode -> course -> sections`. Terms that are
    ///     absent (for example because the request failed) leave their items untouched.
    static func compare(
        items: [WatchItem],
        live: [String: [CourseKey: [CourseSection]]],
        now: Date = .now
    ) -> Outcome {
        var updated = items
        var alerts: [WatchlistAlert] = []
        var missing = Set<String>()

        for index in updated.indices {
            let item = updated[index]
            guard let termSections = live[item.termCode] else { continue }

            guard let section = (termSections[item.courseKey] ?? []).first(where: { $0.crn == item.crn }) else {
                // The registrar no longer lists this CRN. Keep the last known numbers.
                missing.insert(item.id)
                updated[index].lastCheckedAt = now
                continue
            }

            let seatsOpened = item.lastSeatsRemaining <= 0 && section.seatsRemaining > 0
            let waitlistOpened = item.notifyOnWaitlist
                && !seatsOpened
                && section.seatsRemaining <= 0
                && item.lastWaitlistRemaining <= 0
                && section.waitlistRemaining > 0

            var next = item
            next.lastSeatsRemaining = section.seatsRemaining
            next.lastWaitlistRemaining = section.waitlistRemaining
            next.seatCapacity = section.seatCapacity
            next.lastCheckedAt = now

            if seatsOpened || waitlistOpened {
                next.lastNotifiedAt = now
                alerts.append(WatchlistAlert(
                    kind: seatsOpened ? .seats : .waitlist,
                    termCode: item.termCode,
                    crn: item.crn,
                    courseKey: item.courseKey,
                    courseTitle: item.courseTitle,
                    sectionName: sectionName(for: section),
                    seatsRemaining: section.seatsRemaining,
                    seatCapacity: section.seatCapacity,
                    waitlistRemaining: section.waitlistRemaining
                ))
            }
            updated[index] = next
        }

        return Outcome(items: updated, alerts: alerts, missingIDs: missing, checkedTermCodes: Set(live.keys))
    }

    /// `Lecture 02`, or just the class type when there is no section number.
    static func sectionName(for section: CourseSection) -> String {
        let number = section.sectionNumber.trimmingCharacters(in: .whitespaces)
        return number.isEmpty ? section.classType : "\(section.classType) \(number)"
    }
}
