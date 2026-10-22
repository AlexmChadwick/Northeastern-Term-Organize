//
//  SchedulePreferenceRules.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Reasons

/// One short phrase saying why a schedule suits the student's wishes ("Fridays off") or
/// where it falls short of them ("Starts 8:00 AM"). Shown as a tag on result cards.
struct ScheduleReason: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A wish the schedule meets.
        case benefit
        /// A wish the schedule doesn't meet (only wishes that were "if possible").
        case caveat
    }

    var kind: Kind
    var text: String
    var symbol: String

    var id: String { "\(kind == .benefit ? "+" : "-")\(text)" }
    var isCaveat: Bool { kind == .caveat }
}

// MARK: - Rules

/// The parts of the preferences the generator applies to single sections, plus the explanations
/// shown on result cards. Everything here is pure and works on plain `CourseSection`s.
enum SchedulePreferenceRules {
    // MARK: Hard rules for one section

    /// The preference rules that remove `section`, as `ScheduleFilterReason` bits (0 = it stays).
    static func rejectionReasons(for section: CourseSection, preferences p: SchedulePreferences) -> UInt32 {
        var reasons: UInt32 = 0
        let weekly = section.weeklyMeetings

        if let limit = p.earliestStart, limit.strength == .required,
           weekly.contains(where: { ($0.start ?? Int.max) < limit.minutes }) {
            reasons |= ScheduleFilterReason.prefStartsTooEarly.bit
        }
        if let limit = p.latestEnd, limit.strength == .required,
           weekly.contains(where: { ($0.end ?? 0) > limit.minutes }) {
            reasons |= ScheduleFilterReason.prefEndsTooLate.bit
        }
        if p.daysOffStrength == .required, !p.daysOff.isEmpty,
           weekly.contains(where: { !$0.days.isDisjoint(with: p.daysOff) }) {
            reasons |= ScheduleFilterReason.prefDayOff.bit
        }
        for block in p.blockedTimes where block.isActive && block.strength == .required {
            if overlaps(block, weekly) {
                reasons |= ScheduleFilterReason.blockedTime.bit
                break
            }
        }
        if p.format != .noPreference, p.formatStrength == .required,
           SchedulePreferences.format(of: section).mismatch(with: p.format) > 0 {
            reasons |= ScheduleFilterReason.prefFormat.bit
        }
        if let campus = p.campus, p.campusStrength == .required,
           !section.isOnline, !ScheduleGenerator.hasNoCampus(section), section.campus != campus {
            reasons |= ScheduleFilterReason.prefCampus.bit
        }
        switch p.seats {
        case .any: break
        case .openOnly:
            if isFull(section) { reasons |= ScheduleFilterReason.prefSeats.bit }
        case .waitlistOK:
            if isFull(section), section.waitlistRemaining <= 0 { reasons |= ScheduleFilterReason.prefSeats.bit }
        }
        if let cap = p.maxMinutesPerDay {
            var perDay = [Int](repeating: 0, count: 7)
            for interval in ScheduleInterval.intervals(for: section) { perDay[Int(interval.day)] += Int(interval.end) - Int(interval.start) }
            if perDay.contains(where: { $0 > cap }) { reasons |= ScheduleFilterReason.prefWorkload.bit }
        }
        return reasons
    }

    /// A section with a seat limit and no seats left. Sections Banner lists without any limit (independent study) are never full.
    static func isFull(_ section: CourseSection) -> Bool {
        section.seatCapacity > 0 && section.seatsRemaining <= 0
    }

    private static func overlaps(_ block: BlockedTime, _ meetings: [Meeting]) -> Bool {
        meetings.contains { meeting in
            guard let start = meeting.start, let end = meeting.end else { return false }
            return block.overlaps(days: meeting.days, start: start, end: end)
        }
    }

    /// Whether two sections have in-person meetings in different buildings (or unknown ones) on the same
    /// day, in the same weeks, with fewer than `minutes` between them. Overlaps don't count: they are conflicts.
    static func tooClose(_ a: CourseSection, _ aMeetings: [Meeting], _ b: CourseSection, _ bMeetings: [Meeting], minutes: Int) -> Bool {
        guard minutes > 0, !a.isOnline, !b.isOnline else { return false }
        for x in aMeetings where !x.isOnline {
            guard let xs = x.start, let xe = x.end else { continue }
            for y in bMeetings where !y.isOnline {
                guard let ys = y.start, let ye = y.end, !x.days.isDisjoint(with: y.days) else { continue }
                let gap = ys >= xe ? ys - xe : (xs >= ye ? xs - ye : -1)
                guard gap >= 0, gap < minutes else { continue }
                guard Meeting.dateWindowsOverlap(x.startDate, x.endDate, y.startDate, y.endDate) else { continue }
                if let bx = x.buildingCode ?? x.building, let by = y.buildingCode ?? y.building, bx == by { continue }
                return true
            }
        }
        return false
    }

    // MARK: Ranking points for one section

    /// Points (positive or negative) the preferences give a section on its own: time of day, soft limits,
    /// soft blocked times, format, campus and instructors. Added to the schedule's score once per section.
    static func sectionScore(for section: CourseSection, intervals: [ScheduleInterval], preferences p: SchedulePreferences) -> Double {
        var score = 0.0

        if p.hasTimeOfDayPreference {
            for interval in intervals {
                for band in TimeBand.allCases {
                    let preference = p[band]
                    guard preference != .okay else { continue }
                    let minutes = band.overlap(start: Int(interval.start), end: Int(interval.end))
                    guard minutes > 0 else { continue }
                    let perHour = preference == .prefer ? ScheduleScoring.preferredBandPerHour : ScheduleScoring.avoidedBandPerHour
                    score += perHour * Double(minutes) / 60
                }
            }
        }

        if let limit = p.earliestStart, limit.strength == .preferred {
            for interval in intervals where Int(interval.start) < limit.minutes {
                score -= softLimitPenalty(minutesOutside: limit.minutes - Int(interval.start))
            }
        }
        if let limit = p.latestEnd, limit.strength == .preferred {
            for interval in intervals where Int(interval.end) > limit.minutes {
                score -= softLimitPenalty(minutesOutside: Int(interval.end) - limit.minutes)
            }
        }

        for block in p.blockedTimes where block.isActive && block.strength == .preferred {
            for interval in intervals where block.overlaps(days: DaySet(day: Int(interval.day)), start: Int(interval.start), end: Int(interval.end)) {
                score -= ScheduleScoring.softBlockedPerMeeting
            }
        }

        if p.format != .noPreference {
            score -= ScheduleScoring.formatMismatchPerSection * SchedulePreferences.format(of: section).mismatch(with: p.format)
        }
        if let campus = p.campus, p.campusStrength == .preferred,
           !section.isOnline, !ScheduleGenerator.hasNoCampus(section), section.campus != campus {
            score -= ScheduleScoring.campusMismatchPerSection
        }

        if !p.preferredInstructors.isEmpty || !p.avoidedInstructors.isEmpty {
            let names = Set((section.instructors ?? []).map { $0.name.lowercased() })
            if !names.isEmpty {
                if p.preferredInstructors.contains(where: { names.contains($0.lowercased()) }) {
                    score += ScheduleScoring.preferredInstructorPerSection
                }
                if p.avoidedInstructors.contains(where: { names.contains($0.lowercased()) }) {
                    score += ScheduleScoring.avoidedInstructorPerSection
                }
            }
        }
        return score
    }

    private static func softLimitPenalty(minutesOutside: Int) -> Double {
        min(ScheduleScoring.softLimitCap, ScheduleScoring.softLimitBase + Double(minutesOutside) / 10)
    }

    // MARK: Explanations

    /// Short phrases saying how well `sections` match the wishes: up to `benefits` things it gets right,
    /// then up to `caveats` things it doesn't. Empty when there are no preferences.
    static func reasons(
        for sections: [CourseSection], preferences p: SchedulePreferences, benefits maxBenefits: Int = 4, caveats maxCaveats: Int = 2
    ) -> [ScheduleReason] {
        guard !p.isDefault, !sections.isEmpty else { return [] }

        var table = ScheduleBuildingTable()
        var intervals: [ScheduleInterval] = []
        for section in sections { intervals += ScheduleInterval.intervals(for: section, buildings: &table) }
        var options = ScheduleMeasureOptions()
        if p.breaks == .avoidBackToBack { options.backToBackBelow = SchedulePreferences.backToBackMinutes }
        if p.breaks == .atLeast { options.travelMinutes = p.minimumBreakMinutes }
        options.lunch = p.lunch
        let measure = ScheduleMeasure.measure(intervals, options: options)
        let hasClasses = measure.classDays > 0

        var good: [ScheduleReason] = []
        var bad: [ScheduleReason] = []
        func pro(_ text: String, _ symbol: String) { good.append(ScheduleReason(kind: .benefit, text: text, symbol: symbol)) }
        func con(_ text: String, _ symbol: String) { bad.append(ScheduleReason(kind: .caveat, text: text, symbol: symbol)) }

        // Days off
        if hasClasses, !p.daysOff.isEmpty {
            let used = DaySet(rawValue: measure.classDayMask & p.daysOff.rawValue)
            let free = p.daysOff.subtracting(used)
            if !free.isEmpty { pro(SchedulePreferences.daysOffPhrase(free), "calendar.badge.minus") }
            if !used.isEmpty, p.daysOffStrength == .preferred {
                con("Class on \(used.indices.map { DaySet.shortNames[$0] }.joined(separator: ", "))", "calendar.badge.exclamationmark")
            }
        }

        // Start and finish
        if hasClasses, let limit = p.earliestStart {
            if measure.earliestStart >= limit.minutes {
                pro("No classes before \(SchedulePreferences.shortTime(limit.minutes))", "sunrise")
            } else if limit.strength == .preferred {
                con("Starts \(TimeOfDay.label(measure.earliestStart))", "sunrise")
            }
        }
        if hasClasses, let limit = p.latestEnd {
            if measure.latestEnd <= limit.minutes {
                pro("Done by \(SchedulePreferences.shortTime(limit.minutes))", "sunset")
            } else if limit.strength == .preferred {
                con("Ends \(TimeOfDay.label(measure.latestEnd))", "sunset")
            }
        }

        // Layout and gaps
        if hasClasses {
            switch p.dayLayout {
            case .noPreference: break
            case .fewerDays:
                let days = measure.campusDays > 0 ? measure.campusDays : measure.classDays
                if days <= 3 { pro(days == 1 ? "1 day on campus" : "\(days) days on campus", "calendar") }
            case .spreadOut:
                if measure.classDays >= 4 { pro("Spread over \(measure.classDays) days", "calendar") }
            }
            if p.gaps == .compact, measure.gapMinutes <= 30 { pro("Short gaps", "rectangle.compress.vertical") }
        }

        // Time of day
        if hasClasses, measure.totalMinutes > 0 {
            func minutes(in bands: [TimeBand]) -> Int {
                intervals.reduce(0) { total, interval in
                    total + bands.reduce(0) { $0 + $1.overlap(start: Int(interval.start), end: Int(interval.end)) }
                }
            }
            let preferred = p.preferredBands
            if !preferred.isEmpty {
                let share = Double(minutes(in: preferred)) / Double(measure.totalMinutes)
                let name = SchedulePreferences.bandPhrase(preferred)
                if share >= 0.999 {
                    pro("All \(name)", preferred.first?.symbol ?? "sun.max")
                } else if share >= 0.6 {
                    pro("Mostly \(name)", preferred.first?.symbol ?? "sun.max")
                }
            }
            let avoided = p.avoidedBands
            if !avoided.isEmpty {
                let name = SchedulePreferences.bandPhrase(avoided)
                if minutes(in: avoided) == 0 {
                    pro("No \(name)", avoided.first?.symbol ?? "nosign")
                } else {
                    con("Includes \(name)", avoided.first?.symbol ?? "clock")
                }
            }
        }

        // Breaks
        if hasClasses, p.lunch != nil {
            let free = measure.classDays - measure.lunchMisses
            if measure.lunchMisses == 0 {
                pro("Lunch free every day", "fork.knife")
            } else if free * 2 >= measure.classDays {
                pro("Lunch free most days", "fork.knife")
            } else {
                con("Lunch often busy", "fork.knife")
            }
        }
        if hasClasses {
            switch p.breaks {
            case .fine: break
            case .avoidBackToBack:
                if measure.backToBack == 0 { pro("No back-to-back classes", "figure.walk") }
                else { con(measure.backToBack == 1 ? "1 back-to-back" : "\(measure.backToBack) back-to-back", "figure.walk") }
            case .atLeast:
                if measure.tightTransitions == 0 { pro("Time to walk between classes", "figure.walk") }
                else { con("Tight between buildings", "figure.walk") }
            }
        }

        // Instructors
        if !p.preferredInstructors.isEmpty || !p.avoidedInstructors.isEmpty {
            func names(matching wanted: [String]) -> [String] {
                let set = Set(wanted.map { $0.lowercased() })
                var result: [String] = []
                for section in sections {
                    for instructor in section.instructors ?? [] where set.contains(instructor.name.lowercased()) {
                        if !result.contains(instructor.displayName) { result.append(instructor.displayName) }
                    }
                }
                return result
            }
            let liked = names(matching: p.preferredInstructors)
            if liked.count == 1 { pro("With \(liked[0])", "person.fill") }
            else if liked.count > 1 { pro("With \(liked.count) preferred instructors", "person.2.fill") }
            let disliked = names(matching: p.avoidedInstructors)
            if let first = disliked.first { con(disliked.count == 1 ? "With \(first)" : "With \(disliked.count) avoided instructors", "person.fill.xmark") }
        }

        // Format and place
        if p.format != .noPreference {
            let formats = sections.map { SchedulePreferences.format(of: $0) }
            let deliveries = formats.filter { if case .other = $0 { return false } else { return true } }
            if !deliveries.isEmpty {
                if deliveries.allSatisfy({ $0.mismatch(with: p.format) == 0 }) {
                    pro("All \(p.format.title.lowercased())", p.format == .online ? "wifi" : "building.2")
                } else if p.formatStrength == .preferred {
                    con("Not all \(p.format.title.lowercased())", "wifi")
                }
            }
        }
        if let campus = p.campus {
            let onCampus = sections.filter { !$0.isOnline && !ScheduleGenerator.hasNoCampus($0) }
            if !onCampus.isEmpty {
                if onCampus.allSatisfy({ $0.campus == campus }) { pro("\(campus) campus", "mappin.and.ellipse") }
                else if p.campusStrength == .preferred { con("Includes another campus", "mappin.and.ellipse") }
            }
        }

        // Seats
        switch p.seats {
        case .any: break
        case .openOnly: pro("All sections open", "chair.lounge")
        case .waitlistOK:
            let waitlisted = sections.filter { isFull($0) }.count
            if waitlisted == 0 { pro("All sections open", "chair.lounge") }
            else { con(waitlisted == 1 ? "1 waitlisted section" : "\(waitlisted) waitlisted sections", "chair.lounge") }
        }

        // Blocks that were only preferred
        for block in p.blockedTimes where block.isActive && block.strength == .preferred {
            let touches = intervals.contains { block.overlaps(days: DaySet(day: Int($0.day)), start: Int($0.start), end: Int($0.end)) }
            if touches { con("Overlaps \(block.label)", "calendar.badge.exclamationmark") }
        }

        // Two wishes can say the same thing ("Overlaps Club" for two blocks with one name): show it once.
        func unique(_ reasons: [ScheduleReason]) -> [ScheduleReason] {
            var seen = Set<String>()
            return reasons.filter { seen.insert($0.id).inserted }
        }
        return Array(unique(good).prefix(maxBenefits)) + Array(unique(bad).prefix(maxCaveats))
    }
}
