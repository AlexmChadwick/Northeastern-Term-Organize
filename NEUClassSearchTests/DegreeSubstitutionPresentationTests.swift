//
//  DegreeSubstitutionPresentationTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// What the iPhone and iPad requirements screens decide before drawing: a substitution that is
/// really a renumbered course (and undoing that), which counted courses sit under the requirement
/// they replace, and which sentences of the catalog show for each filter.
@MainActor
struct DegreeSubstitutionPresentationTests {
    private static let cs3000 = CourseKey(subject: "CS", number: "3000")
    private static let cs3001 = CourseKey(subject: "CS", number: "3001")
    private static let cs4535 = CourseKey(subject: "CS", number: "4535")
    private static let cs4973 = CourseKey(subject: "CS", number: "4973")
    private static let cy3740 = CourseKey(subject: "CY", number: "3740")

    private func store() -> (UserDataStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UserData-\(UUID().uuidString).json")
        return (UserDataStore(fileURL: url), url)
    }

    private func rule(_ label: String, in requirements: ProgramRequirements) throws -> RequirementRule {
        try #require(requirements.allRules.first { $0.label == label })
    }

    /// The made-up program's student, who took CS 3001 where the catalog names CS 3000, and whose
    /// adviser approved it with a substitution (the first), beside another that waives a requirement.
    private func renumberedPlan(_ requirements: ProgramRequirements) throws -> (plan: DegreePlan, renumbering: RequirementSubstitution, waiver: RequirementSubstitution) {
        var plan = DegreeRequirementsTests.plan()
        plan.completed.removeAll { $0.key == Self.cs3000 }
        plan.completed.append(DegreeRequirementsTests.course("CS 3001"))
        let required = try rule("CS 3000", in: requirements)
        let security = try rule("Complete one of the following:", in: requirements)
        let renumbering = RequirementSubstitution(ruleID: required.id, ruleTitle: "CS 3000", change: .countCourse(Self.cs3001), note: "Approved")
        let waiver = RequirementSubstitution(ruleID: security.id, ruleTitle: "Security Course", change: .waive)
        plan.substitutions = [renumbering, waiver]
        return (plan, renumbering, waiver)
    }

    // MARK: Same course, new number

    @Test func onlyASubstitutionForOneNamedCourseIsARenumbering() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let (plan, renumbering, waiver) = try renumberedPlan(requirements)
        let either = try rule("CS 4500 or CS 4530", in: requirements)
        var other = plan
        other.substitutions += [
            // Two courses name the requirement, so no one of them is what the substitute replaced.
            RequirementSubstitution(ruleID: either.id, ruleTitle: "CS 4500 or CS 4530", change: .countCourse(Self.cs4535)),
            // The required course itself is no renumbering.
            RequirementSubstitution(ruleID: renumbering.ruleID, ruleTitle: "CS 3000", change: .countCourse(Self.cs3000)),
        ]
        #expect(DegreeRenumbering.renumberable(in: other, requirements: requirements) == [renumbering.id])
        #expect(!DegreeRenumbering.renumberable(in: other, requirements: requirements).contains(waiver.id))

        // Banner is asked about both courses, once each.
        #expect(DegreeRenumbering.coursesToLookUp(in: other, requirements: requirements) == [Self.cs3000, Self.cs3001])
        var none = plan
        none.substitutions = [waiver]
        #expect(DegreeRenumbering.coursesToLookUp(in: none, requirements: requirements).isEmpty)
    }

    @Test func turnsASubstitutionIntoTheEquivalenceItAmountsTo() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let (plan, renumbering, waiver) = try renumberedPlan(requirements)
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let stored = store.addDegreePlan(plan)

        let change = try #require(DegreeRenumbering.convert(renumbering, planID: stored.id, requirements: requirements, userData: store))
        #expect(change.course == Self.cs3001 && change.countsAs == Self.cs3000)
        #expect(change.message == "CS 3001 now counts as CS 3000")
        #expect(change.canUndo)

        let after = try #require(store.degreePlan(id: stored.id))
        #expect(after.substitutions.map(\.id) == [waiver.id])
        #expect(after.courseEquivalences.map(\.course) == [Self.cs3001])
        #expect(after.courseEquivalences.first?.countsAs == Self.cs3000)
        #expect(after.courseEquivalences.first?.note == "Renumbered")

        // The audit then counts CS 3001 as CS 3000, like any renumbered course: not by substitution.
        let audit = DegreeAudit.run(plan: after, requirements: requirements)
        let result = try #require(audit.result(for: renumbering.ruleID))
        #expect(result.status == .complete)
        #expect(result.used.map(\.key) == [Self.cs3001])
        #expect(result.used.first?.satisfies == Self.cs3000)
        #expect(result.used.first?.bySubstitution == false)

        // Converting again does nothing: the substitution is gone.
        #expect(DegreeRenumbering.convert(renumbering, planID: stored.id, requirements: requirements, userData: store) == nil)
    }

    @Test func undoPutsTheSubstitutionBackWhereItWas() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let (plan, renumbering, waiver) = try renumberedPlan(requirements)
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let stored = store.addDegreePlan(plan)
        let change = try #require(DegreeRenumbering.convert(renumbering, planID: stored.id, requirements: requirements, userData: store))

        // Something else changes before Undo is tapped: it stays.
        let extra = RequirementSubstitution(ruleID: "elsewhere", ruleTitle: "Elsewhere", change: .waive)
        store.updateDegreePlan(id: stored.id) { $0.substitutions.append(extra) }

        change.undo(planID: stored.id, userData: store)
        let restored = try #require(store.degreePlan(id: stored.id))
        #expect(restored.substitutions.map(\.id) == [renumbering.id, waiver.id, extra.id])
        #expect(restored.courseEquivalences.isEmpty)

        // Undo twice is harmless.
        change.undo(planID: stored.id, userData: store)
        #expect(store.degreePlan(id: stored.id)?.substitutions.count == 3)
    }

    @Test func declaresARenumberingWithoutASubstitution() throws {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let stored = store.addDegreePlan(DegreePlan(name: "Plan"))

        #expect(DegreeRenumbering.declare(course: Self.cs3000, countsAs: Self.cs3000, planID: stored.id, userData: store) == nil)
        let change = try #require(DegreeRenumbering.declare(course: Self.cs3001, countsAs: Self.cs3000, planID: stored.id, userData: store))
        #expect(change.substitution == nil && change.canUndo)
        #expect(store.degreePlan(id: stored.id)?.courseEquivalences.map(\.note) == ["Renumbered"])

        // Already counted as one course: nothing is declared, and there is nothing to undo.
        let again = try #require(DegreeRenumbering.declare(course: Self.cs3001, countsAs: Self.cs3000, planID: stored.id, userData: store))
        #expect(!again.canUndo)
        #expect(store.degreePlan(id: stored.id)?.courseEquivalences.count == 1)

        change.undo(planID: stored.id, userData: store)
        #expect(store.degreePlan(id: stored.id)?.courseEquivalences.isEmpty == true)
    }

    /// The question is asked once Banner says the required course is retired and the substitute isn't.
    @Test func asksAboutARetiredRequiredCourseOnly() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let setup = try renumberedPlan(requirements)
        var plan = setup.plan

        let retired = DegreeSubstitutionEditing.likelyRenumberings(in: plan, requirements: requirements) { $0 == Self.cs3000 }
        #expect(retired.map(\.substitution.id) == [setup.renumbering.id])
        #expect(retired.first?.question == "Is CS 3001 the new number of CS 3000?")
        #expect(DegreeSubstitutionEditing.likelyRenumberings(in: plan, requirements: requirements) { _ in nil }.isEmpty)
        #expect(DegreeSubstitutionEditing.likelyRenumberings(in: plan, requirements: requirements) { _ in false }.isEmpty)

        // Once the plan counts them as one course, there is nothing left to ask.
        plan.declareEquivalence(course: Self.cs3001, countsAs: Self.cs3000)
        #expect(DegreeSubstitutionEditing.likelyRenumberings(in: plan, requirements: requirements) { $0 == Self.cs3000 }.isEmpty)
    }

    /// "Keep as substitution" is remembered for the pair of courses.
    @Test func aKeptSubstitutionIsNotAskedAboutAgain() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let (plan, renumbering, waiver) = try renumberedPlan(requirements)
        let retired: (CourseKey) -> Bool? = { $0 == Self.cs3000 }

        let asked = DegreeRenumbering.likely(in: plan, requirements: requirements, dismissed: [], isRetired: retired)
        #expect(Set(asked.keys) == [renumbering.id])
        #expect(asked[waiver.id] == nil)

        let kept = DegreeEquivalencePrompt.pairID(Self.cs3001, Self.cs3000)
        #expect(DegreeRenumbering.likely(in: plan, requirements: requirements, dismissed: [kept], isRetired: retired).isEmpty)
        // Another pair's dismissal doesn't count.
        let other = DegreeEquivalencePrompt.pairID(Self.cs3001, Self.cs4535)
        #expect(DegreeRenumbering.likely(in: plan, requirements: requirements, dismissed: [other], isRetired: retired).count == 1)
        // Nothing is asked until Banner has said the required course is gone.
        #expect(DegreeRenumbering.likely(in: plan, requirements: requirements, dismissed: [], isRetired: { _ in nil }).isEmpty)
    }

    // MARK: Where a substitute sits

    @Test func aSubstituteSitsUnderTheRequirementItReplaces() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        var plan = DegreeRequirementsTests.plan()
        let either = try rule("CS 4500 or CS 4530", in: requirements)
        let security = try rule("Complete one of the following:", in: requirements)
        plan.substitutions = [
            RequirementSubstitution(ruleID: either.id, ruleTitle: "CS 4500 or CS 4530", change: .countCourse(Self.cs4535), note: "Approved by advising"),
            RequirementSubstitution(ruleID: security.id, ruleTitle: "Security Course", change: .countCourse(Self.cs4973)),
        ]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)

        // A course the requirement doesn't list goes under it; the note and approval stay with it.
        let eitherResult = try #require(audit.result(for: either.id))
        let split = DegreeSubstituteRows.split(eitherResult, listed: Set(either.listedCourses))
        #expect(split.substitutes.map(\.key) == [Self.cs4535] && split.others.isEmpty)
        #expect(DegreeSubstituteRows.requirementName(of: eitherResult, requirements: requirements) == "CS 4500 or CS 4530")
        #expect(DegreeSubstituteRows.note(counting: Self.cs4535, in: eitherResult) == "Approved by advising")
        #expect(DegreeSubstituteRows.caption(counting: Self.cs4535, in: eitherResult, requirements: requirements)
                == "Counts for CS 4500 or CS 4530 by substitution · Approved by advising")

        // A list is named by its heading, not by "Complete one of the following".
        let securityResult = try #require(audit.result(for: security.id))
        #expect(DegreeSubstituteRows.split(securityResult, listed: Set(security.listedCourses)).substitutes.map(\.key) == [Self.cs4973])
        #expect(DegreeSubstituteRows.caption(counting: Self.cs4973, in: securityResult, requirements: requirements)
                == "Counts for Security Course by substitution")

        // A row says where its course counts, unless it sits under its requirement, whose heading says so.
        let info = DegreeCourseRowInfo(status: .planned(term: "Spring 2027"), isCountedHere: true, bySubstitution: true, caption: "ignored")
        #expect(DegreeSubstituteRows.caption(of: info, counting: Self.cs4535, in: eitherResult, requirements: requirements, isChild: true)
                == "Approved by advising")
        #expect(DegreeSubstituteRows.caption(of: info, counting: Self.cs4535, in: eitherResult, requirements: requirements, isChild: false)
                == "Counts for CS 4500 or CS 4530 by substitution · Approved by advising")
        let plain = DegreeCourseRowInfo(status: .notInPlan, caption: "No longer offered")
        #expect(DegreeSubstituteRows.caption(of: plain, counting: Self.cs4535, in: eitherResult, requirements: requirements, isChild: false)
                == "No longer offered")

        // One the requirement lists already has its row there: nothing goes under.
        var listed = plan
        listed.substitutions = [RequirementSubstitution(ruleID: security.id, ruleTitle: "Security Course", change: .countCourse(Self.cy3740))]
        listed.completed.append(DegreeRequirementsTests.course("CY 3740"))
        let listedResult = try #require(DegreeAudit.run(plan: listed, requirements: requirements).result(for: security.id))
        let listedSplit = DegreeSubstituteRows.split(listedResult, listed: Set(security.listedCourses))
        #expect(listedSplit.substitutes.isEmpty)
    }

    // MARK: Sentences of the catalog

    private static let notesPage = """
    <div id="programrequirementstextcontainer" class="tab_content">
    <h2>Major Requirements</h2>
    <table class="sc_courselist"><tbody>
    <tr class="even firstrow"><td class="codecol"><a class="bubblelink code">CS&#160;3000</a></td><td>Algorithms and Data</td><td class="hourscol">4</td></tr>
    <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete 8 semester hours of CS classes. Choose courses within the following ranges:</span></td><td class="hourscol">8</td></tr>
    <tr class="even lastrow"><td colspan="2"><div style="margin-left:20px;" class="blockindent"><span class="courselistcomment commentindent"><a class="bubblelink code">CS&#160;2500</a> or higher</span></div></td><td class="hourscol"></td></tr>
    </tbody></table>
    <h2>GPA Requirement</h2>
    <p>Minimum 2.000 GPA required in the major.</p>
    <h2>Credit Requirement</h2>
    <p>Complete 12 semester hours in the major.</p>
    <h2>NUpath Requirements Satisfied</h2>
    <p>Integrating Knowledge and Skills Through Experience is satisfied through co-op.</p>
    <h2>Program Requirement</h2>
    <p>12 total semester hours required</p>
    </div>
    """

    private func notesAudit(completed: [String], planned: [String] = []) throws -> (DegreeAudit, ProgramRequirements) {
        let program = CatalogProgram(title: "Notes, BS", path: "undergraduate/notes/")
        let requirements = try #require(ProgramCatalogParser.requirements(fromHTML: Self.notesPage, year: CatalogYear(startYear: 2024), program: program))
        var plan = DegreePlan(name: "Notes")
        plan.completed = completed.map { code in
            code == "COOP 3946" ? DegreeRequirementsTests.course(code, 0, "Co-op Work Experience - HT") : DegreeRequirementsTests.course(code)
        }
        var fall = DegreePlanTerm(season: .fall, year: 2027)
        fall.courses = planned.map { DegreeRequirementsTests.course($0) }
        plan.terms = [fall]
        return (DegreeAudit.run(plan: plan, requirements: requirements), requirements)
    }

    private func entries(_ filter: DegreeRequirementsFilter, audit: DegreeAudit, requirements: ProgramRequirements) -> [String: DegreeNoteEntry] {
        var found: [String: DegreeNoteEntry] = [:]
        for section in requirements.sections {
            for entry in DegreeRequirementNotes.entries(of: section, audit: audit, filter: filter, statesTotalHours: requirements.totalHours != nil) {
                found[section.title] = entry
            }
        }
        return found
    }

    @Test func showsEachSentenceWithItsCheckForTheFilter() throws {
        // Twelve hours and a co-op done: the checked sentences are complete.
        let (done, requirements) = try notesAudit(completed: ["CS 3000", "CS 3200", "CS 3500", "COOP 3946"])
        let all = entries(.all, audit: done, requirements: requirements)
        #expect(Set(all.keys) == ["GPA Requirement", "Credit Requirement", "NUpath Requirements Satisfied", "Program Requirement"])
        // The GPA can't be checked from a plan, so it has no check; the others do.
        #expect(all["GPA Requirement"]?.check == nil)
        #expect(all["Credit Requirement"]?.check?.status == .complete)
        #expect(all["NUpath Requirements Satisfied"]?.check?.detail == "COOP 3946 completed")
        #expect(all["Program Requirement"]?.check != nil)
        // Done lists the complete ones; nothing is left for Remaining.
        #expect(Set(entries(.done, audit: done, requirements: requirements).keys) == ["Credit Requirement", "NUpath Requirements Satisfied", "Program Requirement"])
        #expect(entries(.remaining, audit: done, requirements: requirements).isEmpty)

        // Some hours, planned, and no co-op: those are still open; the GPA never shows there.
        let (short, shortRequirements) = try notesAudit(completed: ["CS 3000"], planned: ["CS 3200"])
        let remaining = entries(.remaining, audit: short, requirements: shortRequirements)
        #expect(Set(remaining.keys) == ["Credit Requirement", "NUpath Requirements Satisfied", "Program Requirement"])
        #expect(remaining["NUpath Requirements Satisfied"]?.check?.detail == "No co-op in the plan")
        #expect(remaining["GPA Requirement"] == nil)
        #expect(entries(.done, audit: short, requirements: shortRequirements)["NUpath Requirements Satisfied"] == nil)
    }

    @Test func aCheckThatDoesNotCountYetShowsInAllOnly() {
        var check = DegreeAudit.NoteCheck(sectionID: "nupath-requirements", note: "NUpath", kind: .nupath, status: .missing, detail: "looking up 2 courses")
        check.counts = false
        #expect(DegreeRequirementsFilter.all.includes(check))
        #expect(!DegreeRequirementsFilter.remaining.includes(check))
        #expect(!DegreeRequirementsFilter.done.includes(check))
        check.counts = true
        #expect(DegreeRequirementsFilter.remaining.includes(check))
        #expect(!DegreeRequirementsFilter.done.includes(check))
    }
}
