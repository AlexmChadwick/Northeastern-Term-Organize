//
//  ScheduleGeneratorSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Generator input and favorites

extension ScheduleCourseInput {
    /// What the generator works from: one entry per course of `plan`, with every section the term
    /// lists and the credits rounded up to whole credits.
    static func inputs(for plan: SchedulePlan, index: CatalogIndex) -> [ScheduleCourseInput] {
        plan.courses.map { planCourse in
            let course = index.course(planCourse.key)
            return ScheduleCourseInput(
                key: planCourse.key, isRequired: planCourse.isRequired, sections: index.sections(for: planCourse.key),
                excludedCRNs: planCourse.excludedCRNs,
                minCredits: Int((course?.minCredits ?? 0).rounded(.up)),
                maxCredits: Int((course?.maxCredits ?? 0).rounded(.up))
            )
        }
    }
}

extension GeneratedSchedule {
    /// The plan's starred combinations, newest first, measured like generated schedules. A favorite is
    /// skipped when it can no longer be applied: a section is gone from the catalog, or its course was
    /// removed from the plan.
    static func favorites(of plan: SchedulePlan, index: CatalogIndex, preferences: SchedulePreferences) -> [GeneratedSchedule] {
        let order = Dictionary(plan.courses.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.favoriteCombinations.reversed().compactMap { crns in
            let sections = crns.compactMap { index.section(crn: $0) }
            guard sections.count == crns.count, !sections.isEmpty,
                  sections.allSatisfy({ order[$0.courseKey] != nil }) else { return nil }
            let ordered = sections.sorted { (order[$0.courseKey] ?? .max) < (order[$1.courseKey] ?? .max) }
            return GeneratedSchedule(sections: ordered, preferences: preferences)
        }
    }
}

// MARK: - Loosening a rule

extension PlanEditing {
    /// Applies one of the "no schedules fit" suggestions: making a course optional edits the plan,
    /// a preference suggestion edits the plan's preferences, and the rest loosen its filters.
    static func apply(_ relaxation: ScheduleRelaxation, to plan: inout SchedulePlan) {
        switch relaxation {
        case .makeOptional(let key):
            setRequired(false, for: key, in: &plan)
        case .preference:
            var preferences = plan.preferences ?? SchedulePreferences()
            relaxation.apply(to: &preferences)
            plan.preferences = preferences.isDefault ? nil : preferences
        default:
            relaxation.apply(to: &plan.filters)
        }
    }

    /// Makes courses optional, so they are only added to a schedule when they fit.
    static func makeOptional(_ keys: [CourseKey], in plan: inout SchedulePlan) {
        for key in keys { setRequired(false, for: key, in: &plan) }
    }
}

// MARK: - Rearranging the degree plan

extension ScheduleReorderSuggestions {
    /// The semester of the primary degree plan that matches a schedule's term: the one whose courses
    /// can be rearranged to make the schedule work.
    static func semester(
        for plan: SchedulePlan, degreePlan: DegreePlan?, terms: [Term], index: CatalogIndex?
    ) -> (plan: DegreePlan, term: Term)? {
        guard let degreePlan else { return nil }
        let term = ScheduleAutofillSupport.term(for: plan.termCode, terms: terms, index: index)
        guard degreePlan.term(matching: term) != nil else { return nil }
        return (degreePlan, term)
    }
}

/// What applying a degree plan rearrangement did.
enum ScheduleReorderOutcome {
    /// The degree plan has changed since the suggestion was made: nothing was done.
    case stale
    /// The degree plan and the schedule were changed; `undo` puts both back as they were.
    case applied(undo: @MainActor () -> Void)
}

enum ScheduleReorderApplication {
    /// Applies a degree plan rearrangement. The courses it moves to another semester come out of the
    /// schedule, and the ones it brings into this semester are added when they are offered this term.
    @MainActor
    static func apply(_ option: ScheduleReorderOption, toPlan planID: UUID, index: CatalogIndex?, userData: UserDataStore) -> ScheduleReorderOutcome {
        guard let plan = userData.plan(id: planID), let degreePlan = userData.primaryDegreePlan else { return .stale }
        // A suggestion is made for the degree plan as it was: when it has changed since, applying it does nothing.
        var trial = degreePlan
        option.apply(&trial)
        guard trial.terms != degreePlan.terms else { return .stale }
        let degreePlanBefore = degreePlan
        userData.updateDegreePlan(id: degreePlan.id) { option.apply(&$0) }

        var removals: [PlanCourseRemoval] = []
        for key in option.movedAway {
            guard let planCourse = plan.course(key) else { continue }
            let crns = Set(index?.sections(for: key).map(\.crn) ?? [])
            removals.append(PlanCourseRemoval(
                course: planCourse,
                index: plan.courses.firstIndex { $0.key == key } ?? plan.courses.count,
                selectedCRNs: plan.selectedCRNs.filter { crns.contains($0) },
                favoriteCombinations: plan.favoriteCombinations.filter { $0.contains { crns.contains($0) } }
            ))
            userData.removeCourse(key, fromPlan: planID, sectionsOfCourse: Array(crns))
        }
        var added: [CourseKey] = []
        for key in option.movedIn where !(index?.sections(for: key).isEmpty ?? true) {
            if userData.addCourse(key, toPlan: planID, required: true) { added.append(key) }
        }

        return .applied {
            userData.replaceDegreePlan(id: degreePlanBefore.id, with: degreePlanBefore)
            for key in added { userData.removeCourse(key, fromPlan: planID) }
            userData.updatePlan(id: planID) { plan in
                for removal in removals.reversed() { PlanEditing.restore(removal, in: &plan) }
            }
        }
    }
}

// MARK: - Editing a schedule's courses

/// Edits of a schedule's course list that the iPhone and the Mac screens share.
@MainActor
enum SchedulePlanActions {
    /// Removes a course from a plan, with its chosen sections and the favorite combinations that used
    /// it, and returns what is needed to put it back (`PlanEditing.restore`).
    static func removeCourse(_ entry: ResolvedPlan.Entry, from plan: SchedulePlan, index: CatalogIndex?, userData: UserDataStore) -> PlanCourseRemoval {
        // Every CRN of the course: the catalog's sections, plus anything selected for it.
        var crns = entry.courseCRNs.union(entry.selected.map(\.crn))
        if let index { crns.formUnion(index.sections(for: entry.key).map(\.crn)) }
        let removal = PlanCourseRemoval(
            course: entry.planCourse,
            index: plan.courses.firstIndex { $0.key == entry.key } ?? plan.courses.count,
            selectedCRNs: plan.selectedCRNs.filter { crns.contains($0) },
            favoriteCombinations: plan.favoriteCombinations.filter { $0.contains { crns.contains($0) } }
        )
        userData.removeCourse(entry.key, fromPlan: plan.id, sectionsOfCourse: Array(crns))
        return removal
    }

    /// Removes selections (and favorites) left behind by a removed course once the catalog can say
    /// which sections belonged to it: without a loaded catalog the course's CRNs weren't known.
    static func pruneLeftovers(of removal: PlanCourseRemoval, planID: UUID, termCode: String, catalog: CatalogStore, userData: UserDataStore) async {
        guard let index = await catalog.index(for: termCode) else { return }
        userData.updatePlan(id: planID) { plan in
            let pruned = PlanEditing.pruneOrphans(using: index, in: &plan)
            // Only what belonged to this course is undone with it.
            let own: (String) -> Bool = { index.section(crn: $0)?.courseKey == removal.course.key }
            removal.selectedCRNs.append(contentsOf: pruned.selected.filter { own($0) && !removal.selectedCRNs.contains($0) })
            removal.favoriteCombinations.append(contentsOf: pruned.favorites.filter { combination in
                combination.contains(where: own) && !removal.favoriteCombinations.contains(combination)
            })
        }
    }

    /// Adds every course of an autofill suggestion as a required course; returns the ones that were
    /// not in the schedule yet.
    static func addAutofill(_ suggestion: ScheduleAutofillSuggestion, toPlan planID: UUID, userData: UserDataStore) -> [CourseKey] {
        var added: [CourseKey] = []
        for key in suggestion.courses where userData.addCourse(key, toPlan: planID, required: true) {
            added.append(key)
        }
        return added
    }

    /// Takes out just the courses an autofill added.
    static func undoAutofill(_ keys: [CourseKey], planID: UUID, index: CatalogIndex?, userData: UserDataStore) {
        for key in keys {
            let crns = index?.sections(for: key).map(\.crn) ?? []
            userData.removeCourse(key, fromPlan: planID, sectionsOfCourse: crns)
        }
    }
}
