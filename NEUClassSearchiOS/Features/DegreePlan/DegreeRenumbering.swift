//
//  DegreeRenumbering.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A course the plan has that is the required course under a new number (CS 3484 for IS 4800),
/// recorded as the equivalence it is instead of as a substitution, with what Undo needs to put the
/// plan back as it was.
struct DegreeRenumbering {
    /// The course the plan has (CS 3484).
    var course: CourseKey
    /// The course the requirement names, which it now counts as (IS 4800).
    var countsAs: CourseKey
    /// The substitution that was turned into the equivalence, and where it was in the plan's list;
    /// nil when the equivalence was declared without one.
    var substitution: RequirementSubstitution?
    var substitutionIndex = 0
    /// The equivalence that was declared; nil when the plan already counted the two as one course.
    var equivalenceID: UUID?

    /// `CS 3484 now counts as IS 4800`.
    var message: String { "\(course) now counts as \(countsAs)" }

    /// Whether Undo has anything to put back.
    var canUndo: Bool { substitution != nil || equivalenceID != nil }

    /// Turns a plan's "count a course" substitution into the equivalence it amounts to: the
    /// course then counts as the required one everywhere, shown like any renumbered course.
    /// Nil when the substitution isn't in the plan or isn't a renumbering (the requirement must
    /// name exactly one course).
    @MainActor
    static func convert(_ substitution: RequirementSubstitution, planID: UUID, requirements: ProgramRequirements?,
                        userData: UserDataStore) -> DegreeRenumbering? {
        guard let plan = userData.degreePlan(id: planID),
              let index = plan.substitutions.firstIndex(where: { $0.id == substitution.id }),
              let equivalence = DegreeSubstitutionEditing.renumbering(for: plan.substitutions[index], requirements: requirements) else { return nil }
        let stored = plan.substitutions[index]
        let known = Set(plan.courseEquivalences.map(\.id))
        userData.updateDegreePlan(id: planID) { DegreeSubstitutionEditing.convertToEquivalence(stored, requirements: requirements, in: &$0) }
        let declared = userData.degreePlan(id: planID)?.courseEquivalences.first { !known.contains($0.id) }?.id
        return DegreeRenumbering(course: equivalence.course, countsAs: equivalence.countsAs, substitution: stored,
                                 substitutionIndex: index, equivalenceID: declared)
    }

    /// Declares that `course` is `countsAs` under a new number, for a substitution that hasn't
    /// been saved. Nil when the courses are the same.
    @MainActor
    static func declare(course: CourseKey, countsAs: CourseKey, planID: UUID, userData: UserDataStore) -> DegreeRenumbering? {
        guard course != countsAs, userData.degreePlan(id: planID) != nil else { return nil }
        let id = userData.declareDegreeEquivalence(planID: planID, course: course, countsAs: countsAs, note: "Renumbered")
        return DegreeRenumbering(course: course, countsAs: countsAs, equivalenceID: id)
    }

    /// Puts the substitution back where it was and removes the equivalence, leaving anything else
    /// that changed in the meantime alone.
    @MainActor
    func undo(planID: UUID, userData: UserDataStore) {
        userData.updateDegreePlan(id: planID) { plan in
            if let equivalenceID { plan.removeEquivalence(id: equivalenceID) }
            if let substitution, !plan.substitutions.contains(where: { $0.id == substitution.id }) {
                plan.substitutions.insert(substitution, at: min(max(0, substitutionIndex), plan.substitutions.count))
            }
        }
    }

    /// The substitutions that are most likely a course under a new number (the required course is no
    /// longer offered, the substitute is), by substitution id, without the ones the student kept as
    /// substitutions (`dismissed`, the pair ids `DegreeEquivalenceDismissals` keeps).
    ///
    /// - Parameter isRetired: whether a course is no longer offered, nil when that isn't known; by
    ///   default what Banner's course catalog has said (`CourseInfoStore`).
    @MainActor
    static func likely(in plan: DegreePlan, requirements: ProgramRequirements?, dismissed: Set<String>,
                       isRetired: ((CourseKey) -> Bool?)? = nil) -> [UUID: DegreeSubstitutionEditing.LikelyRenumbering] {
        let retired = isRetired ?? { CourseInfoStore.shared.info(for: $0)?.isRetired }
        let found = DegreeSubstitutionEditing.likelyRenumberings(in: plan, requirements: requirements, isRetired: retired)
            .filter { !dismissed.contains(DegreeEquivalencePrompt.pairID($0.course, $0.countsAs)) }
        return Dictionary(found.map { ($0.substitution.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The substitutions of a plan that amount to a renumbered course (the requirement names exactly
    /// one course, and the substitute isn't it), by id.
    static func renumberable(in plan: DegreePlan, requirements: ProgramRequirements?) -> Set<UUID> {
        Set(plan.substitutions.filter { DegreeSubstitutionEditing.renumbering(for: $0, requirements: requirements) != nil }.map(\.id))
    }

    /// The courses to look up in Banner to know whether a renumbering-shaped substitution's
    /// requirement is retired: the course it names and the course that stands in for it.
    static func coursesToLookUp(in plan: DegreePlan, requirements: ProgramRequirements?) -> [CourseKey] {
        var seen = Set<CourseKey>()
        return plan.substitutions
            .compactMap { DegreeSubstitutionEditing.renumbering(for: $0, requirements: requirements) }
            .flatMap { [$0.countsAs, $0.course] }
            .filter { seen.insert($0).inserted }
    }
}
