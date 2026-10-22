//
//  SchedulePlanSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Editing helpers

/// Pure helpers that edit a `SchedulePlan`. Views call them inside
/// `UserDataStore.updatePlan(id:_:)`.
enum PlanEditing {
    /// "Plan A", "Plan B", … skipping names that are already used.
    static func nextPlanName(existing: [String]) -> String {
        let used = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            let name = "Plan \(scalar)"
            if !used.contains(name.lowercased()) { return name }
        }
        var n = 27
        while used.contains("plan \(n)") { n += 1 }
        return "Plan \(n)"
    }

    /// Chooses `crn` for one row, replacing that row's pin. Pass `nil` to clear it.
    /// This is the edit that changes a pin. Generation does not call it.
    ///
    /// `entryID` is the row (`PlanCourse.id`). Without it, the call still replaces
    /// selected CRNs in `courseCRNs`, and updates the pin only when exactly one row
    /// already holds one of those CRNs. A pin that belongs to another row of the
    /// same number is left alone. Clearing is refused while another row shares the
    /// number, and a CRN another row already has is refused.
    static func setSection(_ crn: String?, courseCRNs: Set<String>, entryID: String? = nil, in plan: inout SchedulePlan) {
        if let entryID {
            guard let target = plan.courses.firstIndex(where: { $0.id == entryID }) else { return }
            let others = plan.courses.enumerated().filter { $0.offset != target && $0.element.key == plan.courses[target].key }
            if crn == nil, !others.isEmpty { return }
            if let crn, plan.courses.contains(where: { $0.id != plan.courses[target].id && $0.pinnedCRN == crn }) { return }
            let reserved = Set(others.compactMap(\.element.pinnedCRN))
            if let old = plan.courses[target].pinnedCRN, !reserved.contains(old) {
                plan.selectedCRNs.removeAll { $0 == old }
            }
            plan.selectedCRNs.removeAll { courseCRNs.contains($0) && !reserved.contains($0) }
            plan.courses[target].pinnedCRN = crn
            if let crn, !plan.selectedCRNs.contains(crn) { plan.selectedCRNs.append(crn) }
            return
        }

        let reserved = Set(plan.courses.compactMap(\.pinnedCRN).filter { !courseCRNs.contains($0) })
        let pinnedInside = plan.courses.indices.filter { plan.courses[$0].pinnedCRN.map { courseCRNs.contains($0) } ?? false }
        if pinnedInside.count > 1 { return }
        plan.selectedCRNs.removeAll { courseCRNs.contains($0) && !reserved.contains($0) }
        if let crn, !plan.selectedCRNs.contains(crn) { plan.selectedCRNs.append(crn) }
        if pinnedInside.count == 1 {
            plan.courses[pinnedInside[0]].pinnedCRN = crn
        }
    }

    static func setRequired(_ isRequired: Bool, for key: CourseKey, in plan: inout SchedulePlan) {
        for i in plan.courses.indices where plan.courses[i].key == key {
            plan.courses[i].isRequired = isRequired
        }
    }

    static func setRequired(_ isRequired: Bool, entryID: String, in plan: inout SchedulePlan) {
        guard let i = plan.courses.firstIndex(where: { $0.id == entryID }) else { return }
        plan.courses[i].isRequired = isRequired
    }

    /// Adds or removes a section from the "don't use when generating" list.
    static func setExcluded(_ excluded: Bool, crn: String, for key: CourseKey, in plan: inout SchedulePlan) {
        guard let i = plan.courses.firstIndex(where: { $0.key == key }) else { return }
        setExcluded(excluded, crn: crn, at: i, in: &plan)
    }

    static func setExcluded(_ excluded: Bool, crn: String, entryID: String, in plan: inout SchedulePlan) {
        guard let i = plan.courses.firstIndex(where: { $0.id == entryID }) else { return }
        setExcluded(excluded, crn: crn, at: i, in: &plan)
    }

    private static func setExcluded(_ excluded: Bool, crn: String, at i: Int, in plan: inout SchedulePlan) {
        if excluded {
            plan.courses[i].excludedCRNs.insert(crn)
        } else {
            plan.courses[i].excludedCRNs.remove(crn)
        }
    }

    static func isFavorite(_ plan: SchedulePlan, sortedCRNs: [String]) -> Bool {
        plan.favoriteCombinations.contains(sortedCRNs)
    }

    /// Keeps every CRN a row already chose. A generated schedule may fill a row that
    /// has none, and that fill is recorded as the row's pin. A different section of
    /// a pinned row is ignored, including when that pin is no longer in the catalog.
    /// Two rows of one number are not one choice: each keeps its own CRN. The pin
    /// is the CRN (`index.section(crn:)`), not "a section of this subject and number".
    static func adoptGeneratedSchedule(_ crns: [String], into plan: inout SchedulePlan, index: CatalogIndex) {
        func isLocked(_ course: PlanCourse) -> Bool {
            if course.pinnedCRN != nil { return true }
            let siblings = plan.courses.contains { $0.key == course.key && $0.id != course.id }
            if siblings { return false }
            if plan.selectedCRNs.contains(where: { index.section(crn: $0)?.courseKey == course.key }) {
                return true
            }
            // A chosen CRN the catalog dropped does not resolve to a course key.
            // That still locks this only row, so Use Schedule does not store a
            // different section. A CRN that resolves to another course does not.
            let unlisted = plan.selectedCRNs.contains { index.section(crn: $0) == nil }
            let foreign = plan.selectedCRNs.contains { crn in
                guard let section = index.section(crn: crn) else { return false }
                return section.courseKey != course.key
            }
            return unlisted && !foreign
        }
        var locked = Set(plan.courses.filter(isLocked).map(\.id))
        var next = plan.selectedCRNs
        for crn in crns {
            guard let section = index.section(crn: crn) else { continue }
            guard let i = plan.courses.indices.first(where: {
                plan.courses[$0].key == section.courseKey && !locked.contains(plan.courses[$0].id)
            }) else { continue }
            if !next.contains(crn) { next.append(crn) }
            if plan.courses[i].pinnedCRN == nil { plan.courses[i].pinnedCRN = crn }
            locked.insert(plan.courses[i].id)
        }
        plan.selectedCRNs = next
    }

    /// Selected CRNs whose section in this term is `key`. Lookup is by CRN.
    static func selectedCRNs(_ crns: [String], for key: CourseKey, index: CatalogIndex) -> [String] {
        crns.filter { index.section(crn: $0)?.courseKey == key }
    }

    static func setFavorite(_ favorite: Bool, sortedCRNs: [String], in plan: inout SchedulePlan) {
        plan.favoriteCombinations.removeAll { $0 == sortedCRNs }
        if favorite { plan.favoriteCombinations.append(sortedCRNs) }
    }

    /// Drops selections that no longer resolve to a section of a plan course.
    static func removeStaleCRNs(_ crns: [String], from plan: inout SchedulePlan) {
        let stale = Set(crns)
        plan.selectedCRNs.removeAll { stale.contains($0) }
    }

    /// Drops selected sections (and favorite combinations) whose course is no longer
    /// in the plan. CRNs the catalog doesn't know are left alone: those are reported
    /// separately as "no longer listed". Returns what was removed.
    @discardableResult
    static func pruneOrphans(using index: CatalogIndex, in plan: inout SchedulePlan) -> (selected: [String], favorites: [[String]]) {
        let keys = Set(plan.courses.map(\.key))
        func isOrphan(_ crn: String) -> Bool {
            guard let section = index.section(crn: crn) else { return false }
            return !keys.contains(section.courseKey)
        }
        let selected = plan.selectedCRNs.filter(isOrphan)
        let favorites = plan.favoriteCombinations.filter { $0.contains(where: isOrphan) }
        plan.selectedCRNs.removeAll(where: isOrphan)
        plan.favoriteCombinations.removeAll { $0.contains(where: isOrphan) }
        return (selected, favorites)
    }

    /// Puts back exactly the course that was removed (at its old position) with its
    /// chosen sections and favorite combinations, leaving everything else as it is.
    static func restore(_ removal: PlanCourseRemoval, in plan: inout SchedulePlan) {
        if plan.courses.contains(where: { $0.id == removal.course.id }) { return }
        if let pin = removal.course.pinnedCRN, plan.courses.contains(where: { $0.pinnedCRN == pin }) { return }
        if removal.course.pinnedCRN == nil,
           plan.courses.contains(where: { $0.key == removal.course.key && $0.pinnedCRN == nil }) { return }
        plan.courses.insert(removal.course, at: min(max(0, removal.index), plan.courses.count))
        for crn in removal.selectedCRNs where !plan.selectedCRNs.contains(crn) { plan.selectedCRNs.append(crn) }
        for combination in removal.favoriteCombinations where !plan.favoriteCombinations.contains(combination) {
            plan.favoriteCombinations.append(combination)
        }
    }
}

/// A course taken out of a plan, kept so "Undo" can put back just that course.
/// A class (not a struct) because the sections it owned are sometimes only
/// discovered once the catalog finishes loading.
final class PlanCourseRemoval {
    let course: PlanCourse
    /// Where the course sat in the plan's list.
    let index: Int
    var selectedCRNs: [String]
    var favoriteCombinations: [[String]]

    init(course: PlanCourse, index: Int, selectedCRNs: [String], favoriteCombinations: [[String]]) {
        self.course = course
        self.index = index
        self.selectedCRNs = selectedCRNs
        self.favoriteCombinations = favoriteCombinations
    }
}

// MARK: - Conflicts

/// Two selected sections whose weekly meetings overlap.
struct ScheduleConflict: Identifiable, Hashable {
    var first: CourseSection
    var second: CourseSection
    var days: DaySet
    /// The first overlapping window, minutes after midnight.
    var start: Int
    var end: Int

    var id: String { "\(first.crn)|\(second.crn)" }

    /// `CS 3000 overlaps MATH 2331 · Mon, Wed 10:30 – 11:35 AM`.
    var summary: String {
        "\(first.courseKey) overlaps \(second.courseKey) · \(days.shortLabel) \(TimeOfDay.rangeLabel(start: start, end: end))"
    }
}

enum ScheduleConflicts {
    /// The overlap between two sections' weekly meetings, if any. Like
    /// `CourseSection.conflicts(with:)` it respects each meeting's date window, so
    /// half-term sections at the same weekday and time don't overlap.
    static func overlap(_ a: CourseSection, _ b: CourseSection) -> (days: DaySet, start: Int, end: Int)? {
        var days = DaySet()
        var window: (start: Int, end: Int)?
        for m1 in a.weeklyMeetings {
            for m2 in b.weeklyMeetings where m1.overlaps(with: m2) {
                guard let s1 = m1.start, let e1 = m1.end, let s2 = m2.start, let e2 = m2.end else { continue }
                days.formUnion(m1.days.intersection(m2.days))
                let start = max(s1, s2), end = min(e1, e2)
                if window == nil || start < window!.start { window = (start, end) }
            }
        }
        guard let window else { return nil }
        return (days, window.start, window.end)
    }

    /// Every conflicting pair among `sections`.
    static func find(among sections: [CourseSection]) -> [ScheduleConflict] {
        var result: [ScheduleConflict] = []
        for i in sections.indices {
            for j in sections.indices where j > i {
                if let o = overlap(sections[i], sections[j]) {
                    result.append(ScheduleConflict(first: sections[i], second: sections[j], days: o.days, start: o.start, end: o.end))
                }
            }
        }
        return result
    }

    /// The sections in `others` that overlap `section`.
    static func sections(overlapping section: CourseSection, in others: [CourseSection]) -> [CourseSection] {
        others.filter { $0.crn != section.crn && overlap(section, $0) != nil }
    }
}

// MARK: - Resolved plan

/// A plan resolved against a term's catalog: which section is chosen for each
/// course, what the calendar shows and what needs the user's attention.
/// Cheap to build, so views recompute it whenever the plan or catalog changes.
struct ResolvedPlan {
    struct Entry: Identifiable {
        let planCourse: PlanCourse
        let course: Course?
        let allSections: [CourseSection]
        /// Sections chosen for this course (normally zero or one).
        let selected: [CourseSection]
        /// Whether the term's catalog is loaded (otherwise nothing can be resolved).
        let catalogAvailable: Bool

        var id: String { planCourse.id }
        var key: CourseKey { planCourse.key }
        var color: CourseColor { CourseColor.at(planCourse.colorIndex) }
        var chosen: CourseSection? { selected.first }
        /// The course is not in the term's catalog at all.
        var isMissing: Bool { catalogAvailable && course == nil && allSections.isEmpty }
        /// The course is listed but has no sections this term.
        var hasNoSections: Bool { catalogAvailable && course != nil && allSections.isEmpty }
        var title: String { course?.title ?? allSections.first?.title ?? "" }
        var availableSections: [CourseSection] { allSections.filter { !planCourse.excludedCRNs.contains($0.crn) } }
        var courseCRNs: Set<String> { Set(allSections.map(\.crn)) }
        /// This course counts towards the plan's credits.
        var countsTowardsCredits: Bool { planCourse.isRequired || !selected.isEmpty }
    }

    let plan: SchedulePlan
    let hasCatalog: Bool
    let entries: [Entry]
    /// Selected CRNs the catalog doesn't list (the term's data changed).
    let unlistedCRNs: [String]
    /// Selected CRNs of real sections whose course is no longer in the plan
    /// (typically left over from a removed course).
    let orphanedCRNs: [String]
    let selectedSections: [CourseSection]
    /// Calendar blocks for the selected sections, conflicts marked.
    let events: [CalendarEvent]
    let conflicts: [ScheduleConflict]
    /// Selected sections without a fixed weekly time (online / TBA).
    let untimed: [(entry: Entry, section: CourseSection)]
    let fullSections: [(entry: Entry, section: CourseSection)]
    let missingCourses: [CourseKey]
    let credits: (min: Double, max: Double)

    init(plan: SchedulePlan, index: CatalogIndex?) {
        self.plan = plan
        hasCatalog = index != nil

        var bySection: [String: CourseSection] = [:]
        if let index {
            for crn in plan.selectedCRNs {
                if let section = index.section(crn: crn) { bySection[crn] = section }
            }
        }

        var entries: [Entry] = []
        var claimed = Set<String>()
        for planCourse in plan.courses {
            let all = index?.sections(for: planCourse.key) ?? []
            let siblings = plan.courses.filter { $0.key == planCourse.key && $0.id != planCourse.id }
            let siblingPins = Set(siblings.compactMap(\.pinnedCRN))
            let selected: [CourseSection]
            if let pin = planCourse.pinnedCRN, let section = bySection[pin], section.courseKey == planCourse.key {
                var chosen = [section]
                claimed.insert(pin)
                // A single row can still show a linked component beside its pin.
                if siblings.isEmpty {
                    for crn in plan.selectedCRNs where crn != pin {
                        guard let extra = bySection[crn], extra.courseKey == planCourse.key else { continue }
                        chosen.append(extra)
                        claimed.insert(crn)
                    }
                }
                selected = chosen
            } else if siblings.isEmpty {
                selected = plan.selectedCRNs.compactMap { crn -> CourseSection? in
                    guard let section = bySection[crn], section.courseKey == planCourse.key else { return nil }
                    claimed.insert(crn)
                    return section
                }
            } else {
                selected = plan.selectedCRNs.compactMap { crn -> CourseSection? in
                    guard !siblingPins.contains(crn), let section = bySection[crn], section.courseKey == planCourse.key else { return nil }
                    claimed.insert(crn)
                    return section
                }
            }
            entries.append(Entry(planCourse: planCourse, course: index?.course(planCourse.key), allSections: all, selected: selected, catalogAvailable: index != nil))
        }
        self.entries = entries
        let unclaimed = index == nil ? [] : plan.selectedCRNs.filter { !claimed.contains($0) }
        unlistedCRNs = unclaimed.filter { bySection[$0] == nil }
        orphanedCRNs = unclaimed.filter { bySection[$0] != nil }

        let sections = entries.flatMap(\.selected)
        selectedSections = sections
        var events: [CalendarEvent] = []
        var untimed: [(Entry, CourseSection)] = []
        var full: [(Entry, CourseSection)] = []
        for entry in entries {
            for section in entry.selected {
                let blocks = CalendarEvent.events(for: section, color: entry.color)
                if blocks.isEmpty { untimed.append((entry, section)) }
                events.append(contentsOf: blocks)
                if section.isFull { full.append((entry, section)) }
            }
        }
        self.events = CalendarEvent.markingConflicts(events)
        self.untimed = untimed.map { (entry: $0.0, section: $0.1) }
        fullSections = full.map { (entry: $0.0, section: $0.1) }
        conflicts = ScheduleConflicts.find(among: sections)
        missingCourses = entries.filter { $0.isMissing || $0.hasNoSections }.map(\.key)

        var low = 0.0, high = 0.0
        for entry in entries where entry.countsTowardsCredits {
            guard let course = entry.course else { continue }
            let section = entry.planCourse.pinnedCRN.flatMap { pin in entry.allSections.first { $0.crn == pin } }
            let chosen = ChosenCredits.resolved(stored: entry.planCourse.credits, course: course, section: section)
            low += chosen
            high += chosen
        }
        credits = (low, high)
    }

    /// Every selected CRN that doesn't belong to a plan course, whatever the cause.
    var staleCRNs: [String] { unlistedCRNs + orphanedCRNs }

    var creditsLabel: String { CreditFormatter.label(min: credits.min, max: credits.max) }
    var isOverCreditLimit: Bool { credits.min > 19 }
    var isEmpty: Bool { entries.isEmpty }
    var hasSelection: Bool { !selectedSections.isEmpty }

    /// CRNs in plan-course order, ready for registration.
    var crnsForRegistration: [String] { selectedSections.map(\.crn) }

    func entry(for key: CourseKey) -> Entry? { entries.first { $0.key == key } }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    func entry(forCRN crn: String) -> (entry: Entry, section: CourseSection)? {
        for entry in entries {
            if let section = entry.selected.first(where: { $0.crn == crn }) { return (entry, section) }
        }
        return nil
    }

    /// Courses with no chosen section (that could have one).
    var coursesWithoutSection: [Entry] { entries.filter { $0.selected.isEmpty && !$0.isMissing && !$0.hasNoSections } }
}

// MARK: - Formatting

enum ScheduleFormat {
    /// `Lecture 02`.
    static func sectionTitle(_ section: CourseSection) -> String {
        section.sectionNumber.isEmpty ? section.classType : "\(section.classType) \(section.sectionNumber)"
    }

    /// `Lecture 02 · CRN 12345`.
    static func sectionTitleWithCRN(_ section: CourseSection) -> String {
        "\(sectionTitle(section)) · CRN \(section.crn)"
    }

    /// The building and room of the first in-person weekly meeting, or `Online`.
    static func location(of section: CourseSection) -> String? {
        let meetings = section.weeklyMeetings
        if let inPerson = meetings.first(where: { !$0.isOnline && ($0.buildingCode ?? $0.building) != nil }) {
            return inPerson.locationLabel
        }
        if section.isOnline || meetings.contains(where: \.isOnline) { return "Online" }
        return meetings.isEmpty ? nil : "Location TBA"
    }

    /// Instructor names when they are loaded, otherwise nil.
    static func instructors(of section: CourseSection) -> String? {
        guard let instructors = section.instructors, !instructors.isEmpty else { return nil }
        return instructors.sorted { $0.primary && !$1.primary }.map(\.displayName).joined(separator: ", ")
    }

    /// `Lecture 02 · MWR 10:30 – 11:35 AM`.
    static func sectionSummary(_ section: CourseSection) -> String {
        "\(sectionTitle(section)) · \(section.scheduleSummary)"
    }

    /// `2h`, `1h 30m`, `45m`.
    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m)m"
        case (_, 0): return "\(h)h"
        default: return "\(h)h \(m)m"
        }
    }

    /// `4 days · starts 9:15 AM · 2h gaps`.
    static func metricsLine(_ schedule: GeneratedSchedule) -> String {
        var parts: [String] = []
        if schedule.classDays == 0 {
            parts.append("No set meeting times")
        } else if schedule.daysOnCampus == 0 {
            parts.append(schedule.classDays == 1 ? "1 online day" : "\(schedule.classDays) online days")
        } else {
            parts.append(schedule.daysOnCampus == 1 ? "1 day" : "\(schedule.daysOnCampus) days")
        }
        if let start = schedule.earliestStart { parts.append("starts \(TimeOfDay.label(start))") }
        if schedule.classDays > 0 {
            parts.append(schedule.totalGapMinutes == 0 ? "no gaps" : "\(duration(minutes: schedule.totalGapMinutes)) gaps")
        }
        return parts.joined(separator: " · ")
    }

    /// Secondary line: `ends 3:30 PM · tightest section 3 seats`.
    static func detailLine(_ schedule: GeneratedSchedule) -> String {
        var parts: [String] = []
        if let end = schedule.latestEnd { parts.append("ends \(TimeOfDay.label(end))") }
        if schedule.fullSections > 0 {
            parts.append(schedule.fullSections == 1 ? "1 full section" : "\(schedule.fullSections) full sections")
        } else if !schedule.sections.isEmpty {
            parts.append(schedule.minSeats == 1 ? "tightest section 1 seat" : "tightest section \(schedule.minSeats) seats")
        }
        return parts.joined(separator: " · ")
    }

    /// Days on which the schedule has in-person classes.
    static func campusDays(of sections: [CourseSection]) -> DaySet {
        var days = DaySet()
        for section in sections where !section.isOnline {
            for meeting in section.weeklyMeetings where !meeting.isOnline { days.formUnion(meeting.days) }
        }
        return days
    }

    /// Days on which any section meets at a fixed time.
    static func classDays(of sections: [CourseSection]) -> DaySet {
        sections.reduce(into: DaySet()) { $0.formUnion($1.meetingDays) }
    }

    static func seatsText(_ section: CourseSection) -> String {
        if section.seatsRemaining > 0 { return "\(section.seatsRemaining) of \(section.seatCapacity) open" }
        if section.waitlistCapacity > 0 { return "Full · \(section.waitlistRemaining) waitlist" }
        return "Full"
    }

    /// `CS 3000 · Lecture 02 · CRN 12345` for accessibility and copy text.
    static func fullLabel(_ section: CourseSection) -> String {
        "\(section.courseKey) · \(sectionTitle(section)) · CRN \(section.crn)"
    }
}

// MARK: - Calendar layout helpers

enum PlanCalendarSupport {
    /// The hours a `WeekCalendarView` shows for these events, mirroring its own logic.
    static func hourRange(events: [CalendarEvent], startHour: Int?, endHour: Int?, compact: Bool) -> ClosedRange<Int> {
        let defaultStart = startHour ?? 8
        let defaultEnd = endHour ?? 18
        guard !events.isEmpty else { return defaultStart...max(defaultStart + 1, defaultEnd) }
        let minStart = events.map(\.start).min()! / 60
        let maxEnd = Int((Double(events.map(\.end).max()!) / 60).rounded(.up))
        let lower = min(startHour ?? minStart, minStart)
        let upper = max(endHour ?? maxEnd, maxEnd, lower + (compact ? 1 : 4))
        return max(0, lower)...min(24, upper)
    }

    /// The hour height that makes the calendar exactly `height` points tall.
    static func hourHeight(fitting height: CGFloat, range: ClosedRange<Int>) -> CGFloat {
        height / CGFloat(max(1, range.upperBound - range.lowerBound))
    }

    /// Day columns a calendar will show for these events.
    static func visibleDays(events: [CalendarEvent], showWeekends: Bool) -> [Int] {
        var days = [1, 2, 3, 4, 5]
        let eventDays = Set(events.map(\.day))
        if showWeekends || eventDays.contains(6) { days.append(6) }
        if showWeekends || eventDays.contains(0) { days.insert(0, at: 0) }
        return days
    }
}

// MARK: - Dates

enum ScheduleDates {
    static let newYork = TimeZone(identifier: "America/New_York") ?? .current

    /// Banner's dates are Gregorian, so they are never read with the user's own
    /// calendar (which may be Buddhist, Japanese… where `year: 2026` means
    /// something else entirely).
    static func gregorian(in timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static var newYorkCalendar: Calendar { gregorian(in: newYork) }

    /// Parses `yyyy-MM-dd` into its components.
    static func components(fromISO iso: String?) -> DateComponents? {
        guard let iso else { return nil }
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Parses `yyyy-MM-dd` as midnight in `timeZone` (the device's by default), using
    /// the Gregorian calendar.
    static func date(fromISO iso: String?, in timeZone: TimeZone = .current) -> Date? {
        guard let parts = components(fromISO: iso) else { return nil }
        return gregorian(in: timeZone).date(from: parts)
    }
}

// MARK: - Widget data

/// Flattens a plan into the weekly meetings shared with widgets and the Up Next accessory.
enum ScheduleWidgetBuilder {
    static func make(plan: SchedulePlan, index: CatalogIndex, now: Date = .now) -> WidgetScheduleData {
        var meetings: [WidgetScheduleData.Meeting] = []
        var usedIDs = Set<String>()
        var seenMeetings = Set<String>()
        var firstDay: Date?
        var lastDay: Date?

        for crn in plan.selectedCRNs {
            guard let section = index.section(crn: crn), let planCourse = plan.course(section.courseKey) else { continue }
            let title = index.course(section.courseKey)?.title ?? section.title
            for meeting in section.weeklyMeetings {
                guard let start = meeting.start, let end = meeting.end else { continue }
                let location = meeting.isOnline || section.isOnline ? "Online" : meeting.locationLabel
                for day in meeting.days.indices {
                    // Banner often lists several records for the same weekday and time; keep one.
                    let key = "\(section.crn)|\(day)|\(start)|\(end)|\(meeting.startDate ?? "")|\(meeting.endDate ?? "")"
                    guard seenMeetings.insert(key).inserted else { continue }
                    // Records that differ only by date window (or end time) still need unique ids.
                    let baseID = "\(section.crn)-\(day)-\(start)"
                    var id = baseID
                    var suffix = 2
                    while !usedIDs.insert(id).inserted {
                        id = "\(baseID)-\(suffix)"
                        suffix += 1
                    }
                    meetings.append(WidgetScheduleData.Meeting(
                        id: id,
                        crn: section.crn,
                        courseCode: section.courseKey.description,
                        title: title,
                        location: location,
                        classType: section.classType,
                        weekday: day,
                        start: start,
                        end: end,
                        colorIndex: planCourse.colorIndex,
                        startDate: meeting.startDate,
                        endDate: meeting.endDate
                    ))
                }
                if let date = ScheduleDates.date(fromISO: meeting.startDate) {
                    firstDay = min(firstDay ?? date, date)
                }
                if let date = ScheduleDates.date(fromISO: meeting.endDate) {
                    lastDay = max(lastDay ?? date, date)
                }
            }
        }
        meetings.sort { ($0.weekday, $0.start, $0.id) < ($1.weekday, $1.start, $1.id) }

        return WidgetScheduleData(
            generatedAt: now,
            termCode: plan.termCode,
            termName: index.term.name,
            planName: plan.name,
            classesStart: firstDay,
            classesEnd: lastDay,
            meetings: meetings
        )
    }
}

extension CatalogStore {
    /// The index for a plan's term: whatever is loaded for it (observable, so live
    /// refreshes and syncs show up immediately), else `fallback` (the result of an
    /// explicit `index(for:)` load that may have just finished).
    func planIndex(for termCode: String, fallback: CatalogIndex?) -> CatalogIndex? {
        cachedIndex(for: termCode) ?? fallback
    }
}
