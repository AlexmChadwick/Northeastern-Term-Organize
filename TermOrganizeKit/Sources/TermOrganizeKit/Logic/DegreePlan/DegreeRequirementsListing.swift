//
//  DegreeRequirementsListing.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Which requirements the page shows.
enum DegreeRequirementsFilter: String, CaseIterable, Identifiable {
    case all, remaining, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .remaining: "Remaining"
        case .done: "Done"
        }
    }

    /// Remaining: not complete yet (missing, partly done, or planned). Done: complete or waived.
    func includes(_ status: DegreeAudit.Status) -> Bool {
        switch self {
        case .all: true
        case .remaining: status <= .planned
        case .done: status >= .complete
        }
    }
}

/// One item of a requirement's list, in catalog order: an option of a "complete N of the
/// following" list, or one alternative of a required course ("CS 4500 or CS 4530").
struct DegreeListEntry: Identifiable {
    /// Position in the catalog's list.
    var id: Int
    /// Courses taken together, for each way to satisfy the item.
    var alternatives: [[CourseKey]]
    /// The category subheader that starts here (`Biology`).
    var category: String?

    var courses: [CourseKey] { alternatives.flatMap { $0 } }
}

/// How a requirement is laid out like the academic catalog's page: which items of its list show
/// (a long list keeps the options that matter), where its category subheaders go, and how each
/// course row stands. The iPhone and Mac requirements screens both read it.
enum DegreeRequirementsListing {
    /// Lists longer than this show only the options that matter until expanded.
    static let collapseThreshold = 6
    /// How many other options a collapsed list of an open requirement still shows.
    static let extraOptionsWhenCollapsed = 3

    /// Lists of options, hour requirements, petitions and waivers get a heading row; required
    /// courses are just their course rows, as in the catalog.
    static func hasHeaderRow(_ result: DegreeAudit.RuleResult) -> Bool {
        switch result.effectiveKind {
        case nil, .choose, .generalElectives: true
        case .required: isReplaced(result)
        }
    }

    /// The requirement was replaced by a petition.
    static func isReplaced(_ result: DegreeAudit.RuleResult) -> Bool {
        result.substitutions.contains { if case .replace = $0.change { true } else { false } }
    }

    /// Whether a counted course already has a row: its own, or the row of the listed course it
    /// counts as.
    static func isShown(_ use: DegreeAudit.CourseUse, listed: Set<CourseKey>) -> Bool {
        listed.contains(use.key) || use.satisfies.map(listed.contains) == true
    }

    // MARK: Lists

    /// The items of a list to show. A long list shows the options in the plan (or counted, or with
    /// a suggested equivalence) and, while the requirement is open, a few more, until expanded;
    /// the full list keeps the catalog's category subheaders.
    static func visible(
        _ entries: [DegreeListEntry],
        result: DegreeAudit.RuleResult,
        isExpanded: Bool,
        lookup: DegreeCourseLookup,
        prompts: DegreeEquivalencePrompts
    ) -> (shown: [DegreeListEntry], isLong: Bool, showsCategories: Bool) {
        let isLong = entries.count > collapseThreshold
        let shown = isLong && !isExpanded
            ? collapsed(entries, extra: result.status.isSatisfied ? 0 : extraOptionsWhenCollapsed) {
                isRelevant($0, result: result, lookup: lookup, prompts: prompts)
            }
            : entries
        return (shown, isLong, !isLong || isExpanded)
    }

    /// An entry that a collapsed list keeps: a course of it is in the plan, counts here, or has a
    /// suggested equivalence.
    static func isRelevant(_ entry: DegreeListEntry, result: DegreeAudit.RuleResult, lookup: DegreeCourseLookup,
                           prompts: DegreeEquivalencePrompts) -> Bool {
        entry.courses.contains { key in
            let info = lookup.rowInfo(for: key, in: result)
            return info.isCountedHere || info.status != .notInPlan
                || (!result.status.isSatisfied && prompts.forListed(key) != nil)
        }
    }

    /// The relevant entries and the first `extra` others, in catalog order.
    static func collapsed(_ entries: [DegreeListEntry], extra: Int, isRelevant: (DegreeListEntry) -> Bool) -> [DegreeListEntry] {
        var others = 0
        return entries.filter { entry in
            if isRelevant(entry) { return true }
            guard others < extra else { return false }
            others += 1
            return true
        }
    }

    /// A "complete N of the following" list's options, each category subheader before the first
    /// option of its category: from the catalog (`optionCategories`) when the requirements say,
    /// else placed by `categoryStarts` (requirements saved before they recorded it).
    static func entries(options: [CourseOption], of rule: RequirementRule, subjectName: (String) -> String?) -> [DegreeListEntry] {
        let starts: [Int: String]
        if case .choose(_, _, let own, _) = rule.kind, own == options,
           let categories = rule.optionCategories, categories.count == options.count {
            starts = Dictionary(uniqueKeysWithValues: categories.indices.compactMap { index in
                guard let category = categories[index], index == 0 || categories[index - 1] != category else { return nil }
                return (index, category)
            })
        } else {
            starts = categoryStarts(of: options, categories: rule.degreeCategories, subjectName: subjectName)
        }
        return options.enumerated().map { index, option in
            DegreeListEntry(id: index, alternatives: option.alternatives, category: starts[index])
        }
    }

    /// A required course's alternatives, one entry each.
    static func entries(alternativesOf option: CourseOption) -> [DegreeListEntry] {
        option.alternatives.enumerated().map { index, alternative in
            DegreeListEntry(id: index, alternatives: [alternative])
        }
    }

    /// Where each category subheader goes, by option index. The catalog lists the subheaders in
    /// order, each before its options, but the requirements don't say where; options of one
    /// category share subjects. When each run of options with one subject is one category, the
    /// runs are the categories; otherwise a run starts the next category when its subject's name
    /// shares a word with it (`PHYS`, Physics). Empty when the categories can't be placed.
    static func categoryStarts(of options: [CourseOption], categories: [String], subjectName: (String) -> String?) -> [Int: String] {
        guard let first = categories.first, !options.isEmpty else { return [:] }
        let subjects = options.map { $0.allCourses.first?.subject ?? "" }
        let runs = subjects.indices.filter { $0 == 0 || subjects[$0] != subjects[$0 - 1] }
        if runs.count == categories.count {
            return Dictionary(uniqueKeysWithValues: zip(runs, categories))
        }
        var starts = [0: first]
        var current = 0
        for start in runs.dropFirst() where current + 1 < categories.count {
            let name = subjectName(subjects[start]) ?? subjects[start]
            if sharesWord(name, categories[current + 1]) {
                current += 1
                starts[start] = categories[current]
            }
        }
        return current == categories.count - 1 ? starts : [:]
    }

    /// Whether two names share a word (or one's start: `BIOL` and `Biology`), ignoring short ones.
    static func sharesWord(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 }
        }
        let right = words(b)
        return words(a).contains { left in right.contains { left.hasPrefix($0) || $0.hasPrefix(left) } }
    }

    /// The options and ranges a rule lists in the catalog.
    static func listing(of rule: RequirementRule) -> (options: [CourseOption], ranges: [CourseRange]) {
        switch rule.kind {
        case .required(let option): ([option], [])
        case .choose(_, _, let options, let ranges): (options, ranges)
        case .generalElectives: ([], [])
        }
    }

    // MARK: Rows

    /// How a course row of a requirement stands: what the row shows, and which actions an open
    /// requirement offers on it.
    struct CourseRow {
        var key: CourseKey
        var info: DegreeCourseRowInfo
        /// The caption to show: the substitution's note for a course counted by substitution,
        /// else the lookup's.
        var caption: String?
        var isWaived: Bool
        /// The requirement is still open, so the course can be added, or another one counted.
        var canAct: Bool
        /// Open and the plan doesn't have the course: it may be in the plan under another number.
        var isMissing: Bool
    }

    /// - Parameter counted: a course the requirement counts that it doesn't list.
    static func row(for key: CourseKey, in result: DegreeAudit.RuleResult, lookup: DegreeCourseLookup,
                    counted: DegreeAudit.CourseUse? = nil) -> CourseRow {
        let info = lookup.rowInfo(for: key, in: result, counted: counted)
        // A course counted by substitution says what it counts for (by a name that reads on its
        // own: "CS 4500 or CS 4530", not a list's "Complete one of the following:"), and who
        // approved it.
        let name = lookup.requirements.degreeShortName(ofRule: result.rule.id) ?? result.rule.displayLabel
        let substitutionNote = info.bySubstitution
            ? (["Counts for \(name) by substitution"]
               + [result.substitutions.first { $0.change == .countCourse(counted?.key ?? key) }.flatMap(DegreeRequirementText.substitutionCaption)]
                .compactMap { $0 }).joined(separator: " · ")
            : nil
        let canAct = !result.status.isSatisfied
        return CourseRow(
            key: key,
            info: info,
            caption: info.bySubstitution ? substitutionNote : info.caption,
            isWaived: result.status == .waived,
            canAct: canAct,
            isMissing: canAct && info.status == .notInPlan
        )
    }
}
