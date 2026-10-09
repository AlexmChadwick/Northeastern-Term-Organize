//
//  WatchlistStatus.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Availability of a watched section as of its last check.
enum WatchlistStatus: Equatable {
    case open
    case waitlist
    case full
    /// Banner no longer lists the section.
    case missing

    init(item: WatchItem, isMissing: Bool) {
        if isMissing {
            self = .missing
        } else if item.lastSeatsRemaining > 0 {
            self = .open
        } else if item.lastWaitlistRemaining > 0 {
            self = .waitlist
        } else {
            self = .full
        }
    }

    var symbol: String {
        switch self {
        case .open: "checkmark.circle.fill"
        case .waitlist: "hourglass.circle.fill"
        case .full: "xmark.circle.fill"
        case .missing: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .open: .green
        case .waitlist: .orange
        case .full: .red
        case .missing: .secondary
        }
    }

    /// One line describing the numbers behind the status, e.g. `3 of 40 open`.
    func detail(for item: WatchItem) -> String {
        switch self {
        case .open:
            return item.seatCapacity > 0
                ? "\(item.lastSeatsRemaining) of \(item.seatCapacity) open"
                : "\(item.lastSeatsRemaining) open"
        case .waitlist:
            let spots = item.lastWaitlistRemaining
            return "Full · \(spots) waitlist \(spots == 1 ? "spot" : "spots") open"
        case .full:
            return "Full"
        case .missing:
            return "No longer listed"
        }
    }

    /// The same numbers phrased for VoiceOver: `3 of 40 seats open`.
    func spokenDetail(for item: WatchItem) -> String {
        guard self == .open else { return detail(for: item) }
        let seats = item.lastSeatsRemaining
        return item.seatCapacity > 0
            ? "\(seats) of \(item.seatCapacity) seats open"
            : "\(seats) \(seats == 1 ? "seat" : "seats") open"
    }
}

enum WatchlistFormat {
    /// `just now`, `5 min ago`, `3 hr ago`, `yesterday`, `4 days ago`.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return "just now"
        case ..<3_600:
            return "\(Int(seconds / 60)) min ago"
        case ..<86_400:
            return "\(Int(seconds / 3_600)) hr ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "yesterday" : "\(days) days ago"
        }
    }
}
