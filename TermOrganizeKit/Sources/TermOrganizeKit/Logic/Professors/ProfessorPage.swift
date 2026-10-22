//
//  ProfessorPage.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  What an instructor's page shows, worked out from the term's catalog: their sections, a color per
//  course for the weekly calendar and the Rate My Professors link. Shared by the iPhone and iPad
//  page and the Mac window. Nothing here touches SwiftUI views.
//

import Foundation

enum ProfessorPage {
    /// Their sections, ordered by course and section number. A live refresh can drop sections the
    /// directory still remembers, so only the ones the index still lists come back.
    static func sections(of summary: InstructorSummary, in index: CatalogIndex) -> [CourseSection] {
        summary.crns
            .compactMap { index.section(crn: $0) }
            .sorted { lhs, rhs in
                if lhs.courseKey != rhs.courseKey { return lhs.courseKey < rhs.courseKey }
                return lhs.sectionNumber.localizedStandardCompare(rhs.sectionNumber) == .orderedAscending
            }
    }

    /// A color per course. Each course keeps its stable `forCourse` color unless another of the
    /// instructor's courses already took it, so the calendar and its legend are never ambiguous.
    static func courseColors(for keys: [CourseKey]) -> [CourseKey: CourseColor] {
        let palette = CourseColor.palette
        var used = Set<Int>()
        var colors: [CourseKey: CourseColor] = [:]
        for key in keys {
            var slot = palette.firstIndex(of: CourseColor.forCourse(key)) ?? 0
            if used.count < palette.count {
                while used.contains(slot) { slot = (slot + 1) % palette.count }
            }
            used.insert(slot)
            colors[key] = palette[slot]
        }
        return colors
    }

    /// `https://www.ratemyprofessors.com/search/professors/696?q=First%20Last` (696 is Northeastern).
    static func rateMyProfessorsURL(for displayName: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let query = displayName.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://www.ratemyprofessors.com/search/professors/696?q=\(query)")
    }

    /// `Section 02` / `Sections 01, 04`: which sections of a course the instructor teaches.
    static func sectionNote(for key: CourseKey, in sections: [CourseSection]) -> String {
        let numbers = sections.filter { $0.courseKey == key }.map(\.sectionNumber)
        return "\(numbers.count == 1 ? "Section" : "Sections") \(numbers.joined(separator: ", "))"
    }

    /// `Teaches 6 sections across 3 courses`, counted from the sections that still exist.
    static func summaryText(for sections: [CourseSection]) -> String {
        let courseCount = Set(sections.map(\.courseKey)).count
        return "Teaches \(CourseFormat.count(sections.count, "section")) across \(CourseFormat.count(courseCount, "course"))"
    }
}
