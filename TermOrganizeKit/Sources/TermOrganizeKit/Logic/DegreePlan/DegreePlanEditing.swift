//
//  DegreePlanEditing.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Edits to a degree plan, written as functions on `inout DegreePlan` so they work
/// with `UserDataStore.updateDegreePlan(id:_:)` and are easy to reason about.
enum DegreePlanEditing {
    // MARK: Courses

    static func removePlannedCourse(_ courseID: UUID, from plan: inout DegreePlan) {
        for index in plan.terms.indices {
            plan.terms[index].courses.removeAll { $0.id == courseID }
        }
    }

    static func removeCompletedCourse(_ courseID: UUID, from plan: inout DegreePlan) {
        plan.completed.removeAll { $0.id == courseID }
    }

    /// Appends a course to a semester.
    static func add(_ course: DegreePlanCourse, toTerm termID: UUID, in plan: inout DegreePlan) {
        guard let index = plan.terms.firstIndex(where: { $0.id == termID }) else { return }
        plan.terms[index].courses.append(course)
    }

    /// Appends a course to the plan's semester for `semester`'s season and year, adding the
    /// semester first when the plan doesn't have it.
    static func addCourse(_ course: DegreePlanCourse, to semester: DegreePlanTerm, in plan: inout DegreePlan) {
        addTerm(semester, to: &plan)
        guard let index = plan.terms.firstIndex(where: { $0.season == semester.season && $0.year == semester.year }) else { return }
        plan.terms[index].courses.append(course)
    }

    /// Puts another course in a planned course's place (same semester and position), such as
    /// the new number of a course that is no longer offered.
    static func replacePlannedCourse(_ courseID: UUID, with replacement: DegreePlanCourse, in plan: inout DegreePlan) {
        for index in plan.terms.indices {
            if let position = plan.terms[index].courses.firstIndex(where: { $0.id == courseID }) {
                plan.terms[index].courses[position] = replacement
                return
            }
        }
    }

    /// Moves a planned course to the end of another semester.
    static func move(_ courseID: UUID, toTerm termID: UUID, in plan: inout DegreePlan) {
        guard let destination = plan.terms.firstIndex(where: { $0.id == termID }),
              let moved = takePlannedCourse(courseID, from: &plan) else { return }
        plan.terms[destination].courses.append(moved)
    }

    /// Moves a planned course to a semester at a position (0 is the top), the way dropping it
    /// between two courses does. The course may already be in that semester, which reorders it.
    static func move(_ courseID: UUID, toTerm termID: UUID, at position: Int, in plan: inout DegreePlan) {
        guard let destination = plan.terms.firstIndex(where: { $0.id == termID }) else { return }
        var index = position
        if let current = plan.terms[destination].courses.firstIndex(where: { $0.id == courseID }), current < position {
            // Taking the course out moves everything after it up by one.
            index -= 1
        }
        guard let moved = takePlannedCourse(courseID, from: &plan) else { return }
        plan.terms[destination].courses.insert(moved, at: min(max(0, index), plan.terms[destination].courses.count))
    }

    /// Moves a planned course onto the completed list. A number already completed stays
    /// there as its own row, so a second copy is not thrown away.
    static func markCompleted(_ courseID: UUID, in plan: inout DegreePlan) {
        guard let moved = takePlannedCourse(courseID, from: &plan) else { return }
        plan.completed.append(moved)
    }

    private static func takePlannedCourse(_ courseID: UUID, from plan: inout DegreePlan) -> DegreePlanCourse? {
        for index in plan.terms.indices {
            if let position = plan.terms[index].courses.firstIndex(where: { $0.id == courseID }) {
                return plan.terms[index].courses.remove(at: position)
            }
        }
        return nil
    }

    // MARK: Semesters

    static func removeTerm(_ termID: UUID, from plan: inout DegreePlan) {
        plan.terms.removeAll { $0.id == termID }
    }

    /// Adds a semester unless the plan already has it.
    static func addTerm(_ term: DegreePlanTerm, to plan: inout DegreePlan) {
        guard !plan.terms.contains(where: { $0.season == term.season && $0.year == term.year }) else { return }
        plan.terms.append(term)
        plan.sortTerms()
    }

    // MARK: Degree requirements

    /// Keeps a plan's degree requirement setup, substitutions and star when its courses are
    /// replaced (re-importing the degree audit's PDF).
    static func carryOverRequirements(from existing: DegreePlan, to plan: inout DegreePlan) {
        plan.catalogYear = existing.catalogYear
        plan.catalogProgramPath = existing.catalogProgramPath
        plan.catalogProgramTitle = existing.catalogProgramTitle
        plan.concentrationID = existing.concentrationID
        plan.substitutions = existing.substitutions
        plan.isPrimary = existing.isPrimary
    }

    // MARK: Student info

    static func removeStudentInfo(from plan: inout DegreePlan) {
        plan.studentName = nil
        plan.studentID = nil
    }

    // MARK: Copies and names

    /// A copy of a plan with fresh identifiers, named "<name> copy" (numbered when taken).
    static func duplicate(_ plan: DegreePlan, existingNames: [String]) -> DegreePlan {
        var copy = plan
        copy.id = UUID()
        copy.name = uniqueName("\(plan.name) copy", existing: existingNames)
        copy.isPrimary = false
        copy.importedFrom = nil
        copy.printedAt = nil
        copy.createdAt = .now
        copy.updatedAt = .now
        copy.completed = plan.completed.map(withFreshID)
        copy.terms = plan.terms.map { term in
            var fresh = term
            fresh.id = UUID()
            fresh.courses = term.courses.map(withFreshID)
            return fresh
        }
        return copy
    }

    private static func withFreshID(_ course: DegreePlanCourse) -> DegreePlanCourse {
        var fresh = course
        fresh.id = UUID()
        return fresh
    }

    /// `base`, or `base 2`, `base 3`… when the name is taken (ignoring case).
    static func uniqueName(_ base: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let wanted = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taken.contains(wanted.lowercased()) else { return wanted }
        var number = 2
        while taken.contains("\(wanted) \(number)".lowercased()) { number += 1 }
        return "\(wanted) \(number)"
    }

    /// `New Plan`, or `New Plan 2` when taken.
    static func defaultNewPlanName(existing: [String]) -> String {
        uniqueName("New Plan", existing: existing)
    }

    /// The name of a schedule built from a semester: `Spring 2027 plan`.
    static func scheduleName(for semester: DegreePlanTerm, existing: [String]) -> String {
        uniqueName("\(semester.name) plan", existing: existing)
    }

    /// An existing plan an import would replace: same name and program.
    static func existingMatch(for plan: DegreePlan, name: String, in plans: [DegreePlan]) -> DegreePlan? {
        let wantedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedProgram = (plan.program ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return plans
            .filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wantedName) == .orderedSame
                    && ($0.program ?? "").trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wantedProgram) == .orderedSame
            }
            .max { $0.updatedAt < $1.updatedAt }
    }
}
