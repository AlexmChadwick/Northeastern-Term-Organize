//
//  BannerParsers.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), packages/scraper/src/generate/steps/reqs.ts
//  and courseNames.ts, Copyright (C) Sandbox at Northeastern University and the
//  SearchNEU contributors, licensed under the GNU Affero General Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift, adapted to the app's
//  `Requisite` model, and made tolerant of unknown subjects and score-less tests.
//

import Foundation

enum BannerParsers {
    /// Maps subject descriptions used in requisite tables (e.g. "Computer Science")
    /// to subject codes (e.g. "CS").
    struct SubjectLookup: Sendable {
        private var byName: [String: String] = [:]

        init(_ subjects: [Subject]) {
            for s in subjects {
                byName[s.name.lowercased()] = s.code
                byName[s.code.lowercased()] = s.code
            }
        }

        func code(for name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let code = byName[trimmed.lowercased()] { return code }
            // Campus listings name the subject with a suffix ("Computer Science - MMC" for
            // Mills College at Northeastern); they share the main subject's code.
            if let range = trimmed.range(of: #"\s+-\s+[A-Z]{2,5}$"#, options: .regularExpression),
               let code = byName[trimmed[..<range.lowerBound].lowercased()] {
                return code
            }
            // Fall back to the raw text so the UI can still show something useful.
            return trimmed
        }
    }

    // MARK: Prerequisites

    /// Reference-type builder used while walking the flat Banner table.
    private final class ConditionNode {
        var isAnd = false
        var items: [Item] = []
        enum Item {
            case leaf(Requisite)
            case node(ConditionNode)
        }

        func build() -> Requisite? {
            let built: [Requisite] = items.compactMap {
                switch $0 {
                case .leaf(let r): return r
                case .node(let n): return n.build()
                }
            }
            if built.isEmpty { return nil }
            return isAnd ? .and(built) : .or(built)
        }
    }

    /// Parses Banner's prerequisite table. Columns are:
    /// `And/Or | ( | Test | Score | Subject | Course Number | Level | Grade | )`.
    ///
    /// Parentheses open and close nested conditions; the And/Or column sets the
    /// type of the condition currently being built (port of SearchNEU's
    /// `parsePrereqs`).
    static func prerequisites(fromHTML html: String, subjects: SubjectLookup) -> Requisite? {
        guard let rows = HTMLText.tableRows(html), !rows.isEmpty else { return nil }

        let root = ConditionNode()
        var stack: [ConditionNode] = [root]
        var current = root

        for cells in rows {
            func cell(_ i: Int) -> String { i < cells.count ? cells[i].trimmingCharacters(in: .whitespacesAndNewlines) : "" }
            guard cells.count >= 6 else { continue }

            let andOr = cell(0).lowercased()
            if andOr == "and" { current.isAnd = true } else if andOr == "or" { current.isAnd = false }

            if !cell(1).isEmpty {
                let child = ConditionNode()
                current.items.append(.node(child))
                stack.append(child)
                current = child
            }

            let testName = cell(2)
            if !testName.isEmpty {
                let score = Double(cell(3))
                current.items.append(.leaf(.test(name: testName, score: score)))
            }

            let subjectName = cell(4)
            let number = cell(5)
            if !subjectName.isEmpty, !number.isEmpty {
                current.items.append(.leaf(.course(CourseKey(subject: subjects.code(for: subjectName), number: number))))
            }

            if !cell(8).isEmpty, stack.count > 1 {
                stack.removeLast()
                current = stack[stack.count - 1]
            }
        }

        return root.build()?.simplified()
    }

    // MARK: Corequisites

    /// Parses Banner's corequisite table (`Subject | Course Number | Title`).
    /// Multiple corequisites are all required (port of SearchNEU's `parseCoreqs`).
    static func corequisites(fromHTML html: String, subjects: SubjectLookup) -> Requisite? {
        guard let rows = HTMLText.tableRows(html) else { return nil }
        let items: [Requisite] = rows.compactMap { cells in
            let (subjectName, number): (String, String)
            if cells.count == 3 {
                (subjectName, number) = (cells[0], cells[1])
            } else if cells.count >= 4 {
                (subjectName, number) = (cells[1], cells[2])
            } else {
                return nil
            }
            guard !subjectName.isEmpty, !number.isEmpty else { return nil }
            return .course(CourseKey(subject: subjects.code(for: subjectName), number: number))
        }
        switch items.count {
        case 0: return nil
        case 1: return items[0]
        default: return .and(items)
        }
    }

    // MARK: Descriptions & catalog details

    /// Extracts the plain-text course description.
    static func description(fromHTML html: String) -> String {
        let text = HTMLText.plainText(html)
        let lowered = text.lowercased()
        if lowered.hasPrefix("no course description") || lowered.contains("no information available") { return "" }
        return text
    }

    struct CatalogDetails: Sendable {
        var title: String?
        var college: String?
        var department: String?
        /// Credit hours: `4` is 4...4, `1 TO 4` is 1...4.
        var minCredits: Double?
        var maxCredits: Double?
    }

    /// Parses the "catalog details" fragment of a section (`getSectionCatalogDetails`) or of a
    /// course (`courseSearchResults/getCourseCatalogDetails`, which has the same shape):
    /// title, college, department and credit hours.
    static func catalogDetails(fromHTML html: String) -> CatalogDetails {
        let lines = HTMLText.plainText(html).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        func value(for label: String) -> String? {
            guard let i = lines.firstIndex(where: { $0.hasPrefix(label) }) else { return nil }
            let inline = lines[i].dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            if !inline.isEmpty { return inline }
            guard i + 1 < lines.count, !lines[i + 1].hasSuffix(":") else { return nil }
            return lines[i + 1]
        }

        /// Banner appends the org code, e.g. "Computer Science CS"; drop it.
        func stripTrailingCode(_ s: String?) -> String? {
            guard let s else { return nil }
            var parts = s.split(separator: " ")
            if parts.count > 1, let last = parts.last, last.count <= 4, last == last.uppercased(), last.allSatisfy({ $0.isLetter || $0.isNumber }) {
                parts.removeLast()
            }
            return parts.joined(separator: " ")
        }

        let credits = value(for: "Credit Hours:").flatMap(creditRange(from:))
        return CatalogDetails(
            title: value(for: "Title:"),
            college: stripTrailingCode(value(for: "College:")).map(expandCollegeName),
            department: stripTrailingCode(value(for: "Department:")).map(expandCollegeName),
            minCredits: credits?.low,
            maxCredits: credits?.high
        )
    }

    /// Reads credit hours written as `4`, `4.000`, `1 TO 4` or `1.000 TO 4.000`.
    static func creditRange(from text: String) -> (low: Double, high: Double)? {
        let numbers = text.matches(of: #/\d+(?:\.\d+)?/#).compactMap { Double($0.output) }
        guard let first = numbers.first else { return nil }
        let second = numbers.count > 1 ? numbers[1] : first
        return (min(first, second), max(first, second))
    }

    /// Expands Banner's abbreviated college names for display.
    static func expandCollegeName(_ s: String) -> String {
        var out = " \(s) "
        let replacements = [
            (" Coll of ", " College of "), (" Col of ", " College of "), (" Coll ", " College "),
            (" Comp Sciences ", " Computer Sciences "), (" Hlth ", " Health "), (" Sci ", " Science "),
            (" Engr ", " Engineering "), (" Prof ", " Professional "), (" School Business ", " School of Business "),
            (" Soc Sci ", " Social Sciences "), (" Humanities ", " Humanities "),
        ]
        for (from, to) in replacements { out = out.replacingOccurrences(of: from, with: to) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Course catalog lookups

    /// Whether the course codes Banner's catalog typeahead returned
    /// (`courseSearch/get_subjectcoursecombo`, e.g. `CS3386`) include `course`. The endpoint
    /// matches by prefix, so the code has to match exactly.
    static func catalogCodes(_ items: [BannerCodeDescription], contain course: CourseKey) -> Bool {
        let wanted = normalizedCode("\(course.subject)\(course.number)")
        return items.contains { normalizedCode($0.code) == wanted }
    }

    private static func normalizedCode(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.uppercased()
    }

    // MARK: Equivalent courses

    /// Parses a course's mutual exclusions (`courseSearchResults/getCourseMutuallyExclusions`):
    /// the courses credit can't be earned for as well as this one, which is how a registrar
    /// links a renumbered course to its replacement.
    ///
    /// Banner answers "No Mutual Exclusion information available." when a course has none, and
    /// that is what every course sampled (CS 2100, CS 2510 and MATH 1341) answered, so the shape
    /// of a populated list has not been seen. This reads every table row that has a subject
    /// followed by a course number, and, failing that, course codes written out in the text.
    static func mutualExclusions(fromHTML html: String, subjects: SubjectLookup) -> [CourseKey] {
        let text = HTMLText.plainText(html)
        if text.localizedCaseInsensitiveContains("no mutual exclusion") { return [] }

        var keys: [CourseKey] = []
        func add(_ key: CourseKey) {
            if !keys.contains(key) { keys.append(key) }
        }

        for cells in HTMLText.tableRows(html) ?? [] {
            let cells = cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for i in cells.indices.dropLast() where isSubjectText(cells[i]) && isCourseNumber(cells[i + 1]) {
                add(CourseKey(subject: subjects.code(for: cells[i]), number: cells[i + 1]))
                break
            }
        }
        if keys.isEmpty {
            for match in text.matches(of: #/\b([A-Z]{2,6})\s?(\d{3,4}[A-Z]?)\b/#) {
                add(CourseKey(subject: String(match.output.1), number: String(match.output.2)))
            }
        }
        return keys
    }

    private static func isSubjectText(_ text: String) -> Bool {
        text.contains { $0.isLetter } && !isCourseNumber(text)
    }

    /// `2100`, `201M`, `21EM`: three to five letters or digits, starting with a digit.
    private static func isCourseNumber(_ text: String) -> Bool {
        (3...5).contains(text.count) && text.first?.isNumber == true && text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// A section cross-listed with another (`searchResults/getXlstSections`).
    struct CrossListedSection: Sendable, Hashable {
        var crn: String
        var course: CourseKey
        var title: String
        var section: String
    }

    /// Parses the sections cross-listed with a section (`searchResults/getXlstSections`; note
    /// Banner's spelling). The table lists the *other* sections of the cross-list, with columns
    /// `CRN | Subject | Course Number | Title | Section`. Banner names the subject in words
    /// (`English`), which `subjects` turns into a code.
    static func crossListedSections(fromHTML html: String, subjects: SubjectLookup) -> [CrossListedSection] {
        guard let rows = HTMLText.tableRows(html) else { return [] }
        return rows.compactMap { cells in
            guard cells.count >= 4 else { return nil }
            let crn = cells[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = cells[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let number = cells[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !crn.isEmpty, crn.allSatisfy(\.isNumber), !subject.isEmpty, !number.isEmpty else { return nil }
            return CrossListedSection(
                crn: crn,
                course: CourseKey(subject: subjects.code(for: subject), number: number),
                title: cells[3].trimmingCharacters(in: .whitespacesAndNewlines),
                section: cells.count > 4 ? cells[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            )
        }
    }
}
