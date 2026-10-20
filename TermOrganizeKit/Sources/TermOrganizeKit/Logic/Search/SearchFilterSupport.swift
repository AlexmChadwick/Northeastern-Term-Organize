//
//  SearchFilterSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The pieces of the search filters that don't draw anything: day presets, chip titles and the
//  minutes-after-midnight conversion for time pickers. Shared by the iPhone, iPad and Mac interfaces.
//

import Foundation

/// Meeting-day presets offered by the filter bar's Days menu.
enum SearchDayPreset: String, CaseIterable, Identifiable {
    case any
    case noFridays
    case mwr
    case tf
    case mr
    case wf
    /// Stands for any day set that no preset describes. Choosing it opens the
    /// full day editor; it is also what the picker shows while such a set is active.
    case custom

    var id: String { rawValue }

    /// The days sections may meet on, or nil for no restriction. (`custom` has
    /// no fixed days of its own.)
    var days: DaySet? {
        switch self {
        case .any, .custom: nil
        case .noFridays: [.monday, .tuesday, .wednesday, .thursday]
        case .mwr: [.monday, .wednesday, .thursday]
        case .tf: [.tuesday, .friday]
        case .mr: [.monday, .thursday]
        case .wf: [.wednesday, .friday]
        }
    }

    var menuTitle: String {
        switch self {
        case .any: "Any days"
        case .noFridays: "No Friday classes"
        case .mwr: "Mon, Wed, Thu only"
        case .tf: "Tue, Fri only"
        case .mr: "Mon, Thu only"
        case .wf: "Wed, Fri only"
        case .custom: "Custom…"
        }
    }

    var chipTitle: String {
        switch self {
        case .any: "Days"
        case .noFridays: "No Fridays"
        case .mwr: "MWR only"
        case .tf: "TF only"
        case .mr: "MR only"
        case .wf: "WF only"
        case .custom: "Custom days"
        }
    }

    /// The preset that describes exactly `days`, if any (never `custom`).
    static func matching(_ days: DaySet?) -> SearchDayPreset? {
        allCases.first { $0 != .custom && $0.days == days }
    }

    /// The preset to show as selected for `days`: a matching preset, or `custom`.
    static func selection(for days: DaySet?) -> SearchDayPreset {
        matching(days) ?? .custom
    }
}

/// Short chip titles that summarize the active filters.
enum SearchFilterTitles {
    static func days(_ days: DaySet?) -> String {
        guard let days else { return "Days" }
        if let preset = SearchDayPreset.matching(days) { return preset.chipTitle }
        return days.isEmpty ? "No set days" : "\(days.compactLabel) only"
    }

    static func subjects(_ subjects: Set<String>) -> String {
        switch subjects.count {
        case 0: return "Subject"
        case 1: return subjects.first ?? "Subject"
        default: return "\(subjects.count) subjects"
        }
    }

    static func nupaths(_ nupaths: Set<NUPath>) -> String {
        switch nupaths.count {
        case 0: return "NUpath"
        case 1, 2: return NUPath.allCases.filter { nupaths.contains($0) }.map(\.short).joined(separator: ", ")
        default: return "NUpath · \(nupaths.count)"
        }
    }

    static func level(_ level: Int) -> String {
        level == 0 ? "Under 1000" : "\(level)000"
    }
}

/// Converts between minutes after midnight (what `SearchFilters` stores) and
/// the `Date` values a time-only `DatePicker` works with.
enum SearchTimeOfDay {
    /// Only the time of day matters, so a fixed Gregorian calendar keeps the
    /// conversion identical whatever calendar the user has selected.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// A fixed mid-January day, so daylight saving shifts can never skip a time.
    static func date(fromMinutes minutes: Int) -> Date {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        let components = DateComponents(year: 2001, month: 1, day: 15, hour: clamped / 60, minute: clamped % 60)
        return calendar.date(from: components) ?? .now
    }

    static func minutes(from date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
