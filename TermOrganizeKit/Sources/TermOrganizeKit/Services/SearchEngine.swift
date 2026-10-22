//
//  SearchEngine.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  An on-device replacement for the hosted search used by SearchNEU. Like
//  SearchNEU's MiniSearch setup it boosts course codes over titles, matches
//  word prefixes, tolerates small typos and requires every query word to
//  match; it additionally searches instructors and descriptions.
//

import Foundation

// MARK: - Query

enum SearchSort: String, CaseIterable, Codable, Identifiable, Sendable {
    case relevance, courseNumber, title, openSeats

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relevance: "Best Match"
        case .courseNumber: "Course Number"
        case .title: "Title"
        case .openSeats: "Most Open Seats"
        }
    }

    var symbol: String {
        switch self {
        case .relevance: "sparkle.magnifyingglass"
        case .courseNumber: "number"
        case .title: "textformat"
        case .openSeats: "chair.lounge"
        }
    }
}

/// Undergrad is a course number below 5000. Grad is 5000 and above.
enum DegreeLevelFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case all, undergrad, grad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .undergrad: "Undergrad"
        case .grad: "Grad"
        }
    }

    func matches(_ key: CourseKey) -> Bool {
        switch self {
        case .all: true
        case .undergrad: key.numericValue < 5000
        case .grad: key.numericValue >= 5000
        }
    }
}

enum InstructionFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    case any, inPerson, online
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Any"
        case .inPerson: "In Person"
        case .online: "Online"
        }
    }
}

/// Filters applied to search results. Course-level filters (subject, NUpath,
/// level, credits, no prerequisites, no corequisites) apply to the course; the
/// rest require at least one section that satisfies all of them.
struct SearchFilters: Hashable, Codable, Sendable {
    var subjects: Set<String> = []
    var nupaths: Set<NUPath> = []
    /// Course levels, e.g. 1 for 1000-level.
    var levels: Set<Int> = []
    var minCredits: Double?
    var maxCredits: Double?
    /// Keep a course only when its fetched catalog entry lists no prerequisites.
    /// A stub whose requisites were never loaded is left out.
    var noPrerequisites = false
    /// Keep a course only when its fetched catalog entry lists no corequisites.
    /// A stub whose requisites were never loaded is left out.
    var noCorequisites = false
    /// Nil and `.all` both mean every course. Optional so filters saved before
    /// the control existed still decode.
    var degreeLevel: DegreeLevelFilter? = nil

    var campuses: Set<String> = []
    var classTypes: Set<String> = []
    var honorsOnly = false
    var openSeatsOnly = false
    var instruction: InstructionFilter = .any
    /// When set, sections must meet only on these days.
    var allowedDays: DaySet?
    /// Minutes after midnight.
    var startsAfter: Int?
    /// Minutes after midnight.
    var endsBefore: Int?

    var isEmpty: Bool { activeCount == 0 }

    var activeCount: Int {
        var n = 0
        if !subjects.isEmpty { n += 1 }
        if !nupaths.isEmpty { n += 1 }
        if !levels.isEmpty { n += 1 }
        if minCredits != nil || maxCredits != nil { n += 1 }
        if noPrerequisites { n += 1 }
        if noCorequisites { n += 1 }
        if let degreeLevel, degreeLevel != .all { n += 1 }
        if !campuses.isEmpty { n += 1 }
        if !classTypes.isEmpty { n += 1 }
        if honorsOnly { n += 1 }
        if openSeatsOnly { n += 1 }
        if instruction != .any { n += 1 }
        if allowedDays != nil { n += 1 }
        if startsAfter != nil || endsBefore != nil { n += 1 }
        return n
    }

    var hasSectionFilters: Bool {
        !campuses.isEmpty || !classTypes.isEmpty || honorsOnly || openSeatsOnly || instruction != .any
            || allowedDays != nil || startsAfter != nil || endsBefore != nil
    }

    func matches(course: Course) -> Bool {
        if !subjects.isEmpty, !subjects.contains(course.subject) { return false }
        if !nupaths.isEmpty {
            let attrs = Set(course.attributes)
            if !nupaths.allSatisfy({ attrs.contains($0.attributeCode) }) { return false }
        }
        if !levels.isEmpty {
            guard let level = course.key.level, levels.contains(level) else { return false }
        }
        if let minCredits, course.maxCredits < minCredits { return false }
        if let maxCredits, course.minCredits > maxCredits { return false }
        if noPrerequisites, !course.listsNoPrerequisites { return false }
        if noCorequisites, !course.listsNoCorequisites { return false }
        if let degreeLevel, !degreeLevel.matches(course.key) { return false }
        return true
    }

    func matches(section s: CourseSection) -> Bool {
        if !campuses.isEmpty, !campuses.contains(s.campus) { return false }
        if !classTypes.isEmpty, !classTypes.contains(s.classType) { return false }
        if honorsOnly, !s.honors { return false }
        if openSeatsOnly, !s.isOpen { return false }
        switch instruction {
        case .any: break
        case .online: if !s.isOnline { return false }
        case .inPerson: if s.isOnline { return false }
        }
        let weekly = s.weeklyMeetings
        if let allowedDays {
            for m in weekly where !m.days.isSubset(of: allowedDays) { return false }
        }
        if let startsAfter {
            for m in weekly where (m.start ?? 0) < startsAfter { return false }
        }
        if let endsBefore {
            for m in weekly where (m.end ?? 0) > endsBefore { return false }
        }
        return true
    }
}

struct SearchQuery: Hashable, Sendable {
    var text = ""
    var filters = SearchFilters()
    var sort = SearchSort.relevance
}

// MARK: - Results

struct SearchResult: Identifiable, Hashable, Sendable {
    var course: Course
    var stats: CourseStats
    var score: Double
    /// Why the course matched, when it was not obvious from the title (e.g.
    /// "Taught by Jane Doe" or "Mentions “robotics”").
    var matchNote: String?
    var id: CourseKey { course.key }
}

struct SearchResponse: Sendable {
    var results: [SearchResult] = []
    /// A section whose CRN exactly matches the query.
    var crnMatch: CourseSection?
    /// Instructors whose names match every query word.
    var instructors: [InstructorSummary] = []
    /// Subjects whose code or name matches the query.
    var subjects: [Subject] = []
    var totalCount: Int { results.count }
}

// MARK: - Documents

/// Precomputed, normalized text for a course.
struct SearchDocument: Sendable {
    let key: CourseKey
    let subjectLower: String
    let numberLower: String
    let titleNormalized: String
    let titleWords: [String]
    let subjectWords: [String]
    let instructorWords: [String]
    let instructorNames: [String]
    let descriptionWords: Set<String>
    let topicWords: [String]
    let nupathShorts: Set<String>

    init(course: Course, subjectName: String, instructorNames: [String], sectionTitles: [String]) {
        key = course.key
        subjectLower = course.subject.lowercased()
        numberLower = course.number.lowercased()
        titleNormalized = SearchText.normalize(course.title)
        titleWords = SearchText.words(course.title)
        subjectWords = SearchText.words(subjectName)
        self.instructorNames = instructorNames
        instructorWords = instructorNames.flatMap(SearchText.words)
        descriptionWords = Set(SearchText.words(course.description).filter { $0.count >= 3 })
        topicWords = sectionTitles.flatMap(SearchText.words)
        nupathShorts = Set(course.nupaths.map { $0.short.lowercased() })
    }
}

enum SearchText {
    /// Lowercases, strips diacritics and replaces punctuation with spaces.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if ch == "&" {
                if !lastWasSpace { out.append(" ") }
                out.append("and ")
                lastWasSpace = true
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static let stopWords: Set<String> = ["and", "of", "the", "to", "in", "for", "a", "an", "with", "on", "at", "intro", "introduction"]

    /// Student shorthand expanded before matching (whole words only).
    static let aliases: [String: String] = [
        "orgo": "organic chemistry", "ochem": "organic chemistry", "linalg": "linear algebra",
        "diffeq": "differential equations", "diffeqs": "differential equations", "stats": "statistics",
        "stat": "statistics", "econ": "economics", "psych": "psychology", "chem": "chemistry",
        "ml": "machine learning", "ai": "artificial intelligence", "hci": "human computer interaction",
        "ood": "object oriented", "algo": "algorithms", "algos": "algorithms", "swe": "software engineering",
        "nlp": "natural language processing", "db": "databases", "dbs": "databases", "fundies": "program design",
        "compsci": "computer science", "cs1": "program design implementation 1", "discrete": "discrete",
        "theory": "theory", "calc": "calculus", "bio": "biology", "phys": "physics", "intl": "international",
        "mgmt": "management", "acct": "accounting", "mktg": "marketing", "philo": "philosophy", "poli": "political",
        "polisci": "political science", "comm": "communication", "comms": "communication", "lab": "lab",
    ]

    /// Applies `aliases` to a normalized query, leaving subject codes untouched.
    static func expandAliases(_ normalized: String, subjectCodes: Set<String>) -> String {
        normalized.split(separator: " ").map { word in
            let w = String(word)
            if subjectCodes.contains(w.uppercased()) { return w }
            return aliases[w] ?? w
        }.joined(separator: " ")
    }

    static func words(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    /// Damerau-free Levenshtein distance capped at `limit` (returns limit + 1 when exceeded).
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                rowMin = min(rowMin, curr[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}

// MARK: - Engine

enum SearchEngine {
    static func search(_ query: SearchQuery, in index: CatalogIndex) -> SearchResponse {
        var response = SearchResponse()
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = query.filters

        func passesFilters(_ course: Course) -> Bool {
            guard filters.matches(course: course) else { return false }
            guard filters.hasSectionFilters else { return true }
            return index.sections(for: course.key).contains { filters.matches(section: $0) }
        }

        /// Availability shown on a row: over the sections that satisfy the section
        /// filters when any are active (so "Online" shows online seats only).
        func stats(for course: Course) -> CourseStats {
            guard filters.hasSectionFilters else { return index.stats(for: course.key) }
            return CatalogIndex.makeStats(index.sections(for: course.key).filter { filters.matches(section: $0) })
        }

        // CRN lookup.
        if text.count == 5, text.allSatisfy(\.isNumber), let section = index.section(crn: text) {
            response.crnMatch = section
        }

        var scored: [SearchResult] = []
        if text.isEmpty {
            scored = index.courses.compactMap { course in
                guard passesFilters(course) else { return nil }
                return SearchResult(course: course, stats: stats(for: course), score: 0)
            }
            response.results = sort(scored, by: query.sort == .relevance ? .courseNumber : query.sort)
            return response
        }

        let rawNormalized = SearchText.normalize(text)
        let normalized = SearchText.expandAliases(rawNormalized, subjectCodes: Set(index.subjectsByCode.keys))
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return response }

        // Subjects matching the whole query ("cs", "computer science").
        response.subjects = index.activeSubjects.filter { subject in
            let name = SearchText.normalize(subject.name)
            return subject.code.lowercased() == rawNormalized || name == rawNormalized || name == normalized
                || (rawNormalized.count >= 4 && name.hasPrefix(rawNormalized))
        }

        // Instructors matching every token.
        let rawTokens = rawNormalized.split(separator: " ").map(String.init)
        if rawTokens.allSatisfy({ $0.count >= 2 }), !rawTokens.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            response.instructors = index.instructors.filter { instructor in
                let words = SearchText.words(instructor.displayName)
                return rawTokens.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
            }
            .prefix(8).map { $0 }
        }

        let code = parseCourseCode(rawNormalized, subjects: index.subjectsByCode)

        for doc in index.searchDocuments {
            guard let course = index.course(doc.key) else { continue }
            var score: Double
            var note: String?

            if let code {
                guard doc.subjectLower == code.subject else { continue }
                if code.number.isEmpty {
                    score = 600 - Double(doc.key.numericValue) / 100
                } else if doc.numberLower == code.number {
                    score = 2000
                } else if doc.numberLower.hasPrefix(code.number) {
                    score = 1200 - Double(doc.numberLower.count - code.number.count)
                } else {
                    continue
                }
            } else {
                guard let match = scoreTokens(tokens, phrase: normalized, doc: doc) else { continue }
                score = match.score
                note = match.note
            }

            guard passesFilters(course) else { continue }
            scored.append(SearchResult(course: course, stats: stats(for: course), score: score, matchNote: note))
        }

        response.results = sort(scored, by: query.sort)
        return response
    }

    /// Recognizes `cs`, `cs3`, `cs 3000`, `cs3000` (subject must exist).
    private static func parseCourseCode(_ normalized: String, subjects: [String: Subject]) -> (subject: String, number: String)? {
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let letters = compact.prefix { $0.isLetter }
        let rest = compact.dropFirst(letters.count)
        guard letters.count >= 2, letters.count <= 5, subjects[letters.uppercased()] != nil else { return nil }
        guard rest.allSatisfy({ $0.isNumber || $0.isLetter }), rest.count <= 4 else { return nil }
        if rest.isEmpty {
            // Only treat a bare subject code as a code query when it's the whole query.
            return normalized == String(letters) ? (String(letters), "") : nil
        }
        guard rest.first?.isNumber == true else { return nil }
        return (String(letters), String(rest))
    }

    private static func scoreTokens(_ tokens: [String], phrase: String, doc: SearchDocument) -> (score: Double, note: String?)? {
        var total: Double = 0
        var titleHits = 0
        var note: String?

        let meaningful = tokens.filter { !SearchText.stopWords.contains($0) }
        let wantsIntro = tokens.contains { $0 == "intro" || $0 == "introduction" || $0 == "introductory" }
        for token in (meaningful.isEmpty ? tokens : meaningful) {
            var best: Double = 0
            var bestNote: String?

            if token == doc.subjectLower { best = max(best, 50) }
            if token == doc.numberLower { best = max(best, 60) } else if token.allSatisfy(\.isNumber), doc.numberLower.hasPrefix(token) { best = max(best, 30) }
            if doc.titleWords.contains(token) {
                best = max(best, 40); titleHits += 1
            } else if token.count >= 2, doc.titleWords.contains(where: { $0.hasPrefix(token) }) {
                best = max(best, 28); titleHits += 1
            }
            if doc.subjectWords.contains(where: { $0.hasPrefix(token) }) { best = max(best, token.count >= 3 ? 20 : 8) }
            if doc.nupathShorts.contains(token) { best = max(best, 15) }
            if best == 0, token.count >= 2, doc.topicWords.contains(where: { $0.hasPrefix(token) }) {
                best = 24; bestNote = "Topic match"
            }
            if best == 0, token.count >= 2, doc.instructorWords.contains(where: { $0.hasPrefix(token) }) {
                best = 22
                if let name = doc.instructorNames.first(where: { SearchText.words($0).contains { $0.hasPrefix(token) } }) {
                    bestNote = "Taught by \(name)"
                }
            }
            if best == 0, token.count >= 3, doc.descriptionWords.contains(token) || (token.count >= 5 && doc.descriptionWords.contains(where: { $0.hasPrefix(token) })) {
                best = 6; bestNote = "Description mentions “\(token)”"
            }
            if best == 0, token.count >= 4 {
                let limit = token.count >= 7 ? 2 : 1
                if doc.titleWords.contains(where: { SearchText.editDistance($0, token, limit: limit) <= limit || ($0.count > token.count && SearchText.editDistance(String($0.prefix(token.count)), token, limit: 1) <= 1) }) {
                    best = 12; titleHits += 1
                }
            }

            if best == 0 { return nil }
            total += best
            if note == nil { note = bestNote }
        }

        if doc.titleNormalized == phrase { total += 150 }
        else if doc.titleNormalized.hasPrefix(phrase) { total += 80 }
        else if phrase.count >= 4, doc.titleNormalized.contains(phrase) { total += 50 }
        if titleHits >= max(1, meaningful.count) { total += 25; note = nil }
        if wantsIntro, let level = doc.key.level {
            // "intro …" prefers introductory courses.
            total += level == 1 ? 15 : (level == 2 ? 6 : 0)
        }
        // Prefer introductory courses slightly when scores tie.
        total -= Double(doc.key.numericValue) / 10_000
        return (total, note)
    }

    static func sort(_ results: [SearchResult], by sort: SearchSort) -> [SearchResult] {
        switch sort {
        case .relevance:
            return results.sorted { $0.score != $1.score ? $0.score > $1.score : $0.course.key < $1.course.key }
        case .courseNumber:
            return results.sorted { $0.course.key < $1.course.key }
        case .title:
            return results.sorted { $0.course.title.localizedStandardCompare($1.course.title) == .orderedAscending }
        case .openSeats:
            return results.sorted { $0.stats.seatsRemaining != $1.stats.seatsRemaining ? $0.stats.seatsRemaining > $1.stats.seatsRemaining : $0.course.key < $1.course.key }
        }
    }
}
