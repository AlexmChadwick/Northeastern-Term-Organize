//
//  CourseTitleMatcher.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Compares course titles, to tell whether two courses may be one course under two numbers.
///
/// A department that renumbers a course often keeps its title ("Human Computer Interaction"
/// became "Principles of Human-Computer Interaction"), and nothing in Banner says which course
/// replaced which. Titles are reduced to the words that say what a course is about, lowercase and
/// singular, without the filler that begins so many of them ("Principles of", "Introduction to"),
/// and two are alike when they share most of those words. Nothing here knows any department.
///
/// It is a hint, not proof: a match is only suggested to the student, who confirms it. So it errs
/// toward saying nothing:
/// - titles with fewer than two telling words ("Seminar", "Directed Study", "Special Topics") are
///   too generic to compare,
/// - courses of a sequence are different courses: "Calculus 1" and "Calculus 2" never match, because
///   their part numbers differ,
/// - so are a course and its lab, or its advanced version: "Sensation and Perception" and
///   "Laboratory in Sensation and Perception" never match.
enum CourseTitleMatcher {
    /// The least similarity that counts as alike: the share of the words in either title that both have.
    static let minimumSimilarity = 0.6

    /// A course title reduced to what tells courses apart.
    struct Title: Hashable, Sendable {
        /// The words that say what the course is about: lowercase, singular, without filler.
        var words: Set<String>
        /// Part numbers ("1", "ii"; roman numerals are read as numbers, so "II" is "2"): the courses
        /// of a sequence differ only by them.
        var parts: Set<String>
        /// Words that make a different course of the same subject: its lab, its advanced version.
        var qualifiers: Set<String>
        /// The last word, when the title is long enough to have been cut off. The degree audit
        /// shortens titles to 30 characters, so "Engin" may stand for "Engineering".
        var cutOffWord: String?

        init(_ text: String) {
            var words = Set<String>()
            var parts = Set<String>()
            var last: String?
            for raw in Self.tokens(of: text) {
                if let part = Self.part(of: raw) {
                    parts.insert(part)
                    last = nil
                    continue
                }
                let word = CourseTitleMatcher.synonyms[Self.singular(raw)] ?? Self.singular(raw)
                guard !CourseTitleMatcher.filler.contains(word) else {
                    last = nil
                    continue
                }
                words.insert(word)
                last = word
            }
            self.words = words
            self.parts = parts
            qualifiers = words.intersection(CourseTitleMatcher.qualifiers)
            // Audit titles are cut at 30 characters: the last word may be a fragment.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            cutOffWord = trimmed.count >= 29 ? last.flatMap { $0.count >= 3 ? $0 : nil } : nil
        }

        /// Whether the title says enough to compare: two or more telling words, not all of them
        /// words every kind of course has ("Directed Study", "Research Seminar").
        var isDistinctive: Bool {
            words.count >= 2 && !words.isSubset(of: CourseTitleMatcher.formats)
        }

        /// Words, lowercased, with diacritics and apostrophes removed; punctuation and spaces separate.
        private static func tokens(of text: String) -> [String] {
            let folded = text
                .replacingOccurrences(of: "&", with: " and ")
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "’", with: "")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            var tokens: [String] = []
            var current = ""
            for character in folded {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { tokens.append(current) }
            return tokens
        }

        /// The number of a course in a sequence: `1` and `2a` as written, `ii` as `2`; nil for a word.
        private static func part(of token: String) -> String? {
            if token.first?.isNumber == true { return token }
            return CourseTitleMatcher.romanNumerals[token].map(String.init)
        }

        /// Systems -> system, studies -> study; words that only look plural are left alone.
        private static func singular(_ word: String) -> String {
            guard word.count > 3 else { return word }
            if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
            if word.hasSuffix("sses") { return String(word.dropLast(2)) }
            if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
                return String(word.dropLast())
            }
            return word
        }
    }

    /// How alike two titles are, from `minimum` to 1; nil when they are not alike.
    ///
    /// They are alike when the words they share make up at least `minimum` of all the words in
    /// them (Jaccard similarity), or when every word of one title is in the other (the score is
    /// then at least `minimum`). Both need two telling words, and titles with different part
    /// numbers never match.
    static func similarity(of a: String, to b: String, minimum: Double = minimumSimilarity) -> Double? {
        similarity(of: Title(a), to: Title(b), minimum: minimum)
    }

    static func similarity(of a: Title, to b: Title, minimum: Double = minimumSimilarity) -> Double? {
        // Courses of a sequence: "Calculus 1" and "Calculus 2" are not one course.
        if !a.parts.isEmpty, !b.parts.isEmpty, a.parts != b.parts { return nil }
        // Nor are a course and its lab, or its advanced version.
        guard a.qualifiers == b.qualifiers else { return nil }

        let aWords = completing(a, from: b.words)
        let bWords = completing(b, from: a.words)
        guard aWords.count >= 2, bWords.count >= 2 else { return nil }
        let shared = aWords.intersection(bWords).count
        guard shared > 0 else { return nil }
        // Words every kind of course has don't make two courses alike ("Directed Study").
        guard !aWords.isSubset(of: formats), !bWords.isSubset(of: formats) else { return nil }

        let score = Double(shared) / Double(aWords.union(bWords).count)
        if score >= minimum { return score }
        // One title's words all appear in the other's ("Cell Biology" in "Cell Biology of Cancer").
        let contained = shared == aWords.count || shared == bWords.count
        return contained ? minimum : nil
    }

    /// A title's words, with a cut-off last word completed from the other title's words
    /// ("Engin" becomes "Engineering" when the other title has it).
    private static func completing(_ title: Title, from other: Set<String>) -> Set<String> {
        guard let cut = title.cutOffWord, !other.contains(cut),
              let full = other.sorted().first(where: { $0.hasPrefix(cut) && $0.count > cut.count }) else { return title.words }
        var words = title.words
        words.remove(cut)
        words.insert(full)
        return words
    }

    /// Words that open or fill many titles without telling courses apart, and the ways Banner
    /// abbreviates them.
    fileprivate static let filler: Set<String> = [
        "a", "an", "and", "as", "at", "by", "for", "from", "in", "into", "of", "on", "or", "the", "to", "with",
        "principle", "introduction", "introductory", "intro", "fundamental", "topic",
        "prncple", "prncpl", "intr", "introd",
    ]

    /// Words that name a kind of course rather than its subject: a title made only of them is generic.
    fileprivate static let formats: Set<String> = [
        "special", "directed", "independent", "study", "research", "thesis", "dissertation", "seminar", "project",
        "practicum", "capstone", "continuation", "experience", "internship", "co", "op", "work", "term", "workshop",
        "lab", "reading", "tutorial", "residency", "preparation",
    ]

    /// Words that, in one title and not the other, make two different courses.
    fileprivate static let qualifiers: Set<String> = ["lab", "recitation", "advanced", "intermediate", "elementary"]

    /// Words written two ways in titles.
    fileprivate static let synonyms: [String: String] = ["laboratory": "lab"]

    fileprivate static let romanNumerals: [String: Int] = [
        "i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10,
    ]
}
