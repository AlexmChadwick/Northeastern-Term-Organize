//
//  CourseSection+Display.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Display helpers on `CourseSection` shared by the course, section and professor screens.
//

import Foundation

extension CourseSection {
    /// The campus for display, or nil for Banner's placeholder campuses.
    var courseDisplayCampus: String? {
        let trimmed = campus.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveContains("no campus") { return nil }
        return trimmed
    }

    /// `In person`, `Online`, `Hybrid`…
    var courseInstructionLabel: String? {
        guard let method = instructionMethod?.trimmingCharacters(in: .whitespaces), !method.isEmpty else { return nil }
        return method.caseInsensitiveCompare("Traditional") == .orderedSame ? "In person" : method
    }

    /// `Boston · In person`, without repeating identical parts.
    var courseWhereLabel: String? {
        let campus = courseDisplayCampus
        // "Traditional" with no campus means arranged individually, not "in person".
        let isTraditional = instructionMethod?.caseInsensitiveCompare("Traditional") == .orderedSame
        let method = (campus == nil && isTraditional) ? nil : courseInstructionLabel
        var parts: [String] = []
        for part in [campus, method].compactMap({ $0 })
        where !parts.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Instructors with the primary one first (without duplicates), or nil while they have not been loaded.
    var courseSortedInstructors: [Instructor]? {
        guard let instructors else { return nil }
        var seen = Set<String>()
        return instructors.enumerated().sorted { lhs, rhs in
            if lhs.element.primary != rhs.element.primary { return lhs.element.primary }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
        .filter { seen.insert($0.name).inserted }
    }

    /// CRNs of cross-listed sections, without duplicates or this section itself.
    var courseCrossListedCRNs: [String] {
        var seen: Set<String> = [crn]
        return crossListCRNs.filter { seen.insert($0).inserted }
    }

    /// Attribute codes without duplicates, in Banner order.
    var courseUniqueAttributes: [String] {
        var seen = Set<String>()
        return attributes.filter { seen.insert($0).inserted }
    }

    /// `Part of term 2A · Sep 9 – Oct 25`, or nil for full-term sections.
    var coursePartOfTermLabel: String? {
        let code = partOfTerm.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code != "1" else { return nil }
        let range = CourseFormat.dateRange(start: meetings.compactMap(\.startDate).min(), end: meetings.compactMap(\.endDate).max())
        return ["Part of term \(code)", range].compactMap { $0 }.joined(separator: " · ")
    }

    /// The special-topics description, when present and non-empty.
    var courseTopicDescription: String? {
        guard let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Spoken seat summary, e.g. `12 of 40 seats open`.
    var courseSeatsSpoken: String {
        if seatCapacity <= 0 && seatsRemaining <= 0 { return "No seat limit listed" }
        if seatsRemaining > 0 { return "\(seatsRemaining) of \(seatCapacity) seats open" }
        if waitlistCapacity > 0 { return "Full, \(waitlistRemaining) of \(waitlistCapacity) waitlist spots open" }
        return "Full"
    }
}

