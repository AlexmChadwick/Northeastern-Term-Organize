//
//  DegreeSubstitutionSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A substitution to add or edit, for one requirement.
struct DegreeSubstitutionRequest: Identifiable {
    enum Kind: String, CaseIterable, Hashable {
        case countCourse, replace, waive

        init(_ change: RequirementSubstitution.Change) {
            switch change {
            case .countCourse: self = .countCourse
            case .replace: self = .replace
            case .waive: self = .waive
            }
        }
    }

    var planID: UUID
    var ruleID: String
    /// The requirement's name, saved with a new substitution.
    var ruleTitle: String
    var existing: RequirementSubstitution?
    var kind: Kind
    /// The course a new "count a course" substitution starts with (a course the audit found
    /// nearly fits, say).
    var course: CourseKey?

    init(planID: UUID, ruleID: String, ruleTitle: String, existing: RequirementSubstitution? = nil, kind: Kind? = nil, course: CourseKey? = nil) {
        self.planID = planID
        self.ruleID = ruleID
        self.ruleTitle = ruleTitle
        self.existing = existing
        self.kind = kind ?? existing.map { Kind($0.change) } ?? .countCourse
        self.course = course
    }

    var id: String { existing.map { "edit-\($0.id)" } ?? "new-\(ruleID)-\(kind.rawValue)\(course.map { "-\($0)" } ?? "")" }
}

extension DegreeSubstitutionRequest {
    /// What a petition starts with: as many courses (or semester hours) as the requirement asks
    /// for, by default four credits a course.
    static func initialAmount(rule: RequirementRule?) -> (count: Int, hours: Double, inHours: Bool) {
        switch rule?.kind {
        case .choose(let count, let hours, _, _)?:
            if let count { return (max(1, count), hours ?? Double(count * 4), false) }
            if let hours { return (max(1, Int(hours / 4)), hours, true) }
        case .required(let option)?:
            let courses = max(1, option.alternatives.first?.count ?? 1)
            return (courses, rule?.hours ?? Double(courses * 4), false)
        case .generalElectives(let hours)?:
            return (max(1, Int(hours / 4)), hours, true)
        case nil:
            break
        }
        return (1, 4, false)
    }
}

/// What the substitution form decides, apart from how it looks: what can be saved, what the
/// change is, and how a course of the plan is described next to the requirement.
enum DegreeSubstitutionEditing {
    /// Whether the form has what the chosen kind of change needs. A petition taking courses like
    /// a requirement with a minimum course number (`needsCourseNumbers`) must say which numbers
    /// count.
    static func canSave(kind: DegreeSubstitutionRequest.Kind, course: CourseKey?, likeRuleID: String?, specificCourses: Set<CourseKey>,
                        needsCourseNumbers: Bool = false, courseNumbers: CourseNumberLimit? = nil) -> Bool {
        switch kind {
        case .countCourse: course != nil
        case .replace: (likeRuleID != nil || !specificCourses.isEmpty) && (!needsCourseNumbers || likeRuleID == nil || courseNumbers != nil)
        case .waive: true
        }
    }

    /// Whether a petition taking courses like `likeRuleID` has to say which course numbers count:
    /// that requirement's ranges start at a minimum (`CS 2500 or higher`).
    static func needsCourseNumbers(likeRuleID: String?, requirements: ProgramRequirements?) -> Bool {
        guard let likeRuleID, let requirements else { return false }
        return RequirementReplacement(likeRuleID: likeRuleID).asksForCourseNumbers(in: requirements)
    }

    /// The ranges of the requirement a petition takes courses like, as the catalog lists them.
    static func likeRanges(likeRuleID: String?, requirements: ProgramRequirements?) -> [CourseRange] {
        guard let likeRuleID, let requirements else { return [] }
        return RequirementReplacement(likeRuleID: likeRuleID).likeRanges(in: requirements)
    }

    /// A requirement's name as a source of "courses like…": `Khoury Elective Courses`.
    static func sourceName(of rule: RequirementRule, requirements: ProgramRequirements?) -> String {
        rule.degreeIsGeneralElectives ? "General electives (any course)" : (requirements?.degreeShortName(ofRule: rule.id) ?? rule.displayLabel)
    }

    /// The change the form describes; nil while it is incomplete.
    static func change(
        kind: DegreeSubstitutionRequest.Kind,
        course: CourseKey?,
        amountInHours: Bool,
        count: Int,
        hours: Double,
        likeRuleID: String?,
        specificCourses: Set<CourseKey>,
        courseNumbers: CourseNumberLimit? = nil,
        requirements: ProgramRequirements?,
        ruleTitle: String
    ) -> RequirementSubstitution.Change? {
        switch kind {
        case .countCourse:
            guard let course else { return nil }
            return .countCourse(course)
        case .replace:
            return .replace(RequirementReplacement(
                count: amountInHours ? nil : count,
                hours: amountInHours ? hours : nil,
                likeRuleID: likeRuleID,
                likeRuleTitle: likeRuleID.map { id in requirements?.rule(id: id).map { sourceName(of: $0, requirements: requirements) } ?? ruleTitle },
                courses: specificCourses.sorted(),
                courseNumbers: needsCourseNumbers(likeRuleID: likeRuleID, requirements: requirements) ? courseNumbers : nil
            ))
        case .waive:
            return .waive
        }
    }

    /// The substitution to store: the one being edited with its change, note and approval date
    /// updated, or a new one.
    static func substitution(for request: DegreeSubstitutionRequest, change: RequirementSubstitution.Change,
                             note: String, approvedOn: Date?) -> RequirementSubstitution {
        var substitution = request.existing ?? RequirementSubstitution(ruleID: request.ruleID, ruleTitle: request.ruleTitle, change: change)
        // One saved under another catalog year now belongs to the requirement it was opened for.
        substitution.ruleID = request.ruleID
        substitution.change = change
        substitution.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        substitution.approvedOn = approvedOn
        return substitution
    }

    /// The equivalence a "count a course" substitution amounts to when its course is the
    /// required course under a new number (CS 3484 for IS 4800): the requirement names exactly one
    /// course. Nil for anything else.
    static func renumbering(for substitution: RequirementSubstitution, requirements: ProgramRequirements?) -> CourseEquivalence? {
        guard case .countCourse(let course) = substitution.change,
              let rule = requirements?.degreeRule(id: substitution.ruleID, named: substitution.ruleTitle),
              case .required(let option) = rule.kind, option.alternatives.count == 1,
              let named = option.alternatives.first, named.count == 1, named[0] != course else { return nil }
        return CourseEquivalence(course: course, countsAs: named[0], note: "Renumbered")
    }

    /// Turns a substitution into the equivalence it amounts to: the course then counts as the
    /// other everywhere (prerequisites included), shown like any renumbered course.
    static func convertToEquivalence(_ substitution: RequirementSubstitution, requirements: ProgramRequirements?, in plan: inout DegreePlan) {
        guard let equivalence = renumbering(for: substitution, requirements: requirements) else { return }
        plan.substitutions.removeAll { $0.id == substitution.id }
        _ = plan.declareEquivalence(course: equivalence.course, countsAs: equivalence.countsAs, note: equivalence.note)
    }

    /// A substitution that is most likely a renumbering, to offer turning it into one.
    struct LikelyRenumbering: Identifiable, Hashable, Sendable {
        var substitution: RequirementSubstitution
        /// The course the plan has (CS 3484) and the retired course the requirement names (IS 4800).
        var course: CourseKey
        var countsAs: CourseKey

        var id: UUID { substitution.id }
        /// "Is CS 3484 the new number of IS 4800?"
        var question: String { "Is \(course) the new number of \(countsAs)?" }
        var explanation: String {
            "\(countsAs) isn’t offered anymore. If \(course) is the same course under a new number, it counts as \(countsAs) everywhere, prerequisites included, like other renumbered courses."
        }
    }

    /// The plan's substitutions that count a course for a requirement naming one course that
    /// has been retired since: most likely the same course under a new number. Substitutions
    /// whose course doesn't look retired are left alone (any can still be converted by hand).
    ///
    /// - Parameter isRetired: whether a course is no longer in the newest catalog; nil when that
    ///   isn't known (yet).
    static func likelyRenumberings(in plan: DegreePlan, requirements: ProgramRequirements?, isRetired: (CourseKey) -> Bool?) -> [LikelyRenumbering] {
        plan.substitutions.compactMap { substitution in
            guard let equivalence = renumbering(for: substitution, requirements: requirements),
                  isRetired(equivalence.countsAs) == true, isRetired(equivalence.course) != true,
                  !plan.declaredEquivalences.areEquivalent(equivalence.course, equivalence.countsAs) else { return nil }
            return LikelyRenumbering(substitution: substitution, course: equivalence.course, countsAs: equivalence.countsAs)
        }
    }

    /// Stores a substitution in a plan: replaces the one with the same id, else adds it.
    static func store(_ substitution: RequirementSubstitution, in plan: inout DegreePlan) {
        if let index = plan.substitutions.firstIndex(where: { $0.id == substitution.id }) {
            plan.substitutions[index] = substitution
        } else {
            plan.substitutions.append(substitution)
        }
    }

    /// Whether choosing a course for the requirement takes nothing from another one: the audit
    /// counts it nowhere, here, or only as a general elective.
    static func isFree(countingRuleID: String?, ruleID: String, requirements: ProgramRequirements?) -> Bool {
        guard let countingRuleID else { return true }
        return countingRuleID == ruleID || requirements?.rule(id: countingRuleID)?.degreeIsGeneralElectives == true
    }

    /// Where the audit counts a course of the plan, beside the requirement being changed.
    static func caption(for choice: DegreePlanCourseChoice, countingRuleID: String?, ruleID: String, requirements: ProgramRequirements?) -> String? {
        guard let countingRuleID else { return nil }
        if countingRuleID == ruleID { return "Counts toward this requirement" }
        if requirements?.rule(id: countingRuleID)?.degreeIsGeneralElectives == true { return "Now a general elective" }
        return "Counts toward \(requirements?.degreeCountingName(ofRule: countingRuleID, for: choice.key) ?? "another requirement")"
    }

    /// The plan's courses that match what was typed in a picker's search field, by code or title.
    static func matching(_ choices: [DegreePlanCourseChoice], query: String) -> [DegreePlanCourseChoice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        let compact = query.replacingOccurrences(of: " ", with: "")
        return choices.filter {
            $0.key.description.localizedCaseInsensitiveContains(query)
                || "\($0.key.subject)\($0.key.number)".localizedCaseInsensitiveContains(compact)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }
}
