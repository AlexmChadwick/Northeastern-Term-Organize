//
//  MacDegreePlansSamples.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

#if DEBUG
import SwiftUI

extension MacSampleData {
    /// Sample data for snapshots: the degree plans of an invented student, "Sam Sample", in the
    /// Computer Science BS program (2024–2025 catalog, Human-Centered Computing concentration):
    /// courses done and in progress (a co-op among them), six planned semesters (one with nothing
    /// in it yet, one course with a missing prerequisite, one planned twice, one numbered below
    /// the electives' minimum), a petition that hasn't said which course numbers count (its
    /// details ask), a waiver, two renumbered courses (CS 3500 for CS 3100, CS 2484 for IS 4300),
    /// a course substituted for "CS 4500 or CS 4530" and another for the retired IS 4800, which
    /// is really the same course under a new number (the requirements offer to say so), and a
    /// third plan whose requirements aren't set up. Titles and credits come from the term's
    /// catalog when it lists the course.
    @MainActor
    static func seedDegreePlans(userData: UserDataStore, catalog: CatalogStore) {
        let primary = userData.addDegreePlan(SampleDegreePlans.bscs(index: catalog.readyIndex))
        var whatIf = DegreePlanEditing.duplicate(primary, existingNames: userData.degreePlans.map(\.name))
        whatIf.name = "What-if: Systems Concentration"
        whatIf.concentrationID = "concentration-in-systems"
        whatIf.substitutions = []
        // No co-op in this one, to show a requirement the plan doesn't meet yet.
        whatIf.completed.removeAll { $0.key?.subject == "COOP" }
        whatIf.terms = whatIf.terms.map { term in
            var term = term
            term.courses.removeAll { $0.key == CourseKey(subject: "CS", number: "4410") }
            return term
        }
        userData.addDegreePlan(whatIf)
        // A plan that hasn't set up its degree requirements yet.
        userData.addDegreePlan(SampleDegreePlans.draft(index: catalog.readyIndex))
    }

    /// Views of this area outside the main window, for `-MacSnapshotView <name>`; nil for names
    /// it doesn't know:
    /// `newDegreePlan`, `importReview` (a synthetic plan that matches the sample plan),
    /// `importNew` (one that doesn't), `importFailure`, `setup`, `substitution` (the sample
    /// petition), `substitutionCount`, `substitutionRenumber` (the substitution for the retired
    /// IS 4800, which offers to make it a renumbering), `equivalence`, `export`, `addCourse`,
    /// `details`, `milestone` (the notes for a plan that meets every requirement), `plan` and
    /// `requirements` (the whole page, at the size given; `planCompleted` has the completed
    /// courses open, `requirementsChecks` the parts of the NUpath check), `planSelected` and
    /// `planSelectedSubstitute` (the plan with CS 3484, or CS 4535, selected, so the requirements
    /// show where it counts), `paneDetails` (the plan with the pane showing one requirement's
    /// details), `planRenumbered` (the plan after CS 3484 was made the new number of IS 4800),
    /// `planNoRequirements` (a plan whose requirements aren't set up), `inspectorOnly` (the
    /// Science requirement's details at the inspector's width) and `requirementsInspector` (the
    /// requirements page with the Science requirement selected).
    @MainActor
    static func degreePlansSnapshotView(named name: String, catalog: CatalogStore, userData: UserDataStore) -> AnyView? {
        let planID = userData.sortedDegreePlans.first?.id
        switch name {
        case "newDegreePlan":
            return AnyView(MacNewDegreePlanSheet())
        case "importReview":
            let text = SampleDegreePlans.exportText(from: userData.sortedDegreePlans.first, extraLines: true)
            return AnyView(MacDegreePlanImportSheet(url: SampleDegreePlans.write(text, as: "BSCS Four-Year Plan – view-plan.txt")))
        case "importNew":
            var plan = SampleDegreePlans.bscs(index: catalog.readyIndex)
            plan.name = "Spring 2027 Draft"
            let text = SampleDegreePlans.exportText(from: plan, extraLines: false)
            return AnyView(MacDegreePlanImportSheet(url: SampleDegreePlans.write(text, as: "Spring 2027 Draft – view-plan.txt")))
        case "importFailure":
            let url = SampleDegreePlans.write("Class schedule\nMonday\n9:50 AM  Lecture\nNothing in here looks like a degree plan.\n", as: "schedule.txt")
            return AnyView(MacDegreePlanImportSheet(url: url))
        case "setup":
            guard let planID else { return nil }
            return AnyView(MacDegreeRequirementsSetupSheet(planID: planID))
        case "substitution", "substitutionCount", "substitutionRenumber":
            guard let planID else { return nil }
            let mode: SampleSubstitutionHost.Mode = name == "substitutionCount" ? .countsCourse : (name == "substitutionRenumber" ? .renumbering : .petition)
            return AnyView(SampleSubstitutionHost(planID: planID, mode: mode))
        case "equivalence":
            guard let planID else { return nil }
            let request = DegreeEquivalenceRequest(planID: planID, course: CourseKey(subject: "CS", number: "2510"))
            return AnyView(MacDegreeEquivalenceSheet(request: request))
        case "export":
            guard let planID else { return nil }
            return AnyView(MacDegreePlanExportSheet(planID: planID))
        case "addCourse":
            guard let planID, let termID = userData.degreePlan(id: planID)?.terms.first?.id else { return nil }
            let editor = MacDegreePlanEditor(userData: userData, planID: planID, undoManager: nil)
            return AnyView(MacDegreePlanAddCourse(planID: planID, termID: termID, editor: editor, initialText: "CS 41"))
        case "details":
            guard let planID else { return nil }
            return AnyView(MacDegreePlanDetailsSheet(planID: planID))
        case "milestone":
            // The notes for a plan that meets every degree requirement.
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    MacDegreeMilestoneRow(milestone: .completed, hasLaterSemesters: true)
                        .padding(8)
                        .background(Color.green.opacity(0.12))
                    MacDegreeMilestoneRow(milestone: .after(termID: UUID(), name: "Spring 2028"), hasLaterSemesters: true)
                        .padding(8)
                        .background(Color.green.opacity(0.12))
                }
                .frame(width: 620)
                .padding()
            )
        case "plan", "planCompleted":
            guard let planID else { return nil }
            return AnyView(MacDegreePlanView(planID: planID, showsCompleted: name == "planCompleted" ? true : nil))
        case "planSelected", "planSelectedSubstitute":
            guard let planID else { return nil }
            let key = CourseKey(subject: "CS", number: name == "planSelected" ? "3484" : "4535")
            return AnyView(MacDegreePlanView(planID: planID, showsCompleted: true, initiallySelected: key))
        case "paneDetails":
            guard let planID else { return nil }
            return AnyView(MacDegreePlanView(planID: planID, initialRequirement: "IS 4800", opensRequirementDetails: true))
        case "planRenumbered":
            guard let planID else { return nil }
            return AnyView(SampleRenumberedHost(planID: planID))
        case "planNoRequirements":
            guard let draftID = userData.degreePlans.first(where: { $0.catalogProgramPath == nil })?.id else { return nil }
            return AnyView(MacDegreePlanView(planID: draftID))
        case "requirements":
            guard let planID else { return nil }
            return AnyView(MacDegreeRequirementsView(planID: planID))
        case "requirementsChecks":
            guard let planID else { return nil }
            return AnyView(MacDegreeRequirementsView(planID: planID, expandsChecks: true))
        case "inspectorOnly":
            guard let planID else { return nil }
            return AnyView(SampleInspectorHost(planID: planID))
        case "requirementsInspector":
            guard let planID else { return nil }
            return AnyView(
                MacDegreeRequirementsView(planID: planID, initialRule: "Science")
                    .frame(width: 1280, height: 800)
            )
        default:
            return nil
        }
    }
}

// MARK: - The invented student

/// Sam Sample's plan, and the text of its degree audit export.
private enum SampleDegreePlans {
    static let programPath = "undergraduate/computer-information-science/computer-science/bscs/"
    static let science = "supporting-courses/science-requirement/complete-any-two-courses-and-any-required-labs-courses-may-b"
    static let softwareEngineering = "computer-science-requirements/computer-science-required-courses/cs-4500-or-cs-4530"
    static let empiricalResearch = "concentration-in-human-centered-computing/courses/is-4800"
    static let khouryElectives = "computer-science-requirements/khoury-elective-courses/complete-8-semester-hours-of-cs-cy-ds-or-is-classes-that-are"
    static let presentation = "computer-science-requirements/presentation-requirement/complete-one-of-the-following"

    static func bscs(index: CatalogIndex?) -> DegreePlan {
        /// A course of the plan: the catalog's title and credits when the term lists it.
        func course(_ subject: String, _ number: String, _ title: String, _ credits: Double) -> DegreePlanCourse {
            let key = CourseKey(subject: subject, number: number)
            let listed = index?.course(key)
            return DegreePlanCourse(key: key, title: DegreePlanFormat.exportTitle(listed?.title ?? title), credits: listed?.defaultChoiceCredits ?? credits)
        }

        var plan = DegreePlan(name: "BSCS Four-Year Plan")
        plan.program = "CS-B-CSCI-BSCS"
        plan.studentName = "Sam Sample"
        plan.studentID = "001234567"
        plan.importedFrom = "view-plan.pdf"
        plan.printedAt = DegreePlanFormat.parsePrintedDate("10/03/2026 12:42")
        plan.catalogYear = 2024
        plan.catalogProgramPath = programPath
        plan.catalogProgramTitle = "Computer Science, BSCS"
        plan.concentrationID = "concentration-in-human-centered-computing"

        plan.completed = [
            course("CS", "1200", "First Year Seminar", 1),
            course("CS", "1800", "Discrete Structures", 4),
            course("CS", "1802", "Seminar for CS 1800", 1),
            course("CS", "2500", "Fundamentals of Computer Science 1", 4),
            course("CS", "2501", "Lab for CS 2500", 1),
            course("CS", "2510", "Fundamentals of Computer Science 2", 4),
            course("CS", "2511", "Lab for CS 2510", 1),
            course("ENGW", "1111", "First-Year Writing", 4),
            course("MATH", "1341", "Calculus 1 for Science and Engineering", 4),
            course("MATH", "1365", "Introduction to Mathematical Reasoning", 4),
            course("PHYS", "1151", "Physics for Engineering 1", 3),
            course("PHYS", "1152", "Lab for PHYS 1151", 1),
            course("PHYS", "1153", "Interactive Learning Seminar for PHYS 1151", 1),
            course("CS", "3000", "Algorithms and Data", 4),
            course("CS", "3500", "Object-Oriented Design", 4),
            course("CS", "3501", "Lab for CS 3500", 1),
            course("COMM", "1112", "Public Speaking", 4),
            course("PHIL", "1145", "Technology and Human Values", 4),
            DegreePlanCourse(key: CourseKey(subject: "COOP", number: "3945"), title: "Co-op Work Experience", credits: 0),
            DegreePlanCourse(key: nil, label: "NO AP CREDIT", title: "No description", credits: 0),
        ]

        plan.terms = [
            DegreePlanTerm(season: .spring, year: 2027, courses: [
                course("CS", "3650", "Computer Systems", 4),
                course("CS", "3800", "Theory of Computation", 4),
                course("DS", "3000", "Foundations of Data Science", 4),
                course("CS", "2800", "Logic and Computation", 4),
            ]),
            DegreePlanTerm(season: .summerA, year: 2027),
            DegreePlanTerm(season: .fall, year: 2027, courses: [
                course("CS", "4400", "Programming Languages", 4),
                // Needs CS 4400, which is planned in the same semester.
                course("CS", "4410", "Compilers", 4),
                course("CS", "4730", "Distributed Systems", 4),
                course("CY", "2550", "Foundations of Cybersecurity", 4),
            ]),
            DegreePlanTerm(season: .spring, year: 2028, courses: [
                course("CS", "4100", "Principles of Artificial Intelligence", 4),
                course("DS", "4400", "Machine Learning", 4),
                course("ENGW", "3302", "Advanced Writing in the Technical Professions", 4),
                course("HIST", "2220", "History of Technology", 4),
            ]),
            DegreePlanTerm(season: .fall, year: 2028, courses: [
                course("CS", "4550", "Web Development", 4),
                // Below the Khoury electives' minimum (CS 2500), so it only counts as a general
                // elective, unless the petition accepts any course number.
                course("CS", "2386", "Game Programming 1", 4),
                course("PSYC", "1101", "Foundations of Psychology", 4),
                // Approved for IS 4800, which isn't offered anymore: the same course under a new number.
                course("CS", "3484", "GUI Programming", 4),
            ]),
            DegreePlanTerm(season: .spring, year: 2029, courses: [
                // Planned twice, to show the flag.
                course("PSYC", "1101", "Foundations of Psychology", 4),
                course("GAME", "1110", "Games and Society", 4),
                // The new number of IS 4300.
                course("CS", "2484", "Principles of Human-Computer Interaction", 4),
                // Approved in place of CS 4500 or CS 4530.
                course("CS", "4535", "Professional Practicum Capstone", 4),
            ]),
        ]

        plan.courseEquivalences = [
            CourseEquivalence(course: CourseKey(subject: "CS", number: "3500"), countsAs: CourseKey(subject: "CS", number: "3100"), note: "Renumbered in 2025"),
            CourseEquivalence(course: CourseKey(subject: "CS", number: "2484"), countsAs: CourseKey(subject: "IS", number: "4300"), note: "Renumbered"),
        ]
        plan.substitutions = [
            RequirementSubstitution(
                ruleID: science,
                ruleTitle: "Science Requirement",
                change: .replace(RequirementReplacement(count: 2, hours: nil, likeRuleID: khouryElectives, likeRuleTitle: "Khoury Elective Courses", courses: [])),
                note: "Petition approved by Khoury advising",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12))
            ),
            RequirementSubstitution(
                ruleID: presentation,
                ruleTitle: "Presentation Requirement",
                change: .waive,
                note: "Waived with transfer credit",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 21))
            ),
            RequirementSubstitution(
                ruleID: softwareEngineering,
                ruleTitle: "CS 4500 or CS 4530",
                change: .countCourse(CourseKey(subject: "CS", number: "4535")),
                note: "Practicum approved in place of software engineering",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4))
            ),
            RequirementSubstitution(
                ruleID: empiricalResearch,
                ruleTitle: "IS 4800",
                change: .countCourse(CourseKey(subject: "CS", number: "3484")),
                note: "Approved by Khoury advising",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 18))
            ),
        ]
        return plan
    }

    /// A small plan with no program chosen, so its requirements aren't set up.
    static func draft(index: CatalogIndex?) -> DegreePlan {
        func course(_ subject: String, _ number: String, _ title: String, _ credits: Double) -> DegreePlanCourse {
            let key = CourseKey(subject: subject, number: number)
            let listed = index?.course(key)
            return DegreePlanCourse(key: key, title: DegreePlanFormat.exportTitle(listed?.title ?? title), credits: listed?.defaultChoiceCredits ?? credits)
        }
        var plan = DegreePlan(name: "Co-op Year Draft")
        plan.terms = [
            DegreePlanTerm(season: .spring, year: 2027, courses: [
                course("CS", "3000", "Algorithms and Data", 4),
                course("CS", "3650", "Computer Systems", 4),
                course("MATH", "1365", "Introduction to Mathematical Reasoning", 4),
            ]),
            DegreePlanTerm(season: .fall, year: 2027, courses: [
                course("CS", "3800", "Theory of Computation", 4),
                course("CS", "4400", "Programming Languages", 4),
            ]),
        ]
        return plan
    }

    /// The degree audit's text for a plan, as PDF text extraction gives it; `extraLines` adds a
    /// line or two the importer doesn't understand.
    static func exportText(from plan: DegreePlan?, extraLines: Bool) -> String {
        guard let plan else { return "" }
        var text = DegreePlanFormat.text(for: plan, printedAt: plan.printedAt ?? .now, includeStudent: true)
        if extraLines {
            text += "\n  Prerequisite override requested by advisor\n  CS 4999 Independent Study"
        }
        return text
    }

    /// Writes a synthetic file into the snapshot folder and returns its URL.
    static func write(_ text: String, as name: String) -> URL {
        let url = MacSnapshot.directory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Hosts

/// The requirement inspector on its own, for the Science requirement (the sample petition's),
/// once the program's requirements have loaded.
private struct SampleInspectorHost: View {
    var planID: UUID

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        Group {
            if let plan = userData.degreePlan(id: planID), let requirements = programCatalog.requirements(for: plan) {
                let equivalences = CourseInfoStore.shared.equivalences(for: plan)
                let audit = DegreeAudit.run(plan: plan, requirements: requirements, equivalences: equivalences,
                                            attributes: CourseInfoStore.shared.degreeAttributes(for: plan))
                let page = MacDegreeRequirementsPage(
                    plan: plan,
                    context: programCatalog.degreeRequirementsContext(for: plan, equivalences: equivalences),
                    requirements: requirements,
                    audit: audit,
                    lookup: DegreeCourseLookup.make(plan: plan, requirements: requirements, audit: audit, userData: userData, catalog: catalog),
                    equivalences: equivalences,
                    addTargets: DegreeCourseLookup.addTargets(for: plan),
                    prompts: DegreeEquivalencePrompts(),
                    expandedRules: [],
                    subjectName: { _ in nil },
                    actions: MacDegreeRequirementActions()
                )
                MacDegreeRequirementInspector(page: page, ruleID: SampleDegreePlans.science)
            } else {
                ProgressView("Loading requirements…")
            }
        }
        .frame(width: 380, height: 900)
        .task {
            if let plan = userData.degreePlan(id: planID) {
                await programCatalog.loadRequirements(for: plan)
            }
        }
    }
}

/// The plan after its substitution for the retired IS 4800 was made a renumbering (CS 3484 is
/// the new number), once the program's requirements have loaded.
private struct SampleRenumberedHost: View {
    var planID: UUID

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog

    var body: some View {
        MacDegreePlanView(planID: planID, initiallySelected: CourseKey(subject: "CS", number: "3484"))
            .task {
                guard let plan = userData.degreePlan(id: planID) else { return }
                await programCatalog.loadRequirements(for: plan)
                guard let requirements = programCatalog.requirements(for: plan),
                      let substitution = plan.substitutions.first(where: { $0.ruleID == SampleDegreePlans.empiricalResearch }) else { return }
                userData.updateDegreePlan(id: planID) {
                    DegreeSubstitutionEditing.convertToEquivalence(substitution, requirements: requirements, in: &$0)
                }
            }
    }
}

/// The substitution sheet for the sample plan, once the program's requirements have loaded.
private struct SampleSubstitutionHost: View {
    enum Mode {
        /// The sample petition (the Science requirement's).
        case petition
        /// A new "count a course" substitution for Computing and Social Issues.
        case countsCourse
        /// The substitution for IS 4800, which is the same course under a new number.
        case renumbering
    }

    var planID: UUID
    var mode: Mode

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog

    var body: some View {
        Group {
            if let plan = userData.degreePlan(id: planID), let requirements = programCatalog.requirements(for: plan) {
                let request: DegreeSubstitutionRequest = switch mode {
                case .countsCourse:
                    DegreeSubstitutionRequest(
                        planID: planID,
                        ruleID: "supporting-courses/computing-and-social-issues/complete-one-of-the-following",
                        ruleTitle: requirements.degreeShortName(ofRule: "supporting-courses/computing-and-social-issues/complete-one-of-the-following") ?? "Computing and Social Issues",
                        kind: .countCourse
                    )
                case .renumbering:
                    DegreeSubstitutionRequest(
                        planID: planID,
                        ruleID: SampleDegreePlans.empiricalResearch,
                        ruleTitle: requirements.degreeShortName(ofRule: SampleDegreePlans.empiricalResearch) ?? "IS 4800",
                        existing: plan.substitutions.first { $0.ruleID == SampleDegreePlans.empiricalResearch }
                    )
                case .petition:
                    DegreeSubstitutionRequest(
                        planID: planID,
                        ruleID: SampleDegreePlans.science,
                        ruleTitle: requirements.degreeShortName(ofRule: SampleDegreePlans.science) ?? "Science Requirement",
                        existing: plan.substitutions.first { $0.ruleID == SampleDegreePlans.science }
                    )
                }
                MacRequirementSubstitutionSheet(request: request, onConvert: { _ in })
            } else {
                ProgressView("Loading requirements…")
                    .frame(width: 560, height: 700)
            }
        }
        .task {
            if let plan = userData.degreePlan(id: planID) {
                await programCatalog.loadRequirements(for: plan)
            }
        }
    }
}
#endif
