//
//  Course.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Identifies a course independent of term, e.g. `CS 3000`.
struct CourseKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Subject code, e.g. `CS`.
    var subject: String
    /// Course number, e.g. `3000` (may contain letters, e.g. `201M`).
    var number: String

    init(subject: String, number: String) {
        self.subject = subject
        self.number = number
    }

    /// Parses `CS 3000`, `CS3000` or `cs-3000`.
    init?(string: String) {
        let cleaned = string.uppercased().replacingOccurrences(of: "-", with: " ")
        let letters = cleaned.prefix { $0.isLetter }
        let rest = cleaned.dropFirst(letters.count).trimmingCharacters(in: .whitespaces)
        guard !letters.isEmpty, !rest.isEmpty, rest.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        self.init(subject: String(letters), number: rest)
    }

    var description: String { "\(subject) \(number)" }

    /// Numeric course level (1 for 1000-level, 5 for 5000-level ...), if parseable.
    var level: Int? {
        guard let first = number.first, let digit = first.wholeNumberValue else { return nil }
        return digit
    }

    /// Numeric value of the course number used for range filters and sorting.
    var numericValue: Int {
        Int(number.prefix { $0.isNumber }) ?? 0
    }

    static func < (lhs: CourseKey, rhs: CourseKey) -> Bool {
        if lhs.subject != rhs.subject { return lhs.subject < rhs.subject }
        if lhs.numericValue != rhs.numericValue { return lhs.numericValue < rhs.numericValue }
        return lhs.number < rhs.number
    }
}

/// A course offered in a term, shared by all of its sections.
struct Course: Codable, Hashable, Identifiable, Sendable {
    var subject: String
    var number: String
    var title: String
    var description: String
    var minCredits: Double
    var maxCredits: Double
    /// Banner attribute codes shared by the course's sections (NUpath, honors, ...).
    var attributes: [String]
    var prereqs: Requisite?
    var coreqs: Requisite?
    /// Courses that list this course as a prerequisite ("prereq for").
    var postreqs: [CourseKey]
    /// Special topics courses have per-section titles and descriptions.
    var specialTopics: Bool
    /// College that offers the course, e.g. `Khoury Coll of Comp Sciences`.
    var college: String?
    /// Department, e.g. `Computer Science`.
    var department: String?
    /// False for stubs created from a section sync whose description and
    /// requisites have not been fetched yet.
    var detailsLoaded: Bool

    var key: CourseKey { CourseKey(subject: subject, number: number) }

    /// The fetched catalog entry lists no prerequisites.
    ///
    /// `prereqs == nil` is not enough. A stub (`detailsLoaded == false`) is built
    /// with both requisite fields nil before Banner's tables are read, and that
    /// nil means unknown. After `fetchCourseDetails`, `detailsLoaded` is true and
    /// a nil field is the empty table ("No prerequisite information available.").
    var listsNoPrerequisites: Bool { detailsLoaded && prereqs == nil }

    /// The fetched catalog entry lists no corequisites. A stub's nil `coreqs` is unknown.
    var listsNoCorequisites: Bool { detailsLoaded && coreqs == nil }

    var id: CourseKey { key }
    var code: String { key.description }

    /// `4 credits`, `1-4 credits`, `0 credits`.
    var creditsLabel: String {
        CreditFormatter.label(min: minCredits, max: maxCredits)
    }

    var nupaths: [NUPath] { NUPath.from(attributeCodes: attributes) }
}

enum CreditFormatter {
    static func number(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func label(min: Double, max: Double) -> String {
        let text = min == max ? number(min) : "\(number(min))–\(number(max))"
        return "\(text) \(max == 1 && min == 1 ? "credit" : "credits")"
    }
}

/// A subject such as `CS` / `Computer Science`.
struct Subject: Codable, Hashable, Identifiable, Sendable {
    var code: String
    var name: String
    var id: String { code }
}

/// A Banner section/course attribute such as `NCFQ` / `NUpath Formal/Quant Reasoning`.
struct AttributeInfo: Codable, Hashable, Identifiable, Sendable {
    var code: String
    var name: String
    var id: String { code }
}

/// A Banner campus, e.g. `BOS` / `Boston`.
struct Campus: Codable, Hashable, Identifiable, Sendable {
    var code: String
    var name: String
    var id: String { code }

    var isOnline: Bool { name.localizedCaseInsensitiveContains("online") }
}

/// Northeastern's NUpath general education attributes.
enum NUPath: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case nd = "NCND"
    case ei = "NCEI"
    case ic = "NCIC"
    case fq = "NCFQ"
    case si = "NCSI"
    case ad = "NCAD"
    case dd = "NCDD"
    case er = "NCER"
    case wf = "NCW1"
    case wi = "NCWI"
    case wd = "NCW3"
    case ex = "NCEX"
    case ce = "NCCE"

    var id: String { rawValue }

    /// Banner attribute code, e.g. `NCFQ`.
    var attributeCode: String { rawValue }

    /// Two letter abbreviation used by students, e.g. `FQ`.
    var short: String {
        switch self {
        case .nd: "ND"
        case .ei: "EI"
        case .ic: "IC"
        case .fq: "FQ"
        case .si: "SI"
        case .ad: "AD"
        case .dd: "DD"
        case .er: "ER"
        case .wf: "WF"
        case .wi: "WI"
        case .wd: "WD"
        case .ex: "EX"
        case .ce: "CE"
        }
    }

    var name: String {
        switch self {
        case .nd: "Natural & Designed World"
        case .ei: "Creative Expression & Innovation"
        case .ic: "Interpreting Culture"
        case .fq: "Formal & Quantitative Reasoning"
        case .si: "Societies & Institutions"
        case .ad: "Analyzing & Using Data"
        case .dd: "Difference & Diversity"
        case .er: "Ethical Reasoning"
        case .wf: "First-Year Writing"
        case .wi: "Writing Intensive"
        case .wd: "Advanced Writing in the Disciplines"
        case .ex: "Integration Experience"
        case .ce: "Capstone Experience"
        }
    }

    /// SF Symbol that loosely represents the category.
    var symbol: String {
        switch self {
        case .nd: "leaf"
        case .ei: "paintpalette"
        case .ic: "theatermasks"
        case .fq: "function"
        case .si: "building.columns"
        case .ad: "chart.bar.xaxis"
        case .dd: "person.3"
        case .er: "scale.3d"
        case .wf: "pencil.and.scribble"
        case .wi: "doc.text"
        case .wd: "text.book.closed"
        case .ex: "figure.walk.motion"
        case .ce: "graduationcap"
        }
    }

    static func from(attributeCodes: [String]) -> [NUPath] {
        let set = Set(attributeCodes)
        return allCases.filter { set.contains($0.rawValue) }
    }

    static func from(short: String) -> NUPath? {
        allCases.first { $0.short.caseInsensitiveCompare(short) == .orderedSame }
    }
}

/// The Banner attribute code that marks honors sections.
let honorsAttributeCode = "GNHN"
