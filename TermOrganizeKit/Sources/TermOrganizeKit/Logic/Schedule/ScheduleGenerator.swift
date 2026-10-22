//
//  ScheduleGenerator.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), apps/searchneu/lib/scheduler/generateSchedules.ts,
//  binaryMeetingTime.ts and filters.ts, Copyright (C) Sandbox at Northeastern University
//  and the SearchNEU contributors, licensed under the GNU Affero General Public License v3.
//  Modified 2026-10-03: ported from TypeScript to Swift. Conflicts are still detected with
//  five-minute slot bitmasks, but the odometer was replaced by a depth-first search with
//  forward checking, optional courses keep only maximal combinations, every schedule is
//  scored and streamed through a bounded "best N" collector for the chosen sort order,
//  and very large search spaces are sampled instead of silently truncated.
//  Modified 2026-10-04: sections and schedules are also judged against the student's
//  `SchedulePreferences` (hard rules prune the search, soft rules add to the score),
//  credit targets replace the "only maximal combinations" rule, and an empty result
//  explains which courses block it.
//

import Foundation

// MARK: - Sorting

/// How generated schedules are ordered.
enum ScheduleSortOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case best
    case fewestDays
    case latestStart
    case earliestFinish
    case fewestGaps
    case mostSeats

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: "Best overall"
        case .fewestDays: "Fewest days on campus"
        case .latestStart: "Latest start"
        case .earliestFinish: "Earliest finish"
        case .fewestGaps: "Fewest gaps"
        case .mostSeats: "Most open seats"
        }
    }

    var shortLabel: String {
        switch self {
        case .best: "Best overall"
        case .fewestDays: "Fewest days"
        case .latestStart: "Latest start"
        case .earliestFinish: "Earliest finish"
        case .fewestGaps: "Fewest gaps"
        case .mostSeats: "Most seats"
        }
    }

    var symbol: String {
        switch self {
        case .best: "sparkles"
        case .fewestDays: "calendar.badge.minus"
        case .latestStart: "sunrise"
        case .earliestFinish: "sunset"
        case .fewestGaps: "rectangle.compress.vertical"
        case .mostSeats: "chair.lounge"
        }
    }
}

// MARK: - Slot masks

/// Meeting times as a bitmask: 7 days × 288 five-minute slots packed into 32
/// 64-bit words. Two sections conflict when their masks share a set bit
/// (port of SearchNEU's `binaryMeetingTime.ts`, which uses a BigInt).
struct ScheduleSlotMask: Hashable, Sendable {
    typealias Words = SIMD32<UInt64>

    static let minutesPerSlot = 5
    static let slotsPerDay = 24 * 60 / 5
    static let wordCount = 32

    private(set) var words = Words()

    init() {}

    /// Builds the mask of a section's weekly meetings (final exams and TBA times are ignored).
    init(section: CourseSection) {
        for meeting in section.weeklyMeetings { insert(meeting) }
    }

    init(meetings: [Meeting]) {
        for meeting in meetings { insert(meeting) }
    }

    mutating func insert(_ meeting: Meeting) {
        guard let start = meeting.start, let end = meeting.end else { return }
        for day in meeting.days.indices { insert(day: day, start: start, end: end) }
    }

    /// Marks every five-minute slot touched by `start..<end` (minutes after midnight) on `day`.
    mutating func insert(day: Int, start: Int, end: Int) {
        guard (0..<7).contains(day), end > start else { return }
        let first = max(0, start / Self.minutesPerSlot)
        // Round the end up so that even a one-minute overlap is a conflict.
        let lastExclusive = min(Self.slotsPerDay, max(first + 1, (end + Self.minutesPerSlot - 1) / Self.minutesPerSlot))
        guard first < lastExclusive else { return }
        for slot in first..<lastExclusive {
            let bit = day * Self.slotsPerDay + slot
            words[bit >> 6] |= 1 << UInt64(bit & 63)
        }
    }

    var isEmpty: Bool { words == Words() }

    /// True when the two masks occupy at least one common slot.
    func conflicts(with other: ScheduleSlotMask) -> Bool {
        (words & other.words) != Words()
    }

    func union(_ other: ScheduleSlotMask) -> ScheduleSlotMask {
        var copy = self
        copy.words |= other.words
        return copy
    }
}

// MARK: - Filtering

/// Why a section was left out before the search started.
enum ScheduleFilterReason: Int, CaseIterable, Hashable, Sendable {
    case excludedByUser
    case startsTooEarly
    case endsTooLate
    case freeDay
    case honors
    case online
    case seats
    case campus
    // The student's preferences ("your ideal week").
    case blockedTime
    case prefStartsTooEarly
    case prefEndsTooLate
    case prefDayOff
    case prefFormat
    case prefSeats
    case prefCampus
    /// Too much class time on one day by itself.
    case prefWorkload

    var bit: UInt32 { 1 << UInt32(rawValue) }
}

/// Everything a schedule is generated from: one entry per plan course.
struct ScheduleCourseInput: Identifiable, Sendable {
    var key: CourseKey
    var isRequired: Bool
    /// Sections the generator may choose. When the user has pinned a CRN, this is only
    /// that section (looked up by CRN). Another section of the same subject and number
    /// is not included.
    var sections: [CourseSection]
    var excludedCRNs: Set<String> = []
    /// Whole credits the course is worth (a range for variable-credit courses), for credit targets.
    var minCredits = 0
    var maxCredits = 0
    /// Set when this row is locked to a CRN the catalog does not have. `sections` is
    /// then empty. Generation reports the row as unavailable and does not substitute
    /// another section of the same subject and number.
    var unavailablePin: String? = nil
    var id: CourseKey { key }

    /// Candidates for one row.
    ///
    /// `pin` is resolved with `index.section(crn:)`. When that section's course is
    /// `key`, it is the only candidate. When `pin` is set and the catalog has no
    /// section with that CRN, the row stays locked: `sections` is empty and
    /// `unavailablePin` is the CRN. A CRN that belongs to a different course is
    /// locked the same way, so another section of `key` is not substituted.
    /// `fallback` is used only when `pin` is nil or blank.
    static func lockedSections(
        for key: CourseKey, in index: CatalogIndex, pin: String?, fallback: [CourseSection]
    ) -> (sections: [CourseSection], unavailablePin: String?) {
        let trimmed = pin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return (fallback, nil) }
        if let section = index.section(crn: trimmed), section.courseKey == key {
            return ([section], nil)
        }
        return ([], trimmed)
    }
}

/// A complete conflict-free schedule with the numbers used to rank it.
struct GeneratedSchedule: Identifiable, Sendable {
    /// CRNs in plan-course order.
    var crns: [String]
    var sections: [CourseSection]
    /// Days with at least one in-person weekly meeting.
    var daysOnCampus: Int
    /// Days with any timed meeting (including synchronous online classes).
    var classDays: Int
    /// Minutes after midnight; nil when nothing meets at a fixed time.
    var earliestStart: Int?
    var latestEnd: Int?
    /// Idle time between classes on the same day (breaks shorter than 20 minutes are ignored).
    var totalGapMinutes: Int
    /// The fewest open seats among the sections.
    var minSeats: Int
    var totalSeats: Int
    var fullSections: Int
    /// Composite "best overall" score; higher is better. With preferences it includes their points.
    var score: Double
    /// Why the schedule suits the student's preferences (and where it doesn't); empty without preferences.
    var reasons: [ScheduleReason]
    /// Sorted CRNs, as stored in `SchedulePlan.favoriteCombinations`.
    var sortedCRNs: [String]
    let id: String

    init(
        crns: [String], sections: [CourseSection],
        daysOnCampus: Int, classDays: Int, earliestStart: Int?, latestEnd: Int?,
        totalGapMinutes: Int, minSeats: Int, totalSeats: Int, fullSections: Int, score: Double,
        reasons: [ScheduleReason] = []
    ) {
        self.crns = crns
        self.sections = sections
        self.daysOnCampus = daysOnCampus
        self.classDays = classDays
        self.earliestStart = earliestStart
        self.latestEnd = latestEnd
        self.totalGapMinutes = totalGapMinutes
        self.minSeats = minSeats
        self.totalSeats = totalSeats
        self.fullSections = fullSections
        self.score = score
        self.reasons = reasons
        self.sortedCRNs = crns.sorted()
        self.id = sortedCRNs.joined(separator: "-")
    }

    /// Measures an arbitrary set of sections (used for favorites and the current schedule).
    /// With `preferences` the score and the reasons follow them, just like generated schedules.
    init(sections: [CourseSection], preferences: SchedulePreferences = SchedulePreferences()) {
        var buildings = ScheduleBuildingTable()
        var intervals: [ScheduleInterval] = []
        var minSeats = Int.max, totalSeats = 0, full = 0
        var points = 0.0
        for section in sections {
            let own = ScheduleInterval.intervals(for: section, buildings: &buildings)
            intervals.append(contentsOf: own)
            if !preferences.isDefault {
                points += SchedulePreferenceRules.sectionScore(for: section, intervals: own, preferences: preferences)
            }
            let seats = max(0, section.seatsRemaining)
            minSeats = min(minSeats, seats)
            totalSeats += seats
            if seats == 0 { full += 1 }
        }
        let raw = ScheduleMeasure.measure(intervals, options: ScheduleScoring.measureOptions(for: preferences))
        let weights = ScheduleScoring.Weights(preferences: preferences)
        self.init(
            crns: sections.map(\.crn),
            sections: sections,
            daysOnCampus: raw.campusDays,
            classDays: raw.classDays,
            earliestStart: raw.earliestStart == Int.max ? nil : raw.earliestStart,
            latestEnd: raw.latestEnd == Int.min ? nil : raw.latestEnd,
            totalGapMinutes: raw.gapMinutes,
            minSeats: minSeats == Int.max ? 0 : minSeats,
            totalSeats: totalSeats,
            fullSections: full,
            score: weights.score(measure: raw, fullSections: full, minSeats: minSeats == Int.max ? 0 : minSeats) + points,
            reasons: SchedulePreferenceRules.reasons(for: sections, preferences: preferences)
        )
    }
}

extension GeneratedSchedule: Hashable {
    static func == (lhs: GeneratedSchedule, rhs: GeneratedSchedule) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The outcome of a generator run.
struct ScheduleGenerationResult: Sendable {
    /// The best schedules for the requested sort, at most `Limits.maxResults`.
    var schedules: [GeneratedSchedule] = []
    /// Valid schedules seen. Exact when `isExhaustive`, otherwise a lower bound.
    var totalFound = 0
    /// False when the search space was too large to enumerate and a sample was used instead.
    var isExhaustive = true
    var wasCancelled = false
    var diagnostics = ScheduleDiagnostics()
    var elapsed: TimeInterval = 0

    /// Whether some valid schedules are not in `schedules`.
    var isTruncated: Bool { !isExhaustive || schedules.count < totalFound }
}

// MARK: - Diagnostics

/// Explains an empty result: which sections each constraint removed and which
/// courses can never be combined.
struct ScheduleDiagnostics: Sendable {
    struct CourseReport: Identifiable, Hashable, Sendable {
        var key: CourseKey
        var isRequired: Bool
        var totalSections: Int
        var remainingSections: Int
        /// How many sections each constraint rejected (a section can fail several).
        var rejections: [ScheduleFilterReason: Int]
        /// The CRN this row is locked to when the catalog no longer has it.
        /// Empty `totalSections` then means unavailable, not "not offered".
        var unavailablePin: String? = nil

        var id: CourseKey { key }
        var isBlocked: Bool { remainingSections == 0 }
    }

    struct ConflictPair: Hashable, Sendable {
        enum Reason: Hashable, Sendable {
            /// Some meeting of one overlaps a meeting of the other in every combination.
            case overlap
            /// They never overlap, but not with the time the student wants between buildings.
            case travelTime
        }

        var first: CourseKey
        var second: CourseKey
        var reason = Reason.overlap
    }

    enum CountProblem: Hashable, Sendable {
        /// More required courses than the requested course count.
        case tooManyRequired(required: Int, wanted: Int)
        /// Fewer usable courses than the requested course count.
        case tooFewCourses(available: Int, wanted: Int)
        /// The required courses alone are worth more credits than the credit target allows.
        case creditsOverTarget(required: Int, limit: Int)
        /// Every usable course together is worth fewer credits than the credit target asks for.
        case creditsUnderTarget(available: Int, wanted: Int)
    }

    var filters = ScheduleFilters()
    var preferences = SchedulePreferences()
    var courses: [CourseReport] = []
    /// Pairs of courses whose remaining sections all overlap.
    var conflictingPairs: [ConflictPair] = []
    var countProblem: CountProblem?
    var hasNoCourses: Bool { courses.isEmpty }
    var blockedRequiredCourses: [CourseReport] { courses.filter { $0.isRequired && $0.isBlocked } }
}

/// A single change that might turn "no schedules" into some.
enum ScheduleRelaxation: Hashable, Sendable, Identifiable {
    case clearEarliestStart
    case clearLatestEnd
    case clearFreeDays
    case allowHonors
    case allowOnline
    case allowFullSections
    case clearCampus
    case clearCourseCount
    case makeOptional(CourseKey)
    /// Loosen one of the student's preferences (see `PreferenceRelaxation`).
    case preference(PreferenceRelaxation)

    var id: String {
        switch self {
        case .makeOptional(let key): "optional-\(key)"
        case .preference(let relaxation): "preference-\(relaxation)"
        default: "\(self)"
        }
    }

    var title: String {
        switch self {
        case .clearEarliestStart: "Remove start time limit"
        case .clearLatestEnd: "Remove end time limit"
        case .clearFreeDays: "Allow classes on every day"
        case .allowHonors: "Include honors sections"
        case .allowOnline: "Include online sections"
        case .allowFullSections: "Include full sections"
        case .clearCampus: "Allow any campus"
        case .clearCourseCount: "Use any number of courses"
        case .makeOptional(let key): "Make \(key) optional"
        case .preference(let relaxation): relaxation.title
        }
    }

    var symbol: String {
        switch self {
        case .clearEarliestStart: "sunrise"
        case .clearLatestEnd: "sunset"
        case .clearFreeDays: "calendar"
        case .allowHonors: "star"
        case .allowOnline: "wifi"
        case .allowFullSections: "chair.lounge"
        case .clearCampus: "building.2"
        case .clearCourseCount: "number"
        case .makeOptional: "questionmark.circle"
        case .preference(let relaxation): relaxation.symbol
        }
    }

    /// Applies the filter part of the change. `makeOptional` edits the plan instead,
    /// and `preference` edits the preferences (`apply(to: &preferences)`).
    func apply(to filters: inout ScheduleFilters) {
        switch self {
        case .clearEarliestStart: filters.earliestStart = nil
        case .clearLatestEnd: filters.latestEnd = nil
        case .clearFreeDays: filters.freeDays = DaySet()
        case .allowHonors: filters.includeHonors = true
        case .allowOnline: filters.includeOnline = true
        case .allowFullSections:
            filters.hideFullSections = false
            filters.minSeats = 0
        case .clearCampus: filters.campus = nil
        case .clearCourseCount: filters.courseCount = nil
        case .makeOptional, .preference: break
        }
    }

    /// Applies the preference part of the change (only `preference` has one).
    func apply(to preferences: inout SchedulePreferences) {
        if case .preference(let relaxation) = self { relaxation.apply(to: &preferences) }
    }
}

/// A change to the student's preferences that might turn "no schedules" into some. Required wishes
/// become "if possible" (the schedules that respect them still come first); limits are lifted.
enum PreferenceRelaxation: Hashable, Sendable {
    case softenEarliestStart
    case softenLatestEnd
    case softenDaysOff
    case softenBlockedTime(id: UUID, label: String)
    case softenFormat
    case softenCampus
    case allowFullSections
    case clearMaxClassesPerDay
    case clearMaxMinutesPerDay
    case softenMinimumBreak
    case clearCreditTarget

    var title: String {
        switch self {
        case .softenEarliestStart: "Allow earlier classes if needed"
        case .softenLatestEnd: "Allow later classes if needed"
        case .softenDaysOff: "Allow classes on your days off if needed"
        case .softenBlockedTime(_, let label): "Allow classes during “\(label)” if needed"
        case .softenFormat: "Allow other formats if needed"
        case .softenCampus: "Allow other campuses if needed"
        case .allowFullSections: "Include full sections"
        case .clearMaxClassesPerDay: "Remove the classes-a-day limit"
        case .clearMaxMinutesPerDay: "Remove the hours-a-day limit"
        case .softenMinimumBreak: "Don’t require time to walk between classes"
        case .clearCreditTarget: "Remove the credit target"
        }
    }

    var symbol: String {
        switch self {
        case .softenEarliestStart: "sunrise"
        case .softenLatestEnd: "sunset"
        case .softenDaysOff: "calendar"
        case .softenBlockedTime: "calendar.badge.clock"
        case .softenFormat: "wifi"
        case .softenCampus: "building.2"
        case .allowFullSections: "chair.lounge"
        case .clearMaxClassesPerDay, .clearMaxMinutesPerDay: "gauge.with.dots.needle.33percent"
        case .softenMinimumBreak: "figure.walk"
        case .clearCreditTarget: "number"
        }
    }

    func apply(to p: inout SchedulePreferences) {
        switch self {
        case .softenEarliestStart: p.earliestStart?.strength = .preferred
        case .softenLatestEnd: p.latestEnd?.strength = .preferred
        case .softenDaysOff: p.daysOffStrength = .preferred
        case .softenBlockedTime(let id, _):
            if let i = p.blockedTimes.firstIndex(where: { $0.id == id }) { p.blockedTimes[i].strength = .preferred }
        case .softenFormat: p.formatStrength = .preferred
        case .softenCampus: p.campusStrength = .preferred
        case .allowFullSections: p.seats = .any
        case .clearMaxClassesPerDay: p.maxClassesPerDay = nil
        case .clearMaxMinutesPerDay: p.maxMinutesPerDay = nil
        case .softenMinimumBreak: p.minimumBreakStrength = .preferred
        case .clearCreditTarget: p.creditTarget = nil
        }
    }

    /// The relaxations that apply to the rules `p` currently enforces.
    static func available(for p: SchedulePreferences) -> [PreferenceRelaxation] {
        var result: [PreferenceRelaxation] = []
        if p.earliestStart?.strength == .required { result.append(.softenEarliestStart) }
        if p.latestEnd?.strength == .required { result.append(.softenLatestEnd) }
        if !p.daysOff.isEmpty, p.daysOffStrength == .required { result.append(.softenDaysOff) }
        for block in p.activeBlockedTimes where block.strength == .required {
            result.append(.softenBlockedTime(id: block.id, label: block.label))
        }
        if p.format != .noPreference, p.formatStrength == .required { result.append(.softenFormat) }
        if p.campus != nil, p.campusStrength == .required { result.append(.softenCampus) }
        if p.seats != .any { result.append(.allowFullSections) }
        if p.maxClassesPerDay != nil { result.append(.clearMaxClassesPerDay) }
        if p.maxMinutesPerDay != nil { result.append(.clearMaxMinutesPerDay) }
        if p.breaks == .atLeast, p.minimumBreakStrength == .required { result.append(.softenMinimumBreak) }
        if p.creditTarget != nil { result.append(.clearCreditTarget) }
        return result
    }
}

/// A relaxation together with the number of schedules it would unlock.
struct ScheduleSuggestion: Identifiable, Hashable, Sendable {
    var relaxation: ScheduleRelaxation
    var scheduleCount: Int
    /// True when `scheduleCount` is a lower bound.
    var isLowerBound: Bool
    var id: String { relaxation.id }
}

// MARK: - Generator

/// Generates conflict-free schedules for the courses of a plan.
///
/// Required courses appear in every schedule; optional courses are added when
/// they fit. With `filters.courseCount` set, exactly that many courses are
/// used, otherwise every required course plus as many optional courses as fit
/// (only maximal combinations are kept). Sections without weekly meeting times
/// never conflict. The generator is pure: call it from `Task.detached`.
///
/// Every valid schedule is streamed through a bounded "best N" collector, so
/// even millions of combinations are ranked exactly in well under a second and
/// with almost no memory. If the space is still too big, a stratified sample of
/// it is ranked as well and the result is marked as not exhaustive.
enum ScheduleGenerator {
    struct Limits: Sendable {
        /// Schedules returned.
        var maxResults = 5_000
        /// Valid schedules the exhaustive pass may examine before the space counts as too big to list.
        var maxExhaustiveLeaves = 2_500_000
        /// Search nodes visited per pass.
        var maxNodes = 12_000_000
        /// Wall-clock budget of the exhaustive pass.
        var timeBudget: TimeInterval = 0.9
        /// Schedules examined by the sampling pass over a space that was too big.
        var sampleLeaves = 150_000
        /// Wall-clock budget of the sampling pass.
        var sampleTimeBudget: TimeInterval = 0.35
        /// Sample the space when it is too big to enumerate.
        var allowSampling = true

        static let standard = Limits()
        /// Cheap existence checks used to rank relaxations.
        static let probe = Limits(maxResults: 1, maxExhaustiveLeaves: 300, maxNodes: 300_000, timeBudget: 0.25, sampleLeaves: 0, sampleTimeBudget: 0, allowSampling: false)
    }

    // MARK: Filters

    /// The constraints that reject a section: the plan's filters and, when given, the preferences' hard rules.
    static func rejectionReasons(
        for section: CourseSection, filters: ScheduleFilters,
        preferences: SchedulePreferences = SchedulePreferences(), excluded: Set<String> = []
    ) -> UInt32 {
        var reasons: UInt32 = 0
        if excluded.contains(section.crn) { reasons |= ScheduleFilterReason.excludedByUser.bit }
        let weekly = section.weeklyMeetings
        if let earliest = filters.earliestStart, weekly.contains(where: { ($0.start ?? Int.max) < earliest }) {
            reasons |= ScheduleFilterReason.startsTooEarly.bit
        }
        if let latest = filters.latestEnd, weekly.contains(where: { ($0.end ?? 0) > latest }) {
            reasons |= ScheduleFilterReason.endsTooLate.bit
        }
        if !filters.freeDays.isEmpty, weekly.contains(where: { !$0.days.isDisjoint(with: filters.freeDays) }) {
            reasons |= ScheduleFilterReason.freeDay.bit
        }
        if !filters.includeHonors, section.honors { reasons |= ScheduleFilterReason.honors.bit }
        if !filters.includeOnline, section.isOnline { reasons |= ScheduleFilterReason.online.bit }
        if filters.hideFullSections, section.seatsRemaining <= 0 { reasons |= ScheduleFilterReason.seats.bit }
        if filters.minSeats > 0, section.seatsRemaining < filters.minSeats { reasons |= ScheduleFilterReason.seats.bit }
        if let campus = filters.campus, !section.isOnline, !hasNoCampus(section), section.campus != campus {
            reasons |= ScheduleFilterReason.campus.bit
        }
        if !preferences.isDefault {
            reasons |= SchedulePreferenceRules.rejectionReasons(for: section, preferences: preferences)
        }
        return reasons
    }

    /// Banner files sections that need no room (research, independent study…)
    /// under "No campus, no room needed"; like online sections they fit any campus.
    static func hasNoCampus(_ section: CourseSection) -> Bool {
        section.campus.localizedCaseInsensitiveContains("no campus")
    }

    /// Whether a section passes every filter (ignoring user exclusions).
    static func passesFilters(_ section: CourseSection, filters: ScheduleFilters) -> Bool {
        rejectionReasons(for: section, filters: filters) == 0
    }

    // MARK: Entry point

    /// Generates the plan's schedules. `preferences` are "your ideal week": their hard rules remove
    /// schedules like filters do, and the rest ranks what remains (the "best" sort puts the best
    /// match first; the other sorts use it to break ties).
    static func generate(
        courses: [ScheduleCourseInput],
        filters: ScheduleFilters,
        preferences: SchedulePreferences = SchedulePreferences(),
        sort: ScheduleSortOption = .best,
        limits: Limits = .standard
    ) -> ScheduleGenerationResult {
        let started = ProcessInfo.processInfo.systemUptime
        var result = run(courses: courses, filters: filters, preferences: preferences.normalized(), sort: sort, limits: limits)
        result.elapsed = ProcessInfo.processInfo.systemUptime - started
        return result
    }

    private static func run(
        courses: [ScheduleCourseInput],
        filters: ScheduleFilters,
        preferences: SchedulePreferences,
        sort: ScheduleSortOption,
        limits: Limits
    ) -> ScheduleGenerationResult {
        var result = ScheduleGenerationResult()
        let hasPreferences = !preferences.isDefault

        // 1. Apply the filters and remember why sections were dropped.
        var kept: [[CourseSection]] = []
        var reports: [ScheduleDiagnostics.CourseReport] = []
        for course in courses {
            var remaining: [CourseSection] = []
            var rejections: [ScheduleFilterReason: Int] = [:]
            for section in course.sections {
                let reasons = rejectionReasons(for: section, filters: filters, preferences: preferences, excluded: course.excludedCRNs)
                if reasons == 0 {
                    remaining.append(section)
                } else {
                    for reason in ScheduleFilterReason.allCases where reasons & reason.bit != 0 {
                        rejections[reason, default: 0] += 1
                    }
                }
            }
            kept.append(remaining)
            reports.append(.init(
                key: course.key, isRequired: course.isRequired,
                totalSections: course.sections.count, remainingSections: remaining.count,
                rejections: rejections,
                unavailablePin: course.unavailablePin
            ))
        }
        result.diagnostics = ScheduleDiagnostics(filters: filters, preferences: preferences, courses: reports)

        // 2. Decide which courses take part.
        let requiredIndexes = courses.indices.filter { courses[$0].isRequired }
        let optionalIndexes = courses.indices.filter { !courses[$0].isRequired && !kept[$0].isEmpty }
        let target = filters.courseCount.flatMap { $0 > 0 ? $0 : nil }
        let creditWindow = preferences.creditTarget.map { $0.lower...$0.upper }

        guard !courses.isEmpty else { return result }
        if requiredIndexes.contains(where: { kept[$0].isEmpty }) { return result }
        if let target {
            if requiredIndexes.count > target {
                result.diagnostics.countProblem = .tooManyRequired(required: requiredIndexes.count, wanted: target)
                return result
            }
            if requiredIndexes.count + optionalIndexes.count < target {
                result.diagnostics.countProblem = .tooFewCourses(available: requiredIndexes.count + optionalIndexes.count, wanted: target)
                return result
            }
        }
        if let creditWindow {
            let required = requiredIndexes.reduce(0) { $0 + courses[$1].minCredits }
            if required > creditWindow.upperBound {
                result.diagnostics.countProblem = .creditsOverTarget(required: required, limit: creditWindow.upperBound)
                return result
            }
            let available = requiredIndexes.reduce(0) { $0 + courses[$1].maxCredits } + optionalIndexes.reduce(0) { $0 + courses[$1].maxCredits }
            if available < creditWindow.lowerBound {
                result.diagnostics.countProblem = .creditsUnderTarget(available: available, wanted: creditWindow.lowerBound)
                return result
            }
        }

        // Fewest sections first prunes the search the earliest.
        func ordered(_ indexes: [Int]) -> [Int] {
            indexes.sorted { kept[$0].count != kept[$1].count ? kept[$0].count < kept[$1].count : $0 < $1 }
        }
        let searchOrder = ordered(requiredIndexes) + ordered(optionalIndexes)
        guard !searchOrder.isEmpty else { return result }

        // 3. Flatten sections into global ids and precompute masks, intervals and per-section points.
        var sections: [CourseSection] = []
        var masks: [ScheduleSlotMask] = []
        var weeklyMeetings: [[Meeting]] = []
        var intervalStart: [Int] = []
        var intervals: [ScheduleInterval] = []
        var sectionPoints: [Double] = []
        var rules = ScheduleSearchRules()
        var buildings = ScheduleBuildingTable()
        var slots: [ScheduleSearch.Slot] = []
        for courseIndex in searchOrder {
            let first = sections.count
            var candidates: [(section: CourseSection, intervals: [ScheduleInterval], points: Double)] = []
            for section in kept[courseIndex] {
                let own = ScheduleInterval.intervals(for: section, buildings: &buildings)
                let points = hasPreferences ? SchedulePreferenceRules.sectionScore(for: section, intervals: own, preferences: preferences) : 0
                candidates.append((section, own, points))
            }
            if hasPreferences {
                // Best sections first (ties keep the catalog's order), so a search too big to finish
                // meets the schedules the student wants before it runs out of time.
                candidates = candidates.enumerated().sorted {
                    $0.element.points != $1.element.points ? $0.element.points > $1.element.points : $0.offset < $1.offset
                }.map(\.element)
            }
            for candidate in candidates {
                let section = candidate.section
                sections.append(section)
                let weekly = section.weeklyMeetings
                weeklyMeetings.append(weekly)
                masks.append(ScheduleSlotMask(meetings: weekly))
                intervalStart.append(intervals.count)
                intervals.append(contentsOf: candidate.intervals)
                sectionPoints.append(candidate.points)
                rules.append(section: candidate.intervals)
            }
            slots.append(.init(courseIndex: courseIndex, isRequired: courses[courseIndex].isRequired, start: first, size: sections.count - first))
            rules.slotMinCredits.append(courses[courseIndex].minCredits)
            rules.slotMaxCredits.append(max(courses[courseIndex].minCredits, courses[courseIndex].maxCredits))
        }
        intervalStart.append(intervals.count)
        rules.maxClassesPerDay = Int32(clamping: preferences.maxClassesPerDay ?? Int(Int32.max))
        rules.maxMinutesPerDay = Int32(clamping: preferences.maxMinutesPerDay ?? Int(Int32.max))
        if preferences.breaks == .atLeast, preferences.minimumBreakStrength == .required {
            rules.travelMinutes = preferences.minimumBreakMinutes
        }
        rules.creditWindow = creditWindow

        let collector = ScheduleCollector(
            sort: sort,
            capacity: max(1, limits.maxResults),
            slotStart: slots.map(\.start),
            intervalStart: intervalStart,
            intervals: intervals,
            seatsRemaining: sections.map { max(0, $0.seatsRemaining) },
            sectionPoints: sectionPoints,
            weights: ScheduleScoring.Weights(preferences: preferences),
            options: ScheduleScoring.measureOptions(for: preferences)
        )
        let search = ScheduleSearch(
            slots: slots, masks: masks, weeklyMeetings: weeklyMeetings, sections: sections,
            target: target, rules: rules, limits: limits, collector: collector, seed: seed(for: sections)
        )

        // 4. Search: exhaustively first, then by stratified sampling when the space is too big.
        search.runExhaustive()
        if search.cancelled {
            result.wasCancelled = true
            return result
        }
        var totalFound = search.leafCount
        var exhaustive = !search.hitLimit
        if search.hitLimit {
            exhaustive = false
            if limits.allowSampling, limits.sampleLeaves > 0 {
                search.runSampled()
                if search.cancelled {
                    result.wasCancelled = true
                    return result
                }
                totalFound = max(totalFound, search.leafCount)
            }
        }
        result.totalFound = totalFound
        result.isExhaustive = exhaustive

        if totalFound == 0 {
            if exhaustive { result.diagnostics.conflictingPairs = conflictingPairs(search: search, slots: slots, courses: courses) }
            return result
        }

        // 5. Materialize the winners (best first).
        let slotCount = slots.count
        var schedules: [GeneratedSchedule] = []
        schedules.reserveCapacity(collector.count)
        for ranked in collector.ranked() {
            var picked: [(course: Int, id: Int)] = []
            picked.reserveCapacity(slotCount)
            for s in 0..<slotCount {
                let pick = ranked.picks[ranked.picks.startIndex + s]
                if pick == ScheduleSearch.skipMarker { continue }
                picked.append((slots[s].courseIndex, slots[s].start + Int(pick)))
            }
            picked.sort { $0.course < $1.course }
            let chosen = picked.map { sections[$0.id] }
            let m = ranked.metrics
            schedules.append(GeneratedSchedule(
                crns: chosen.map(\.crn),
                sections: chosen,
                daysOnCampus: m.campusDays,
                classDays: m.classDays,
                earliestStart: m.earliest == Int.max ? nil : m.earliest,
                latestEnd: m.classDays == 0 ? nil : m.latest,
                totalGapMinutes: m.gap,
                minSeats: m.minSeats,
                totalSeats: m.totalSeats,
                fullSections: m.full,
                score: m.score,
                reasons: hasPreferences ? SchedulePreferenceRules.reasons(for: chosen, preferences: preferences) : []
            ))
        }
        result.schedules = schedules
        return result
    }

    // MARK: Diagnostics and suggestions

    /// Pairs of required courses whose remaining sections can't be combined: they all overlap (or, when the
    /// student requires time to walk between buildings, are all too close).
    private static func conflictingPairs(search: ScheduleSearch, slots: [ScheduleSearch.Slot], courses: [ScheduleCourseInput]) -> [ScheduleDiagnostics.ConflictPair] {
        var pairs: [ScheduleDiagnostics.ConflictPair] = []
        for a in slots.indices {
            for b in slots.indices where b > a && slots[a].isRequired && slots[b].isRequired {
                if !search.hasCompatiblePair(slotA: a, slotB: b) {
                    pairs.append(.init(
                        first: courses[slots[a].courseIndex].key, second: courses[slots[b].courseIndex].key,
                        reason: search.hasOverlapFreePair(slotA: a, slotB: b) ? .travelTime : .overlap
                    ))
                }
            }
        }
        return pairs
    }

    /// Tries each single relaxation and returns the ones that produce schedules, best first.
    /// `includeCourseRelaxations` also tries making each required course optional; `analyzeBlockers` does that
    /// more thoroughly, so callers that use it pass false.
    static func suggestRelaxations(
        courses: [ScheduleCourseInput], filters: ScheduleFilters,
        preferences: SchedulePreferences = SchedulePreferences(), includeCourseRelaxations: Bool = true
    ) -> [ScheduleSuggestion] {
        var candidates: [(ScheduleRelaxation, ScheduleFilters, SchedulePreferences, [ScheduleCourseInput])] = []

        func addFilter(_ relaxation: ScheduleRelaxation, when isActive: Bool) {
            guard isActive else { return }
            var relaxed = filters
            relaxation.apply(to: &relaxed)
            candidates.append((relaxation, relaxed, preferences, courses))
        }
        addFilter(.clearEarliestStart, when: filters.earliestStart != nil)
        addFilter(.clearLatestEnd, when: filters.latestEnd != nil)
        addFilter(.clearFreeDays, when: !filters.freeDays.isEmpty)
        addFilter(.allowHonors, when: !filters.includeHonors)
        addFilter(.allowOnline, when: !filters.includeOnline)
        addFilter(.allowFullSections, when: filters.hideFullSections || filters.minSeats > 0)
        addFilter(.clearCampus, when: filters.campus != nil)
        addFilter(.clearCourseCount, when: filters.courseCount != nil)
        for relaxation in PreferenceRelaxation.available(for: preferences) {
            var relaxed = preferences
            relaxation.apply(to: &relaxed)
            candidates.append((.preference(relaxation), filters, relaxed, courses))
        }
        if includeCourseRelaxations {
            for (index, course) in courses.enumerated() where course.isRequired && courses.count > 1 {
                var relaxedCourses = courses
                relaxedCourses[index].isRequired = false
                candidates.append((.makeOptional(course.key), filters, preferences, relaxedCourses))
            }
        }

        var suggestions: [ScheduleSuggestion] = []
        for (relaxation, relaxedFilters, relaxedPreferences, relaxedCourses) in candidates {
            if Task.isCancelled { break }
            let probe = generate(courses: relaxedCourses, filters: relaxedFilters, preferences: relaxedPreferences, sort: .best, limits: .probe)
            guard probe.totalFound > 0 else { continue }
            suggestions.append(ScheduleSuggestion(relaxation: relaxation, scheduleCount: probe.totalFound, isLowerBound: !probe.isExhaustive))
        }
        return suggestions.sorted { $0.scheduleCount > $1.scheduleCount }
    }

    private static func seed(for sections: [CourseSection]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for section in sections {
            for byte in section.crn.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }
}

// MARK: - Ranking

/// Numbers kept per candidate schedule while ranking.
private struct LeafMetrics {
    var classDays = 0
    var campusDays = 0
    var earliest = Int.max
    var latest = 0
    var gap = 0
    var minSeats = 0
    var totalSeats = 0
    var full = 0
    var score = 0.0
}

private extension ScheduleSortOption {
    /// Whether `a` ranks ahead of `b`; `tieBreak` decides exact ties.
    func precedes(_ a: LeafMetrics, _ b: LeafMetrics, tieBreak: Bool) -> Bool {
        switch self {
        case .best:
            break
        case .fewestDays:
            if a.campusDays != b.campusDays { return a.campusDays < b.campusDays }
            if a.classDays != b.classDays { return a.classDays < b.classDays }
            if a.gap != b.gap { return a.gap < b.gap }
        case .latestStart:
            if a.earliest != b.earliest { return a.earliest > b.earliest }
            if a.campusDays != b.campusDays { return a.campusDays < b.campusDays }
        case .earliestFinish:
            if a.latest != b.latest { return a.latest < b.latest }
            if a.campusDays != b.campusDays { return a.campusDays < b.campusDays }
        case .fewestGaps:
            if a.gap != b.gap { return a.gap < b.gap }
            if a.campusDays != b.campusDays { return a.campusDays < b.campusDays }
        case .mostSeats:
            if a.minSeats != b.minSeats { return a.minSeats > b.minSeats }
            if a.totalSeats != b.totalSeats { return a.totalSeats > b.totalSeats }
        }
        if a.score != b.score { return a.score > b.score }
        return tieBreak
    }
}

/// Keeps the best `capacity` schedules offered to it, as a binary heap whose
/// root is the worst schedule kept. Offering a schedule that would not make the
/// cut costs one measurement and one comparison.
private final class ScheduleCollector {
    struct Entry {
        var metrics: LeafMetrics
        var seq: Int
        var hash: UInt64
        /// Offset of this entry's picks in `pickStore`.
        var base: Int
    }

    private let sort: ScheduleSortOption
    private let capacity: Int
    private let slotCount: Int
    private let slotStart: [Int]
    private let intervalStart: [Int]
    private let intervals: [ScheduleInterval]
    private let seatsRemaining: [Int]
    /// Points the preferences give each section on its own.
    private let sectionPoints: [Double]
    private let weights: ScheduleScoring.Weights
    private let options: ScheduleMeasureOptions
    private let scratch: UnsafeMutablePointer<ScheduleInterval>

    private var entries: [Entry] = []
    private var pickStore: [UInt16]
    private var members = Set<UInt64>()
    private var nextSeq = 0

    init(
        sort: ScheduleSortOption, capacity: Int, slotStart: [Int], intervalStart: [Int], intervals: [ScheduleInterval],
        seatsRemaining: [Int], sectionPoints: [Double], weights: ScheduleScoring.Weights, options: ScheduleMeasureOptions
    ) {
        self.sort = sort
        self.capacity = capacity
        self.slotStart = slotStart
        slotCount = slotStart.count
        self.intervalStart = intervalStart
        self.intervals = intervals
        self.seatsRemaining = seatsRemaining
        self.sectionPoints = sectionPoints
        self.weights = weights
        self.options = options
        pickStore = []
        // Worst case: every slot picks its section with the most intervals.
        var perSlot: [Int] = []
        for s in 0..<slotStart.count {
            let lower = slotStart[s]
            let upper = s + 1 < slotStart.count ? slotStart[s + 1] : seatsRemaining.count
            var widest = 0
            for g in lower..<upper { widest = max(widest, intervalStart[g + 1] - intervalStart[g]) }
            perSlot.append(widest)
        }
        scratch = UnsafeMutablePointer<ScheduleInterval>.allocate(capacity: max(1, perSlot.reduce(0, +)))
    }

    deinit { scratch.deallocate() }

    var count: Int { entries.count }

    /// Measures the schedule described by `picks` (local section index per slot, -1 = none)
    /// and keeps it if it ranks among the best.
    func offer(_ picks: [Int]) {
        var n = 0
        var minSeats = Int.max, totalSeats = 0, full = 0
        var points = 0.0
        for s in 0..<slotCount {
            let pick = picks[s]
            if pick < 0 { continue }
            let g = slotStart[s] + pick
            var k = intervalStart[g]
            let end = intervalStart[g + 1]
            while k < end {
                scratch[n] = intervals[k]
                n += 1
                k += 1
            }
            let seats = seatsRemaining[g]
            minSeats = min(minSeats, seats)
            totalSeats += seats
            if seats == 0 { full += 1 }
            points += sectionPoints[g]
        }
        let raw = ScheduleMeasure.measure(scratch, count: n, options: options)
        let seatsFloor = minSeats == Int.max ? 0 : minSeats
        var m = LeafMetrics()
        m.classDays = raw.classDays
        m.campusDays = raw.campusDays
        m.earliest = raw.earliestStart
        m.latest = raw.latestEnd == Int.min ? 0 : raw.latestEnd
        m.gap = raw.gapMinutes
        m.minSeats = seatsFloor
        m.totalSeats = totalSeats
        m.full = full
        m.score = weights.score(measure: raw, fullSections: full, minSeats: seatsFloor) + points

        let seq = nextSeq
        nextSeq += 1
        if entries.count == capacity {
            // Later arrivals lose exact ties, so only a strictly better schedule replaces the worst.
            if !sort.precedes(m, entries[0].metrics, tieBreak: false) { return }
        }

        var hash: UInt64 = 0xcbf29ce484222325
        for s in 0..<slotCount {
            hash ^= UInt64(truncatingIfNeeded: picks[s] &+ 1)
            hash = hash &* 0x100000001b3
        }
        if members.contains(hash) { return }
        members.insert(hash)

        if entries.count < capacity {
            let base = entries.count * slotCount
            pickStore.append(contentsOf: repeatElement(0, count: slotCount))
            store(picks, at: base)
            entries.append(Entry(metrics: m, seq: seq, hash: hash, base: base))
            siftUp(entries.count - 1)
        } else {
            let base = entries[0].base
            members.remove(entries[0].hash)
            store(picks, at: base)
            entries[0] = Entry(metrics: m, seq: seq, hash: hash, base: base)
            siftDown(0)
        }
    }

    /// The kept schedules, best first.
    func ranked() -> [(metrics: LeafMetrics, picks: ArraySlice<UInt16>)] {
        let sorted = entries.sorted { sort.precedes($0.metrics, $1.metrics, tieBreak: $0.seq < $1.seq) }
        return sorted.map { ($0.metrics, pickStore[$0.base..<($0.base + slotCount)]) }
    }

    private func store(_ picks: [Int], at base: Int) {
        for s in 0..<slotCount {
            pickStore[base + s] = picks[s] < 0 ? ScheduleSearch.skipMarker : UInt16(truncatingIfNeeded: picks[s])
        }
    }

    /// Whether `a` ranks behind `b`.
    private func isWorse(_ a: Entry, _ b: Entry) -> Bool {
        sort.precedes(b.metrics, a.metrics, tieBreak: b.seq < a.seq)
    }

    private func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard isWorse(entries[child], entries[parent]) else { return }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private func siftDown(_ index: Int) {
        var parent = index
        let n = entries.count
        while true {
            let left = 2 * parent + 1, right = left + 1
            var worst = parent
            if left < n, isWorse(entries[left], entries[worst]) { worst = left }
            if right < n, isWorse(entries[right], entries[worst]) { worst = right }
            if worst == parent { return }
            entries.swapAt(parent, worst)
            parent = worst
        }
    }
}

// MARK: - Search

/// Deterministic random numbers for reproducible sampling.
private struct ScheduleSplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The hard rules the search enforces while it builds a schedule, as opposed to the filters,
/// which remove sections before it starts. All of them only get harder as sections are added,
/// so a partial schedule that breaks one can be dropped on the spot.
private struct ScheduleSearchRules {
    /// Most sections meeting on one day, and most class minutes on one day (`Int32.max` = no limit).
    var maxClassesPerDay = Int32.max
    var maxMinutesPerDay = Int32.max
    /// Per section (global id): per weekday, whether it meets that day and for how many minutes.
    var dayClasses: [SIMD8<Int32>] = []
    var dayMinutes: [SIMD8<Int32>] = []
    /// The least time required between in-person classes in different buildings (0 = none).
    var travelMinutes = 0
    /// The total credits a schedule must add up to, with each slot's credits (in search order).
    var creditWindow: ClosedRange<Int>?
    var slotMinCredits: [Int] = []
    var slotMaxCredits: [Int] = []

    var limitsDays: Bool { maxClassesPerDay != .max || maxMinutesPerDay != .max }

    /// Records one section's per-day load; call once per section, in global id order.
    mutating func append(section own: [ScheduleInterval]) {
        var classes = SIMD8<Int32>(repeating: 0)
        var minutes = SIMD8<Int32>(repeating: 0)
        for interval in own {
            let day = Int(interval.day)
            classes[day] = 1
            minutes[day] += Int32(interval.end) - Int32(interval.start)
        }
        dayClasses.append(classes)
        dayMinutes.append(minutes)
    }
}

/// Depth-first search over one section per course (or none for optional
/// courses) with forward checking.
///
/// Every course owns a bitset "domain" of the sections that still fit with all
/// choices made so far. Choosing a section intersects each other course's
/// domain with the precomputed set of sections compatible with it, so dead ends
/// are detected as soon as a required course runs out of options.
private final class ScheduleSearch {
    struct Slot {
        var courseIndex: Int
        var isRequired: Bool
        /// Global id of the first section.
        var start: Int
        var size: Int
    }

    static let skip = -1
    static let skipMarker: UInt16 = .max

    private let slots: [Slot]
    private let slotCount: Int
    private let slotWords: [Int]
    private let domainOffset: [Int]
    private let domainTotal: Int
    private let compatOffset: [Int]
    private let compat: UnsafeMutablePointer<UInt64>
    private let domains: UnsafeMutablePointer<UInt64>
    private let target: Int?
    private let rules: ScheduleSearchRules
    private let masks: [ScheduleSlotMask]
    private let weeklyMeetings: [[Meeting]]
    private let limits: ScheduleGenerator.Limits
    private let collector: ScheduleCollector

    /// The rules need the running totals below.
    private let limitsDays: Bool
    private var loadClasses = SIMD8<Int32>(repeating: 0)
    private var loadMinutes = SIMD8<Int32>(repeating: 0)
    private var creditsMin = 0
    private var creditsMax = 0

    private var maxLeaves = 0
    private var deadline: UInt64 = 0

    private var picks: [Int]
    private var chosen = 0
    private var nodes = 0
    private var rng: ScheduleSplitMix64

    /// Valid schedules found by the most recent pass.
    private(set) var leafCount = 0
    private(set) var hitLimit = false
    private(set) var cancelled = false
    private var aborted = false

    init(
        slots: [Slot], masks: [ScheduleSlotMask], weeklyMeetings: [[Meeting]], sections: [CourseSection],
        target: Int?, rules: ScheduleSearchRules, limits: ScheduleGenerator.Limits, collector: ScheduleCollector, seed: UInt64
    ) {
        self.slots = slots
        slotCount = slots.count
        self.target = target
        self.rules = rules
        self.masks = masks
        self.weeklyMeetings = weeklyMeetings
        limitsDays = rules.limitsDays
        self.limits = limits
        self.collector = collector
        rng = ScheduleSplitMix64(state: seed)
        picks = [Int](repeating: ScheduleSearch.skip, count: slots.count)

        let words = slots.map { ($0.size + 63) / 64 }
        slotWords = words
        var offsets: [Int] = []
        var total = 0
        for w in words {
            offsets.append(total)
            total += w
        }
        domainOffset = offsets
        domainTotal = max(1, total)

        let sectionTotal = masks.count
        var compatOffsets = [Int](repeating: 0, count: sectionTotal * slots.count)
        var cursor = 0
        for g in 0..<sectionTotal {
            for s in 0..<slots.count {
                compatOffsets[g * slots.count + s] = cursor
                cursor += words[s]
            }
        }
        compatOffset = compatOffsets
        compat = UnsafeMutablePointer<UInt64>.allocate(capacity: max(1, cursor))
        compat.initialize(repeating: 0, count: max(1, cursor))

        var slotOf = [Int](repeating: 0, count: sectionTotal)
        for (s, slot) in slots.enumerated() {
            for g in slot.start..<(slot.start + slot.size) { slotOf[g] = s }
        }
        for g in 0..<sectionTotal {
            let own = slotOf[g]
            for s in 0..<slots.count where s != own {
                let base = compatOffsets[g * slots.count + s]
                for j in 0..<slots[s].size {
                    let h = slots[s].start + j
                    // The masks only know weekdays and times, so they are a fast pre-filter:
                    // sections that share a slot are confirmed against each meeting's date
                    // window (half-term sections at the same time do not conflict).
                    if masks[g].conflicts(with: masks[h]), Self.meetingsConflict(weeklyMeetings[g], weeklyMeetings[h]) { continue }
                    // A required break between buildings makes sections that are too close just as incompatible.
                    if rules.travelMinutes > 0,
                       SchedulePreferenceRules.tooClose(sections[g], weeklyMeetings[g], sections[h], weeklyMeetings[h], minutes: rules.travelMinutes) {
                        continue
                    }
                    compat[base + (j >> 6)] |= 1 << UInt64(j & 63)
                }
            }
        }

        let domainCount = (slots.count + 1) * domainTotal
        domains = UnsafeMutablePointer<UInt64>.allocate(capacity: domainCount)
        domains.initialize(repeating: 0, count: domainCount)
    }

    deinit {
        compat.deallocate()
        domains.deallocate()
    }

    /// Whether any meeting of one section overlaps any of the other's, date windows included.
    private static func meetingsConflict(_ a: [Meeting], _ b: [Meeting]) -> Bool {
        a.contains { first in b.contains { first.overlaps(with: $0) } }
    }

    // MARK: Whole-problem helpers

    /// True when some section of slot A fits with some section of slot B.
    func hasCompatiblePair(slotA: Int, slotB: Int) -> Bool {
        for j in 0..<slots[slotA].size {
            let g = slots[slotA].start + j
            let base = compatOffset[g * slotCount + slotB]
            for k in 0..<slotWords[slotB] where compat[base + k] != 0 { return true }
        }
        return false
    }

    /// Like `hasCompatiblePair`, but ignoring the required time between buildings: whether some
    /// section of slot A merely avoids overlapping some section of slot B.
    func hasOverlapFreePair(slotA: Int, slotB: Int) -> Bool {
        guard rules.travelMinutes > 0 else { return hasCompatiblePair(slotA: slotA, slotB: slotB) }
        for i in 0..<slots[slotA].size {
            for j in 0..<slots[slotB].size {
                let g = slots[slotA].start + i, h = slots[slotB].start + j
                if !(masks[g].conflicts(with: masks[h]) && Self.meetingsConflict(weeklyMeetings[g], weeklyMeetings[h])) { return true }
            }
        }
        return false
    }

    private func resetState(maxLeaves: Int, timeBudget: TimeInterval) {
        self.maxLeaves = max(1, maxLeaves)
        leafCount = 0
        hitLimit = false
        aborted = false
        nodes = 0
        chosen = 0
        loadClasses = SIMD8<Int32>(repeating: 0)
        loadMinutes = SIMD8<Int32>(repeating: 0)
        creditsMin = 0
        creditsMax = 0
        for i in 0..<slotCount { picks[i] = Self.skip }
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0.05, timeBudget) * 1_000_000_000)
        // Initial domains: every section of every course.
        let root = domains
        for s in 0..<slotCount {
            let off = domainOffset[s]
            let size = slots[s].size
            for w in 0..<slotWords[s] {
                let remaining = size - w * 64
                root[off + w] = remaining >= 64 ? UInt64.max : (UInt64(1) << UInt64(remaining)) - 1
            }
        }
    }

    // MARK: Exhaustive pass

    func runExhaustive() {
        resetState(maxLeaves: limits.maxExhaustiveLeaves, timeBudget: limits.timeBudget)
        descendExhaustive(0)
        if cancelled { aborted = true }
    }

    private func checkBudget() {
        if Task.isCancelled {
            cancelled = true
            aborted = true
        } else if nodes >= limits.maxNodes || DispatchTime.now().uptimeNanoseconds >= deadline {
            hitLimit = true
            aborted = true
        }
    }

    /// Intersects the domains at `depth` with the sections compatible with `local`
    /// of slot `depth`, writing the result at `depth + 1`. Returns false when a
    /// later required course has no section left.
    @inline(__always)
    private func choose(depth: Int, local: Int) -> Bool {
        let g = slots[depth].start + local
        let src = domains + depth * domainTotal
        let dst = domains + (depth + 1) * domainTotal
        for s in 0..<slotCount {
            let off = domainOffset[s]
            let w = slotWords[s]
            if s == depth {
                for k in 0..<w { dst[off + k] = src[off + k] }
                continue
            }
            let base = compatOffset[g * slotCount + s]
            var any: UInt64 = 0
            for k in 0..<w {
                let v = src[off + k] & compat[base + k]
                dst[off + k] = v
                any |= v
            }
            if any == 0, s > depth, slots[s].isRequired { return false }
        }
        return true
    }

    @inline(__always)
    private func copyDomain(depth: Int) {
        let src = domains + depth * domainTotal
        let dst = domains + (depth + 1) * domainTotal
        for k in 0..<domainTotal { dst[k] = src[k] }
    }

    // MARK: Hard rules

    /// Whether `section` (global id `g`) of slot `s` can join the picks made so far without breaking
    /// the classes-a-day, hours-a-day or credit limits.
    @inline(__always)
    private func canAdd(_ g: Int, slot s: Int) -> Bool {
        if limitsDays {
            let classes = loadClasses &+ rules.dayClasses[g]
            let minutes = loadMinutes &+ rules.dayMinutes[g]
            if any(classes .> SIMD8<Int32>(repeating: rules.maxClassesPerDay))
                || any(minutes .> SIMD8<Int32>(repeating: rules.maxMinutesPerDay)) { return false }
        }
        if let window = rules.creditWindow, creditsMin + rules.slotMinCredits[s] > window.upperBound { return false }
        return true
    }

    @inline(__always)
    private func take(_ g: Int, slot s: Int) {
        if limitsDays {
            loadClasses &+= rules.dayClasses[g]
            loadMinutes &+= rules.dayMinutes[g]
        }
        creditsMin += rules.slotMinCredits[s]
        creditsMax += rules.slotMaxCredits[s]
    }

    @inline(__always)
    private func release(_ g: Int, slot s: Int) {
        if limitsDays {
            loadClasses &-= rules.dayClasses[g]
            loadMinutes &-= rules.dayMinutes[g]
        }
        creditsMin -= rules.slotMinCredits[s]
        creditsMax -= rules.slotMaxCredits[s]
    }

    /// Whether some section of slot `s` is still compatible with the picks so far and within the limits.
    private func canStillAdd(depth: Int, slot s: Int) -> Bool {
        let dom = domains + depth * domainTotal
        let off = domainOffset[s]
        for k in 0..<slotWords[s] {
            var bits = dom[off + k]
            if !limitsDays && rules.creditWindow == nil {
                if bits != 0 { return true }
                continue
            }
            while bits != 0 {
                let local = k * 64 + bits.trailingZeroBitCount
                bits &= bits &- 1
                if canAdd(slots[s].start + local, slot: s) { return true }
            }
        }
        return false
    }

    /// Whether the picks so far can still end in a valid schedule, when only slots `first...` remain to be
    /// decided: enough courses must stay reachable for the requested course count, and the credits of the
    /// courses that still have to join (and could join) must be able to land inside the credit target.
    private func isFeasible(depth: Int, from first: Int) -> Bool {
        guard target != nil || rules.creditWindow != nil else { return true }
        var reachable = chosen
        var mostCredits = creditsMax
        var leastCredits = creditsMin
        var s = first
        while s < slotCount {
            let required = slots[s].isRequired
            if required || canStillAdd(depth: depth, slot: s) {
                reachable += 1
                mostCredits += rules.slotMaxCredits[s]
            }
            if required { leastCredits += rules.slotMinCredits[s] }
            s += 1
        }
        if let target, reachable < target { return false }
        if let window = rules.creditWindow, mostCredits < window.lowerBound || leastCredits > window.upperBound { return false }
        return true
    }

    /// Offers the current picks to the collector when they form a valid schedule: the requested number of
    /// courses, or credits inside the target, or (without either) a maximal one.
    @discardableResult
    private func recordLeaf(depth: Int) -> Bool {
        if chosen == 0 { return false }
        if let target, chosen != target { return false }
        if let window = rules.creditWindow, creditsMin > window.upperBound || creditsMax < window.lowerBound { return false }
        if target == nil, rules.creditWindow == nil {
            // Maximal: no skipped optional course could still be added.
            for s in 0..<slotCount where !slots[s].isRequired && picks[s] == Self.skip {
                if canStillAdd(depth: depth, slot: s) { return false }
            }
        }
        collector.offer(picks)
        leafCount += 1
        return true
    }

    private func descendExhaustive(_ depth: Int) {
        if aborted { return }
        nodes &+= 1
        if nodes & 0x3FF == 0 {
            checkBudget()
            if aborted { return }
        }

        if depth == slotCount {
            if recordLeaf(depth: depth), leafCount >= maxLeaves {
                hitLimit = true
                aborted = true
            }
            return
        }

        // Exactly enough courses: the remaining optional ones are all skipped.
        if let target, chosen == target {
            for s in depth..<slotCount { picks[s] = Self.skip }
            if recordLeaf(depth: depth), leafCount >= maxLeaves {
                hitLimit = true
                aborted = true
            }
            return
        }
        if !isFeasible(depth: depth, from: depth) { return }

        let slot = slots[depth]
        if !slot.isRequired {
            // Choice A: leave this optional course out (enough courses and credits must remain reachable).
            if isFeasible(depth: depth, from: depth + 1) {
                picks[depth] = Self.skip
                copyDomain(depth: depth)
                descendExhaustive(depth + 1)
                if aborted { return }
            }
        }

        // Choice B: each section that still fits.
        let dom = domains + depth * domainTotal
        let off = domainOffset[depth]
        for word in 0..<slotWords[depth] {
            var bits = dom[off + word]
            while bits != 0 {
                let local = word * 64 + bits.trailingZeroBitCount
                bits &= bits &- 1
                let g = slot.start + local
                guard canAdd(g, slot: depth), choose(depth: depth, local: local) else { continue }
                take(g, slot: depth)
                picks[depth] = local
                chosen += 1
                descendExhaustive(depth + 1)
                chosen -= 1
                picks[depth] = Self.skip
                release(g, slot: depth)
                if aborted { return }
            }
        }
    }

    // MARK: Sampled pass

    /// Examines a spread-out sample: the leaf budget is split evenly between
    /// the options at every level, so each section of the first courses is
    /// represented and deeper choices are random.
    func runSampled() {
        resetState(maxLeaves: limits.sampleLeaves, timeBudget: limits.sampleTimeBudget)
        _ = descendSampled(0, budget: maxLeaves)
        if cancelled { aborted = true }
    }

    private func descendSampled(_ depth: Int, budget: Int) -> Int {
        if aborted { return 0 }
        nodes &+= 1
        if nodes & 0x3FF == 0 {
            checkBudget()
            if aborted { return 0 }
        }

        if depth == slotCount { return recordLeaf(depth: depth) ? 1 : 0 }

        if let target, chosen == target {
            for s in depth..<slotCount { picks[s] = Self.skip }
            return recordLeaf(depth: depth) ? 1 : 0
        }
        if !isFeasible(depth: depth, from: depth) { return 0 }

        let slot = slots[depth]
        var options: [Int] = []
        if !slot.isRequired, isFeasible(depth: depth, from: depth + 1) { options.append(Self.skip) }
        let dom = domains + depth * domainTotal
        let off = domainOffset[depth]
        for word in 0..<slotWords[depth] {
            var bits = dom[off + word]
            while bits != 0 {
                let local = word * 64 + bits.trailingZeroBitCount
                bits &= bits &- 1
                if canAdd(slot.start + local, slot: depth) { options.append(local) }
            }
        }
        if options.isEmpty { return 0 }
        options.shuffle(using: &rng)

        var remaining = budget
        var left = options.count
        var emitted = 0
        for option in options {
            if aborted || remaining <= 0 { break }
            let share = max(1, (remaining + left - 1) / left)
            left -= 1
            var got = 0
            if option == Self.skip {
                picks[depth] = Self.skip
                copyDomain(depth: depth)
                got = descendSampled(depth + 1, budget: share)
            } else if choose(depth: depth, local: option) {
                let g = slot.start + option
                take(g, slot: depth)
                picks[depth] = option
                chosen += 1
                got = descendSampled(depth + 1, budget: share)
                chosen -= 1
                picks[depth] = Self.skip
                release(g, slot: depth)
            }
            emitted += got
            remaining -= got
        }
        return emitted
    }
}
