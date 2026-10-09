//
//  SchedulePreferences.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Building blocks

/// How firmly a wish is applied to the generated schedules.
enum PreferenceStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Schedules that satisfy it rank higher; none are removed.
    case preferred
    /// Schedules that break it are removed.
    case required

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferred: "If possible"
        case .required: "Always"
        }
    }
}

/// A slice of the day. The bands partition the 24 hours, so every class minute falls in exactly one.
enum TimeBand: String, Codable, CaseIterable, Identifiable, Sendable {
    case earlyMorning
    case morning
    case midday
    case afternoon
    case evening
    case night

    var id: String { rawValue }

    /// Minutes after midnight.
    var minutes: Range<Int> {
        switch self {
        case .earlyMorning: 0..<(9 * 60)
        case .morning: (9 * 60)..<(12 * 60)
        case .midday: (12 * 60)..<(14 * 60)
        case .afternoon: (14 * 60)..<(17 * 60)
        case .evening: (17 * 60)..<(19 * 60)
        case .night: (19 * 60)..<(24 * 60)
        }
    }

    var title: String {
        switch self {
        case .earlyMorning: "Early morning"
        case .morning: "Morning"
        case .midday: "Midday"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    /// The hours the band covers, e.g. `Before 9 AM`.
    var detail: String {
        switch self {
        case .earlyMorning: "Before 9 AM"
        case .morning: "9 AM – noon"
        case .midday: "Noon – 2 PM"
        case .afternoon: "2 – 5 PM"
        case .evening: "5 – 7 PM"
        case .night: "After 7 PM"
        }
    }

    var symbol: String {
        switch self {
        case .earlyMorning: "sunrise"
        case .morning: "sun.horizon"
        case .midday: "sun.max"
        case .afternoon: "sun.haze"
        case .evening: "sunset"
        case .night: "moon.stars"
        }
    }

    /// Minutes of `start..<end` (minutes after midnight) that fall inside the band.
    func overlap(start: Int, end: Int) -> Int {
        max(0, min(end, minutes.upperBound) - max(start, minutes.lowerBound))
    }
}

/// How a time-of-day band is felt about.
enum TimePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case avoid
    case okay
    case prefer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avoid: "Avoid"
        case .okay: "OK"
        case .prefer: "Prefer"
        }
    }
}

/// An earliest start or latest end, as minutes after midnight.
struct TimeLimit: Codable, Hashable, Sendable {
    var minutes: Int
    var strength: PreferenceStrength = .required

    init(minutes: Int, strength: PreferenceStrength = .required) {
        self.minutes = minutes
        self.strength = strength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = try c.decode(Int.self, forKey: .minutes)
        strength = c.lenient(PreferenceStrength.self, .strength) ?? .required
    }
}

/// How many days classes are spread over.
enum DayLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case noPreference
    case fewerDays
    case spreadOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noPreference: "No preference"
        case .fewerDays: "Fewer days on campus"
        case .spreadOut: "Spread out evenly"
        }
    }
}

/// How idle time between classes on the same day is felt about.
enum GapPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case noPreference
    case fine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Keep short"
        case .noPreference: "No preference"
        case .fine: "Fine"
        }
    }
}

/// How classes that follow each other closely are felt about.
enum BreakPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case fine
    /// Prefer a real break (at least `SchedulePreferences.backToBackMinutes`) between classes.
    case avoidBackToBack
    /// Leave `minimumBreakMinutes` between in-person classes in different buildings.
    case atLeast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fine: "Fine"
        case .avoidBackToBack: "Avoid"
        case .atLeast: "Time to walk"
        }
    }
}

/// A protected stretch of the day: on days with classes, `minutes` of it should be free.
struct LunchBreak: Codable, Hashable, Sendable {
    /// Minutes after midnight.
    var start = 11 * 60 + 30
    var end = 14 * 60
    /// How much of the window has to stay free in one piece.
    var minutes = 30

    init(start: Int = 11 * 60 + 30, end: Int = 14 * 60, minutes: Int = 30) {
        self.start = start
        self.end = end
        self.minutes = minutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = c.lenient(Int.self, .start) ?? 11 * 60 + 30
        end = c.lenient(Int.self, .end) ?? 14 * 60
        minutes = c.lenient(Int.self, .minutes) ?? 30
    }
}

/// A recurring weekly commitment no class may overlap: a club meeting, a job, a commute.
struct BlockedTime: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var label: String
    var days: DaySet
    /// Minutes after midnight.
    var start: Int
    var end: Int
    /// `.required` removes every section that overlaps; `.preferred` only ranks them lower.
    var strength: PreferenceStrength = .required
    /// Turned off blocks are kept (so they can be switched back on) but never applied.
    var isEnabled = true

    init(
        id: UUID = UUID(), label: String, days: DaySet, start: Int, end: Int,
        strength: PreferenceStrength = .required, isEnabled: Bool = true
    ) {
        self.id = id
        self.label = label
        self.days = days
        self.start = start
        self.end = end
        self.strength = strength
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(UUID.self, .id) ?? UUID()
        label = c.lenient(String.self, .label) ?? ""
        days = c.lenient(DaySet.self, .days) ?? DaySet()
        start = c.lenient(Int.self, .start) ?? 0
        end = c.lenient(Int.self, .end) ?? 0
        strength = c.lenient(PreferenceStrength.self, .strength) ?? .required
        isEnabled = c.lenient(Bool.self, .isEnabled) ?? true
    }

    /// Whether it can be applied: it has days and a positive time range.
    var isValid: Bool { !days.isEmpty && end > start && start >= 0 && end <= 24 * 60 }

    /// Applied to the generator.
    var isActive: Bool { isEnabled && isValid }

    /// Whether a weekly meeting overlaps the block (the block recurs all term, so date windows don't matter).
    func overlaps(days meetingDays: DaySet, start meetingStart: Int, end meetingEnd: Int) -> Bool {
        !days.isDisjoint(with: meetingDays) && meetingStart < end && start < meetingEnd
    }

    /// `Tue, Thu 6 – 8 PM`.
    var summary: String {
        "\(days.shortLabel) \(TimeOfDay.rangeLabel(start: start, end: end))"
    }

    /// How the block reads in a list: its days and hours, `· If I must` when it only ranks schedules
    /// lower, `· Off` when switched off, or what is still missing.
    var listDetail: String {
        guard isValid else { return days.isEmpty ? "Choose the days" : "Check the times" }
        var text = summary
        if !isEnabled { text += " · Off" } else if strength == .preferred { text += " · If I must" }
        return text
    }
}

/// How a section is delivered, for the in-person / online / hybrid wish.
enum FormatPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case noPreference
    case inPerson
    case hybrid
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noPreference: "No preference"
        case .inPerson: "In person"
        case .hybrid: "Hybrid"
        case .online: "Online"
        }
    }
}

/// What to do about sections with no open seats.
enum SeatPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Don't filter; full sections just rank lower.
    case any
    /// Full sections are fine as long as their waitlist has room.
    case waitlistOK
    /// Only sections with open seats.
    case openOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Don't filter"
        case .waitlistOK: "Open or waitlist"
        case .openOnly: "Open seats only"
        }
    }
}

/// The total credits to aim for. Only applies to plans with optional courses.
struct CreditTarget: Codable, Hashable, Sendable {
    var lower: Int
    var upper: Int

    init(lower: Int, upper: Int) {
        self.lower = lower
        self.upper = max(lower, upper)
    }

    var label: String { lower == upper ? "\(lower) credits" : "\(lower)–\(upper) credits" }
}

// MARK: - Preferences

/// "Your ideal week": what a student wants a schedule to look like.
///
/// Hard constraints (`.required`, blocked times, the limits) remove schedules; everything
/// else only ranks them. The empty value `SchedulePreferences()` has no opinions, so the
/// generator behaves exactly as it does without preferences.
struct SchedulePreferences: Codable, Hashable, Sendable {
    // MARK: Time of day

    /// Bands that aren't "OK". Kept sparse so equal preferences compare equal.
    var timeOfDay: [TimeBand: TimePreference] = [:]
    var earliestStart: TimeLimit?
    var latestEnd: TimeLimit?

    // MARK: Days

    var daysOff = DaySet()
    var daysOffStrength: PreferenceStrength = .preferred
    var dayLayout: DayLayout = .noPreference
    /// Most sections meeting on any one day.
    var maxClassesPerDay: Int?
    /// Most class minutes on any one day.
    var maxMinutesPerDay: Int?

    // MARK: Breaks

    var gaps: GapPreference = .noPreference
    var breaks: BreakPreference = .fine
    var minimumBreakMinutes = 15
    var minimumBreakStrength: PreferenceStrength = .preferred
    var lunch: LunchBreak?

    // MARK: Blocked times

    var blockedTimes: [BlockedTime] = []

    // MARK: Format and place

    var format: FormatPreference = .noPreference
    var formatStrength: PreferenceStrength = .preferred
    /// Campus name as Banner spells it, e.g. `Boston`.
    var campus: String?
    var campusStrength: PreferenceStrength = .preferred

    // MARK: Seats, instructors, credits

    var seats: SeatPolicy = .any
    /// Banner names (`Last, First`).
    var preferredInstructors: [String] = []
    var avoidedInstructors: [String] = []
    var creditTarget: CreditTarget?

    init() {}

    /// A gap shorter than this counts as "back-to-back" for `.avoidBackToBack`.
    static let backToBackMinutes = 30

    // MARK: Derived values

    var isDefault: Bool { self == SchedulePreferences() }

    subscript(band: TimeBand) -> TimePreference {
        get { timeOfDay[band] ?? .okay }
        set { timeOfDay[band] = newValue == .okay ? nil : newValue }
    }

    var preferredBands: [TimeBand] { TimeBand.allCases.filter { self[$0] == .prefer } }
    var avoidedBands: [TimeBand] { TimeBand.allCases.filter { self[$0] == .avoid } }
    var hasTimeOfDayPreference: Bool { !timeOfDay.isEmpty }

    /// Blocks that are applied.
    var activeBlockedTimes: [BlockedTime] { blockedTimes.filter(\.isActive) }

    /// Whether any wish is in force (switched-off blocked times don't count). What the screens go by:
    /// `isDefault` is for deciding whether there is anything to store.
    var hasWishes: Bool { activeCount > 0 }

    /// How many separate wishes are set (for a badge).
    var activeCount: Int {
        var n = 0
        if hasTimeOfDayPreference { n += 1 }
        if earliestStart != nil { n += 1 }
        if latestEnd != nil { n += 1 }
        if !daysOff.isEmpty { n += 1 }
        if dayLayout != .noPreference { n += 1 }
        if maxClassesPerDay != nil || maxMinutesPerDay != nil { n += 1 }
        if gaps != .noPreference { n += 1 }
        if breaks != .fine { n += 1 }
        if lunch != nil { n += 1 }
        n += activeBlockedTimes.count
        if format != .noPreference { n += 1 }
        if campus != nil { n += 1 }
        if seats != .any { n += 1 }
        if !preferredInstructors.isEmpty || !avoidedInstructors.isEmpty { n += 1 }
        if creditTarget != nil { n += 1 }
        return n
    }

    /// Where a section meets, for the format wish.
    static func format(of section: CourseSection) -> SectionFormat {
        if section.isOnline { return .online }
        let method = (section.instructionMethod ?? "").lowercased()
        if method.contains("hybrid") { return .hybrid }
        if method.contains("live cast") || method.contains("video") || method.contains("remote") { return .online }
        if method.contains("traditional") { return .inPerson }
        return .other
    }

    /// The delivery of a section as far as the format wish is concerned.
    enum SectionFormat: Sendable {
        case inPerson, hybrid, online
        /// One-on-one, co-op, study abroad…: no format to speak of.
        case other

        /// How far the section is from what `preference` asks for: 0 matches, 0.5 is in between, 1 is the opposite.
        func mismatch(with preference: FormatPreference) -> Double {
            switch (preference, self) {
            case (.noPreference, _), (_, .other): 0
            case (.inPerson, .inPerson), (.online, .online), (.hybrid, .hybrid): 0
            case (.inPerson, .hybrid), (.online, .hybrid): 0.5
            case (.hybrid, .inPerson), (.hybrid, .online): 0.5
            case (.inPerson, .online), (.online, .inPerson): 1
            }
        }
    }

    // MARK: Cleaning

    /// Clamps every value into a sensible range and drops entries that can't be applied
    /// (blocks without days, windows that end before they start). Used on anything that
    /// didn't come from the survey controls, such as Apple Intelligence's draft.
    func normalized() -> SchedulePreferences {
        var p = self
        func clampTime(_ limit: TimeLimit?, range: ClosedRange<Int>) -> TimeLimit? {
            guard var limit else { return nil }
            limit.minutes = min(max(limit.minutes, range.lowerBound), range.upperBound)
            return limit
        }
        p.earliestStart = clampTime(p.earliestStart, range: 0...(23 * 60 + 45))
        p.latestEnd = clampTime(p.latestEnd, range: 30...(24 * 60))
        p.maxClassesPerDay = p.maxClassesPerDay.flatMap { (1...8).contains($0) ? $0 : nil }
        p.maxMinutesPerDay = p.maxMinutesPerDay.flatMap { (60...(12 * 60)).contains($0) ? $0 : nil }
        p.minimumBreakMinutes = min(max(p.minimumBreakMinutes, 5), 90)
        if var lunch = p.lunch {
            lunch.start = min(max(lunch.start, 9 * 60), 15 * 60)
            lunch.end = min(max(lunch.end, lunch.start + 30), 17 * 60)
            lunch.minutes = min(max(lunch.minutes, 15), lunch.end - lunch.start)
            p.lunch = lunch
        }
        var seen = Set<String>()
        p.blockedTimes = p.blockedTimes.compactMap { block in
            var block = block
            block.label = block.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if block.label.isEmpty { block.label = "Blocked time" }
            block.start = min(max(block.start, 0), 24 * 60)
            block.end = min(max(block.end, 0), 24 * 60)
            guard block.isValid else { return nil }
            // The same commitment twice (a model repeating itself) is one commitment.
            let key = "\(block.label.lowercased())|\(block.days.rawValue)|\(block.start)|\(block.end)"
            return seen.insert(key).inserted ? block : nil
        }
        if p.blockedTimes.count > 20 { p.blockedTimes = Array(p.blockedTimes.prefix(20)) }
        if let campus = p.campus?.trimmingCharacters(in: .whitespacesAndNewlines) { p.campus = campus.isEmpty ? nil : campus }
        func cleaned(_ names: [String]) -> [String] {
            var seen = Set<String>()
            return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
                .prefix(30).map { $0 }
        }
        p.preferredInstructors = cleaned(p.preferredInstructors)
        let preferred = Set(p.preferredInstructors.map { $0.lowercased() })
        p.avoidedInstructors = cleaned(p.avoidedInstructors).filter { !preferred.contains($0.lowercased()) }
        if var credits = p.creditTarget {
            credits.lower = min(max(credits.lower, 1), 30)
            credits.upper = min(max(credits.upper, credits.lower), 30)
            p.creditTarget = credits
        }
        return p
    }
}

// MARK: - Codable

extension SchedulePreferences {
    private enum CodingKeys: String, CodingKey {
        case timeOfDay, earliestStart, latestEnd
        case daysOff, daysOffStrength, dayLayout, maxClassesPerDay, maxMinutesPerDay
        case gaps, breaks, minimumBreakMinutes, minimumBreakStrength, lunch
        case blockedTimes
        case format, formatStrength, campus, campusStrength
        case seats, preferredInstructors, avoidedInstructors, creditTarget
    }

    /// Tolerant decoding: every field is optional, so preferences saved by an older or newer
    /// version load with defaults for what is missing and never take the saved schedule down. Even a
    /// value that isn't an object at all decodes (as no preferences), because one unreadable field
    /// would otherwise lose every saved schedule with it.
    init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let raw = c.lenient([String: String].self, .timeOfDay) {
            for (band, preference) in raw {
                if let band = TimeBand(rawValue: band), let preference = TimePreference(rawValue: preference) {
                    self[band] = preference
                }
            }
        }
        earliestStart = c.lenient(TimeLimit.self, .earliestStart)
        latestEnd = c.lenient(TimeLimit.self, .latestEnd)
        daysOff = c.lenient(DaySet.self, .daysOff) ?? DaySet()
        daysOffStrength = c.lenient(PreferenceStrength.self, .daysOffStrength) ?? .preferred
        dayLayout = c.lenient(DayLayout.self, .dayLayout) ?? .noPreference
        maxClassesPerDay = c.lenient(Int.self, .maxClassesPerDay)
        maxMinutesPerDay = c.lenient(Int.self, .maxMinutesPerDay)
        gaps = c.lenient(GapPreference.self, .gaps) ?? .noPreference
        breaks = c.lenient(BreakPreference.self, .breaks) ?? .fine
        minimumBreakMinutes = c.lenient(Int.self, .minimumBreakMinutes) ?? 15
        minimumBreakStrength = c.lenient(PreferenceStrength.self, .minimumBreakStrength) ?? .preferred
        lunch = c.lenient(LunchBreak.self, .lunch)
        // One damaged block shouldn't lose the others.
        blockedTimes = (c.lenient([LossyBlockedTime].self, .blockedTimes) ?? []).compactMap(\.value)
        format = c.lenient(FormatPreference.self, .format) ?? .noPreference
        formatStrength = c.lenient(PreferenceStrength.self, .formatStrength) ?? .preferred
        campus = c.lenient(String.self, .campus)
        campusStrength = c.lenient(PreferenceStrength.self, .campusStrength) ?? .preferred
        seats = c.lenient(SeatPolicy.self, .seats) ?? .any
        preferredInstructors = c.lenient([String].self, .preferredInstructors) ?? []
        avoidedInstructors = c.lenient([String].self, .avoidedInstructors) ?? []
        creditTarget = c.lenient(CreditTarget.self, .creditTarget)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !timeOfDay.isEmpty {
            try c.encode(Dictionary(uniqueKeysWithValues: timeOfDay.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .timeOfDay)
        }
        try c.encodeIfPresent(earliestStart, forKey: .earliestStart)
        try c.encodeIfPresent(latestEnd, forKey: .latestEnd)
        try c.encode(daysOff, forKey: .daysOff)
        try c.encode(daysOffStrength, forKey: .daysOffStrength)
        try c.encode(dayLayout, forKey: .dayLayout)
        try c.encodeIfPresent(maxClassesPerDay, forKey: .maxClassesPerDay)
        try c.encodeIfPresent(maxMinutesPerDay, forKey: .maxMinutesPerDay)
        try c.encode(gaps, forKey: .gaps)
        try c.encode(breaks, forKey: .breaks)
        try c.encode(minimumBreakMinutes, forKey: .minimumBreakMinutes)
        try c.encode(minimumBreakStrength, forKey: .minimumBreakStrength)
        try c.encodeIfPresent(lunch, forKey: .lunch)
        try c.encode(blockedTimes, forKey: .blockedTimes)
        try c.encode(format, forKey: .format)
        try c.encode(formatStrength, forKey: .formatStrength)
        try c.encodeIfPresent(campus, forKey: .campus)
        try c.encode(campusStrength, forKey: .campusStrength)
        try c.encode(seats, forKey: .seats)
        try c.encode(preferredInstructors, forKey: .preferredInstructors)
        try c.encode(avoidedInstructors, forKey: .avoidedInstructors)
        try c.encodeIfPresent(creditTarget, forKey: .creditTarget)
    }

    /// Decodes a blocked time or, when it is damaged, nothing.
    private struct LossyBlockedTime: Decodable {
        var value: BlockedTime?
        init(from decoder: Decoder) throws {
            value = try? BlockedTime(from: decoder)
        }
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or nil when it is missing or can't be decoded.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: - Presets

/// One-tap starting points for the survey. Each preset only sets its own wishes, so they combine.
enum SchedulePreset: String, CaseIterable, Identifiable, Sendable {
    case morningPerson
    case nightOwl
    case longWeekends
    case compactDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morningPerson: "Morning person"
        case .nightOwl: "Night owl"
        case .longWeekends: "Long weekends"
        case .compactDays: "Compact days"
        }
    }

    var symbol: String {
        switch self {
        case .morningPerson: "sunrise"
        case .nightOwl: "moon.stars"
        case .longWeekends: "calendar.badge.minus"
        case .compactDays: "rectangle.compress.vertical"
        }
    }

    /// What the preset does, for the accessibility hint.
    var detail: String {
        switch self {
        case .morningPerson: "Prefer classes before noon and avoid evenings."
        case .nightOwl: "Avoid mornings and prefer afternoons and evenings."
        case .longWeekends: "Prefer Fridays off and as few days on campus as possible."
        case .compactDays: "Prefer few days on campus and short gaps between classes."
        }
    }

    private var bands: [TimeBand: TimePreference]? {
        switch self {
        case .morningPerson: [.earlyMorning: .prefer, .morning: .prefer, .evening: .avoid, .night: .avoid]
        case .nightOwl: [.earlyMorning: .avoid, .morning: .avoid, .afternoon: .prefer, .evening: .prefer, .night: .prefer]
        case .longWeekends, .compactDays: nil
        }
    }

    func isApplied(to p: SchedulePreferences) -> Bool {
        switch self {
        case .morningPerson, .nightOwl: p.timeOfDay == bands
        case .longWeekends: p.daysOff.contains(.friday) && p.dayLayout == .fewerDays
        case .compactDays: p.dayLayout == .fewerDays && p.gaps == .compact
        }
    }

    func apply(to p: inout SchedulePreferences) {
        switch self {
        case .morningPerson, .nightOwl:
            p.timeOfDay = bands ?? [:]
        case .longWeekends:
            p.daysOff.insert(.friday)
            p.dayLayout = .fewerDays
        case .compactDays:
            p.dayLayout = .fewerDays
            p.gaps = .compact
        }
    }

    /// Takes the preset's wishes back out.
    func clear(from p: inout SchedulePreferences) {
        switch self {
        case .morningPerson, .nightOwl:
            p.timeOfDay = [:]
        case .longWeekends:
            p.daysOff.remove(.friday)
            if p.gaps != .compact { p.dayLayout = .noPreference }
        case .compactDays:
            p.gaps = .noPreference
            if !p.daysOff.contains(.friday) { p.dayLayout = .noPreference }
        }
    }

    func toggled(in p: SchedulePreferences) -> SchedulePreferences {
        var copy = p
        if isApplied(to: p) { clear(from: &copy) } else { apply(to: &copy) }
        return copy
    }
}

// MARK: - Summary

extension SchedulePreferences {
    /// Short phrases describing the wishes, most important first, e.g.
    /// `["Mornings", "Fridays off", "2 blocked times"]`.
    var summaryParts: [String] {
        var parts: [String] = []
        if let phrase = Self.timeOfDayPhrase(preferred: preferredBands, avoided: avoidedBands) { parts.append(phrase) }
        if let limit = earliestStart {
            parts.append(limit.strength == .required ? "Nothing before \(Self.shortTime(limit.minutes))" : "Prefer after \(Self.shortTime(limit.minutes))")
        }
        if let limit = latestEnd {
            parts.append(limit.strength == .required ? "Done by \(Self.shortTime(limit.minutes))" : "Prefer done by \(Self.shortTime(limit.minutes))")
        }
        if !daysOff.isEmpty { parts.append(Self.daysOffPhrase(daysOff)) }
        switch dayLayout {
        case .noPreference: break
        case .fewerDays: parts.append("Fewer days")
        case .spreadOut: parts.append("Spread out")
        }
        let blocked = activeBlockedTimes.count
        if blocked > 0 { parts.append(blocked == 1 ? "1 blocked time" : "\(blocked) blocked times") }
        switch gaps {
        case .noPreference: break
        case .compact: parts.append("Short gaps")
        case .fine: parts.append("Gaps are fine")
        }
        switch breaks {
        case .fine: break
        case .avoidBackToBack: parts.append("No back-to-back")
        case .atLeast: parts.append("\(minimumBreakMinutes) min to walk")
        }
        if lunch != nil { parts.append("Lunch break") }
        if let maxClassesPerDay { parts.append("Up to \(maxClassesPerDay) a day") }
        if let maxMinutesPerDay { parts.append("Up to \(Self.hoursLabel(minutes: maxMinutesPerDay)) a day") }
        if format != .noPreference { parts.append(format.title) }
        if let campus { parts.append(campus) }
        switch seats {
        case .any: break
        case .waitlistOK: parts.append("Waitlists OK")
        case .openOnly: parts.append("Open seats")
        }
        let instructors = preferredInstructors.count + avoidedInstructors.count
        if instructors > 0 { parts.append(instructors == 1 ? "1 instructor" : "\(instructors) instructors") }
        if let creditTarget { parts.append(creditTarget.label) }
        return parts
    }

    /// `Mornings · Fridays off · 2 blocked times`, trimmed to `limit` phrases with a `+N` for the rest.
    func summary(limit: Int = 3) -> String {
        let parts = summaryParts
        guard !parts.isEmpty else { return "No preferences yet" }
        guard parts.count > limit else { return parts.joined(separator: " · ") }
        return (parts.prefix(limit) + ["+\(parts.count - limit)"]).joined(separator: " · ")
    }

    // MARK: Phrases

    /// `Mornings`, `Afternoons & evenings`, `No early mornings`…
    static func timeOfDayPhrase(preferred: [TimeBand], avoided: [TimeBand]) -> String? {
        if !preferred.isEmpty {
            let text = bandPhrase(preferred)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        if !avoided.isEmpty { return "No " + bandPhrase(avoided) }
        return nil
    }

    /// The bands in plain words: `mornings`, `early mornings`, `afternoons & evenings`. The two morning
    /// bands read as one ("mornings") and so do evening and night.
    static func bandPhrase(_ bands: [TimeBand]) -> String {
        let set = Set(bands)
        var items: [String] = []
        if set.contains(.morning) { items.append("mornings") } else if set.contains(.earlyMorning) { items.append("early mornings") }
        if set.contains(.midday) { items.append("midday") }
        if set.contains(.afternoon) { items.append("afternoons") }
        if set.contains(.evening) { items.append("evenings") } else if set.contains(.night) { items.append("nights") }
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " & " + items[items.count - 1]
        }
    }

    static func daysOffPhrase(_ days: DaySet) -> String {
        let indices = days.indices
        switch indices.count {
        case 0: return ""
        case 1: return "\(DaySet.fullNames[indices[0]])s off"
        default:
            let names = indices.map { DaySet.shortNames[$0] }
            return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1] + " off"
        }
    }

    /// `10 AM`, `10:30 AM`.
    static func shortTime(_ minutes: Int) -> String {
        TimeOfDay.label(minutes).replacingOccurrences(of: ":00", with: "")
    }

    /// `3 h`, `4.5 h`.
    static func hoursLabel(minutes: Int) -> String {
        let hours = Double(minutes) / 60
        return hours.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }
}

// MARK: - Changes

/// A part of the survey, for highlighting what Apple Intelligence filled in.
enum PreferenceField: Hashable, Sendable {
    case timeOfDay(TimeBand)
    case earliestStart
    case latestEnd
    case daysOff
    case dayLayout
    case workload
    case gaps
    case breaks
    case lunch
    case blockedTime(UUID)
    case format
    case campus
    case seats
    case instructors
    case credits
}

extension SchedulePreferences {
    /// The parts of the survey that differ from `old`.
    func changedFields(from old: SchedulePreferences) -> Set<PreferenceField> {
        var changed = Set<PreferenceField>()
        for band in TimeBand.allCases where self[band] != old[band] { changed.insert(.timeOfDay(band)) }
        if earliestStart != old.earliestStart { changed.insert(.earliestStart) }
        if latestEnd != old.latestEnd { changed.insert(.latestEnd) }
        if daysOff != old.daysOff || (!daysOff.isEmpty && daysOffStrength != old.daysOffStrength) { changed.insert(.daysOff) }
        if dayLayout != old.dayLayout { changed.insert(.dayLayout) }
        if maxClassesPerDay != old.maxClassesPerDay || maxMinutesPerDay != old.maxMinutesPerDay { changed.insert(.workload) }
        if gaps != old.gaps { changed.insert(.gaps) }
        if breaks != old.breaks || (breaks == .atLeast && (minimumBreakMinutes != old.minimumBreakMinutes || minimumBreakStrength != old.minimumBreakStrength)) {
            changed.insert(.breaks)
        }
        if lunch != old.lunch { changed.insert(.lunch) }
        let oldBlocks = Dictionary(old.blockedTimes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for block in blockedTimes where oldBlocks[block.id] != block { changed.insert(.blockedTime(block.id)) }
        if format != old.format || (format != .noPreference && formatStrength != old.formatStrength) { changed.insert(.format) }
        if campus != old.campus || (campus != nil && campusStrength != old.campusStrength) { changed.insert(.campus) }
        if seats != old.seats { changed.insert(.seats) }
        if preferredInstructors != old.preferredInstructors || avoidedInstructors != old.avoidedInstructors { changed.insert(.instructors) }
        if creditTarget != old.creditTarget { changed.insert(.credits) }
        return changed
    }
}
