//
//  ScheduleNoResults.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Analysis

/// Everything worth saying about an empty result: why, which courses block it, and what would help.
struct ScheduleNoResults: Sendable {
    var diagnostics: ScheduleDiagnostics
    /// Loosening a filter or preference that would leave schedules.
    var suggestions: [ScheduleSuggestion]
    var blockers: ScheduleBlockerAnalysis
}

extension ScheduleGenerator {
    /// Explains an empty result: the blocking courses and the single relaxations that would help. Meant
    /// for `Task.detached`; cheap, but not free.
    static func analyzeEmptyResult(
        courses: [ScheduleCourseInput],
        filters: ScheduleFilters,
        preferences: SchedulePreferences,
        diagnostics: ScheduleDiagnostics,
        includeBlockers: Bool = true
    ) -> ScheduleNoResults {
        let blockers = includeBlockers
            ? analyzeBlockers(courses: courses, filters: filters, preferences: preferences, diagnostics: diagnostics)
            : ScheduleBlockerAnalysis()
        // The blocking courses already say which courses to let go of; without them, offer that here.
        let suggestions = Task.isCancelled
            ? []
            : suggestRelaxations(courses: courses, filters: filters, preferences: preferences, includeCourseRelaxations: !includeBlockers)
        return ScheduleNoResults(diagnostics: diagnostics, suggestions: suggestions, blockers: blockers)
    }
}

// MARK: - Wording

/// The words of the "no schedules fit" help, shared by every screen that shows it.
enum ScheduleNoResultsText {
    /// One thing standing in the way of a schedule.
    struct Reason {
        var symbol: String
        var title: String
        var detail: String?
    }

    static func requiredCount(_ diagnostics: ScheduleDiagnostics) -> Int {
        diagnostics.courses.filter(\.isRequired).count
    }

    static func title(for diagnostics: ScheduleDiagnostics) -> String {
        let required = requiredCount(diagnostics)
        guard diagnostics.countProblem == nil, required > 1 else { return "No schedules fit" }
        return diagnostics.courses.count > required
            ? "No schedule fits all \(required) required courses"
            : "No schedule fits all \(required) courses"
    }

    static func headline(for diagnostics: ScheduleDiagnostics, blockers: ScheduleBlockerAnalysis?) -> String {
        if diagnostics.hasNoCourses { return "Add some courses to this schedule first." }
        if let blockers, blockers.options.isEmpty == false { return "Here’s what would work." }
        if diagnostics.countProblem != nil || !diagnostics.blockedRequiredCourses.isEmpty || !diagnostics.conflictingPairs.isEmpty {
            return "Here’s what’s getting in the way."
        }
        return "These courses can’t all be taken together with the current rules."
    }

    /// `CS 3386`, `CS 3386 and MATH 2331`, `CS 3386, MATH 2331 and PHYS 1151`.
    static func list(_ keys: [CourseKey]) -> String {
        let names = keys.map(\.description)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The facts under a "Works without…" option: how many schedules, and what stops the courses.
    static func detail(of option: ScheduleBlockerOption, blockers: ScheduleBlockerAnalysis, termName: String) -> String {
        var parts: [String] = []
        let count = option.scheduleCount.formatted()
        let noun = option.scheduleCount == 1 && !option.isLowerBound ? "schedule" : "schedules"
        parts.append(option.isLowerBound ? "\(count)+ \(noun)" : "\(count) \(noun)")
        for key in option.courses {
            if blockers.notOffered.contains(key) {
                parts.append("\(key) isn’t offered in \(termName)")
            } else if blockers.filteredOut.contains(key) {
                parts.append("your rules rule out every \(key) section")
            }
        }
        if option.courses.count == 1, let key = option.courses.first {
            let clashes = blockers.clashes(of: key)
            if !clashes.isEmpty { parts.append("overlaps \(list(clashes))") }
        }
        return parts.joined(separator: " · ")
    }

    /// Reasons that say something couldn't be checked ("Offering history unknown") aren't good news.
    static func isUncertain(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("unknown") || reason.localizedCaseInsensitiveContains("couldn’t")
    }

    /// `12 schedules`, `1,000+ schedules` for a loosened rule or an option.
    static func countText(_ suggestion: ScheduleSuggestion) -> String {
        let count = suggestion.scheduleCount.formatted()
        let noun = suggestion.scheduleCount == 1 && !suggestion.isLowerBound ? "schedule" : "schedules"
        return suggestion.isLowerBound ? "\(count)+ \(noun)" : "\(count) \(noun)"
    }

    /// What's in the way: blocked courses, courses that always overlap, count and credit problems.
    static func reasons(for diagnostics: ScheduleDiagnostics, termName: String) -> [Reason] {
        var result: [Reason] = []

        for report in diagnostics.courses where report.isBlocked && report.isRequired {
            if report.totalSections == 0 {
                result.append(Reason(symbol: "questionmark.folder", title: "\(report.key) isn’t offered in \(termName)", detail: "Remove it from the schedule or make it optional."))
            } else {
                result.append(Reason(
                    symbol: "xmark.circle",
                    title: "No \(report.key) sections left",
                    detail: rejectionText(report, diagnostics: diagnostics)
                ))
            }
        }

        for pair in diagnostics.conflictingPairs {
            switch pair.reason {
            case .overlap:
                result.append(Reason(
                    symbol: "rectangle.on.rectangle.slash",
                    title: "\(pair.first) and \(pair.second) always overlap",
                    detail: "Every remaining section of one meets while a section of the other does. Make one optional or pick different sections."
                ))
            case .travelTime:
                let minutes = diagnostics.preferences.minimumBreakMinutes
                result.append(Reason(
                    symbol: "figure.walk",
                    title: "\(pair.first) and \(pair.second) are always too close together",
                    detail: "Every combination leaves less than \(minutes) minutes between them in different buildings. Lower the walking time or make one optional."
                ))
            }
        }

        switch diagnostics.countProblem {
        case .tooManyRequired(let required, let wanted):
            result.append(Reason(
                symbol: "number.circle",
                title: "\(required) courses are required, but schedules are limited to \(wanted)",
                detail: "Raise the number of courses or make some courses optional."
            ))
        case .tooFewCourses(let available, let wanted):
            result.append(Reason(
                symbol: "number.circle",
                title: "Only \(available) \(available == 1 ? "course has" : "courses have") sections left, but \(wanted) are wanted",
                detail: "Lower the number of courses or relax a filter."
            ))
        case .creditsOverTarget(let required, let limit):
            result.append(Reason(
                symbol: "number.circle",
                title: "The required courses are \(required) credits, but your target stops at \(limit)",
                detail: "Raise the credit target or make a course optional."
            ))
        case .creditsUnderTarget(let available, let wanted):
            result.append(Reason(
                symbol: "number.circle",
                title: "Your courses add up to \(available) credits, but you want \(wanted)",
                detail: "Lower the credit target or add a course."
            ))
        case nil:
            break
        }

        for report in diagnostics.courses where report.isBlocked && !report.isRequired && report.totalSections > 0 {
            result.append(Reason(
                symbol: "minus.circle",
                title: "\(report.key) (optional) can’t be added",
                detail: rejectionText(report, diagnostics: diagnostics)
            ))
        }
        return result
    }

    /// Why a course's sections were all rejected: `All 5 sections start before 10 AM.`
    static func rejectionText(_ report: ScheduleDiagnostics.CourseReport, diagnostics: ScheduleDiagnostics) -> String {
        let total = report.totalSections
        let ordered = report.rejections.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
        guard !ordered.isEmpty else { return total == 1 ? "Its only section was filtered out." : "All \(total) sections were filtered out." }
        let filters = diagnostics.filters
        let preferences = diagnostics.preferences

        func phrase(_ reason: ScheduleFilterReason, plural: Bool) -> String {
            switch reason {
            case .excludedByUser: plural ? "are skipped by you" : "is skipped by you"
            case .startsTooEarly: (plural ? "start" : "starts") + " before \(filters.earliestStart.map { TimeOfDay.label($0) } ?? "your limit")"
            case .endsTooLate: (plural ? "end" : "ends") + " after \(filters.latestEnd.map { TimeOfDay.label($0) } ?? "your limit")"
            case .freeDay: (plural ? "meet" : "meets") + " on a day you want free"
            case .honors: plural ? "are honors sections" : "is an honors section"
            case .online: plural ? "are online" : "is online"
            case .seats: plural ? "are full or low on seats" : "is full or low on seats"
            case .campus: plural ? "are on another campus" : "is on another campus"
            case .blockedTime: plural ? "overlap a blocked time" : "overlaps a blocked time"
            case .prefStartsTooEarly: (plural ? "start" : "starts") + " before \(preferences.earliestStart.map { TimeOfDay.label($0.minutes) } ?? "your earliest time")"
            case .prefEndsTooLate: (plural ? "end" : "ends") + " after \(preferences.latestEnd.map { TimeOfDay.label($0.minutes) } ?? "your latest time")"
            case .prefDayOff: (plural ? "meet" : "meets") + " on a day you want off"
            case .prefFormat: (plural ? "aren’t " : "isn’t ") + preferences.format.title.lowercased()
            case .prefSeats: plural ? "have no open seats" : "has no open seats"
            case .prefCampus: plural ? "are on another campus" : "is on another campus"
            case .prefWorkload: plural ? "run longer in a day than your limit" : "runs longer in a day than your limit"
            }
        }

        // One constraint rejected everything: say so plainly.
        if ordered.count == 1, let only = ordered.first, only.value == total {
            if total == 1 { return "Its only section \(phrase(only.key, plural: false))." }
            return "All \(total) sections \(phrase(only.key, plural: true))."
        }
        let parts = ordered.map { reason, count in "\(count) \(phrase(reason, plural: count != 1))" }
        return "Of \(total) sections: " + parts.joined(separator: ", ") + "."
    }
}
