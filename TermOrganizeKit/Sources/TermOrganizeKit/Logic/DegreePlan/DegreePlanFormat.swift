//
//  DegreePlanFormat.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Reads and writes the text layout of Northeastern's degree audit "View Plan"
/// export:
///
///     Printed:  10/03/2026 12:42
///     Student:  …
///     StudentID:  …
///     Degree Audit Plan Name:⇥New Plan
///     Program:⇥⇥CS-B-CSCI-BSCS
///       Completed Courses:
///         CS  1800 (4.0 Hours) Discrete Structures
///         NO AP CREDIT (0.0 Hours) No description
///       -------------------------------------------…
///       Spring  2027 (13.0 Hours)
///         CS  3484 (4.0 Hours) GUI Programming
///       -------------------------------------------…
///       Summer Session A 2027 (8.0 Hours)
///
/// Parsing is tolerant of the whitespace changes PDF text extraction introduces
/// (collapsed spaces, tabs, stray bullet lines).
enum DegreePlanFormat {
    static let separator = String(repeating: "-", count: 115)
    /// The degree audit prints Banner's 30-character short titles.
    static let titleLength = 30

    // MARK: Errors

    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case notADegreePlan

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "That file couldn't be read. Export the plan again as a PDF and try once more."
            case .notADegreePlan:
                "This doesn't look like a degree audit plan. In the degree audit planner, open your plan and choose View Plan, then import the PDF it creates."
            }
        }
    }

    struct ParseResult: Sendable {
        var plan: DegreePlan
        /// Lines that weren't understood (reported, never fatal).
        var skippedLines: [String]
    }

    // MARK: Parsing

    static func parse(text: String, fileName: String? = nil) throws -> ParseResult {
        var plan = DegreePlan(name: "")
        plan.importedFrom = fileName
        var skipped: [String] = []
        var sawStructure = false

        enum Section { case header, completed, term, between }
        var section = Section.header

        for rawLine in text.components(separatedBy: .newlines) {
            let line = normalize(rawLine)
            guard !line.isEmpty, line != "-", line != "•" else { continue }

            if let value = headerValue(line, label: "Printed:") {
                plan.printedAt = parsePrintedDate(value)
                continue
            }
            if let value = headerValue(line, label: "StudentID:") ?? headerValue(line, label: "Student ID:") {
                plan.studentID = value.nilIfBlank
                continue
            }
            if let value = headerValue(line, label: "Student:") {
                plan.studentName = value.nilIfBlank
                continue
            }
            if let value = headerValue(line, label: "Degree Audit Plan Name:") ?? headerValue(line, label: "Plan Name:") {
                plan.name = value
                sawStructure = true
                continue
            }
            if let value = headerValue(line, label: "Program:") {
                plan.program = value.nilIfBlank
                continue
            }
            if line.lowercased().hasPrefix("completed courses") {
                section = .completed
                sawStructure = true
                continue
            }
            if isSeparator(line) {
                section = .between
                continue
            }
            if let term = parseTermHeader(line) {
                plan.terms.append(term)
                section = .term
                sawStructure = true
                continue
            }
            if let course = parseCourseLine(line) {
                switch section {
                case .term:
                    plan.terms[plan.terms.count - 1].courses.append(course)
                case .header, .completed:
                    plan.completed.append(course)
                case .between:
                    // A course right after a separator without a header — keep it with the last term.
                    if plan.terms.isEmpty { plan.completed.append(course) } else { plan.terms[plan.terms.count - 1].courses.append(course) }
                }
                continue
            }
            skipped.append(line)
        }

        guard sawStructure, !(plan.completed.isEmpty && plan.terms.isEmpty && plan.name.isEmpty) else {
            throw ImportError.notADegreePlan
        }
        if plan.name.isEmpty { plan.name = "Imported Plan" }
        plan.sortTerms()
        return ParseResult(plan: plan, skippedLines: skipped)
    }

    /// `Spring 2027 (13.0 Hours)` → a term (the hours total is recomputed from courses).
    static func parseTermHeader(_ line: String) -> DegreePlanTerm? {
        guard let match = line.firstMatch(of: #/^(.+?)\s+(\d{4})\s*\(\s*\d+(?:\.\d+)?\s*Hours?\s*\)$/#.ignoresCase()),
              let season = PlanSeason(exportName: String(match.1)),
              let year = Int(match.2) else { return nil }
        return DegreePlanTerm(season: season, year: year)
    }

    /// `CS 1800 (4.0 Hours) Discrete Structures` or `NO AP CREDIT (0.0 Hours) No description`.
    static func parseCourseLine(_ line: String) -> DegreePlanCourse? {
        guard let match = line.firstMatch(of: #/^(.+?)\s*\(\s*(\d+(?:\.\d+)?)\s*Hours?\s*\)\s*(.*)$/#.ignoresCase()),
              let credits = Double(match.2) else { return nil }
        let code = String(match.1).trimmingCharacters(in: .whitespaces)
        let title = String(match.3).trimmingCharacters(in: .whitespaces)
        if let key = parseCourseCode(code) {
            return DegreePlanCourse(key: key, title: title, credits: credits)
        }
        // A non-course credit line (e.g. "NO AP CREDIT"); keep it so exports match.
        guard code.count <= 40, !code.contains(":") else { return nil }
        return DegreePlanCourse(key: nil, label: code, title: title, credits: credits)
    }

    /// `CS 1800`, `CS  1800`, `GAME1110`, `MATH 209M` → a course key.
    static func parseCourseCode(_ code: String) -> CourseKey? {
        guard let match = code.uppercased().wholeMatch(of: #/([A-Z]{2,5})\s*(\d{4}[A-Z]?)/#) else { return nil }
        return CourseKey(subject: String(match.1), number: String(match.2))
    }

    /// Undoes PDF text extraction artifacts: control characters (PDFKit returns NUL for the
    /// spaces in the bold header), no-break spaces, zero-width characters, runs of spaces,
    /// and a dash bullet glued to the start of a line (`-ENGW3302 (4.0 Hours) …`).
    static func normalize(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            case .format:
                continue
            default:
                scalars.append(scalar)
            }
        }
        var text = String(scalars)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let bullets: Set<Character> = ["-", "•", "–", "—"]
        if let first = text.first, bullets.contains(first), !isSeparator(text) {
            text = String(text.drop { bullets.contains($0) }).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func headerValue(_ line: String, label: String) -> String? {
        guard line.lowercased().hasPrefix(label.lowercased()) else { return nil }
        return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func isSeparator(_ line: String) -> Bool {
        line.count >= 10 && line.allSatisfy { $0 == "-" || $0 == "_" || $0 == "=" }
    }

    static func parsePrintedDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        for format in ["MM/dd/yyyy HH:mm", "MM/dd/yyyy h:mm a", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    // MARK: Formatting (export)

    /// `(4.0 Hours)` / `(1.0 Hour)`.
    static func hours(_ credits: Double) -> String {
        let number = String(format: "%.1f", credits)
        return "(\(number) \(credits == 1 ? "Hour" : "Hours"))"
    }

    /// `CS  1800` — the subject is padded to four characters, like the audit prints it.
    static func exportCode(_ course: DegreePlanCourse) -> String {
        guard let key = course.key else { return course.label }
        let subject = key.subject.count < 4 ? key.subject.padding(toLength: 4, withPad: " ", startingAt: 0) : key.subject
        return subject + key.number
    }

    static func exportTitle(_ title: String) -> String {
        String(title.prefix(titleLength))
    }

    /// `CS  1800 (4.0 Hours) Discrete Structures`.
    static func courseLine(_ course: DegreePlanCourse) -> String {
        "\(exportCode(course)) \(hours(course.credits)) \(exportTitle(course.title))"
    }

    /// `Spring  2027 (13.0 Hours) ` — one-word seasons get two spaces, as in the audit.
    static func termHeader(_ term: DegreePlanTerm) -> String {
        let gap = term.season.exportName.contains(" ") ? " " : "  "
        return "\(term.season.exportName)\(gap)\(term.year) \(hours(term.credits)) "
    }

    static func printedLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MM/dd/yyyy HH:mm"
        return "Printed:  \(formatter.string(from: date))"
    }

    /// The header block. Student lines are included only when asked (and known).
    static func headerLines(for plan: DegreePlan, printedAt: Date, includeStudent: Bool) -> [String] {
        var lines = [printedLine(printedAt)]
        if includeStudent {
            lines.append("Student:  \(plan.studentName ?? "")")
            lines.append("StudentID:  \(plan.studentID ?? "")")
        }
        // The audit separates these two values with tabs (one and two).
        lines.append("Degree Audit Plan Name:\t\(plan.name)")
        lines.append("Program:\t\t\(plan.program ?? "")")
        return lines
    }

    /// The whole plan as text, line by line, in the export's order. Each entry
    /// carries its indent level: 0 header, 1 section/separator, 2 course.
    static func bodyLines(for plan: DegreePlan) -> [(indent: Int, text: String)] {
        var lines: [(Int, String)] = [(1, "Completed Courses:  ")]
        lines += plan.completed.map { (2, courseLine($0)) }
        for term in plan.terms {
            lines.append((1, separator))
            lines.append((1, termHeader(term)))
            lines += term.courses.map { (2, courseLine($0)) }
        }
        return lines
    }

    /// Plain-text rendition (used for copy/share as text and for round-trip tests).
    static func text(for plan: DegreePlan, printedAt: Date = .now, includeStudent: Bool) -> String {
        let header = headerLines(for: plan, printedAt: printedAt, includeStudent: includeStudent)
        let body = bodyLines(for: plan).map { String(repeating: "  ", count: $0.indent) + $0.text }
        return (header + body).joined(separator: "\n")
    }
}
