//
//  DegreeRequirementsAnnotation.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Course status

/// Where a course stands in the student's plan: the requirements page's status column.
enum DegreeCourseStatus: Equatable {
    /// On the degree audit's completed list. `term` is a best-effort hint from a past schedule
    /// (the audit doesn't record when courses were taken).
    case completed(term: String?)
    /// Completed per the audit (or planned) in a term that's in session now.
    case inProgress(term: String)
    case planned(term: String)
    case notInPlan
    /// Not needed: a substitution meets the requirement that lists it.
    case notNeeded

    /// `Completed`, `In progress · Fall 2026`, `Planned · Spring 2027`, `Not in plan`.
    var label: String {
        switch self {
        case .completed(let term): term.map { "Completed · \($0)" } ?? "Completed"
        case .inProgress(let term): "In progress · \(term)"
        case .planned(let term): "Planned · \(term)"
        case .notInPlan: "Not in plan"
        case .notNeeded: "Not needed"
        }
    }

    /// For VoiceOver: `completed`, `in progress, Fall 2026`, `planned for Spring 2027`.
    var spoken: String {
        switch self {
        case .completed(let term): term.map { "completed, \($0)" } ?? "completed"
        case .inProgress(let term): "in progress, \(term)"
        case .planned(let term): "planned for \(term)"
        case .notInPlan: "not in plan"
        case .notNeeded: "not needed"
        }
    }

    var color: Color {
        switch self {
        case .completed: .green
        case .inProgress, .planned: .blue
        case .notInPlan, .notNeeded: .secondary
        }
    }

    var isInPlan: Bool { self != .notInPlan && self != .notNeeded }
}

// MARK: - Lookup

/// How a course the catalog lists stands for one requirement: its status, whether it counts
/// toward the requirement (itself, through an equivalent course, or by substitution), a caption,
/// and what "Add to plan" would add.
struct DegreeCourseRowInfo {
    var status: DegreeCourseStatus
    var isCountedHere = false
    var bySubstitution = false
    var caption: String?
    /// The course "Add to plan" adds: the listed course, or a current equivalent of one that is
    /// no longer offered; nil when there is nothing to add.
    var addKey: CourseKey?
}

/// Answers, for any course the catalog lists: is it in the plan (and when), where does the
/// audit count it, and what is it called. Built once per screen update.
struct DegreeCourseLookup {
    let requirements: ProgramRequirements
    let audit: DegreeAudit
    /// Which courses count as which: Banner's and the plan's declared ones.
    let equivalences: CourseEquivalences
    private let choices: [CourseKey: DegreePlanCourseChoice]
    private let planKeys: Set<CourseKey>
    /// What Banner's course catalog said about courses (retired ones, titles, credits).
    private let infoStates: [CourseKey: CourseInfoStore.LookupState]
    private let countedBy: [CourseKey: (ruleID: String, use: DegreeAudit.CourseUse)]
    private let inProgressHints: [CourseKey: String]
    private let completedHints: [CourseKey: String]
    private let semestersInSession: Set<String>
    private let bannerCourse: (CourseKey) -> Course?

    /// - Parameters:
    ///   - schedulePlans: the user's schedules; "My Schedule" plans hint when completed
    ///     courses were (or are being) taken.
    ///   - termName: a Banner term code's short name (`Fall 2026`).
    ///   - bannerCourse: the Banner catalog's course, for titles and credits.
    init(plan: DegreePlan, requirements: ProgramRequirements, audit: DegreeAudit, schedulePlans: [SchedulePlan],
         termName: (String) -> String, bannerCourse: @escaping (CourseKey) -> Course?,
         equivalences: CourseEquivalences = .none, infoStates: [CourseKey: CourseInfoStore.LookupState] = [:], now: Date = .now) {
        self.requirements = requirements
        self.audit = audit
        self.bannerCourse = bannerCourse
        self.equivalences = equivalences.merging(plan.declaredEquivalences)
        self.infoStates = infoStates
        choices = Dictionary(plan.degreeCourseChoices.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        planKeys = Set(choices.keys)

        var countedBy: [CourseKey: (ruleID: String, use: DegreeAudit.CourseUse)] = [:]
        for result in audit.ruleResults {
            for use in result.used where countedBy[use.key] == nil {
                countedBy[use.key] = (result.rule.id, use)
            }
        }
        self.countedBy = countedBy

        var inProgress: [CourseKey: String] = [:]
        var completed: [CourseKey: (name: String, end: Date)] = [:]
        for schedule in schedulePlans where schedule.isPrimary {
            guard let window = TermCalendar.approximateWindow(for: schedule.termCode) else { continue }
            let name = termName(schedule.termCode)
            for course in schedule.courses {
                if window.contains(now) {
                    inProgress[course.key] = name
                } else if window.upperBound < now, (completed[course.key]?.end ?? .distantPast) < window.upperBound {
                    completed[course.key] = (name, window.upperBound)
                }
            }
        }
        inProgressHints = inProgress
        completedHints = completed.mapValues(\.name)
        semestersInSession = Set(plan.terms.filter { term in
            TermCalendar.approximateWindow(for: term.degreePlanBannerCode)?.contains(now) ?? false
        }.map(\.name))
    }

    func status(of key: CourseKey) -> DegreeCourseStatus {
        guard let choice = choices[key] else { return .notInPlan }
        if let semester = choice.semester {
            let name = choice.semesterShortName ?? semester
            return semestersInSession.contains(semester) ? .inProgress(term: name) : .planned(term: name)
        }
        if let term = inProgressHints[key] { return .inProgress(term: term) }
        return .completed(term: completedHints[key])
    }

    /// The catalog's title, else Banner's (a loaded term's, then its course catalog's), else the
    /// plan's.
    func title(of key: CourseKey) -> String? {
        requirements.courseTitles[key] ?? bannerCourse(key)?.title ?? infoStates[key]?.degreeInfo?.title.nilIfBlank
            ?? choices[key]?.title.nilIfBlank
    }

    /// The credits of the listing the audit counts (a 0-credit line is often a repeat of a
    /// counted course), else the plan's, else Banner's.
    func credits(of key: CourseKey) -> Double? {
        if let counted = countedBy[key]?.use.credits, counted > 0 { return counted }
        if let planned = choices[key]?.credits, planned > 0 { return planned }
        return bannerCourse(key)?.maxCredits ?? infoStates[key]?.degreeInfo?.maxCredits ?? choices[key]?.credits
    }

    // MARK: Equivalences and retired courses

    /// Only catalogs older than the newest term list the course.
    func isRetired(_ key: CourseKey) -> Bool { infoStates[key]?.degreeIsRetired ?? false }

    /// `No longer offered; last listed Spring 2025`, or `Not in Banner's catalog for recent
    /// terms`; nil for a current course (or one not looked up).
    func offeringNote(for key: CourseKey) -> String? {
        if let retired = infoStates[key]?.degreeRetiredNote { return retired }
        return infoStates[key] == .notFound ? "Not in Banner’s catalog for recent terms" : nil
    }

    /// A course of the plan that counts as `key` (not `key` itself).
    func equivalentInPlan(of key: CourseKey) -> CourseKey? {
        equivalences.satisfiers(of: key, in: planKeys).first { $0 != key }
    }

    /// A course that counts as `key` and is still offered, to plan instead of a retired one.
    func currentEquivalent(of key: CourseKey) -> CourseKey? {
        equivalences.equivalents(of: key).sorted().first { !isRetired($0) }
    }

    /// Where a listed course stands for a requirement. Pass `counted` for a course the
    /// requirement counts that it doesn't list.
    func rowInfo(for key: CourseKey, in result: DegreeAudit.RuleResult, counted: DegreeAudit.CourseUse? = nil) -> DegreeCourseRowInfo {
        if let use = counted ?? result.use(for: key) {
            if use.key != key {
                // Another course of the plan counts as this one (CS 2510 for CS 2100).
                return DegreeCourseRowInfo(
                    status: status(of: use.key), isCountedHere: true, bySubstitution: use.bySubstitution,
                    caption: "Via \(use.key) (\(use.countsAsLabel ?? "counts as \(key)"))"
                )
            }
            return DegreeCourseRowInfo(
                status: status(of: key), isCountedHere: true, bySubstitution: use.bySubstitution,
                caption: use.satisfies.map { "Counts as \($0)" }
            )
        }
        if choices[key] == nil, case .required = result.effectiveKind, result.status.isSatisfied,
           let substitute = result.used.first(where: \.bySubstitution) {
            // A substitution meets this requirement, so the courses it lists aren't needed.
            return DegreeCourseRowInfo(status: .notNeeded, caption: "\(substitute.key.description) counts instead")
        }
        if choices[key] != nil {
            return DegreeCourseRowInfo(status: status(of: key), caption: countingCaption(for: key, except: result.rule.id))
        }
        if let equivalent = equivalentInPlan(of: key) {
            // The plan has it under another number, counted elsewhere or not needed here.
            var caption = "\(equivalent) counts as this course"
            if let elsewhere = countingCaption(for: equivalent, except: result.rule.id), countedBy[equivalent] != nil {
                caption += " · \(elsewhere)"
            }
            return DegreeCourseRowInfo(status: status(of: equivalent), caption: caption)
        }
        if isRetired(key) {
            // It can't be taken any more: offer what replaced it, when that's known.
            let current = currentEquivalent(of: key)
            let caption = [offeringNote(for: key), current.map { "\($0) counts as it" }].compactMap { $0 }.joined(separator: " · ")
            return DegreeCourseRowInfo(status: .notInPlan, caption: caption, addKey: current)
        }
        return DegreeCourseRowInfo(status: .notInPlan, caption: offeringNote(for: key), addKey: key)
    }

    /// The requirement the audit counts a course toward, if any.
    func countingRuleID(of key: CourseKey) -> String? { countedBy[key]?.ruleID }

    func isCountedBySubstitution(_ key: CourseKey) -> Bool { countedBy[key]?.use.bySubstitution ?? false }

    /// `Counts toward Khoury Elective Courses`, `Counts as a general elective`, or (for a
    /// course in the plan that counts nowhere) `Doesn't count toward a requirement`.
    func countingCaption(for key: CourseKey, except ruleID: String? = nil) -> String? {
        guard choices[key] != nil else { return nil }
        guard let counting = countedBy[key]?.ruleID else { return "Doesn’t count toward a requirement" }
        guard counting != ruleID else { return nil }
        if requirements.rule(id: counting)?.degreeIsGeneralElectives == true { return "Counts as a general elective" }
        return "Counts toward \(requirements.degreeCountingName(ofRule: counting, for: key) ?? "another requirement")"
    }

    /// The plan's semesters a course can still be added to; when there are none, the next
    /// few (added as new semesters).
    static func addTargets(for plan: DegreePlan) -> [DegreePlanTerm] {
        let upcoming = plan.terms.filter { !$0.degreePlanHasEnded() }
        return upcoming.isEmpty ? Array(DegreePlanAutofill.nextSemesters(after: plan).prefix(3)) : upcoming
    }

    /// A Banner term code's short name: `Fall 2026`, `Summer A 2027`.
    static func termName(code: String, terms: [Term]) -> String {
        if let term = terms.first(where: { $0.code == code }), !term.bannerDescription.isEmpty, !term.bannerDescription.hasPrefix("Term ") {
            return term.shortName
        }
        let term = Term(code: code, bannerDescription: "")
        return DegreePlanTerm(season: PlanSeason(termSeason: term.season), year: term.calendarYear).shortName
    }
}

extension DegreeCourseLookup {
    /// Builds the lookup from the app's stores.
    @MainActor
    static func make(plan: DegreePlan, requirements: ProgramRequirements, audit: DegreeAudit,
                     userData: UserDataStore, catalog: CatalogStore) -> DegreeCourseLookup {
        let snapshot = catalog.degreePlanSnapshot()
        let terms = catalog.terms
        let info = CourseInfoStore.shared
        let keys = plan.degreePlanCourseKeys + requirements.degreeListedCourses(concentrationID: plan.concentrationID)
        return DegreeCourseLookup(
            plan: plan,
            requirements: requirements,
            audit: audit,
            schedulePlans: userData.plans,
            termName: { termName(code: $0, terms: terms) },
            bannerCourse: { snapshot.course($0) },
            equivalences: info.equivalences(for: plan),
            infoStates: info.degreeLookupStates(for: keys)
        )
    }
}

// MARK: - Progress wording

extension DegreeRequirementText {
    /// A list's or hour requirement's progress: `1 of 1 done`, `2 of 2 planned`, `Needs 1 more`,
    /// `Needs 4 more semester hours`, `Waived`.
    static func progress(_ result: DegreeAudit.RuleResult) -> String {
        let verb = result.status == .planned ? "planned" : "done"
        switch result.effectiveKind {
        case nil:
            return "Waived"
        case .required:
            return result.status.isSatisfied ? (result.status == .planned ? "Planned" : "Done") : (remaining(result) ?? "Not in plan")
        case .choose(let count, let hours, _, _):
            if let count {
                let left = result.remainingCount ?? 0
                return left == 0 ? "\(count) of \(count) \(verb)" : "Needs \(left) more"
            }
            if let hours {
                let left = result.remainingHours ?? 0
                return left == 0 ? "\(CreditFormatter.number(hours)) of \(Self.hours(hours)) \(verb)" : "Needs \(Self.hours(left)) more"
            }
            return result.status.isSatisfied ? verb.capitalized : "Needs 1 more"
        case .generalElectives(let hours):
            let left = result.remainingHours ?? 0
            return left == 0 ? "\(CreditFormatter.number(hours)) of \(Self.hours(hours)) \(verb)" : "Needs \(Self.hours(left)) more"
        }
    }
}
