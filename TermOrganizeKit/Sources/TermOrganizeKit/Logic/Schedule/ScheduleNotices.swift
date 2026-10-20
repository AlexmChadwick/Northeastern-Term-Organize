//
//  ScheduleNotices.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Warnings

/// A short statement about a schedule that needs the student's attention, for lists and cards:
/// `2 conflicts`, `1 full section`.
struct ScheduleWarning: Identifiable, Hashable, Sendable {
    enum Severity: Hashable, Sendable {
        case error, warning, neutral
    }

    var text: String
    /// An SF Symbol name.
    var symbol: String
    var severity: Severity

    var id: String { text }
}

extension ResolvedPlan {
    /// What needs attention, most serious first. Empty while the term's catalog isn't loaded, because
    /// nothing can be said about sections then.
    var warnings: [ScheduleWarning] {
        var items: [ScheduleWarning] = []
        guard hasCatalog else { return items }
        if !conflicts.isEmpty {
            items.append(ScheduleWarning(text: conflicts.count == 1 ? "1 conflict" : "\(conflicts.count) conflicts", symbol: "exclamationmark.triangle.fill", severity: .error))
        }
        if !fullSections.isEmpty {
            items.append(ScheduleWarning(text: fullSections.count == 1 ? "1 full section" : "\(fullSections.count) full sections", symbol: "chair", severity: .warning))
        }
        if !missingCourses.isEmpty {
            items.append(ScheduleWarning(text: missingCourses.count == 1 ? "1 course not offered" : "\(missingCourses.count) courses not offered", symbol: "questionmark.folder", severity: .warning))
        }
        if isOverCreditLimit {
            items.append(ScheduleWarning(text: "Over 19 credits", symbol: "exclamationmark.circle", severity: .warning))
        }
        let missingSections = coursesWithoutSection.filter { $0.planCourse.isRequired }.count
        if missingSections > 0, !plan.courses.isEmpty {
            items.append(ScheduleWarning(text: missingSections == 1 ? "1 course needs a section" : "\(missingSections) courses need sections", symbol: "circle.dashed", severity: .neutral))
        }
        return items
    }
}

// MARK: - Notices

/// A notice about one schedule, shown at the top of it: conflicts, full sections, a heavy credit
/// load, selections the catalog no longer knows.
struct ScheduleNotice: Identifiable, Hashable, Sendable {
    enum Severity: Hashable, Sendable {
        case error, warning, info
    }

    /// A one-tap fix a notice offers.
    enum Fix: Hashable, Sendable {
        /// Forget these selected sections: the catalog doesn't list them, or their course is gone.
        case removeSections([String])
    }

    var id: String
    var severity: Severity
    var title: String
    var lines: [String] = []
    var fix: Fix?

    /// The label of the button that applies the fix.
    var fixTitle: String? {
        switch fix {
        case .removeSections: "Remove"
        case nil: nil
        }
    }
}

enum ScheduleNotices {
    /// The notices for a plan, most serious first.
    ///
    /// - Parameters:
    ///   - termName: The plan's term, as the notices name it.
    ///   - catalogUnavailable: The term's catalog is known to be missing from this device (not just
    ///     still loading).
    static func make(for resolved: ResolvedPlan, termName: String, catalogUnavailable: Bool) -> [ScheduleNotice] {
        var items: [ScheduleNotice] = []

        if !resolved.hasCatalog, catalogUnavailable, !resolved.plan.courses.isEmpty {
            items.append(ScheduleNotice(
                id: "catalog",
                severity: .warning,
                title: "Course data for \(termName) isn’t on this device",
                lines: ["Switch to that term and download its catalog to see sections, times and seats."]
            ))
        }

        if !resolved.conflicts.isEmpty {
            let count = resolved.conflicts.count
            var lines = resolved.conflicts.prefix(3).map(\.summary)
            if count > 3 { lines.append("and \(count - 3) more") }
            items.append(ScheduleNotice(
                id: "conflicts",
                severity: .error,
                title: count == 1 ? "1 time conflict" : "\(count) time conflicts",
                lines: lines
            ))
        }

        if !resolved.fullSections.isEmpty {
            let lines = resolved.fullSections.map { pair -> String in
                let waitlist = pair.section.waitlistCapacity > 0 ? " · \(pair.section.waitlistRemaining) waitlist spots left" : ""
                return "\(pair.section.courseKey) \(ScheduleFormat.sectionTitle(pair.section)) is full\(waitlist)"
            }
            items.append(ScheduleNotice(
                id: "full",
                severity: .warning,
                title: resolved.fullSections.count == 1 ? "1 section is full" : "\(resolved.fullSections.count) sections are full",
                lines: lines
            ))
        }

        if !resolved.missingCourses.isEmpty {
            items.append(ScheduleNotice(
                id: "missing",
                severity: .warning,
                title: resolved.missingCourses.count == 1 ? "1 course isn’t offered in \(termName)" : "\(resolved.missingCourses.count) courses aren’t offered in \(termName)",
                lines: resolved.missingCourses.map { "\($0) has no sections this term." }
            ))
        }

        if resolved.isOverCreditLimit {
            items.append(ScheduleNotice(
                id: "credits",
                severity: .warning,
                title: "\(resolved.creditsLabel) is a heavy load",
                lines: ["Above 19 credits you may need approval from your advisor or college."]
            ))
        }

        if !resolved.unlistedCRNs.isEmpty {
            let unlisted = resolved.unlistedCRNs
            items.append(ScheduleNotice(
                id: "unlisted",
                severity: .info,
                title: unlisted.count == 1 ? "A saved section is no longer listed" : "\(unlisted.count) saved sections are no longer listed",
                lines: ["CRN \(unlisted.joined(separator: ", ")) isn’t in the current \(termName) catalog."],
                fix: .removeSections(unlisted)
            ))
        }

        if !resolved.orphanedCRNs.isEmpty {
            let orphaned = resolved.orphanedCRNs
            items.append(ScheduleNotice(
                id: "orphaned",
                severity: .info,
                title: orphaned.count == 1 ? "A section from a removed course is still selected" : "\(orphaned.count) sections from removed courses are still selected",
                lines: ["CRN \(orphaned.joined(separator: ", ")) doesn’t belong to any course in this schedule."],
                fix: .removeSections(orphaned)
            ))
        }
        return items
    }
}
