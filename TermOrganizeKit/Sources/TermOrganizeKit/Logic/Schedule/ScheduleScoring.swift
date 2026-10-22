//
//  ScheduleScoring.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The interval and measurement code is derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), apps/searchneu/lib/scheduler/binaryMeetingTime.ts
//  and filters.ts, Copyright (C) Sandbox at Northeastern University and the SearchNEU
//  contributors, licensed under the GNU Affero General Public License v3.
//  Modified 2026-10-04: split out of ScheduleGenerator.swift; intervals know their building;
//  measurements also count back-to-back classes, tight walks, lunch breaks and heavy days;
//  the score takes weights derived from the student's preferences.
//

import Foundation

// MARK: - Intervals

/// Maps building codes to small numbers so intervals can say "same building" cheaply.
struct ScheduleBuildingTable: Sendable {
    private var ids: [String: UInt16] = [:]

    /// 0 means unknown (no building listed).
    mutating func id(for meeting: Meeting) -> UInt16 {
        guard let code = meeting.buildingCode ?? meeting.building, !code.isEmpty else { return 0 }
        if let known = ids[code] { return known }
        let next = UInt16(truncatingIfNeeded: ids.count + 1)
        ids[code] = next
        return next
    }
}

/// A weekly time block of a section on a single day.
struct ScheduleInterval: Hashable, Sendable {
    var day: UInt8
    var inPerson: Bool
    var start: Int16
    var end: Int16
    /// Which building (see `ScheduleBuildingTable`); 0 when unknown.
    var building: UInt16 = 0

    /// The section's weekly time blocks, one per day. Sections often list several
    /// records for the same weekday and time (one per date range); those are folded.
    static func intervals(for section: CourseSection) -> [ScheduleInterval] {
        intervals(for: section) { _ in 0 }
    }

    /// Like `intervals(for:)`, with building numbers from a table shared by all sections of a search.
    static func intervals(for section: CourseSection, buildings: inout ScheduleBuildingTable) -> [ScheduleInterval] {
        intervals(for: section) { buildings.id(for: $0) }
    }

    private static func intervals(for section: CourseSection, building: (Meeting) -> UInt16) -> [ScheduleInterval] {
        var result: [ScheduleInterval] = []
        var seen = Set<ScheduleInterval>()
        for meeting in section.weeklyMeetings {
            guard let start = meeting.start, let end = meeting.end else { continue }
            let inPerson = !(section.isOnline || meeting.isOnline)
            let place = inPerson ? building(meeting) : 0
            for day in meeting.days.indices {
                let interval = ScheduleInterval(
                    day: UInt8(day), inPerson: inPerson,
                    start: Int16(clamping: start), end: Int16(clamping: end), building: place
                )
                if seen.insert(interval).inserted { result.append(interval) }
            }
        }
        return result
    }
}

// MARK: - Measurements

/// What to count besides the basics when measuring a schedule. The defaults count nothing extra.
struct ScheduleMeasureOptions: Sendable, Equatable {
    /// Count classes with less than this many minutes between them (0 = don't).
    var backToBackBelow = 0
    /// Count in-person classes in different buildings with less than this many minutes between them (0 = don't).
    var travelMinutes = 0
    /// Count class days on which the window has no free stretch of `minutes`.
    var lunch: LunchBreak?

    static let none = ScheduleMeasureOptions()
}

/// The raw numbers measured from a set of weekly intervals.
struct ScheduleMeasure: Sendable {
    var classDays = 0
    var campusDays = 0
    var earliestStart = Int.max
    var latestEnd = Int.min
    var gapMinutes = 0
    /// Bit 0 is Sunday: the days with any timed class.
    var classDayMask: UInt8 = 0
    /// Class minutes on the heaviest day, and over the week.
    var maxDayMinutes = 0
    var totalMinutes = 0
    /// Consecutive classes closer than `ScheduleMeasureOptions.backToBackBelow`.
    var backToBack = 0
    /// Consecutive in-person classes in different buildings closer than `ScheduleMeasureOptions.travelMinutes`.
    var tightTransitions = 0
    /// Class days without the lunch break.
    var lunchMisses = 0

    /// Breaks shorter than this are passing time, not gaps.
    static let gapThresholdMinutes = 20

    /// Sorts `intervals[0..<count]` by day and start time (in place) and measures them.
    static func measure(_ p: UnsafeMutablePointer<ScheduleInterval>, count n: Int, options: ScheduleMeasureOptions = .none) -> ScheduleMeasure {
        var i = 1
        while i < n {
            let x = p[i]
            var j = i - 1
            while j >= 0 && (p[j].day > x.day || (p[j].day == x.day && p[j].start > x.start)) {
                p[j + 1] = p[j]
                j -= 1
            }
            p[j + 1] = x
            i += 1
        }

        var result = ScheduleMeasure()
        var k = 0
        while k < n {
            let day = p[k].day
            var runEnd = Int(p[k].end)
            var onCampus = p[k].inPerson
            var dayMinutes = Int(p[k].end) - Int(p[k].start)
            var previous = p[k]
            result.earliestStart = min(result.earliestStart, Int(p[k].start))
            result.latestEnd = max(result.latestEnd, Int(p[k].end))
            var m = k + 1
            while m < n && p[m].day == day {
                let current = p[m]
                let start = Int(current.start)
                let gap = start - runEnd
                if gap >= gapThresholdMinutes { result.gapMinutes += gap }
                if gap >= 0 {
                    if gap < options.backToBackBelow { result.backToBack += 1 }
                    if gap < options.travelMinutes, previous.inPerson, current.inPerson,
                       previous.building == 0 || current.building == 0 || previous.building != current.building {
                        result.tightTransitions += 1
                    }
                }
                runEnd = max(runEnd, Int(current.end))
                dayMinutes += Int(current.end) - start
                result.earliestStart = min(result.earliestStart, start)
                result.latestEnd = max(result.latestEnd, Int(current.end))
                if current.inPerson { onCampus = true }
                previous = current
                m += 1
            }
            if let lunch = options.lunch, !hasFreeStretch(p + k, count: m - k, in: lunch) { result.lunchMisses += 1 }
            result.classDays += 1
            result.classDayMask |= UInt8(1) << day
            if onCampus { result.campusDays += 1 }
            result.maxDayMinutes = max(result.maxDayMinutes, dayMinutes)
            result.totalMinutes += dayMinutes
            k = m
        }
        return result
    }

    /// Whether the (start-sorted) intervals of one day leave `lunch.minutes` free in one piece inside the window.
    private static func hasFreeStretch(_ p: UnsafeMutablePointer<ScheduleInterval>, count n: Int, in lunch: LunchBreak) -> Bool {
        var cursor = lunch.start
        for i in 0..<n {
            let start = Int(p[i].start), end = Int(p[i].end)
            guard end > lunch.start, start < lunch.end else { continue }
            if start > cursor, min(start, lunch.end) - cursor >= lunch.minutes { return true }
            cursor = max(cursor, min(end, lunch.end))
        }
        return lunch.end - cursor >= lunch.minutes
    }

    /// Measures arbitrary intervals without disturbing the caller's array.
    static func measure(_ intervals: [ScheduleInterval], options: ScheduleMeasureOptions = .none) -> ScheduleMeasure {
        var copy = intervals
        return copy.withUnsafeMutableBufferPointer { buffer -> ScheduleMeasure in
            guard let base = buffer.baseAddress else { return ScheduleMeasure() }
            return measure(base, count: buffer.count, options: options)
        }
    }
}

// MARK: - Scoring

/// Turns measurements into one number; higher is better.
///
/// The "best overall" score starts at 100 and subtracts for what makes a week worse: days on
/// campus, idle time between classes, uncomfortable hours, full sections. Preferences change
/// the weights (see `Weights.init(preferences:)`) and add per-section points
/// (`SchedulePreferenceRules.sectionScore`), so one number ranks every schedule.
///
/// The weights, in points (a campus day costs 8, so 8 is "one day's worth" of dislike):
///
/// | What | Points |
/// | --- | --- |
/// | Day with an in-person class | −8 (−14 with "fewer days", 0 with "spread out") |
/// | Day with only online classes | −2 (0 with "spread out") |
/// | Class day, with "spread out" | +6 each, and −0.1 per minute the heaviest day exceeds the average |
/// | Idle time between classes (breaks of 20+ min) | −1 per 10 min (−1 per 3.3 min with "keep gaps short", none with "gaps are fine", −1 per 20 min with a protected lunch) |
/// | Class before 9 AM / after 5 PM | −1 per 15 / 20 min (only without time-of-day wishes or limits) |
/// | Full section | −6 each (−3 when waitlists are fine); −2 when the tightest section has 3 seats or fewer |
/// | Class day that is a wished-for day off | −12 each |
/// | Back-to-back classes (under 30 min apart) | −10 each, with "avoid back-to-back" |
/// | Too little time between buildings | −10 each, when it is only preferred |
/// | Class day without the lunch break | −8 each |
/// | Class hour in a preferred / avoided time of day | +3 / −6 per hour |
/// | Class outside a soft start or finish limit | −(4 + 1 per 10 min outside), at most −20, per class day |
/// | Class over a blocked time that is only preferred | −15 per class day |
/// | Section not in the wished-for format | −8 (−4 for hybrid when in-person or online was asked) |
/// | In-person section on another campus than the preferred one | −10 |
/// | Section with a preferred / avoided instructor | +5 / −15 |
///
/// The first block is the leaf-level `Weights`; from "class hour" down are the per-section points,
/// added once for each section of the schedule.
enum ScheduleScoring {
    /// The weights of the leaf-level score. The defaults are the original, preference-free formula.
    struct Weights: Sendable, Equatable {
        var base = 100.0
        /// Points lost per day with an in-person class.
        var perCampusDay = 8.0
        /// Points lost per day with only online classes at fixed times.
        var perOnlineDay = 2.0
        /// Idle minutes (breaks of 20 minutes or more) are divided by this; `.infinity` ignores gaps.
        var gapDivisor = 10.0
        /// Penalize starting before 9 AM (1 point per 15 minutes) and ending after 5 PM (1 point per 20).
        var comfortHours = true
        var perFullSection = 6.0
        /// Lost when no section is full but the tightest has 3 seats or fewer.
        var lowSeatsPenalty = 2.0

        // Preference terms: all zero unless the matching wish is set.

        /// Points gained per day with classes (spread out evenly).
        var perClassDayBonus = 0.0
        /// Points lost per minute the heaviest day exceeds the average class day.
        var perImbalanceMinute = 0.0
        /// Points lost per class day that falls on a day the student wants free.
        var perDayOffMissed = 0.0
        var daysOff = DaySet()
        var perBackToBack = 0.0
        var perTightTransition = 0.0
        var perLunchMiss = 0.0

        init() {}

        /// The weights for a student's wishes. Wishes that contradict a default nudge replace it:
        /// time-of-day wishes switch off the "avoid before 9 / after 5" nudges, "spread out" replaces
        /// the fewer-days nudge, "keep gaps short" triples the gap penalty, and so on.
        init(preferences p: SchedulePreferences) {
            if p.hasTimeOfDayPreference || p.earliestStart != nil || p.latestEnd != nil { comfortHours = false }
            switch p.dayLayout {
            case .noPreference: break
            case .fewerDays: perCampusDay = 14
            case .spreadOut:
                perCampusDay = 0
                perOnlineDay = 0
                perClassDayBonus = 6
                perImbalanceMinute = 0.1
            }
            switch p.gaps {
            case .noPreference:
                // A protected lunch break is idle time on purpose: it shouldn't cost as much as other gaps.
                if p.lunch != nil { gapDivisor = 20 }
            case .compact: gapDivisor = 10.0 / 3.0
            case .fine: gapDivisor = .infinity
            }
            if p.seats == .waitlistOK { perFullSection = 3 }
            if !p.daysOff.isEmpty, p.daysOffStrength == .preferred {
                daysOff = p.daysOff
                perDayOffMissed = 12
            }
            switch p.breaks {
            case .fine: break
            case .avoidBackToBack: perBackToBack = 10
            case .atLeast: if p.minimumBreakStrength == .preferred { perTightTransition = 10 }
            }
            if p.lunch != nil { perLunchMiss = 8 }
        }

        func score(measure m: ScheduleMeasure, fullSections: Int, minSeats: Int) -> Double {
            var score = base
            score -= perCampusDay * Double(m.campusDays)
            score -= perOnlineDay * Double(max(0, m.classDays - m.campusDays))
            score -= Double(m.gapMinutes) / gapDivisor
            if comfortHours {
                if m.earliestStart != Int.max, m.earliestStart < 9 * 60 {
                    score -= Double(9 * 60 - m.earliestStart) / 15.0
                }
                if m.latestEnd != Int.min, m.latestEnd > 17 * 60 {
                    score -= Double(m.latestEnd - 17 * 60) / 20.0
                }
            }
            score -= perFullSection * Double(fullSections)
            if fullSections == 0, minSeats <= 3 { score -= lowSeatsPenalty }

            if perClassDayBonus != 0 { score += perClassDayBonus * Double(m.classDays) }
            if perImbalanceMinute != 0, m.classDays > 0 {
                let average = Double(m.totalMinutes) / Double(m.classDays)
                score -= perImbalanceMinute * max(0, Double(m.maxDayMinutes) - average)
            }
            if perDayOffMissed != 0 {
                score -= perDayOffMissed * Double((m.classDayMask & daysOff.rawValue).nonzeroBitCount)
            }
            if perBackToBack != 0 { score -= perBackToBack * Double(m.backToBack) }
            if perTightTransition != 0 { score -= perTightTransition * Double(m.tightTransitions) }
            if perLunchMiss != 0 { score -= perLunchMiss * Double(m.lunchMisses) }
            return score
        }
    }

    /// The "best overall" composite without preferences: fewer campus days, fewer gaps,
    /// comfortable hours and seats that are not about to run out all score higher.
    static func score(measure: ScheduleMeasure, fullSections: Int, minSeats: Int) -> Double {
        Weights().score(measure: measure, fullSections: fullSections, minSeats: minSeats)
    }

    /// What the preferences ask `ScheduleMeasure` to count.
    static func measureOptions(for p: SchedulePreferences) -> ScheduleMeasureOptions {
        var options = ScheduleMeasureOptions()
        switch p.breaks {
        case .fine: break
        case .avoidBackToBack: options.backToBackBelow = SchedulePreferences.backToBackMinutes
        case .atLeast: if p.minimumBreakStrength == .preferred { options.travelMinutes = p.minimumBreakMinutes }
        }
        options.lunch = p.lunch
        return options
    }

    // MARK: Per-section points

    /// Points per weekly class hour in a band the student prefers.
    static let preferredBandPerHour = 3.0
    /// Points per weekly class hour in a band the student wants to avoid.
    static let avoidedBandPerHour = -6.0
    /// A class meeting outside a soft earliest/latest limit costs `softLimitBase` plus one point per
    /// 10 minutes it is outside, at most `softLimitCap`.
    static let softLimitBase = 4.0
    static let softLimitCap = 20.0
    /// Per class meeting that overlaps a block that is only preferred.
    static let softBlockedPerMeeting = 15.0
    /// Per section, times how far its format is from the wish (0, 0.5 or 1).
    static let formatMismatchPerSection = 8.0
    /// Per in-person section on another campus than the preferred one.
    static let campusMismatchPerSection = 10.0
    static let preferredInstructorPerSection = 5.0
    static let avoidedInstructorPerSection = -15.0
}
