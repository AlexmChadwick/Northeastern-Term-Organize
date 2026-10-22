//
//  ProfessorDirectoryData.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Foundation-only data for the professors directory and monograms.
//

import Foundation

/// One row of the directory, precomputed off the main actor.
struct ProfessorDirectoryEntry: Identifiable, Hashable, Sendable {
    /// The Banner name (`Last, First`).
    var id: String
    var displayName: String
    var sectionCount: Int
    /// `CS 3000, CS 4530 +2`
    var courseSummary: String
    /// Last-name initial, or `#`.
    var letter: String
    /// Lowercased, diacritic-free names and course codes for matching.
    var searchText: String

    static func build(from index: CatalogIndex) -> [ProfessorDirectoryEntry] {
        index.instructors.map { summary in
            ProfessorDirectoryEntry(
                id: summary.name,
                displayName: summary.displayName,
                sectionCount: summary.crns.count,
                courseSummary: courseSummary(summary.courseKeys),
                letter: letter(for: summary.name),
                searchText: fold("\(summary.displayName) \(summary.name) \(summary.courseKeys.map(\.description).joined(separator: " "))")
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func courseSummary(_ keys: [CourseKey]) -> String {
        guard !keys.isEmpty else { return "No courses" }
        let shown = keys.prefix(3).map(\.description).joined(separator: ", ")
        return keys.count > 3 ? "\(shown) +\(keys.count - 3)" : shown
    }

    private static func letter(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "#" }
        let folded = String(first)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .uppercased()
        guard let scalar = folded.unicodeScalars.first, CharacterSet.letters.contains(scalar) else { return "#" }
        return String(folded.prefix(1))
    }

    /// Lowercases and strips diacritics so searches match `Jose` with `José`.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Entries sharing a last-name initial.
struct ProfessorDirectoryGroup: Identifiable {
    var letter: String
    var entries: [ProfessorDirectoryEntry]
    var id: String { letter }

    /// Groups entries already sorted by name, keeping `#` last.
    static func grouping(_ entries: [ProfessorDirectoryEntry]) -> [ProfessorDirectoryGroup] {
        var groups: [ProfessorDirectoryGroup] = []
        var positions: [String: Int] = [:]
        for entry in entries {
            if let position = positions[entry.letter] {
                groups[position].entries.append(entry)
            } else {
                positions[entry.letter] = groups.count
                groups.append(ProfessorDirectoryGroup(letter: entry.letter, entries: [entry]))
            }
        }
        return groups.filter { $0.letter != "#" } + groups.filter { $0.letter == "#" }
    }
}

enum ProfessorNames {
    /// `Last, First` becomes `FL`; single names give one letter.
    static func initials(for bannerName: String) -> String {
        let tokens = Instructor.displayName(from: bannerName)
            .split(separator: " ")
            .filter { $0.first?.isLetter == true }
        guard let first = tokens.first?.first else { return "?" }
        guard tokens.count >= 2, let last = tokens.last?.first else { return String(first).uppercased() }
        return "\(first)\(last)".uppercased()
    }
}
