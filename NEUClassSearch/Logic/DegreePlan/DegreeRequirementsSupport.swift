//
//  DegreeRequirementsSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Context

/// A plan's degree requirements as the screens need them: whether the plan is set up, what
/// has loaded, the audit, and when the plan finishes the degree. Built from the observable
/// `ProgramCatalogStore`, so views that build one update as requirements load.
struct DegreeRequirementsContext {
    let plan: DegreePlan
    let requirements: ProgramRequirements?
    let state: ProgramCatalogStore.LoadState
    let editions: CatalogEditions
    let audit: DegreeAudit?
    /// When the plan meets every requirement; nil when it doesn't (or isn't checked).
    let milestone: DegreeMilestone?

    /// A catalog year and program are chosen.
    var isSetUp: Bool { plan.requirementsYear != nil && plan.catalogProgramPath != nil }
    var year: CatalogYear? { plan.requirementsYear }

    /// `Computer Science, BSCS`.
    var programTitle: String {
        plan.catalogProgramTitle ?? requirements?.program.titleWithoutCampus ?? "Your program"
    }

    var concentration: RequirementSection? {
        guard let id = plan.concentrationID else { return nil }
        return requirements?.concentrations.first { $0.id == id }
    }

    /// `2023–2024 catalog · Human-Centered Computing`.
    var catalogLine: String {
        var parts: [String] = []
        if let year { parts.append("\(year) catalog") }
        if let concentration { parts.append(concentration.concentrationName) }
        return parts.joined(separator: " · ")
    }

    /// The error to show when nothing could be loaded (a saved copy wins over errors).
    var failure: String? {
        guard requirements == nil, case .failed(let message) = state else { return nil }
        return message
    }

    var isLoading: Bool { isSetUp && requirements == nil && failure == nil }

    /// The program's page in its catalog edition.
    var catalogURL: URL? {
        guard let year, let path = plan.catalogProgramPath else { return nil }
        return editions.url(for: year, path: path)
    }

    var isCurrentEdition: Bool { year == editions.current }

    /// Requirements the plan doesn't cover yet, in catalog order.
    var openResults: [DegreeAudit.RuleResult] {
        audit?.ruleResults.filter { !$0.status.isSatisfied } ?? []
    }

    /// Catalog sentences the app checks that the plan doesn't meet yet (NUpath, hours in the
    /// major…), counted like requirements; inconclusive checks aren't listed.
    var openChecks: [DegreeAudit.NoteCheck] {
        audit?.countedChecks.filter { !$0.status.isSatisfied } ?? []
    }

    /// A name for a requirement that reads on its own ("Counts toward …").
    func name(ofRule id: String, fallback: String) -> String {
        requirements?.degreeShortName(ofRule: id) ?? fallback
    }

    /// `Counts toward Khoury Elective Courses` for a course of the plan (completed when
    /// `semester` is nil). Only the instance the audit counts gets a note: a course listed twice
    /// counts once.
    func requirementNote(for course: DegreePlanCourse, semester: DegreePlanTerm?) -> String? {
        guard let key = course.key, let audit, let requirements,
              let result = audit.ruleCounting(key),
              let use = result.used.first(where: { $0.key == key }),
              use.semester == semester?.name, use.credits == course.credits else { return nil }
        if result.rule.degreeIsGeneralElectives { return "Counts as a general elective" }
        let name = requirements.degreeCountingName(ofRule: result.rule.id, for: key) ?? result.rule.displayLabel
        if use.bySubstitution { return "Counts toward \(name) by substitution" }
        // Counted through an equivalence: `Counts as CS 2100` for a requirement that names the
        // course, `Counts toward Software Concentration as CS 3100` for a list.
        if let required = use.satisfies {
            return result.rule.degreeNamesCourses ? "Counts as \(required)" : "Counts toward \(name) as \(required)"
        }
        return "Counts toward \(name)"
    }
}

extension ProgramCatalogStore {
    /// A plan's requirements, audit and (optionally) finish milestone. Pass a cache to reuse
    /// work across body evaluations; the milestone runs one audit per semester.
    ///
    /// - Parameters:
    ///   - equivalences: which courses count as which (`CourseInfoStore.equivalences(for:)`);
    ///     the plan's declared ones apply either way.
    ///   - attributes: the NUpath attributes of the plan's courses; by default what
    ///     `CourseInfoStore.shared` has found (reading it here keeps the screen up to date).
    func degreeRequirementsContext(for plan: DegreePlan, cache: DegreeRequirementsCache? = nil,
                                   equivalences: CourseEquivalences = .none, attributes: DegreeCourseAttributes? = nil,
                                   includesMilestone: Bool = false) -> DegreeRequirementsContext {
        let requirements = requirements(for: plan)
        let attributes = attributes ?? CourseInfoStore.shared.degreeAttributes(for: plan)
        var audit: DegreeAudit?
        var milestone: DegreeMilestone?
        if let requirements {
            if let cache {
                let results = cache.results(plan: plan, requirements: requirements, equivalences: equivalences,
                                            attributes: attributes, includesMilestone: includesMilestone)
                audit = results.audit
                milestone = results.milestone
            } else {
                audit = DegreeAudit.run(plan: plan, requirements: requirements, equivalences: equivalences, attributes: attributes)
                milestone = includesMilestone
                    ? DegreeMilestone.find(plan: plan, requirements: requirements, equivalences: equivalences, attributes: attributes) : nil
            }
        }
        return DegreeRequirementsContext(
            plan: plan,
            requirements: requirements,
            state: requirementsState(for: plan),
            editions: editions,
            audit: audit,
            milestone: milestone
        )
    }

    /// Requirements already loaded for a program and year (the setup sheet's preview).
    func degreeRequirements(year: CatalogYear, path: String) -> ProgramRequirements? {
        requirementsByKey[Self.key(year: year, path: path)]
    }

    func degreeRequirementsState(year: CatalogYear, path: String) -> LoadState {
        states[Self.key(year: year, path: path)] ?? .idle
    }
}

// MARK: - Milestone

/// When a plan meets every degree requirement: with the completed courses alone, or after a
/// planned semester (later semesters are then optional).
enum DegreeMilestone: Equatable {
    case completed
    case after(termID: UUID, name: String)

    /// Audits the plan with only its completed courses, then adding one semester at a time,
    /// and returns the first point where everything is satisfied: every requirement complete,
    /// planned or waived, the catalog's sentences the app checks (hours in the major, NUpath…)
    /// met, a concentration chosen (when the program has them), and enough total credits (when
    /// the catalog states the total).
    static func find(plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences = .none,
                     attributes: DegreeCourseAttributes = .none) -> DegreeMilestone? {
        var partial = plan
        partial.terms = []
        if isFinished(partial, requirements: requirements, equivalences: equivalences, attributes: attributes) { return .completed }
        for index in plan.terms.indices where !plan.terms[index].courses.isEmpty {
            partial.terms = Array(plan.terms[...index])
            if isFinished(partial, requirements: requirements, equivalences: equivalences, attributes: attributes) {
                return .after(termID: plan.terms[index].id, name: plan.terms[index].shortName)
            }
        }
        return nil
    }

    private static func isFinished(_ plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences,
                                   attributes: DegreeCourseAttributes) -> Bool {
        let audit = DegreeAudit.run(plan: plan, requirements: requirements, equivalences: equivalences, attributes: attributes)
        guard audit.totalCount > 0, !audit.needsConcentration,
              audit.ruleResults.allSatisfy({ $0.status.isSatisfied }),
              audit.countedChecks.allSatisfy({ $0.status.isSatisfied }) else { return false }
        if let required = audit.requiredHours {
            return audit.completedHours + audit.plannedHours >= required
        }
        return true
    }

    var termID: UUID? {
        if case .after(let termID, _) = self { return termID }
        return nil
    }

    /// `On track to finish after Spring 2028` / `All degree requirements complete`.
    var summaryLine: String {
        switch self {
        case .completed: "All degree requirements complete"
        case .after(_, let name): "On track to finish after \(name)"
        }
    }
}

/// Remembers the last audit and milestone for a plan, so a view can show them on every body
/// evaluation without re-running a dozen audits. Keep one in `@State`.
@MainActor
final class DegreeRequirementsCache {
    private struct Key: Equatable {
        var plan: DegreePlan
        var year: CatalogYear
        var path: String
        var fetchedAt: Date
        var concentrationCount: Int
        /// Equivalences found in Banner change the audit too (the plan's own are in `plan`).
        var equivalences: CourseEquivalences
        var attributes: DegreeCourseAttributes
        var universitywide: UniversitywideRequirements?
    }

    private var key: Key?
    private var audit: DegreeAudit?
    private var milestone: DegreeMilestone??

    func results(plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences = .none,
                 attributes: DegreeCourseAttributes = .none, includesMilestone: Bool) -> (audit: DegreeAudit, milestone: DegreeMilestone?) {
        let key = Key(plan: plan, year: requirements.year, path: requirements.program.path,
                      fetchedAt: requirements.fetchedAt, concentrationCount: requirements.concentrations.count,
                      equivalences: equivalences, attributes: attributes, universitywide: requirements.universitywide)
        if key != self.key {
            self.key = key
            audit = nil
            milestone = nil
        }
        let audit = self.audit ?? DegreeAudit.run(plan: plan, requirements: requirements, equivalences: equivalences, attributes: attributes)
        self.audit = audit
        guard includesMilestone else { return (audit, nil) }
        if let milestone { return (audit, milestone) }
        let found = DegreeMilestone.find(plan: plan, requirements: requirements, equivalences: equivalences, attributes: attributes)
        milestone = .some(found)
        return (audit, found)
    }
}

// MARK: - Naming

extension ProgramRequirements {
    /// Where a rule sits.
    func degreeLocation(ofRule id: String) -> (section: RequirementSection, group: RequirementGroup, rule: RequirementRule)? {
        for section in sections {
            for group in section.groups {
                if let rule = group.rules.first(where: { $0.id == id }) { return (section, group, rule) }
            }
        }
        return nil
    }

    /// A name that makes sense on its own, for references from elsewhere: the group's title
    /// (`Science Requirement`), a rule that names its courses (`CS 4500 or CS 4530`), or the
    /// concentration for its lists (`Human-Centered Computing concentration`).
    func degreeShortName(ofRule id: String) -> String? {
        guard let location = degreeLocation(ofRule: id) else { return nil }
        if location.group.rules.count == 1, let title = title(ofRule: id) {
            if location.section.isConcentration, location.group.title == nil, !location.rule.degreeNamesCourses {
                return "\(location.section.concentrationName) concentration"
            }
            return title
        }
        if location.rule.degreeNamesCourses { return location.rule.displayLabel }
        if let groupTitle = location.group.title { return groupTitle }
        if location.section.isConcentration { return "\(location.section.concentrationName) concentration" }
        return location.section.title
    }

    /// The requirement a course counts toward, for `Counts toward …` captions. A requirement
    /// that names the course itself (`CS 3800`, `CS 4500 or CS 4530`) is called by its group
    /// (`Computer Science Required Courses`), else its section, so the caption isn't circular.
    func degreeCountingName(ofRule id: String, for course: CourseKey) -> String? {
        guard let name = degreeShortName(ofRule: id) else { return nil }
        guard name.contains(course.description), let location = degreeLocation(ofRule: id) else { return name }
        if let title = location.group.title { return title }
        return location.section.isConcentration ? "\(location.section.concentrationName) concentration" : location.section.title
    }

    /// The title of a rule's row in the requirements list (the group's title for a group's only
    /// rule, else the rule's own wording).
    func degreeRowTitle(ofRule rule: RequirementRule) -> String {
        title(ofRule: rule.id) ?? rule.displayLabel
    }

    /// Every course the applicable requirements list, once, in catalog order.
    func degreeListedCourses(concentrationID: String?) -> [CourseKey] {
        var seen = Set<CourseKey>()
        return applicableSections(concentrationID: concentrationID)
            .flatMap { $0.groups.flatMap { $0.rules.flatMap(\.listedCourses) } }
            .filter { seen.insert($0).inserted }
    }

    /// Rules a replacement can draw courses "like": lists of options or ranges, and general
    /// electives (any course).
    func degreeReplacementSources(excluding ruleID: String, concentrationID: String?) -> [RequirementRule] {
        applicableSections(concentrationID: concentrationID)
            .flatMap { $0.groups.flatMap(\.rules) }
            .filter { rule in
                guard rule.id != ruleID else { return false }
                switch rule.kind {
                case .choose(_, _, let options, let ranges): return !options.isEmpty || !ranges.isEmpty
                case .generalElectives: return true
                case .required: return false
                }
            }
    }
}

extension RequirementRule {
    /// The label names courses (`CS 3000`, `CS 4500 or CS 4530`) rather than describing a choice.
    var degreeNamesCourses: Bool {
        displayLabel.firstMatch(of: #/^[A-Z]{2,5}\s?\d{4}/#) != nil
    }

    var degreeIsGeneralElectives: Bool {
        if case .generalElectives = kind { return true }
        return false
    }

    /// The catalog's category subheaders among the rule's notes (`Biology`, `Physics`): short
    /// notes that aren't sentences.
    var degreeCategories: [String] { notes.filter(Self.degreeIsCategory) }

    /// The rule's notes that are sentences.
    var degreeParagraphs: [String] { notes.filter { !Self.degreeIsCategory($0) } }

    private static func degreeIsCategory(_ note: String) -> Bool {
        note.count <= 48 && !note.contains(".") && !note.contains(":")
    }
}

extension DegreeAudit {
    /// Courses that requirements still open list and the plan doesn't have, once, in catalog
    /// order: the ones worth looking up (a retired one may have a suggested replacement).
    func degreeOpenListedCourses(notIn plan: DegreePlan) -> [CourseKey] {
        let inPlan = Set(plan.degreePlanCourseKeys)
        var seen = Set<CourseKey>()
        return ruleResults
            .filter { !$0.status.isSatisfied }
            .flatMap(\.rule.listedCourses)
            .filter { !inPlan.contains($0) && seen.insert($0).inserted }
    }
}

// MARK: - Status

extension DegreeAudit.Status {
    var degreeSymbol: String {
        switch self {
        case .complete: "checkmark.circle.fill"
        case .planned: "calendar.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .missing: "circle"
        case .waived: "minus.circle.fill"
        }
    }

    var degreeColor: Color {
        switch self {
        case .complete: .green
        case .planned: .blue
        case .partial: .orange
        case .missing: .secondary
        case .waived: .gray
        }
    }

    /// For VoiceOver and captions: `complete`, `planned`…
    var degreeLabel: String {
        switch self {
        case .complete: "complete"
        case .planned: "planned"
        case .partial: "partly done"
        case .missing: "not in your plan"
        case .waived: "waived"
        }
    }
}

// MARK: - Wording

enum DegreeRequirementText {
    /// `4 semester hours`, `1 semester hour`.
    static func hours(_ value: Double) -> String {
        "\(CreditFormatter.number(value)) \(value == 1 ? "semester hour" : "semester hours")"
    }

    /// `105 of 134 credits done · 29 planned`.
    static func creditsLine(_ audit: DegreeAudit) -> String {
        let done = CreditFormatter.number(audit.completedHours)
        var line = audit.requiredHours.map { "\(done) of \(CreditFormatter.number($0)) credits done" } ?? "\(done) credits done"
        if audit.plannedHours > 0 { line += " · \(CreditFormatter.number(audit.plannedHours)) planned" }
        return line
    }

    /// `Your plan covers 21 of 25 requirements`.
    static func coverageLine(_ audit: DegreeAudit) -> String {
        if audit.totalCount > 0, audit.satisfiedCount == audit.totalCount {
            return audit.totalCount == 1 ? "Your plan covers the requirement" : "Your plan covers all \(audit.totalCount) requirements"
        }
        return "Your plan covers \(audit.satisfiedCount) of \(audit.totalCount) requirements"
    }

    /// What's left of a requirement, compactly: `1 more of: CS 4550, DS 4200`,
    /// `4 more semester hours`, `Still needs EECE 2323`. Nil when nothing is left or the row's
    /// title already says it.
    static func remaining(_ result: DegreeAudit.RuleResult) -> String? {
        guard let kind = result.effectiveKind, !result.status.isSatisfied else { return nil }
        // A course counted through an equivalence stands for the course the catalog names.
        let usedKeys = Set(result.used.flatMap { [$0.key] + [$0.satisfies].compactMap { $0 } })
        switch kind {
        case .required(let option):
            guard !result.used.isEmpty else { return nil }
            let missing = option.alternatives
                .map { alternative in alternative.filter { !usedKeys.contains($0) } }
                .min { $0.count < $1.count } ?? []
            return missing.isEmpty ? nil : "Still needs \(missing.map(\.description).joined(separator: " and "))"
        case .choose(_, _, let options, let ranges):
            if let count = result.remainingCount, count > 0 {
                let open = options.filter { option in !option.allCourses.contains(where: usedKeys.contains) }
                if !open.isEmpty {
                    let names = open.prefix(3).map(\.label).joined(separator: ", ")
                    return "\(count) more of: \(names)\(open.count > 3 ? ", …" : "")"
                }
                if let range = ranges.first { return "\(count) more from \(range.label)" }
                return count == 1 ? "1 more course" : "\(count) more courses"
            }
            if let hours = result.remainingHours, hours > 0 { return "\(Self.hours(hours)) more" }
            return nil
        case .generalElectives:
            if let hours = result.remainingHours, hours > 0 { return "\(Self.hours(hours)) more" }
            return nil
        }
    }

    /// `CS 4973 counts toward HCI electives` for a counted course; the requirement's name for
    /// a replacement or waiver (its detail says what changed).
    static func substitutionTitle(_ substitution: RequirementSubstitution, ruleName: String) -> String {
        switch substitution.change {
        case .countCourse(let key): "\(key) counts toward \(ruleName)"
        case .replace, .waive: ruleName
        }
    }

    /// `Replaced by 2 courses like Khoury Elective Courses`, `Waived`.
    static func substitutionDetail(_ substitution: RequirementSubstitution) -> String? {
        switch substitution.change {
        case .countCourse: nil
        case .replace(let replacement): "Replaced by \(lowercasingFirst(replacement.summary))"
        case .waive: "Waived"
        }
    }

    /// `Petition approved by Khoury advising · Approved Sep 12, 2026`.
    static func substitutionCaption(_ substitution: RequirementSubstitution) -> String? {
        var parts: [String] = []
        if let note = substitution.note.nilIfBlank { parts.append(note) }
        if let date = substitution.approvedOn { parts.append("Approved \(DegreePlanText.date(date))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase, !(text.dropFirst().first?.isUppercase ?? false) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

// MARK: - The plan's courses

/// One row in the plan, for pickers. Two copies of a number are two choices.
struct DegreePlanCourseChoice: Identifiable, Hashable {
    var id: UUID = UUID()
    var key: CourseKey
    var title: String
    var credits: Double
    /// `Spring 2027`; nil for completed courses.
    var semester: String?
    /// `Summer A 2027`.
    var semesterShortName: String?
    var isCompleted: Bool { semester == nil }
    /// `Completed` or `Summer A 2027`.
    var whenLine: String { semesterShortName ?? "Completed" }
}

extension DegreePlan {
    var degreeCourseChoices: [DegreePlanCourseChoice] {
        var choices: [DegreePlanCourseChoice] = []
        for course in completed {
            guard let key = course.key else { continue }
            choices.append(DegreePlanCourseChoice(id: course.id, key: key, title: course.title, credits: course.credits))
        }
        for term in terms {
            for course in term.courses {
                guard let key = course.key else { continue }
                choices.append(DegreePlanCourseChoice(id: course.id, key: key, title: course.title, credits: course.credits,
                                                      semester: term.name, semesterShortName: term.shortName))
            }
        }
        return choices
    }

    /// `Summer Session A 2027` → `Summer A 2027`, for the audit's semester names.
    var degreeSemesterShortNames: [String: String] {
        Dictionary(terms.map { ($0.name, $0.shortName) }, uniquingKeysWith: { first, _ in first })
    }
}
