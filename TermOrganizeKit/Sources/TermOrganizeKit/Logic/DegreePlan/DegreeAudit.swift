//
//  DegreeAudit.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Checks a degree plan against its program's requirements from the academic catalog: which
/// requirements are complete, planned, partly done or missing, and where each course counts.
///
/// Like a degree audit, each course counts toward one requirement. Approved substitutions
/// apply first. Then courses are matched from the most specific requirements to the least:
/// required courses, "complete N of the following" lists (including the concentration's),
/// ranges such as "CS 2500 or higher", and finally general electives. Completed courses are
/// preferred over planned ones, and a course several lists name is saved for the list that
/// needs it most. A requirement still short then takes a course from another one when a
/// different course of the plan can count there instead (HIST 2220 for "Computing and Social
/// Issues", so CY 4170 can be a Khoury elective), or when a required course with alternatives
/// can use another one. Finally, if a requirement is still short although the plan has courses
/// that could meet it, every way of matching courses to requirements is searched for one that
/// meets more of them, so the plan is never shown short of a requirement it can meet. A topics
/// course taken again on another topic counts each time, and so do two rows that each name a
/// different CRN. A repeated course counts once. This is a planning aid; the official audit
/// is the registrar's.
///
/// Courses that count as one another (`CourseEquivalences`: a renumbered course and its
/// replacement, whichever department) are interchangeable here: a requirement naming CS 2100 is
/// met by a CS 2510 in the plan, which is then marked (`CourseUse.satisfies`). The equivalences
/// the plan declares always apply, on top of the ones passed in.
struct DegreeAudit: Sendable {
    enum Status: Int, Comparable, Sendable {
        case missing, partial, planned, complete, waived

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Complete, planned, or waived.
        var isSatisfied: Bool { self >= .planned }
    }

    /// A course from the plan, as counted toward a requirement.
    struct CourseUse: Hashable, Sendable, Identifiable {
        var key: CourseKey
        var title: String
        var credits: Double
        /// The planned semester (`Spring 2027`); nil for completed courses.
        var semester: String?
        /// Position in the plan (completed courses first, then semesters in order).
        var order: Int
        /// Counted here because of a substitution.
        var bySubstitution = false
        /// The course the requirement names, when this one counts as it because they are
        /// equivalent (CS 2510 counting as CS 2100). Nil when it counts as itself.
        var satisfies: CourseKey?
        /// 0 the first time a course is in the plan; 1, 2… for another section of the same
        /// number that counts on its own (a different topic, or a different CRN).
        var instance = 0
        /// The section, when the plan row names one. Two rows count separately when
        /// both have a CRN and the CRNs differ.
        var crn: String? = nil

        /// `CS 4973`, or `CS 4973 (2)` for the second time a topics course is taken.
        var id: String { instance == 0 ? key.description : "\(key.description) (\(instance + 1))" }
        var isCompleted: Bool { semester == nil }
        /// Counted as a different course through an equivalence.
        var viaEquivalence: Bool { satisfies != nil }
        /// `counts as CS 2100`, for display next to the course; nil when it counts as itself.
        var countsAsLabel: String? { satisfies.map { "counts as \($0)" } }
    }

    struct RuleResult: Identifiable, Sendable {
        /// The requirement as the catalog lists it.
        var rule: RequirementRule
        /// What was checked: the rule's own kind, a replacement's, or nil when waived.
        var effectiveKind: RequirementRule.Kind?
        var status: Status
        var used: [CourseUse]
        /// Options still needed, for "complete N of the following" requirements.
        var remainingCount: Int?
        /// Semester hours still needed, for hour-based requirements.
        var remainingHours: Double?
        /// The substitutions applied to this requirement.
        var substitutions: [RequirementSubstitution]

        var id: String { rule.id }

        /// The course counted toward `required`, a course this requirement names: the course
        /// itself, or else the equivalent that counts as it (CS 2510 for CS 2100). For rows that
        /// list a requirement's courses and say which one of the plan satisfies each.
        func use(for required: CourseKey) -> CourseUse? {
            used.first { $0.key == required && $0.satisfies == nil } ?? used.first { $0.satisfies == required }
        }
    }

    struct GroupResult: Identifiable, Sendable {
        var group: RequirementGroup
        var rules: [RuleResult]

        var id: String { group.id }
        var status: Status { rules.map(\.status).min() ?? .complete }
    }

    struct SectionResult: Identifiable, Sendable {
        var section: RequirementSection
        var groups: [GroupResult]

        var id: String { section.id }
        var rules: [RuleResult] { groups.flatMap(\.rules) }
        /// Sections that only have notes (e.g. the GPA requirement) count as complete.
        var status: Status { rules.map(\.status).min() ?? .complete }
    }

    var requirements: ProgramRequirements
    /// The sections that apply (the chosen concentration only), in catalog order.
    var sections: [SectionResult]
    /// Courses counted as general electives.
    var generalElectives: [CourseUse]
    /// Courses that don't count toward anything (beyond the general electives needed, or
    /// without credit).
    var unused: [CourseUse]
    var completedHours: Double
    var plannedHours: Double
    /// e.g. 134 from "134 total semester hours required".
    var requiredHours: Double?
    /// Substitutions that couldn't be applied: the requirement isn't part of these
    /// requirements (another concentration or catalog year), or the course isn't in the plan
    /// (or another substitution already uses it).
    var unmatchedSubstitutions: [RequirementSubstitution]
    /// The requirement each applied substitution changes, by substitution id. Usually its own
    /// `ruleID`; for one saved under another catalog year, the requirement with its name here.
    var placements: [UUID: String] = [:]
    /// The program has concentrations and none (or one that no longer exists) is chosen.
    var needsConcentration: Bool
    /// Requirements the catalog states in words that the plan can be checked against.
    var noteChecks: [NoteCheck] = []
    /// The NUpath attributes the audit was run with; audits compared with this one (a petition
    /// answered another way, say) are run with the same.
    var attributes: DegreeCourseAttributes = .none

    /// A requirement the catalog states as a sentence that the plan can still be checked against:
    /// "Complete 72 semester hours in the major", "… is satisfied through co-op".
    struct NoteCheck: Identifiable, Sendable {
        enum Kind: Sendable {
            /// The credits of courses that meet the program's own requirements (not general
            /// electives or the universitywide writing courses), and of other courses within its
            /// elective ranges, against the hours the sentence asks for.
            case majorHours(required: Double)
            /// A co-op work experience in the plan.
            case coop
            /// The NUpath requirements, from the NUpath attributes Banner gives the plan's
            /// courses: one item per requirement.
            case nupath
            /// The universitywide minimums: one item each (total semester hours; the GPA and
            /// residency can't be checked from a plan).
            case universitywide
            /// "134 total semester hours required."
            case totalHours(required: Double)
        }

        /// The section the sentence is in.
        var sectionID: String
        var note: String
        var kind: Kind
        var status: Status
        /// `66 of 72 semester hours · 8 planned`, `COOP 3946 completed`, `No co-op in the plan`,
        /// `11 of 13 complete or planned`. The first number is credits already earned. Planned
        /// credits are the separate ` · N planned` suffix, not part of that first number.
        var detail: String
        /// The parts of a check made of several, in the catalog's order (each NUpath
        /// requirement, each universitywide minimum). Empty for a single check.
        var items: [Item] = []
        /// Whether the check counts toward the requirements met. False while the app can't tell
        /// (NUpath attributes still missing for some of the plan's courses, and a requirement
        /// not found among the others): it shows what it found, but isn't held against the plan.
        var counts = true

        var id: String { "\(sectionID)|\(note)" }

        /// What the check is about, for lists of what's still open: `NUpath requirements`.
        var title: String {
            switch kind {
            case .majorHours: "Semester hours in the major"
            case .coop: "Co-op"
            case .nupath: "NUpath requirements"
            case .universitywide: "Universitywide requirements"
            case .totalHours: "Total semester hours"
            }
        }

        /// One part of a check: `Interpreting Culture (IC)`, `128 total semester hours`.
        struct Item: Identifiable, Sendable {
            var id: String
            var title: String
            /// Nil for a part the app can't check (the GPA, residency).
            var status: Status?
            /// `ARTH 1111 completed`, `Needs 1 more course`, `Not checked: plans have no grades`.
            var detail: String
            /// The courses counted for it (`CourseUse.id`), in plan order.
            var courses: [String] = []
        }
    }

    /// The check for a sentence of a section, when the plan can be checked against it.
    func noteCheck(sectionID: String, note: String) -> NoteCheck? {
        noteChecks.first { $0.sectionID == sectionID && $0.note == note }
    }

    var ruleResults: [RuleResult] { sections.flatMap(\.rules) }

    /// Of these courses, the ones (by id) whose credits reach `need` with the fewest to spare,
    /// as a requirement counted in hours keeps them; nil when they can't reach it.
    static func fewestCreditsChoice(_ uses: [CourseUse], reaching need: Double) -> Set<String>? {
        AuditEngine.fewestCredits(uses, reaching: need)
    }

    func result(for ruleID: String) -> RuleResult? {
        ruleResults.first { $0.rule.id == ruleID }
    }

    /// Requirements satisfied (complete, planned or waived) and in total, sentences checked
    /// against the plan (`noteChecks`) included.
    var satisfiedCount: Int { ruleResults.filter(\.status.isSatisfied).count + countedChecks.filter(\.status.isSatisfied).count }
    var completeCount: Int {
        ruleResults.filter { $0.status == .complete || $0.status == .waived }.count + countedChecks.filter { $0.status == .complete }.count
    }
    var totalCount: Int { ruleResults.count + countedChecks.count }
    /// The note checks that count toward the requirements met (`NoteCheck.counts`).
    var countedChecks: [NoteCheck] { noteChecks.filter(\.counts) }

    /// Whether a sentence says something is satisfied through co-op.
    static func isCoopNote(_ note: String) -> Bool { AuditEngine.isCoopNote(note) }

    /// Why the app can't check a sentence of the catalog, for the ones it knows it can't: grades
    /// and where credits were earned aren't part of a plan. Nil for anything else.
    static func uncheckedReason(for note: String) -> String? {
        if note.firstMatch(of: #/(?i)\bGPA\b|grade\s+point|minimum\s+grade|grade\s+of\s+[A-D]/#) != nil {
            return "Not checked: plans don’t include grades"
        }
        if note.firstMatch(of: #/(?i)residen|(?:at|from)\s+Northeastern|Northeastern\s+University\s+semester\s+hours/#) != nil {
            return "Not checked: a plan doesn’t say where credits were earned"
        }
        // "Pick one of the following concentrations and complete four courses in that
        // concentration. …": what it asks is checked by the concentration's own requirements.
        if note.firstMatch(of: #/(?i)(?:pick|choose|select|complete)\s+(?:one|a)\s+(?:of\s+the\s+following\s+)?concentrations?/#) != nil {
            return "Checked through the concentration you choose"
        }
        return nil
    }

    /// Where a course counts, if anywhere.
    func ruleCounting(_ key: CourseKey) -> RuleResult? {
        ruleResults.first { $0.used.contains { $0.key == key } }
    }

    /// - Parameter equivalences: which courses count as which (`CourseInfoStore.equivalences(for:)`);
    ///   the equivalences declared in the plan are added to them.
    /// - Parameter attributes: the NUpath attributes of the plan's courses
    ///   (`CourseInfoStore.degreeAttributes(for:)`); without them NUpath isn't checked.
    static func run(plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences = .none,
                    attributes: DegreeCourseAttributes = .none) -> DegreeAudit {
        var engine = AuditEngine(plan: plan, requirements: requirements, equivalences: equivalences.merging(plan.declaredEquivalences),
                                 attributes: attributes)
        var audit = engine.run()
        audit.attributes = attributes
        return audit
    }

    /// How a semester-hour minimum stands, for the university minimum, the program total, and
    /// hours in the major.
    ///
    /// `completed` is credits already earned. `planned` is credits in later terms. The line is
    /// `"\(completed) of \(required) semester hours"`, then `" · \(planned) planned"` when
    /// `planned > 0`. The first number is `completed` alone. It is not `completed + planned`.
    ///
    /// Status matches the other requirement rows. `.complete` when `completed >= required`
    /// (a green check). `.planned` when completed credits fall short but
    /// `completed + planned >= required` (a blue calendar). `.partial` when
    /// `completed + planned > 0` and that sum is still under `required` (an orange half circle).
    /// `.missing` when both are 0.
    static func hoursStatus(completed: Double, planned: Double, required: Double) -> (Status, String) {
        let status: Status = completed >= required ? .complete
            : completed + planned >= required ? .planned
            : completed + planned > 0 ? .partial : .missing
        var detail = "\(hoursText(completed)) of \(hoursText(required)) semester hours"
        if planned > 0 { detail += " · \(hoursText(planned)) planned" }
        return (status, detail)
    }

    private static func hoursText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

// MARK: - Engine

private struct AuditEngine {
    typealias CourseUse = DegreeAudit.CourseUse
    /// A course of the plan (`CourseUse.id`): its code, plus which time it is for a topics
    /// course taken more than once.
    typealias UseID = String

    /// The effective requirement of a rule after substitutions.
    enum Effective {
        case waived
        case kind(RequirementRule.Kind, anyCourse: Bool)
    }

    let plan: DegreePlan
    let requirements: ProgramRequirements
    /// Courses that count as one another.
    let equivalences: CourseEquivalences
    let attributes: DegreeCourseAttributes
    let sections: [RequirementSection]
    let rules: [RequirementRule]
    let substitutionsByRule: [String: [RequirementSubstitution]]
    /// Substitutions for requirements these requirements don't have.
    let unplaced: [RequirementSubstitution]
    /// Requirements by name (`science requirement`), for substitutions saved under another
    /// catalog year, where requirements can have other ids.
    let rulesByName: [String: Set<String>]

    /// The plan's courses: the best listing of each, and each time a topics course is taken.
    var pool: [UseID: CourseUse] = [:]
    /// The pool's courses by code, first time first.
    var instances: [CourseKey: [UseID]] = [:]
    var available: Set<UseID> = []
    var used: [String: [CourseUse]] = [:]
    /// Options counted per "complete N of the following" rule.
    var optionsCounted: [String: Int] = [:]
    var effective: [String: Effective] = [:]
    /// How many requirements name each course; contested courses are kept for the list that
    /// needs them (see `contest`, which counts the courses a course is equivalent to too).
    var demand: [CourseKey: Int] = [:]
    /// Courses counted on their own toward a "choose" requirement (a one-course option, or a
    /// course in its ranges), which `rebalance` may move to another requirement.
    var singles: [String: Set<UseID>] = [:]
    var unmatched: [RequirementSubstitution] = []

    init(plan: DegreePlan, requirements: ProgramRequirements, equivalences: CourseEquivalences, attributes: DegreeCourseAttributes = .none) {
        self.plan = plan
        self.requirements = requirements
        self.equivalences = equivalences
        self.attributes = attributes
        sections = requirements.applicableSections(concentrationID: plan.concentrationID)
        rules = sections.flatMap { $0.groups.flatMap(\.rules) }
        var rulesByName: [String: Set<String>] = [:]
        for rule in rules {
            for name in [requirements.degreeShortName(ofRule: rule.id), requirements.title(ofRule: rule.id)].compactMap({ $0 }) {
                rulesByName[name.lowercased(), default: []].insert(rule.id)
            }
        }
        self.rulesByName = rulesByName
        // A substitution goes to its requirement; one saved under another catalog year, whose
        // requirement has a new id here (its wording changed), follows its name when exactly one
        // requirement has it.
        let ids = Set(rules.map(\.id))
        var byRule: [String: [RequirementSubstitution]] = [:]
        var unplaced: [RequirementSubstitution] = []
        for substitution in plan.substitutions {
            if ids.contains(substitution.ruleID) {
                byRule[substitution.ruleID, default: []].append(substitution)
            } else if let named = rulesByName[substitution.ruleTitle.lowercased()], named.count == 1, let id = named.first {
                byRule[id, default: []].append(substitution)
            } else {
                unplaced.append(substitution)
            }
        }
        substitutionsByRule = byRule
        self.unplaced = unplaced

        var order = 0
        func offer(_ course: DegreePlanCourse, semester: String?) {
            defer { order += 1 }
            guard let key = course.key else { return }
            var use = CourseUse(key: key, title: course.title, credits: course.credits, semester: semester, order: order, crn: course.crn)
            let earlier = instances[key, default: []].compactMap { pool[$0] }
            if let repeated = earlier.first(where: { !Self.countsSeparately(use, $0) }) {
                // The same class again: keep the better listing. Completed beats planned; then
                // more credits (a 0-credit line is often a repeat).
                let better = repeated.isCompleted == use.isCompleted ? use.credits > repeated.credits : use.isCompleted
                if better {
                    use.instance = repeated.instance
                    pool[use.id] = use
                }
                return
            }
            use.instance = earlier.count
            pool[use.id] = use
            instances[key, default: []].append(use.id)
        }
        for course in plan.completed { offer(course, semester: nil) }
        for term in plan.terms {
            for course in term.courses { offer(course, semester: term.name) }
        }
        available = Set(pool.keys)
    }

    static func countsSeparately(_ a: CourseUse, _ b: CourseUse) -> Bool {
        DegreeCourseRepeats.countsSeparately(
            title: a.title, credits: a.credits, crn: a.crn, from: b.title, credits: b.credits, otherCRN: b.crn
        )
    }

    mutating func run() -> DegreeAudit {
        resolveSubstitutions()
        applyCourseSubstitutions()

        // Required courses: single courses first, then ones with alternatives.
        let required = rules.enumerated().compactMap { index, rule -> (Int, RequirementRule, CourseOption)? in
            guard case .kind(.required(let option), _) = effective[rule.id] else { return nil }
            return (index, rule, option)
        }
        for (_, rule, option) in required.sorted(by: { ($0.2.alternatives.count, $0.0) < ($1.2.alternatives.count, $1.0) }) {
            fillRequired(rule, option)
        }

        // Lists of options, shortest first; then rules with ranges (and "any course") in order.
        let choices = rules.enumerated().compactMap { index, rule -> (Int, RequirementRule, Int, Bool)? in
            guard case .kind(.choose(_, _, let options, let ranges), let anyCourse) = effective[rule.id] else { return nil }
            return (index, rule, options.count, !ranges.isEmpty || anyCourse)
        }
        for (_, rule, _, _) in choices.filter({ !$0.3 }).sorted(by: { ($0.2, $0.0) < ($1.2, $1.0) }) {
            fillChoice(rule)
        }
        // Among rules with ranges, the ones that count whole courses go first ("two Khoury
        // electives" in place of the science requirement); rules that count semester hours come
        // after, so they can also use what's left, such as 1-credit courses. A shortfall then
        // shows up on the hours requirement ("4 more semester hours"), which is where it can be
        // made up, instead of on a petition that only needs any two courses.
        let rangeChoices = choices.filter(\.3)
        func countsCourses(_ rule: RequirementRule) -> Bool {
            if case .kind(.choose(let count, _, _, _), _) = effective[rule.id] { return count != nil }
            return false
        }
        for (_, rule, _, _) in rangeChoices where countsCourses(rule) {
            fillChoice(rule)
        }
        for (_, rule, _, _) in rangeChoices where !countsCourses(rule) {
            fillChoice(rule)
        }
        rebalance()
        if ensureBestMatching() {
            // Requirements left short show what fits from the rest, before general electives.
            for rule in rules where !isMet(rule.id) {
                switch effective[rule.id] {
                case .kind(.required(let option), _)?: fillRequired(rule, option)
                case .kind(.choose, _)?: fillChoice(rule)
                default: break
                }
            }
        }

        trimSurplusHours()

        // General electives take what's left: the fewest credits that make their hours (or
        // everything, when that isn't enough).
        var generalElectives: [CourseUse] = []
        for rule in rules {
            guard case .kind(.generalElectives(let hours), _) = effective[rule.id] else { continue }
            let counted = used[rule.id, default: []].reduce(0) { $0 + $1.credits }
            let candidates = remaining().filter { $0.credits > 0 }
            let chosen = Self.fewestCredits(candidates, reaching: hours - counted) ?? Set(candidates.map(\.id))
            for use in candidates where chosen.contains(use.id) {
                consume(use.id, for: rule.id)
            }
            generalElectives += used[rule.id] ?? []
        }

        let results = sections.map { section in
            DegreeAudit.SectionResult(section: section, groups: section.groups.map { group in
                DegreeAudit.GroupResult(group: group, rules: group.rules.map(result(for:)))
            })
        }
        let courses = Array(pool.values)
        let concentrationChosen = plan.concentrationID.map { id in requirements.concentrations.contains { $0.id == id } } ?? false
        var placements: [UUID: String] = [:]
        for (ruleID, substitutions) in substitutionsByRule {
            for substitution in substitutions { placements[substitution.id] = ruleID }
        }
        return DegreeAudit(
            requirements: requirements,
            sections: results,
            generalElectives: generalElectives,
            unused: remaining(),
            completedHours: courses.filter(\.isCompleted).reduce(0) { $0 + max(0, $1.credits) },
            plannedHours: courses.filter { !$0.isCompleted }.reduce(0) { $0 + max(0, $1.credits) },
            requiredHours: requirements.totalHours,
            unmatchedSubstitutions: unmatched,
            placements: placements,
            needsConcentration: !requirements.concentrations.isEmpty && !concentrationChosen,
            noteChecks: noteChecks()
        )
    }

    // MARK: Substitutions

    private mutating func resolveSubstitutions() {
        unmatched = unplaced

        for rule in rules {
            let substitutions = substitutionsByRule[rule.id] ?? []
            if substitutions.contains(where: { $0.change == .waive }) {
                effective[rule.id] = .waived
            } else if let replacement = substitutions.compactMap({ substitution -> RequirementReplacement? in
                if case .replace(let replacement) = substitution.change { return replacement }
                return nil
            }).last {
                effective[rule.id] = replacementKind(replacement)
            } else {
                effective[rule.id] = .kind(rule.kind, anyCourse: false)
            }
        }

        for rule in rules {
            guard case .kind(let kind, _) = effective[rule.id] else { continue }
            let listed: [CourseKey]
            switch kind {
            case .required(let option): listed = option.allCourses
            case .choose(_, _, let options, _): listed = options.flatMap(\.allCourses)
            case .generalElectives: listed = []
            }
            for key in Set(listed) { demand[key, default: 0] += 1 }
        }
    }

    /// A replacement draws its courses like another requirement (its options, and its ranges
    /// with the petition's course-number limit) and/or from specific courses. The other
    /// requirement is found by id, else by name (a petition saved under another catalog year).
    private func replacementKind(_ replacement: RequirementReplacement) -> Effective {
        var options = replacement.courses.map { CourseOption(alternatives: [[$0]]) }
        var ranges: [CourseRange] = []
        var anyCourse = false
        let named = replacement.likeRuleTitle.flatMap { rulesByName[$0.lowercased()] }.flatMap { $0.count == 1 ? $0.first : nil }
        if replacement.likeRuleID.flatMap({ requirements.rule(id: $0) }) == nil, named == nil,
           replacement.likeRuleTitle?.lowercased().hasPrefix("general electives") == true {
            // "Courses like general electives": any course, whatever that requirement's id now.
            anyCourse = true
        }
        if let like = replacement.likeRuleID.flatMap({ requirements.rule(id: $0) }) ?? named.flatMap({ requirements.rule(id: $0) }) {
            switch like.kind {
            case .required(let option): options.insert(option, at: 0)
            case .choose(_, _, let likeOptions, let likeRanges):
                options = likeOptions + options
                ranges = likeRanges.map { $0.applying(replacement.courseNumbers) }
            case .generalElectives: anyCourse = true
            }
        }
        let count = replacement.count ?? (replacement.hours == nil ? 1 : nil)
        return .kind(.choose(count: count, hours: replacement.hours, options: options, ranges: ranges), anyCourse: anyCourse)
    }

    private mutating func applyCourseSubstitutions() {
        for rule in rules {
            guard let current = effective[rule.id], case .kind = current else { continue }
            for substitution in substitutionsByRule[rule.id] ?? [] {
                guard case .countCourse(let key) = substitution.change else { continue }
                guard let taken = standIn(for: key) else {
                    unmatched.append(substitution)
                    continue
                }
                consume(taken, for: rule.id, bySubstitution: true, satisfying: key)
                optionsCounted[rule.id, default: 0] += 1
            }
        }
    }

    // MARK: Matching

    private mutating func fillRequired(_ rule: RequirementRule, _ option: CourseOption) {
        // A substitution satisfies the requirement on its own.
        guard used[rule.id, default: []].isEmpty else { return }
        let complete = option.alternatives.filter(isComplete)
        if let best = complete.min(by: { score($0) < score($1) }) {
            for (required, taken) in assign(best) { consume(taken, for: rule.id, satisfying: required) }
            return
        }
        // Partly done: keep what's there (e.g. the lecture without its lab).
        let partial = option.alternatives
            .map { assign($0) }
            .max { $0.count < $1.count }
        for (required, taken) in partial ?? [] { consume(taken, for: rule.id, satisfying: required) }
    }

    private mutating func fillChoice(_ rule: RequirementRule) {
        guard case .kind(.choose(let count, let hours, let options, let ranges), let anyCourse) = effective[rule.id] else { return }
        func done() -> Bool { isSatisfied(rule.id, count: count, hours: hours) }

        // Listed options, least contested first.
        let candidates = options.enumerated().compactMap { index, option -> ([CourseKey], (Int, Int, Int))? in
            let complete = option.alternatives.filter(isComplete)
            guard let best = complete.min(by: { score($0) < score($1) }) else { return nil }
            let s = score(best)
            return (best, (s.0, s.1, index))
        }.sorted { $0.1 < $1.1 }
        for (alternative, _) in candidates where !done() {
            // An earlier option may have used a course this one needs.
            guard isComplete(alternative) else { continue }
            let pairs = assign(alternative)
            for (required, taken) in pairs { consume(taken, for: rule.id, satisfying: required) }
            if pairs.count == 1 { singles[rule.id, default: []].insert(pairs[0].taken) }
            optionsCounted[rule.id, default: 0] += 1
        }

        // Then courses in the ranges. When counting courses, skip labs and seminars. A course
        // is in a range when it is, or an equivalent of it is.
        guard !done(), !ranges.isEmpty || anyCourse else { return }
        let matches = remaining().compactMap { use -> (use: CourseUse, via: CourseKey?)? in
            guard use.credits > 0, count == nil || use.credits >= 2 else { return nil }
            if anyCourse { return (use, nil) }
            guard let inRange = courseInRange(use.key, ranges) else { return nil }
            return (use, inRange == use.key ? nil : inRange)
        }
        for (use, via) in matches where !done() {
            consume(use.id, for: rule.id, satisfying: via)
            optionsCounted[rule.id, default: 0] += 1
            singles[rule.id, default: []].insert(use.id)
        }
    }

    // MARK: Sentences checked against the plan

    /// Checks for the catalog's sentences the plan can answer: hours in the major and co-op.
    /// (A GPA, residency or similar stays unchecked: the plan doesn't say.)
    private func noteChecks() -> [DegreeAudit.NoteCheck] {
        var checks: [DegreeAudit.NoteCheck] = []
        for section in sections {
            let notes = section.notes + section.groups.filter(\.rules.isEmpty).flatMap(\.notes)
            for note in notes {
                if let hours = Self.majorHours(in: note) {
                    checks.append(majorHoursCheck(sectionID: section.id, note: note, required: hours))
                } else if Self.isCoopNote(note) {
                    checks.append(coopCheck(sectionID: section.id, note: note))
                } else if Self.isNUpathNote(note) {
                    if let check = nupathCheck(sectionID: section.id, note: note) { checks.append(check) }
                } else if Self.isUniversitywideNote(note) {
                    if let check = universitywideCheck(sectionID: section.id, note: note) { checks.append(check) }
                } else if let hours = Self.totalHours(in: note) {
                    checks.append(totalHoursCheck(sectionID: section.id, note: note, required: hours))
                }
            }
        }
        return checks
    }

    /// "All undergraduate students are required to complete the NUpath Requirements."
    static func isNUpathNote(_ note: String) -> Bool {
        note.firstMatch(of: #/(?i)complete\s+(?:the\s+)?NUpath\s+requirements/#) != nil
    }

    /// "All undergraduate students are required to complete the Universitywide Requirements."
    static func isUniversitywideNote(_ note: String) -> Bool {
        note.firstMatch(of: #/(?i)complete\s+(?:the\s+)?university-?\s?wide\s+requirements/#) != nil
    }

    /// `134` from "134 total semester hours required".
    static func totalHours(in note: String) -> Double? {
        guard let match = note.firstMatch(of: #/(?i)(\d+(?:\.\d+)?)\s+total\s+semester\s+hours\s+required/#) else { return nil }
        return Double(match.1)
    }

    private static func hours(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }

    /// `72` from "Complete 72 semester hours in the major."
    static func majorHours(in note: String) -> Double? {
        guard let match = note.firstMatch(of: #/(?i)(\d+(?:\.\d+)?)\s+(?:semester\s+)?(?:credit\s+)?hours\s+(?:in|within)\s+the\s+major/#) else { return nil }
        return Double(match.1)
    }

    /// "Integrating Knowledge and Skills Through Experience is satisfied through co-op."
    static func isCoopNote(_ note: String) -> Bool {
        note.firstMatch(of: #/(?i)satisfied\s+(?:through|by|with)\s+(?:a\s+)?co-?op/#) != nil
    }

    /// A co-op work experience (`COOP 3946 Co-op Work Experience`), not a course about co-op
    /// (`CS 1210 Professional Development for Khoury Co-op`).
    static func isCoop(_ use: CourseUse) -> Bool {
        use.key.subject == "COOP" || use.title.firstMatch(of: #/(?i)co-?op\s+(?:work\s+)?experience|cooperative\s+education/#) != nil
    }

    private func majorHoursCheck(sectionID: String, note: String, required: Double) -> DegreeAudit.NoteCheck {
        // Courses that meet the program's own requirements (the universitywide writing courses and
        // general electives don't count) …
        var counted: [UseID: CourseUse] = [:]
        var ranges: [CourseRange] = []
        for section in sections {
            for group in section.groups {
                let isWriting = [section.title, group.title ?? ""].contains { $0.localizedCaseInsensitiveContains("writing") }
                for rule in group.rules {
                    guard case .kind(let kind, _) = effective[rule.id] else { continue }
                    if case .generalElectives = kind { continue }
                    if case .choose(_, _, _, let ruleRanges) = kind { ranges += ruleRanges }
                    if isWriting { continue }
                    for use in used[rule.id, default: []] { counted[use.id] = use }
                }
            }
        }
        // … and other courses within its elective ranges (a Khoury course beyond the hours needed).
        for use in pool.values where counted[use.id] == nil && courseInRange(use.key, ranges) != nil {
            counted[use.id] = use
        }
        let completed = counted.values.filter(\.isCompleted).reduce(0) { $0 + max(0, $1.credits) }
        let planned = counted.values.filter { !$0.isCompleted }.reduce(0) { $0 + max(0, $1.credits) }
        let (status, detail) = DegreeAudit.hoursStatus(completed: completed, planned: planned, required: required)
        return DegreeAudit.NoteCheck(sectionID: sectionID, note: note, kind: .majorHours(required: required), status: status, detail: detail)
    }

    private func coopCheck(sectionID: String, note: String) -> DegreeAudit.NoteCheck {
        let coops = pool.values.filter(Self.isCoop).sorted { $0.order < $1.order }
        var status: DegreeAudit.Status
        var detail: String
        if let done = coops.first(where: \.isCompleted) {
            status = .complete
            detail = "\(done.key.description) completed"
        } else if let next = coops.first {
            status = .planned
            detail = "\(next.key.description) planned\(next.semester.map { " · \($0)" } ?? "")"
        } else {
            status = .missing
            detail = "No co-op in the plan"
            // What a co-op satisfies, a course can too (an integration experience: CS 4535).
            if let path = NUpathRequirement.satisfiedThroughCoop(in: note),
               let course = sortedPool().filter({ nupaths(of: $0)?.contains(path) == true }).min(by: { ($0.isCompleted ? 0 : 1, $0.order) < ($1.isCompleted ? 0 : 1, $1.order) }) {
                status = course.isCompleted ? .complete : .planned
                detail = "No co-op in the plan · \(course.key.description) (\(path.short)) \(course.isCompleted ? "completed" : "planned")"
            }
        }
        return DegreeAudit.NoteCheck(sectionID: sectionID, note: note, kind: .coop, status: status, detail: detail)
    }

    private func sortedPool() -> [CourseUse] { pool.values.sorted { $0.order < $1.order } }

    // MARK: NUpath

    /// A course's NUpath attributes: its own, or (when it isn't known) those of a course it
    /// counts as (a renumbered course and its replacement). Co-ops have none. Nil when unknown.
    private func nupaths(of use: CourseUse) -> Set<NUPath>? {
        if let paths = attributes.nupaths[use.key] { return paths }
        if Self.isCoop(use) { return [] }
        for other in equivalences.group(of: use.key) where other != use.key {
            if let paths = attributes.nupaths[other] { return paths }
        }
        return nil
    }

    /// The NUpath requirements against the plan's courses (all of them: NUpath can be met by
    /// courses that also count for the major, minors or general electives). Nil when no course
    /// was looked up.
    private func nupathCheck(sectionID: String, note: String) -> DegreeAudit.NoteCheck? {
        guard !attributes.isEmpty else { return nil }
        let uses = sortedPool()
        var courses: [NUpathMatching.Course] = []
        var unknown: [CourseUse] = []
        for use in uses {
            guard let paths = nupaths(of: use) else { unknown.append(use); continue }
            if !paths.isEmpty { courses.append(NUpathMatching.Course(id: use.id, paths: paths, isCompleted: use.isCompleted)) }
        }
        // Requirements the program says a co-op satisfies.
        let coops = uses.filter(Self.isCoop).map { NUpathMatching.Course(id: $0.id, paths: [], isCompleted: $0.isCompleted) }
        var coopCounts: [NUPath: [NUpathMatching.Course]] = [:]
        if !coops.isEmpty {
            for section in requirements.sections {
                for note in section.notes + section.groups.flatMap(\.notes) {
                    if let path = NUpathRequirement.satisfiedThroughCoop(in: note) { coopCounts[path] = coops }
                }
            }
        }
        let matching = NUpathMatching(courses: courses, coopCounts: coopCounts)
        let isLoading = unknown.contains { attributes.loading.contains($0.key) }

        var items: [DegreeAudit.NoteCheck.Item] = []
        for requirement in NUpathRequirement.all {
            let chosen = matching.courses(for: requirement.path).compactMap { pool[$0] }
            let status: DegreeAudit.Status?
            var detail: String
            if chosen.count >= requirement.count {
                status = chosen.allSatisfy(\.isCompleted) ? .complete : .planned
                detail = Self.describe(chosen)
            } else {
                // Not found, but a course whose attributes aren't known may have it.
                status = unknown.isEmpty ? (chosen.isEmpty ? .missing : .partial) : nil
                let found = chosen.isEmpty ? "" : "\(chosen.count) of \(requirement.count) · \(Self.describe(chosen))"
                if status == nil {
                    detail = found.isEmpty ? (isLoading ? "Looking up the plan’s courses…" : "Not found among the courses with NUpath data") : found
                } else if chosen.isEmpty {
                    detail = requirement.count == 1 ? "No course in the plan has it" : "Needs \(requirement.count) courses"
                } else {
                    detail = found
                }
            }
            items.append(DegreeAudit.NoteCheck.Item(id: requirement.path.rawValue, title: requirement.title, status: status,
                                                    detail: detail, courses: chosen.map(\.id)))
        }

        let met = items.filter { $0.status?.isSatisfied == true }
        let open = items.filter { $0.status?.isSatisfied != true }
        let status: DegreeAudit.Status = open.isEmpty
            ? (met.allSatisfy { $0.status == .complete } ? .complete : .planned)
            : (met.isEmpty && items.allSatisfy { $0.courses.isEmpty } ? .missing : .partial)
        var detail = "\(met.count) of \(items.count) met"
        let missing = items.filter { $0.status == .missing || $0.status == .partial }
        if !missing.isEmpty, missing.count <= 3 {
            detail += " · missing \(missing.map { NUPath(rawValue: $0.id)?.short ?? $0.title }.joined(separator: ", "))"
        }
        // Courses without data only matter while something isn't found.
        if !unknown.isEmpty, items.contains(where: { $0.status == nil }) {
            let names = unknown.prefix(3).map(\.key.description).joined(separator: ", ")
            detail += isLoading
                ? " · looking up \(unknown.count == 1 ? "1 course" : "\(unknown.count) courses")"
                : " · no NUpath data for \(names)\(unknown.count > 3 ? " and \(unknown.count - 3) more" : "")"
        }
        return DegreeAudit.NoteCheck(sectionID: sectionID, note: note, kind: .nupath, status: status, detail: detail,
                                     items: items, counts: !items.contains { $0.status == nil })
    }

    /// `ENGW 1111 completed`, `CS 3484 completed · CS 4535 planned · Spring 2027`.
    private static func describe(_ uses: [CourseUse]) -> String {
        uses.map { use in
            use.isCompleted ? "\(use.key.description) completed" : "\(use.key.description) planned\(use.semester.map { " · \($0)" } ?? "")"
        }
        .joined(separator: " · ")
    }

    // MARK: Universitywide and total hours

    /// The edition's universitywide minimums: the total semester hours are checked; the GPA and
    /// residency can't be (a plan has no grades, and doesn't say where credits were earned).
    /// Nil when the minimums weren't read.
    private func universitywideCheck(sectionID: String, note: String) -> DegreeAudit.NoteCheck? {
        guard let minimums = requirements.universitywide else { return nil }
        let completed = pool.values.filter(\.isCompleted).reduce(0) { $0 + max(0, $1.credits) }
        let planned = pool.values.filter { !$0.isCompleted }.reduce(0) { $0 + max(0, $1.credits) }
        var items: [DegreeAudit.NoteCheck.Item] = []
        if let total = minimums.totalHours {
            let (status, detail) = DegreeAudit.hoursStatus(completed: completed, planned: planned, required: total)
            items.append(.init(id: "total-hours", title: "\(Self.hours(total)) total semester hours", status: status, detail: detail))
        }
        if minimums.requiresExperientialLearning {
            let coops = sortedPool().filter(Self.isCoop)
            let coop = coops.first(where: \.isCompleted) ?? coops.first
            items.append(.init(id: "experiential", title: "Experiential learning",
                               status: coop.map { $0.isCompleted ? .complete : .planned },
                               detail: coop.map { Self.describe([$0]) } ?? "Not checked: only co-ops are recognized",
                               courses: coop.map { [$0.id] } ?? []))
        }
        if let gpa = minimums.gpa {
            items.append(.init(id: "gpa", title: "\(gpa.formatted(.number.precision(.fractionLength(1...3)))) GPA", status: nil,
                               detail: "Not checked: plans don’t include grades"))
        }
        if let residency = minimums.residencyHours {
            items.append(.init(id: "residency", title: "\(Self.hours(residency)) semester hours at Northeastern", status: nil,
                               detail: "Not checked: a plan doesn’t say where credits were earned"))
        }
        let checked = items.filter { $0.status != nil }
        guard let status = checked.compactMap(\.status).min() else { return nil }
        // `105 of 128 semester hours · 30 planned · GPA and residency not checked`.
        let names = ["experiential": "experiential learning", "gpa": "GPA", "residency": "residency"]
        let unchecked = items.filter { $0.status == nil }.compactMap { names[$0.id] }
        var detail = checked.map(\.detail).joined(separator: " · ")
        if !unchecked.isEmpty {
            detail += " · \(ListFormatter.localizedString(byJoining: unchecked)) not checked"
        }
        return DegreeAudit.NoteCheck(sectionID: sectionID, note: note, kind: .universitywide, status: status, detail: detail, items: items)
    }

    private func totalHoursCheck(sectionID: String, note: String, required: Double) -> DegreeAudit.NoteCheck {
        let completed = pool.values.filter(\.isCompleted).reduce(0) { $0 + max(0, $1.credits) }
        let planned = pool.values.filter { !$0.isCompleted }.reduce(0) { $0 + max(0, $1.credits) }
        let (status, detail) = DegreeAudit.hoursStatus(completed: completed, planned: planned, required: required)
        return DegreeAudit.NoteCheck(sectionID: sectionID, note: note, kind: .totalHours(required: required), status: status, detail: detail)
    }

    // MARK: Surplus hours

    /// A requirement counted in semester hours keeps only what it needs. Once it's met, it takes
    /// the set that makes its hours with the fewest credits to spare, from the courses counted on
    /// their own toward it and unused ones that fit (then the most completed courses, the fewest
    /// courses, the earliest in the plan). The rest go back, for general electives. Substitutions,
    /// and courses that count only with others (a lecture and its lab), stay.
    private mutating func trimSurplusHours() {
        for rule in rules {
            guard case .kind(.choose(nil, let hours?, _, _), _) = effective[rule.id], choiceIsSatisfied(rule.id) else { continue }
            let uses = used[rule.id, default: []]
            let movable = uses.filter { !$0.bySubstitution && singles[rule.id, default: []].contains($0.id) }
            let movableIDs = Set(movable.map(\.id))
            let fixed = uses.filter { !movableIDs.contains($0.id) }.reduce(0) { $0 + $1.credits }
            let unused = remaining().compactMap { use in singleMatch(use, for: rule.id).map { (use: use, named: $0) } }
            guard let keep = Self.fewestCredits(movable + unused.map(\.use), reaching: hours - fixed) else { continue }
            for use in movable where !keep.contains(use.id) { release(use.id, from: rule.id) }
            for (use, named) in unused where keep.contains(use.id) { place(use.id, in: rule.id, as: named) }
        }
    }

    /// The courses whose credits reach `need` with the fewest to spare; among those, the most
    /// completed, then the fewest courses, then the earliest in the plan. Empty when nothing is
    /// needed, nil when they can't reach it.
    static func fewestCredits(_ uses: [CourseUse], reaching need: Double) -> Set<UseID>? {
        guard need > 0 else { return [] }
        let items = uses.filter { $0.credits > 0 }
        // In half credits, so sums are exact.
        let weights = items.map { max(1, Int(($0.credits * 2).rounded())) }
        let target = Int((need * 2).rounded(.up))
        guard weights.reduce(0, +) >= target, let largest = weights.max() else { return nil }
        // The best set is under the target plus one course: with more, a course could be dropped.
        let cap = target + largest
        struct Pick {
            var completed = 0
            var count = 0
            var order = 0
            var items: [Int] = []
            func isBetter(than other: Pick) -> Bool {
                (-completed, count, order) < (-other.completed, other.count, other.order)
            }
        }
        var best = [Pick?](repeating: nil, count: cap + 1)
        best[0] = Pick()
        for (index, item) in items.enumerated() {
            let weight = weights[index]
            guard weight <= cap else { continue }
            for sum in stride(from: cap, through: weight, by: -1) {
                guard var pick = best[sum - weight] else { continue }
                pick.completed += item.isCompleted ? 1 : 0
                pick.count += 1
                pick.order += item.order
                pick.items.append(index)
                if let current = best[sum], !pick.isBetter(than: current) { continue }
                best[sum] = pick
            }
        }
        guard let pick = (target...cap).lazy.compactMap({ best[$0] }).first else { return nil }
        return Set(pick.items.map { items[$0].id })
    }

    // MARK: Rebalancing

    /// Gives requirements that are still short the courses other requirements can do without.
    /// A short requirement takes a course that counts there from one that is met, when that one
    /// stays met: it has a course to spare, it takes an unused course instead (or one a third
    /// requirement can spare, and so on, a few steps deep), or it's a required course with
    /// alternatives that can use another one. Requirements that are met stay met.
    private mutating func rebalance() {
        for rule in rules where !choiceIsSatisfied(rule.id) {
            var budget = 2_000
            moves: while !choiceIsSatisfied(rule.id) {
                // The shortest chain of moves first, so as little as possible changes.
                for steps in 0...3 {
                    if let next = adding(to: rule.id, minCredits: 0, steps: steps, avoiding: [rule.id], budget: &budget) {
                        self = next
                        continue moves
                    }
                }
                break
            }
        }
    }

    /// The audit after one more course counts toward `ruleID` (a course of at least
    /// `minCredits`): an unused course, or, with `steps` left, one a requirement that is met gives
    /// up because it can spare it or can take another course the same way, or one a required
    /// course frees by switching to another of its alternatives. Requirements in `avoiding` are
    /// never asked. Nil when there is no such course.
    private func adding(to ruleID: String, minCredits: Double, steps: Int, avoiding: Set<String>, budget: inout Int) -> AuditEngine? {
        for use in remaining() where use.credits >= minCredits {
            guard let named = singleMatch(use, for: ruleID) else { continue }
            var next = self
            next.place(use.id, in: ruleID, as: named)
            return next
        }
        guard steps > 0 else { return nil }
        for donor in rules where !avoiding.contains(donor.id) && choiceIsSatisfied(donor.id) {
            for use in used[donor.id, default: []] where use.credits >= minCredits && singles[donor.id, default: []].contains(use.id) {
                guard budget > 0 else { return nil }
                budget -= 1
                guard let named = singleMatch(use, for: ruleID) else { continue }
                var next = self
                next.release(use.id, from: donor.id)
                next.place(use.id, in: ruleID, as: named)
                if next.choiceIsSatisfied(donor.id) { return next }
                if let refilled = next.adding(to: donor.id, minCredits: next.shortfall(of: donor.id), steps: steps - 1,
                                              avoiding: avoiding.union([ruleID, donor.id]), budget: &budget),
                   refilled.choiceIsSatisfied(donor.id) {
                    return refilled
                }
            }
        }
        // A required course with alternatives ("CS 4500 or CS 4530") may switch to another
        // alternative the plan completes, freeing the course this requirement needs.
        for donor in rules where !avoiding.contains(donor.id) {
            guard case .kind(.required(let option), _) = effective[donor.id], option.alternatives.count > 1 else { continue }
            let current = used[donor.id, default: []]
            guard !current.isEmpty, !current.contains(where: \.bySubstitution) else { continue }
            for use in current where use.credits >= minCredits {
                guard budget > 0 else { return nil }
                budget -= 1
                guard let named = singleMatch(use, for: ruleID) else { continue }
                var next = self
                next.releaseAll(from: donor.id)
                // Keep the course for `ruleID` while picking the other alternative.
                next.available.remove(use.id)
                let complete = option.alternatives.filter(next.isComplete)
                guard let best = complete.min(by: { next.score($0) < next.score($1) }) else { continue }
                let pairs = next.assign(best)
                next.available.insert(use.id)
                for (required, taken) in pairs { next.consume(taken, for: donor.id, satisfying: required) }
                next.place(use.id, in: ruleID, as: named)
                return next
            }
        }
        return nil
    }

    /// What `use` would count as toward a "choose" requirement on its own: a one-course option
    /// not counted yet that it is (or is equivalent to), or itself (or an equivalent) in the
    /// ranges. Nil when it can't count there on its own.
    private func singleMatch(_ use: CourseUse, for ruleID: String) -> CourseKey? {
        guard case .kind(.choose(let count, _, let options, let ranges), let anyCourse) = effective[ruleID] else { return nil }
        // Hours come from credits; a course without credit adds none.
        if count == nil, use.credits <= 0 { return nil }
        let counted = Set(used[ruleID, default: []].map { $0.satisfies ?? $0.key })
        for option in options where !option.allCourses.contains(where: counted.contains) {
            for alternative in option.alternatives where alternative.count == 1 && equivalences.areEquivalent(alternative[0], use.key) {
                return alternative[0]
            }
        }
        guard use.credits > 0, count == nil || use.credits >= 2 else { return nil }
        if anyCourse { return use.key }
        return ranges.isEmpty ? nil : courseInRange(use.key, ranges)
    }

    /// Whether a "choose" requirement is met; other requirements don't take part in rebalancing.
    private func choiceIsSatisfied(_ ruleID: String) -> Bool {
        guard case .kind(.choose(let count, let hours, _, _), _) = effective[ruleID] else { return true }
        return isSatisfied(ruleID, count: count, hours: hours)
    }

    /// The credits one more course needs to make `ruleID` met: the semester hours it's missing,
    /// or nothing for a requirement that counts courses.
    private func shortfall(of ruleID: String) -> Double {
        guard case .kind(.choose(nil, let hours?, _, _), _) = effective[ruleID] else { return 0 }
        return max(0, hours - used[ruleID, default: []].reduce(0) { $0 + $1.credits })
    }

    /// Counts an unused course on its own toward a "choose" requirement, as `named`.
    private mutating func place(_ id: UseID, in ruleID: String, as named: CourseKey) {
        consume(id, for: ruleID, satisfying: named)
        optionsCounted[ruleID, default: 0] += 1
        singles[ruleID, default: []].insert(id)
    }

    /// Takes back a course counted on its own toward a "choose" requirement.
    private mutating func release(_ id: UseID, from ruleID: String) {
        guard let index = used[ruleID]?.firstIndex(where: { $0.id == id }) else { return }
        used[ruleID]?.remove(at: index)
        optionsCounted[ruleID, default: 0] -= 1
        singles[ruleID]?.remove(id)
        available.insert(id)
    }

    /// Takes back every course counted toward a requirement.
    private mutating func releaseAll(from ruleID: String) {
        for use in used[ruleID] ?? [] { available.insert(use.id) }
        used[ruleID] = []
        optionsCounted[ruleID] = 0
        singles[ruleID] = []
    }

    private func isSatisfied(_ ruleID: String, count: Int?, hours: Double?) -> Bool {
        let counted = optionsCounted[ruleID, default: 0]
        if let count { return counted >= count }
        if let hours { return used[ruleID, default: []].reduce(0) { $0 + $1.credits } >= hours }
        return counted >= 1
    }

    /// Lower is better: fewer planned (not yet taken) courses, then less contested.
    private func score(_ alternative: [CourseKey]) -> (Int, Int) {
        let taken = assign(alternative).compactMap { pool[$0.taken] }
        let planned = taken.filter { !$0.isCompleted }.count
        let contested = taken.reduce(0) { $0 + contest($1.key) }
        return (planned, contested)
    }

    /// How many requirements name the course or a course equivalent to it.
    private func contest(_ key: CourseKey) -> Int {
        equivalences.group(of: key).reduce(0) { $0 + demand[$1, default: 0] }
    }

    /// Counts a course toward a requirement. `required` is the course the requirement names when
    /// the course counts as it through an equivalence.
    private mutating func consume(_ id: UseID, for ruleID: String, bySubstitution: Bool = false, satisfying required: CourseKey? = nil) {
        guard available.contains(id), var use = pool[id] else { return }
        use.bySubstitution = bySubstitution
        use.satisfies = required == use.key ? nil : required
        available.remove(id)
        used[ruleID, default: []].append(use)
    }

    // MARK: Equivalent courses

    /// The course in the plan, not yet counted, that can stand in for `required`: the course
    /// itself, else an equivalent (completed ones first, then in plan order).
    private func standIn(for required: CourseKey, excluding claimed: Set<UseID> = []) -> UseID? {
        let free = { (id: UseID) in available.contains(id) && !claimed.contains(id) }
        if let own = instances[required, default: []].filter(free).min(by: comesFirst) { return own }
        guard !equivalences.isEmpty else { return nil }
        return equivalences.equivalents(of: required)
            .flatMap { instances[$0, default: []] }
            .filter(free)
            .min(by: comesFirst)
    }

    private func comesFirst(_ a: UseID, _ b: UseID) -> Bool {
        let first = (pool[a]?.isCompleted == true ? 0 : 1, pool[a]?.order ?? Int.max)
        let second = (pool[b]?.isCompleted == true ? 0 : 1, pool[b]?.order ?? Int.max)
        return first != second ? first < second : a < b
    }

    /// Matches each course of an alternative with a different course of the plan that can
    /// stand in for it. Courses nothing in the plan covers are left out.
    private func assign(_ alternative: [CourseKey]) -> [(required: CourseKey, taken: UseID)] {
        var named = Set<CourseKey>()
        var claimed = Set<UseID>()
        var matches: [(required: CourseKey, taken: UseID)] = []
        for required in alternative where named.insert(required).inserted {
            guard let taken = standIn(for: required, excluding: claimed) else { continue }
            claimed.insert(taken)
            matches.append((required, taken))
        }
        return matches
    }

    /// Whether the plan covers every course of an alternative.
    private func isComplete(_ alternative: [CourseKey]) -> Bool {
        assign(alternative).count == Set(alternative).count
    }

    /// The course in a range that `key` is, or is equivalent to; nil when none is in it.
    private func courseInRange(_ key: CourseKey, _ ranges: [CourseRange]) -> CourseKey? {
        if ranges.contains(where: { $0.contains(key) }) { return key }
        return equivalences.equivalents(of: key).sorted().first { equivalent in
            ranges.contains { $0.contains(equivalent) }
        }
    }

    /// Unused courses, completed first, then in plan order.
    private func remaining() -> [CourseUse] {
        available.compactMap { pool[$0] }.sorted { ($0.isCompleted ? 0 : 1, $0.order) < ($1.isCompleted ? 0 : 1, $1.order) }
    }

    // MARK: Results

    private func result(for rule: RequirementRule) -> DegreeAudit.RuleResult {
        let uses = used[rule.id] ?? []
        let substitutions = substitutionsByRule[rule.id] ?? []
        guard case .kind(let kind, _) = effective[rule.id] else {
            return DegreeAudit.RuleResult(rule: rule, effectiveKind: nil, status: .waived, used: [], substitutions: substitutions)
        }

        let satisfied: Bool
        var remainingCount: Int?
        var remainingHours: Double?
        let hoursDone = uses.reduce(0) { $0 + $1.credits }
        switch kind {
        case .required(let option):
            // A course counted through an equivalence stands for the course the requirement names.
            let keys = Set(uses.map { $0.satisfies ?? $0.key })
            satisfied = uses.contains(where: \.bySubstitution) || option.alternatives.contains { $0.allSatisfy(keys.contains) }
        case .choose(let count, let hours, _, _):
            satisfied = isSatisfied(rule.id, count: count, hours: hours)
            if let count { remainingCount = max(0, count - optionsCounted[rule.id, default: 0]) }
            else if let hours { remainingHours = max(0, hours - hoursDone) }
            else { remainingCount = satisfied ? 0 : 1 }
        case .generalElectives(let hours):
            satisfied = hoursDone >= hours
            remainingHours = max(0, hours - hoursDone)
        }

        let status: DegreeAudit.Status
        if satisfied {
            status = uses.allSatisfy(\.isCompleted) ? .complete : .planned
        } else {
            status = uses.isEmpty ? .missing : .partial
        }
        return DegreeAudit.RuleResult(rule: rule, effectiveKind: kind, status: status, used: uses,
                                      remainingCount: remainingCount, remainingHours: remainingHours, substitutions: substitutions)
    }
}

// MARK: - Exact matching

/// A set of the courses being matched, by index (up to 128 of them).
private struct CourseBits: Hashable {
    static let capacity = 128

    var low: UInt64 = 0
    var high: UInt64 = 0

    init() {}

    init(_ index: Int) {
        if index < 64 { low = 1 << UInt64(index) } else { high = 1 << UInt64(index - 64) }
    }

    func contains(_ other: CourseBits) -> Bool { low & other.low == other.low && high & other.high == other.high }
    func intersects(_ other: CourseBits) -> Bool { low & other.low != 0 || high & other.high != 0 }
    func has(_ index: Int) -> Bool { index < 64 ? low & (1 << UInt64(index)) != 0 : high & (1 << UInt64(index - 64)) != 0 }

    func union(_ other: CourseBits) -> CourseBits {
        var result = self
        result.low |= other.low
        result.high |= other.high
        return result
    }

    func subtracting(_ other: CourseBits) -> CourseBits {
        var result = self
        result.low &= ~other.low
        result.high &= ~other.high
        return result
    }
}

extension AuditEngine {
    /// A way to count some of the plan's courses toward a requirement: an alternative of one of
    /// its options (`CS 2500 and CS 2501`), or a course in its ranges.
    fileprivate struct Unit {
        var courses: [UseID]
        /// What each course counts as, in the same order.
        var named: [CourseKey]
        var bits: CourseBits
        /// Units of the same option don't both count; each course in the ranges is an option of
        /// its own.
        var option: Int
        var credits: Double
        var isCompleted: Bool
        /// The earliest of its courses in the plan.
        var order: Int
    }

    /// What a requirement still needs once its substitutions are counted, and the units that
    /// can give it.
    fileprivate struct Need {
        enum Amount {
            /// One alternative of a required course.
            case alternative
            case count(Int)
            case hours(Double)
        }

        var ruleID: String
        var amount: Amount
        var units: [Unit]
    }

    private struct SearchKey: Hashable {
        var depth: Int
        var available: CourseBits
    }

    /// Makes sure no other matching of courses to requirements is better. Greedy matching and
    /// rebalancing find the best one for almost every plan; when a requirement is still short
    /// although the plan has courses that could meet it, every matching is searched (pruned,
    /// within a budget). A matching that meets every requirement, general electives included,
    /// is always used; otherwise one is used only if it meets more of the specific requirements
    /// (general electives take what's left, as an audit fills them, so that a short requirement
    /// shows what it really still needs). Returns whether one was.
    fileprivate mutating func ensureBestMatching() -> Bool {
        // Courses substitutions placed stay where they are; the rest can be matched again.
        let pinned = Set(used.values.flatMap { $0.filter(\.bySubstitution).map(\.id) })
        let free = pool.keys.filter { !pinned.contains($0) }.sorted(by: comesFirst)
        guard !free.isEmpty, free.count <= CourseBits.capacity else { return false }
        let index = Dictionary(uniqueKeysWithValues: free.enumerated().map { ($1, $0) })
        let credits = free.map { max(0, pool[$0]?.credits ?? 0) }
        var all = CourseBits()
        for i in free.indices { all = all.union(CourseBits(i)) }

        // What each requirement still needs (those substitutions already meet need nothing).
        var needs: [Need] = []
        var electives: [Double] = []
        for rule in rules {
            switch effective[rule.id] {
            case .kind(.generalElectives(let hours), _)?:
                let counted = used[rule.id, default: []].filter(\.bySubstitution).reduce(0) { $0 + $1.credits }
                if counted < hours { electives.append(hours - counted) }
            case .kind(let kind, let anyCourse)?:
                if let need = need(for: rule.id, kind: kind, anyCourse: anyCourse, free: free, index: index) { needs.append(need) }
            default:
                break
            }
        }

        /// Scores compare specific requirements met first, then general electives.
        let electiveScale = rules.count + 1
        func electivesMet(_ available: CourseBits) -> Int {
            guard !electives.isEmpty else { return 0 }
            var left = free.indices.reduce(0.0) { available.has($1) ? $0 + credits[$1] : $0 }
            var met = 0
            for hours in electives where left >= hours {
                met += 1
                left -= hours
            }
            return met
        }

        var now = CourseBits()
        for id in available { if let i = index[id] { now = now.union(CourseBits(i)) } }
        let currentSpecific = needs.filter { isMet($0.ruleID) }.count
        let currentElectives = electivesMet(now)
        let current = currentSpecific * electiveScale + currentElectives
        // Only worth searching when something short could be met with the plan's courses.
        let mayImprove = needs.contains { !isMet($0.ruleID) && canStillMeet($0, within: all, credits: credits) }
            || electivesMet(all) > electivesMet(now)
        guard mayImprove else { return false }

        // Most constrained requirements first.
        let order = needs.indices.sorted {
            (fills(for: needs[$0], within: all, limit: 400).count, $0) < (fills(for: needs[$1], within: all, limit: 400).count, $1)
        }
        var best: [Int: [Int]]?
        var bestScore = current
        var bestSpecific = currentSpecific
        var bestElectives = currentElectives
        var chosen: [Int: [Int]] = [:]
        var visited: [SearchKey: Int] = [:]
        var nodes = 0
        let budget = 20_000

        // `met` counts specific requirements met so far.
        func visit(_ depth: Int, _ available: CourseBits, _ met: Int) {
            nodes += 1
            guard nodes <= budget else { return }
            let key = SearchKey(depth: depth, available: available)
            if let earlier = visited[key], earlier >= met { return }
            visited[key] = met
            // Everything still possible, at best.
            var optimistic = met
            for later in order[depth...] where canStillMeet(needs[later], within: available, credits: credits) {
                optimistic += 1
            }
            let electivesAtBest = electivesMet(available)
            guard optimistic * electiveScale + electivesAtBest > bestScore else { return }
            guard depth < order.count else {
                bestScore = optimistic * electiveScale + electivesAtBest
                bestSpecific = optimistic
                bestElectives = electivesAtBest
                best = chosen
                return
            }
            let n = order[depth]
            for fill in fills(for: needs[n], within: available, limit: 400) {
                let taken = fill.reduce(CourseBits()) { $0.union(needs[n].units[$1].bits) }
                chosen[n] = fill
                visit(depth + 1, available.subtracting(taken), met + 1)
                chosen[n] = nil
                if nodes > budget { return }
            }
            // Or leave this requirement short.
            visit(depth + 1, available, met)
        }
        visit(0, all, 0)

        guard let best else { return false }
        let meetsEverything = bestSpecific == needs.count && bestElectives == electives.count
        guard bestSpecific > currentSpecific || meetsEverything else { return false }
        adopt(best, needs: needs, free: free)
        return true
    }

    /// What a requirement still needs from the courses being matched; nil when its
    /// substitutions already meet it.
    private func need(for ruleID: String, kind: RequirementRule.Kind, anyCourse: Bool, free: [UseID], index: [UseID: Int]) -> Need? {
        let pinned = used[ruleID, default: []].filter(\.bySubstitution)
        switch kind {
        case .required(let option):
            guard pinned.isEmpty else { return nil }
            let units = option.alternatives.flatMap { alternative in
                assignments(of: alternative, from: free).map { unit($0, option: 0, index: index) }
            }
            return Need(ruleID: ruleID, amount: .alternative, units: units.sorted(by: isPreferred))
        case .choose(let count, let hours, let options, let ranges):
            let counted = Set(pinned.map { $0.satisfies ?? $0.key })
            var units: [Unit] = []
            for (number, option) in options.enumerated() where !option.allCourses.contains(where: counted.contains) {
                for alternative in option.alternatives {
                    units += assignments(of: alternative, from: free).map { unit($0, option: number, index: index) }
                }
            }
            if !ranges.isEmpty || anyCourse {
                var tag = options.count
                for id in free {
                    // As when filling: no labs or seminars when counting courses.
                    guard let use = pool[id], use.credits > 0, count == nil || use.credits >= 2,
                          let named = anyCourse ? use.key : courseInRange(use.key, ranges) else { continue }
                    units.append(unit([(named, id)], option: tag, index: index))
                    tag += 1
                }
            }
            let amount: Need.Amount
            if let count {
                guard count - pinned.count > 0 else { return nil }
                amount = .count(count - pinned.count)
            } else if let hours {
                let left = hours - pinned.reduce(0) { $0 + $1.credits }
                guard left > 0 else { return nil }
                amount = .hours(left)
                units.removeAll { $0.credits <= 0 }
            } else {
                guard pinned.isEmpty else { return nil }
                amount = .count(1)
            }
            return Need(ruleID: ruleID, amount: amount, units: units.sorted(by: isPreferred))
        case .generalElectives:
            return nil
        }
    }

    /// The ways (up to four) to give each course of an alternative a different course of the
    /// plan that is it or counts as it.
    private func assignments(of alternative: [CourseKey], from free: [UseID]) -> [[(named: CourseKey, taken: UseID)]] {
        let freeSet = Set(free)
        var seen = Set<CourseKey>()
        let named = alternative.filter { seen.insert($0).inserted }
        var results: [[(named: CourseKey, taken: UseID)]] = []
        var current: [(named: CourseKey, taken: UseID)] = []
        var claimed = Set<UseID>()
        func extend(_ position: Int) {
            guard results.count < 4 else { return }
            guard position < named.count else {
                results.append(current)
                return
            }
            let key = named[position]
            let candidates = (instances[key, default: []] + equivalences.equivalents(of: key).sorted().flatMap { instances[$0, default: []] })
                .filter { freeSet.contains($0) && !claimed.contains($0) }
            for id in candidates {
                current.append((key, id))
                claimed.insert(id)
                extend(position + 1)
                claimed.remove(id)
                current.removeLast()
            }
        }
        extend(0)
        return results
    }

    private func unit(_ pairs: [(named: CourseKey, taken: UseID)], option: Int, index: [UseID: Int]) -> Unit {
        let uses = pairs.compactMap { pool[$0.taken] }
        let bits = pairs.reduce(CourseBits()) { bits, pair in index[pair.taken].map { bits.union(CourseBits($0)) } ?? bits }
        return Unit(courses: pairs.map(\.taken), named: pairs.map(\.named), bits: bits, option: option,
                    credits: uses.reduce(0) { $0 + max(0, $1.credits) }, isCompleted: uses.allSatisfy(\.isCompleted),
                    order: uses.map(\.order).min() ?? 0)
    }

    /// Completed courses first, then fewer courses, then plan order: the matching found first
    /// reads best.
    private func isPreferred(_ a: Unit, _ b: Unit) -> Bool {
        (a.isCompleted ? 0 : 1, a.courses.count, a.order) < (b.isCompleted ? 0 : 1, b.courses.count, b.order)
    }

    /// The ways (up to `limit`) to meet a need from `available`: one alternative, a number of
    /// units of different options, or the fewest units that make the hours (no unit can be left
    /// out). Units never share a course.
    private func fills(for need: Need, within available: CourseBits, limit: Int) -> [[Int]] {
        let usable = need.units.indices.filter { available.contains(need.units[$0].bits) }
        var result: [[Int]] = []
        var chosen: [Int] = []
        switch need.amount {
        case .alternative:
            return Array(usable.prefix(limit).map { [$0] })
        case .count(let wanted):
            func pick(_ start: Int, _ taken: CourseBits, _ options: Set<Int>) {
                if chosen.count == wanted {
                    result.append(chosen)
                    return
                }
                guard usable.count - start >= wanted - chosen.count else { return }
                for position in start..<usable.count where result.count < limit {
                    let unit = need.units[usable[position]]
                    guard !taken.intersects(unit.bits), !options.contains(unit.option) else { continue }
                    chosen.append(usable[position])
                    pick(position + 1, taken.union(unit.bits), options.union([unit.option]))
                    chosen.removeLast()
                }
            }
            pick(0, CourseBits(), [])
        case .hours(let wanted):
            // Credits still to come after each position, to stop early.
            var later = [Double](repeating: 0, count: usable.count + 1)
            for position in usable.indices.reversed() { later[position] = later[position + 1] + need.units[usable[position]].credits }
            func pick(_ start: Int, _ taken: CourseBits, _ options: Set<Int>, _ credits: Double) {
                if credits >= wanted {
                    if chosen.allSatisfy({ credits - need.units[$0].credits < wanted }) { result.append(chosen) }
                    return
                }
                guard credits + later[start] >= wanted else { return }
                for position in start..<usable.count where result.count < limit {
                    let unit = need.units[usable[position]]
                    guard !taken.intersects(unit.bits), !options.contains(unit.option) else { continue }
                    chosen.append(usable[position])
                    pick(position + 1, taken.union(unit.bits), options.union([unit.option]), credits + unit.credits)
                    chosen.removeLast()
                }
            }
            pick(0, CourseBits(), [], 0)
        }
        return result
    }

    /// Whether a need might still be met from `available` (never false when it can be).
    private func canStillMeet(_ need: Need, within available: CourseBits, credits: [Double]) -> Bool {
        switch need.amount {
        case .alternative:
            return need.units.contains { available.contains($0.bits) }
        case .count(let wanted):
            var options = Set<Int>()
            for unit in need.units where available.contains(unit.bits) {
                options.insert(unit.option)
                if options.count >= wanted { return true }
            }
            return false
        case .hours(let wanted):
            let covered = need.units.reduce(CourseBits()) { available.contains($1.bits) ? $0.union($1.bits) : $0 }
            return credits.indices.reduce(0.0) { covered.has($1) ? $0 + credits[$1] : $0 } >= wanted
        }
    }

    /// Whether a requirement is met as matched so far.
    private func isMet(_ ruleID: String) -> Bool {
        switch effective[ruleID] {
        case .kind(.required(let option), _)?:
            let uses = used[ruleID, default: []]
            let keys = Set(uses.map { $0.satisfies ?? $0.key })
            return uses.contains(where: \.bySubstitution) || option.alternatives.contains { $0.allSatisfy(keys.contains) }
        case .kind(.choose(let count, let hours, _, _), _)?:
            return isSatisfied(ruleID, count: count, hours: hours)
        case .kind(.generalElectives(let hours), _)?:
            return used[ruleID, default: []].reduce(0) { $0 + $1.credits } >= hours
        default:
            return true
        }
    }

    /// Replaces the matching (all but substitutions) with the search's.
    private mutating func adopt(_ fills: [Int: [Int]], needs: [Need], free: [UseID]) {
        for need in needs {
            let pinned = used[need.ruleID, default: []].filter(\.bySubstitution)
            used[need.ruleID] = pinned
            optionsCounted[need.ruleID] = pinned.count
            singles[need.ruleID] = []
        }
        available = Set(free)
        for (n, chosen) in fills {
            let ruleID = needs[n].ruleID
            for position in chosen {
                let unit = needs[n].units[position]
                for (named, id) in zip(unit.named, unit.courses) { consume(id, for: ruleID, satisfying: named) }
                optionsCounted[ruleID, default: 0] += 1
                if unit.courses.count == 1 { singles[ruleID, default: []].insert(unit.courses[0]) }
            }
        }
    }
}
