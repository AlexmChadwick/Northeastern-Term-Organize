//
//  ProgramCatalogModels.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Editions

/// An edition of Northeastern's academic catalog (catalog.northeastern.edu), e.g. 2026–2027.
/// Students follow the degree requirements of the edition for the year they entered their
/// program.
struct CatalogYear: Hashable, Codable, Sendable, Comparable, Identifiable, CustomStringConvertible {
    /// The first calendar year: 2026 for 2026–2027.
    var startYear: Int

    init(startYear: Int) {
        self.startYear = startYear
    }

    /// Parses `2026-2027`, `2026–2027` or `2026-27`.
    init?(string: String) {
        guard let match = string.firstMatch(of: #/(\d{4})\s*[-–]\s*(\d{2,4})/#),
              let start = Int(match.1), let end = Int(match.2),
              end == start + 1 || end == (start + 1) % 100 else { return nil }
        self.init(startYear: start)
    }

    var id: Int { startYear }
    /// `2026-2027`, as in the catalog's archive URLs.
    var slug: String { "\(startYear)-\(startYear + 1)" }
    /// `2026–2027`.
    var description: String { "\(startYear)–\(startYear + 1)" }

    static func < (lhs: CatalogYear, rhs: CatalogYear) -> Bool { lhs.startYear < rhs.startYear }

    /// The edition in effect on `date`. New editions are published over the summer; July is
    /// used as the turnover. Only a fallback — the catalog site says which edition is current.
    static func containing(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> CatalogYear {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 2026
        return CatalogYear(startYear: (parts.month ?? 1) >= 7 ? year : year - 1)
    }
}

/// The editions the catalog site offers: the current one, served from the site root, and
/// archived ones, served under `/archive/<year>/`. Read from the site, so a new edition
/// appears without an app update.
struct CatalogEditions: Codable, Hashable, Sendable {
    static let siteURL = URL(string: "https://catalog.northeastern.edu/")!

    var current: CatalogYear
    /// Newest first.
    var archived: [CatalogYear]
    var fetchedAt: Date
    /// True when made up offline (no copy from the site yet).
    var isEstimated = false

    /// Every edition, newest first.
    var all: [CatalogYear] {
        Array(Set([current] + archived)).sorted(by: >)
    }

    func contains(_ year: CatalogYear) -> Bool {
        year == current || archived.contains(year)
    }

    /// The root of an edition: the site root for the current edition, else its archive.
    func baseURL(for year: CatalogYear) -> URL {
        year == current ? Self.siteURL : Self.siteURL.appendingPathComponent("archive/\(year.slug)/", isDirectory: true)
    }

    /// A page of an edition from its edition-relative path.
    func url(for year: CatalogYear, path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: trimmed, relativeTo: baseURL(for: year))?.absoluteURL ?? baseURL(for: year)
    }

    /// A guess used before the site has been reached: the edition for today, and every
    /// edition back to 2016–2017 (the oldest archived online).
    static func estimated(now: Date = .now) -> CatalogEditions {
        let current = CatalogYear.containing(now)
        let archived = stride(from: current.startYear - 1, through: 2016, by: -1).map(CatalogYear.init(startYear:))
        return CatalogEditions(current: current, archived: archived, fetchedAt: .distantPast, isEstimated: true)
    }
}

// MARK: - Programs

/// A degree program page in a catalog edition.
struct CatalogProgram: Codable, Hashable, Sendable, Identifiable {
    enum Level: String, Codable, Sendable {
        case undergraduate, graduate, other
    }

    /// `Computer Science, BSCS (Boston)`.
    var title: String
    /// The page's path within its edition, without any archive prefix:
    /// `undergraduate/computer-information-science/computer-science/bscs/`.
    var path: String

    var id: String { path }

    var level: Level {
        if path.hasPrefix("undergraduate/") { return .undergraduate }
        if path.hasPrefix("graduate/") { return .graduate }
        return .other
    }

    private var titleParts: (name: String, degree: String?, campus: String?) {
        guard let match = title.wholeMatch(of: #/(.+?),\s*([A-Za-z][A-Za-z.]{1,9})(?:\s*\(([^)]+)\))?\s*/#) else {
            return (title, nil, nil)
        }
        return (String(match.1), String(match.2), match.3.map(String.init))
    }

    /// `Computer Science`.
    var name: String { titleParts.name }
    /// `BSCS`.
    var degree: String? { titleParts.degree }
    /// `Boston`, for editions that list programs per campus.
    var campus: String? { titleParts.campus }
    /// The title without the campus: `Computer Science, BSCS`.
    var titleWithoutCampus: String {
        degree.map { "\(name), \($0)" } ?? title
    }
}

// MARK: - Requirements

/// The "Program Requirements" of a program page.
/// The minimums every bachelor's degree of a catalog edition has, from its "Universitywide
/// Requirements" page: "Minimum 128 total semester hours required", "Minimum 2.000 GPA
/// required", "Students must earn a minimum of 64 Northeastern University semester hours…".
struct UniversitywideRequirements: Codable, Hashable, Sendable {
    var totalHours: Double?
    var gpa: Double?
    /// Semester hours that must be earned at Northeastern (residency).
    var residencyHours: Double?
    /// "…including the experiential learning graduation requirement" (newer editions).
    var requiresExperientialLearning = false
    var fetchedAt: Date
}

struct ProgramRequirements: Codable, Hashable, Sendable {
    var year: CatalogYear
    var program: CatalogProgram
    /// Sections in page order; concentrations are marked with `isConcentration`.
    var sections: [RequirementSection]
    /// `134` from "134 total semester hours required".
    var totalHours: Double?
    var fetchedAt: Date
    /// The catalog's titles for the courses it lists (`CS 3000` → `Algorithms and Data`).
    var courseTitles: [CourseKey: String] = [:]
    /// The edition's universitywide minimums, from its "Universitywide Requirements" page; nil
    /// when that page couldn't be read.
    var universitywide: UniversitywideRequirements?

    var concentrations: [RequirementSection] { sections.filter(\.isConcentration) }

    /// The sections that apply: everything but the concentrations, plus the chosen one.
    func applicableSections(concentrationID: String?) -> [RequirementSection] {
        sections.filter { !$0.isConcentration || $0.id == concentrationID }
    }

    var allRules: [RequirementRule] {
        sections.flatMap { $0.groups.flatMap(\.rules) }
    }

    func rule(id: String) -> RequirementRule? {
        allRules.first { $0.id == id }
    }

    /// A readable name for a rule: its group's title when the group has only that rule
    /// (`Science Requirement`), else the rule's own label.
    func title(ofRule id: String) -> String? {
        for section in sections {
            for group in section.groups {
                guard let rule = group.rules.first(where: { $0.id == id }) else { continue }
                if group.rules.count == 1, let title = group.title ?? (section.isConcentration ? section.title : nil) {
                    return title
                }
                return rule.displayLabel
            }
        }
        return nil
    }
}

struct RequirementSection: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// e.g. `Computer Science Requirements`, `Concentration in Software`.
    var title: String
    /// One of several concentrations; a student completes one.
    var isConcentration: Bool
    var groups: [RequirementGroup]
    /// Paragraphs under the heading, e.g. "Minimum 2.000 GPA required in all CS … courses".
    var notes: [String]

    /// `Software` from `Concentration in Software`, `Concentration: Software` or
    /// `Software Concentration`.
    var concentrationName: String {
        title.replacingOccurrences(of: #"^(Concentration|Track|Option|Pathway)(\s+in\s+|\s*:\s*)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(Concentration|Track|Option|Pathway)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: "* "))
    }
}

struct RequirementGroup: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// The area header, e.g. `Computer Science Required Courses`; nil when the table has none.
    var title: String?
    var rules: [RequirementRule]
    var notes: [String]
}

struct RequirementRule: Codable, Hashable, Sendable, Identifiable {
    enum Kind: Codable, Hashable, Sendable {
        /// One option: a course, a course set taken together, or alternatives.
        case required(CourseOption)
        /// `count` options, or `hours` semester hours, from `options` and `ranges`.
        case choose(count: Int?, hours: Double?, options: [CourseOption], ranges: [CourseRange])
        /// Any courses not used for another requirement.
        case generalElectives(hours: Double)
    }

    var id: String
    var kind: Kind
    /// The catalog's wording: `CS 3000`, `CS 4500 or CS 4530`, `Complete one of the following:`.
    var label: String
    /// The hours column (`4`; `8-9` is read as 8).
    var hours: Double?
    /// Notes under the rule, including category subheaders (`Biology`, `Chemistry`).
    var notes: [String]
    /// For "complete N of the following" lists with category subheaders: the category of each
    /// option, in option order (`Biology`, `Biology`, `Chemistry`…). Nil when the list has none.
    var optionCategories: [String?]? = nil

    /// The label without a trailing colon.
    var displayLabel: String {
        label.hasSuffix(":") ? String(label.dropLast()) : label
    }

    /// Every course the rule names (not the ones its ranges cover).
    var listedCourses: [CourseKey] {
        switch kind {
        case .required(let option): option.allCourses
        case .choose(_, _, let options, _): options.flatMap(\.allCourses)
        case .generalElectives: []
        }
    }
}

/// An item that can be satisfied one of several ways; each way is a set of courses taken
/// together: `[[CS 1800, CS 1802]]`, `[[CS 4500], [CS 4530]]`.
struct CourseOption: Codable, Hashable, Sendable {
    var alternatives: [[CourseKey]]

    var allCourses: [CourseKey] {
        var seen = Set<CourseKey>()
        return alternatives.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// `CS 1800 and CS 1802`, `CS 4500 or CS 4530`.
    var label: String {
        alternatives.map { $0.map(\.description).joined(separator: " and ") }.joined(separator: " or ")
    }
}

/// A range of course numbers: `CS 2500 or higher, except CS 5010`.
struct CourseRange: Codable, Hashable, Sendable {
    var subject: String
    var lowest: Int
    var highest: Int?
    var except: [CourseKey]
    /// The catalog's wording.
    var label: String

    func contains(_ key: CourseKey) -> Bool {
        guard key.subject == subject, !except.contains(key),
              let number = Int(key.number.prefix { $0.isNumber }), key.number.prefix(while: \.isNumber).count == 4 else { return false }
        return number >= lowest && (highest.map { number <= $0 } ?? true)
    }
}

extension ProgramRequirements {
    /// Tolerant decoding: copies saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decode(CatalogYear.self, forKey: .year)
        program = try c.decode(CatalogProgram.self, forKey: .program)
        sections = try c.decode([RequirementSection].self, forKey: .sections)
        totalHours = try c.decodeIfPresent(Double.self, forKey: .totalHours)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        courseTitles = (try? c.decodeIfPresent([CourseKey: String].self, forKey: .courseTitles)) ?? [:]
    }
}
