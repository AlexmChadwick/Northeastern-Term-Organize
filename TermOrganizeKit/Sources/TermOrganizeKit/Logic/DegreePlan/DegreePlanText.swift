//
//  DegreePlanText.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Text

/// Wording shared by the degree plan screens.
enum DegreePlanText {
    /// `13`, `4.5`.
    static func number(_ value: Double) -> String { CreditFormatter.number(value) }

    /// `13 credits`, `1 credit`.
    static func credits(_ value: Double) -> String {
        "\(number(value)) \(value == 1 ? "credit" : "credits")"
    }

    /// `4 courses`, `1 course`.
    static func courses(_ count: Int) -> String { count == 1 ? "1 course" : "\(count) courses" }

    /// `3 semesters`, `1 semester`.
    static func semesters(_ count: Int) -> String { count == 1 ? "1 semester" : "\(count) semesters" }

    /// `Oct 3, 2026`.
    static func date(_ date: Date, in timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone))
    }
}

// MARK: - Model helpers

extension DegreePlanTerm {
    /// A compact name for chips: `Sp ’27`, `Su A ’27`, `Fa ’27`.
    var degreePlanChipName: String {
        let name: String
        switch season {
        case .winter: name = "Wi"
        case .spring: name = "Sp"
        case .summerA: name = "Su A"
        case .summerFull: name = "Su"
        case .summerB: name = "Su B"
        case .fall: name = "Fa"
        }
        return "\(name) ’\(String(format: "%02d", year % 100))"
    }

    /// `13 credits · 4 courses`.
    var degreePlanSummaryLine: String {
        "\(DegreePlanText.credits(credits)) · \(DegreePlanText.courses(courses.count))"
    }

    /// The Banner code of this semester at Northeastern (`202730` for Spring 2027).
    var degreePlanBannerCode: String {
        switch season {
        case .fall: "\(year + 1)10"
        case .winter: "\(year)20"
        case .spring: "\(year)30"
        case .summerA: "\(year)40"
        case .summerFull: "\(year)50"
        case .summerB: "\(year)60"
        }
    }

    /// Whether the semester is over (approximately), so it shouldn't be offered as "next".
    func degreePlanHasEnded(now: Date = .now) -> Bool {
        guard let window = TermCalendar.approximateWindow(for: degreePlanBannerCode) else { return false }
        return window.upperBound < now
    }
}

extension DegreePlan {
    /// Semesters that haven't ended yet, in order.
    func degreePlanUpcomingTerms(now: Date = .now) -> [DegreePlanTerm] {
        terms.filter { !$0.degreePlanHasEnded(now: now) }
    }

    /// The first upcoming semester with courses in it.
    func degreePlanNextTerm(now: Date = .now) -> DegreePlanTerm? {
        degreePlanUpcomingTerms(now: now).first { !$0.courses.isEmpty }
    }

    var degreePlanHasStudentInfo: Bool { studentName != nil || studentID != nil }

    /// `Imported from view-plan.pdf · printed Oct 3, 2026` or `Created Oct 3, 2026`.
    var degreePlanSourceLine: String {
        guard let importedFrom else { return "Created \(DegreePlanText.date(createdAt))" }
        var line = "Imported from \(importedFrom)"
        // The audit prints its timestamp in Boston time, so show the date the PDF shows.
        if let printedAt { line += " · printed \(DegreePlanText.date(printedAt, in: TermCalendar.newYork))" }
        return line
    }

    /// `68 credits completed`, or `No completed courses yet`.
    var degreePlanCompletedLine: String {
        completed.isEmpty ? "No completed courses yet" : "\(DegreePlanText.credits(completedCredits)) completed"
    }

    /// `Spring 2027 · 13 credits · 4 courses`: the next upcoming semester with courses in it.
    func degreePlanNextSummary(now: Date = .now) -> String? {
        guard let next = degreePlanNextTerm(now: now) else { return nil }
        return "\(next.name) · \(DegreePlanText.credits(next.credits)) · \(DegreePlanText.courses(next.courses.count))"
    }

    /// `Next: Spring 2027 · 13 credits · 4 courses`, or why there is no next semester.
    func degreePlanNextLine(now: Date = .now) -> String {
        if let summary = degreePlanNextSummary(now: now) { return "Next: \(summary)" }
        if terms.isEmpty { return "No semesters planned yet" }
        if degreePlanUpcomingTerms(now: now).isEmpty { return "No upcoming semesters" }
        return "No courses planned yet"
    }
}
