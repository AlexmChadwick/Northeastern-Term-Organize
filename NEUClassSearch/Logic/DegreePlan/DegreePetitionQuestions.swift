//
//  DegreePetitionQuestions.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Course-number limits

extension CourseRange {
    /// The range with a petition's course-number limit: unchanged, without its minimum, or with
    /// another minimum. Its maximum and exceptions stay.
    func applying(_ limit: CourseNumberLimit?) -> CourseRange {
        var range = self
        switch limit {
        case nil, .sameAsRequirement?: return self
        case .anyNumber?: range.lowest = 0
        case .atLeast(let minimum)?: range.lowest = minimum
        }
        range.label = range.describedLabel
        return range
    }

    /// `CS 2000 or higher, except CS 5010`, `Any CS course`, `DS courses up to DS 4999, except
    /// DS 4900`, `DS 2000 to DS 4999`.
    var describedLabel: String {
        var text: String
        switch (lowest > 0, highest) {
        case (true, let highest?): text = "\(subject) \(lowest) to \(subject) \(highest)"
        case (true, nil): text = "\(subject) \(lowest) or higher"
        case (false, let highest?): text = "\(subject) courses up to \(subject) \(highest)"
        case (false, nil): text = "Any \(subject) course"
        }
        if !except.isEmpty { text += ", except " + except.map(\.description).joined(separator: ", ") }
        return text
    }

    /// Why `key` isn't in the range, when it's in the range's subject: `Below CS 2500`,
    /// `Above DS 4999`, `CS 5010 is excluded`. Nil when it's in the range or another subject.
    func reasonExcluding(_ key: CourseKey) -> String? {
        guard key.subject == subject, !contains(key) else { return nil }
        if except.contains(key) { return "\(key) is excluded" }
        guard let number = Int(key.number.prefix(while: \.isNumber)) else { return nil }
        if number < lowest { return "Below \(subject) \(lowest)" }
        if let highest, number > highest { return "Above \(subject) \(highest)" }
        return nil
    }
}

extension Array where Element == CourseRange {
    /// `CS, CY, DS or IS`.
    var subjectsText: String {
        var seen = Set<String>()
        let subjects = map(\.subject).filter { seen.insert($0).inserted }
        return ListFormatter.localizedString(byJoining: subjects).replacingOccurrences(of: " and ", with: " or ")
    }

    /// The lowest numbers they start at, e.g. `CS 2500, CY 2000, DS 2500 or IS 2000`; nil when
    /// none has a minimum.
    var minimumsText: String? {
        let minimums = filter { $0.lowest > 0 }.map { "\($0.subject) \($0.lowest)" }
        guard !minimums.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: minimums).replacingOccurrences(of: " and ", with: " or ")
    }
}

extension ProgramRequirements {
    /// A requirement by id, else the one requirement with this name (`Khoury Elective Courses`),
    /// for a substitution saved under another catalog year, where the requirement's id differs.
    func degreeRule(id: String?, named name: String?) -> RequirementRule? {
        if let id, let rule = rule(id: id) { return rule }
        guard let name = name?.lowercased() else { return nil }
        let matches = allRules.filter { rule in
            [degreeShortName(ofRule: rule.id), title(ofRule: rule.id)].contains { $0?.lowercased() == name }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension RequirementReplacement {
    /// The ranges of the requirement it takes courses like, as the catalog lists them; empty when
    /// that requirement has none (a list of courses, or general electives).
    func likeRanges(in requirements: ProgramRequirements) -> [CourseRange] {
        guard let like = requirements.degreeRule(id: likeRuleID, named: likeRuleTitle),
              case .choose(_, _, _, let ranges) = like.kind else { return [] }
        return ranges
    }

    /// Whether the petition has to say which course numbers count: it takes courses like a
    /// requirement whose ranges start at a minimum.
    func asksForCourseNumbers(in requirements: ProgramRequirements) -> Bool {
        likeRanges(in: requirements).contains { $0.lowest > 0 }
    }
}

extension DegreePlan {
    /// Sets which course numbers a petition accepts (nil: not answered).
    mutating func setCourseNumbers(_ limit: CourseNumberLimit?, forSubstitution id: UUID) {
        guard let index = substitutions.firstIndex(where: { $0.id == id }),
              case .replace(var replacement) = substitutions[index].change else { return }
        replacement.courseNumbers = limit
        substitutions[index].change = .replace(replacement)
    }
}

// MARK: - Answers in the petition form

/// The answers a petition form offers for which course numbers count.
enum CourseNumberChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sameAsRequirement, anyNumber, atLeast

    var id: String { rawValue }

    /// The answer a saved limit corresponds to; nil when the petition hasn't answered.
    init?(_ limit: CourseNumberLimit?) {
        switch limit {
        case .sameAsRequirement?: self = .sameAsRequirement
        case .anyNumber?: self = .anyNumber
        case .atLeast?: self = .atLeast
        case nil: return nil
        }
    }

    /// The limit to save; nil when "a different minimum" isn't a course number.
    func limit(minimum: Int) -> CourseNumberLimit? {
        switch self {
        case .sameAsRequirement: .sameAsRequirement
        case .anyNumber: .anyNumber
        case .atLeast: Self.isValidMinimum(minimum) ? .atLeast(minimum) : nil
        }
    }

    static func isValidMinimum(_ minimum: Int) -> Bool { (1...9999).contains(minimum) }

    /// A starting point for "a different minimum": the requirement's lowest minimum rounded
    /// down to the thousand (`2000` for CS 2500 and CY 2000), else the saved one.
    static func suggestedMinimum(for ranges: [CourseRange], saved: CourseNumberLimit?) -> Int {
        if case .atLeast(let minimum)? = saved { return minimum }
        let lowest = ranges.map(\.lowest).filter { $0 > 0 }.min() ?? 2000
        return max(1000, lowest / 1000 * 1000)
    }

    /// `Same as Khoury Elective Courses`, `Any course number`, `A different minimum`.
    func title(likeTitle: String) -> String {
        switch self {
        case .sameAsRequirement: "Same as \(likeTitle)"
        case .anyNumber: "Any course number"
        case .atLeast: "A different minimum"
        }
    }

    /// `CS 2500 or higher · CY 2000 or higher`, `Any CS, CY, DS, or IS course`,
    /// `CS 2000 or higher · CY 2000 or higher`.
    func detail(ranges: [CourseRange], minimum: Int) -> String {
        switch self {
        case .sameAsRequirement: ranges.map(\.label).joined(separator: " · ")
        case .anyNumber: "Any \(ranges.subjectsText) course"
        case .atLeast:
            Self.isValidMinimum(minimum)
                ? ranges.map { $0.applying(.atLeast(minimum)).label }.joined(separator: " · ")
                : "Enter a course number, like 2000"
        }
    }
}

// MARK: - Questions the audit needs answered

/// A petition whose answer changes the audit: it takes courses like a requirement that starts at
/// a minimum course number ("CS 2500 or higher"), the student hasn't said whether that minimum
/// applies, and without it more requirements are met (CS 2386 counts, say).
struct DegreePetitionQuestion: Identifiable, Sendable {
    var substitution: RequirementSubstitution
    /// The requirement the petition replaces (where the audit applied it).
    var ruleID: String
    /// Its name, e.g. `Electrical Engineering`.
    var ruleTitle: String
    /// The requirement it takes courses like, e.g. `Khoury Elective Courses`.
    var likeTitle: String
    /// That requirement's ranges as the catalog lists them.
    var ranges: [CourseRange]
    /// Courses of the plan that count once there's no minimum.
    var courses: [CourseKey]
    /// Requirements met as things are, met with no minimum, and in all.
    var satisfied: Int
    var satisfiedWithoutMinimum: Int
    var total: Int

    var id: UUID { substitution.id }

    /// `Does your Electrical Engineering petition accept any CS, CY, DS or IS course?`
    var question: String {
        "Does your \(ruleTitle) petition accept any \(ranges.subjectsText) course?"
    }

    /// Whether the answer changes how many requirements are met.
    var matters: Bool { satisfiedWithoutMinimum > satisfied }

    /// `Khoury Elective Courses start at CS 2500, CY 2000, DS 2500 or IS 2000. With any number,
    /// CS 2386 counts and every requirement is met.`
    var explanation: String {
        var parts: [String] = []
        if let minimums = ranges.minimumsText { parts.append("\(likeTitle) start at \(minimums).") }
        guard matters else {
            parts.append("Your petition decides whether that minimum applies here.")
            return parts.joined(separator: " ")
        }
        let courseList = ListFormatter.localizedString(byJoining: courses.map(\.description))
        let gained = satisfiedWithoutMinimum - satisfied
        let effect = satisfiedWithoutMinimum >= total
            ? "every requirement is met"
            : "\(gained) more \(gained == 1 ? "requirement is" : "requirements are") met"
        parts.append(courses.isEmpty ? "With any number, \(effect)." : "With any number, \(courseList) \(courses.count == 1 ? "counts" : "count") and \(effect).")
        return parts.joined(separator: " ")
    }
}

enum DegreePetitionQuestions {
    /// The petitions to ask about, in the plan's order: unanswered course-number limits whose
    /// answer changes how many requirements are met.
    static func questions(plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences = .none,
                          audit: DegreeAudit? = nil) -> [DegreePetitionQuestion] {
        let candidates = plan.substitutions.filter { isUnanswered($0, in: requirements) }
        guard !candidates.isEmpty else { return [] }
        let current = audit ?? DegreeAudit.run(plan: plan, requirements: requirements, equivalences: equivalences)
        return candidates.compactMap { substitution in
            question(about: substitution, plan: plan, requirements: requirements, equivalences: equivalences, audit: current)
        }
        .filter(\.matters)
    }

    /// The question about one petition's course numbers, whether or not the answer changes what's
    /// met; nil when the petition has answered, or doesn't need to, or doesn't apply.
    static func question(about substitution: RequirementSubstitution, plan: DegreePlan, requirements: ProgramRequirements,
                         equivalences: CourseEquivalences = .none, audit: DegreeAudit) -> DegreePetitionQuestion? {
        let ruleID = audit.placements[substitution.id] ?? substitution.ruleID
        guard isUnanswered(substitution, in: requirements), case .replace(let replacement) = substitution.change,
              audit.result(for: ruleID) != nil else { return nil }
        var relaxed = plan
        relaxed.setCourseNumbers(.anyNumber, forSubstitution: substitution.id)
        let without = DegreeAudit.run(plan: relaxed, requirements: requirements, equivalences: equivalences, attributes: audit.attributes)
        let ranges = replacement.likeRanges(in: requirements)
        // Courses the petition counts once there's no minimum.
        let newlyCounted = (without.result(for: ruleID)?.used ?? [])
            .map(\.key)
            .filter { key in !ranges.contains { $0.contains(key) } && !replacement.courses.contains(key) }
        return DegreePetitionQuestion(
            substitution: substitution,
            ruleID: ruleID,
            ruleTitle: requirements.title(ofRule: ruleID) ?? substitution.ruleTitle,
            likeTitle: replacement.likeRuleTitle ?? replacement.likeRuleID.flatMap { requirements.title(ofRule: $0) } ?? "That requirement",
            ranges: ranges,
            courses: newlyCounted,
            satisfied: audit.satisfiedCount,
            satisfiedWithoutMinimum: without.satisfiedCount,
            total: audit.totalCount
        )
    }

    /// A petition that takes courses like a requirement with a minimum course number and
    /// hasn't said whether it applies.
    static func isUnanswered(_ substitution: RequirementSubstitution, in requirements: ProgramRequirements) -> Bool {
        guard case .replace(let replacement) = substitution.change else { return false }
        return replacement.courseNumbers == nil && replacement.asksForCourseNumbers(in: requirements)
    }
}

/// Remembers a plan's petition questions until the plan, its requirements or the equivalences
/// change (each question runs the audit again).
@MainActor
final class DegreePetitionQuestionCache {
    private var key: Int?
    private var cached: [DegreePetitionQuestion] = []

    init() {}

    func questions(plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences, audit: DegreeAudit) -> [DegreePetitionQuestion] {
        var hasher = Hasher()
        hasher.combine(plan)
        hasher.combine(requirements.year)
        hasher.combine(requirements.program.path)
        hasher.combine(requirements.fetchedAt)
        hasher.combine(equivalences)
        hasher.combine(audit.attributes)
        let key = hasher.finalize()
        if key != self.key {
            cached = DegreePetitionQuestions.questions(plan: plan, requirements: requirements, equivalences: equivalences, audit: audit)
            self.key = key
        }
        return cached
    }
}

// MARK: - Near misses

extension DegreeAudit {
    /// A course of the plan that counts toward nothing specific but nearly fits a requirement
    /// that's short: it's in one of the requirement's subjects and only its number keeps it out
    /// (CS 2386 for "CS 2500 or higher"). If an adviser approved it, it can be counted there.
    struct NearMiss: Identifiable, Hashable, Sendable {
        var course: CourseUse
        /// The range it falls outside of.
        var range: CourseRange
        /// `Below CS 2500`, `Above DS 4999`, `CS 5010 is excluded`.
        var reason: String

        var id: String { course.id }
    }

    /// For a requirement that's short and has ranges: the plan's general electives and unused
    /// courses that are in one of its subjects but outside its ranges, completed ones first.
    func nearMisses(for ruleID: String) -> [NearMiss] {
        guard let result = result(for: ruleID), !result.status.isSatisfied,
              case .choose(let count, _, _, let ranges)? = result.effectiveKind, !ranges.isEmpty else { return [] }
        let candidates = (generalElectives + unused).filter { $0.credits > 0 && (count == nil || $0.credits >= 2) }
        return candidates.compactMap { use in
            guard !ranges.contains(where: { $0.contains(use.key) }) else { return nil }
            for range in ranges {
                if let reason = range.reasonExcluding(use.key) { return NearMiss(course: use, range: range, reason: reason) }
            }
            return nil
        }
        .sorted { ($0.course.isCompleted ? 0 : 1, $0.course.order) < ($1.course.isCompleted ? 0 : 1, $1.course.order) }
    }
}
