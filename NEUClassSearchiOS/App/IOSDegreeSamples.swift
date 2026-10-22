//
//  IOSDegreeSamples.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

#if DEBUG
import Foundation
import CoreGraphics

/// Sample degree plans for looking at the degree screens in the simulator. Launch the debug build
/// with `-IOSDegreeSamples YES` to seed them (each launch resets them; the plans have fixed ids), and optionally:
/// - `-IOSDegreeSamplesRoute plan|requirements|whatif|whatif-requirements` to open a screen
///   (`termorganize://degree-plan/<id>[/requirements]` also works);
/// - `-IOSDegreeSamplesFilter remaining|done` to start the requirements page on a filter;
/// - `-IOSDegreeSamplesRule <rule id>` to open that requirement's sheet;
/// - `-IOSDegreeSamplesVariant listed` to also count CY 2550, which the Security requirement lists, by
///   substitution (a substitute that already has its row in the list); `open` to leave IS 4800 open
///   (no substitution for CS 3484 yet), to record one;
/// - `-IOSDegreeSamplesSplitWidth <points>` for the width from which the plan and its requirements sit
///   side by side (1000 by default; the simulator can't be turned to landscape from a script, and a
///   portrait iPad is 834 points wide, so 800 shows the split there).
///
/// The student is invented ("Sam Sample"): Computer Science BS, 2024–2025 catalog, Human-Centered
/// Computing concentration. The first plan has a substitution for a required-course alternative
/// (CS 4535 for "CS 4500 or CS 4530"), one for a list (CS 4100 for the concentration's electives),
/// one that is really a renumbering (CS 3484 for IS 4800, which is no longer offered), CS 2484
/// already declared as IS 4300 under its new number, and a co-op. The second ("What-if") has CS
/// 3484 declared as IS 4800 already, no substitutions, no co-op and no ethical reasoning course.
@MainActor
enum IOSDegreeSamples {
    static let planID = UUID(uuidString: "5A3B1E00-0000-4000-8000-0000000000A1") ?? UUID()
    static let whatIfPlanID = UUID(uuidString: "5A3B1E00-0000-4000-8000-0000000000A2") ?? UUID()

    static let programPath = "undergraduate/computer-information-science/computer-science/bscs/"
    static let concentration = "concentration-in-human-centered-computing"
    static let eitherCourse = "computer-science-requirements/computer-science-required-courses/cs-4500-or-cs-4530"
    static let empiricalMethods = "concentration-in-human-centered-computing/courses/is-4800"
    static let humanComputerInteraction = "concentration-in-human-centered-computing/courses/is-4300"
    static let concentrationElectives = "concentration-in-human-centered-computing/courses/complete-two-of-the-following-not-already-taken"
    static let security = "computer-science-requirements/security-required-course/complete-one-of-the-following"

    private static func argument(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: name)
    }

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "IOSDegreeSamples") }

    /// The filter the requirements page starts on, from `-IOSDegreeSamplesFilter`.
    static var requestedFilter: DegreeRequirementsFilter? {
        argument("IOSDegreeSamplesFilter").flatMap(DegreeRequirementsFilter.init(rawValue:))
    }

    /// The requirement whose sheet opens at launch, from `-IOSDegreeSamplesRule`.
    static var requestedRule: String? { argument("IOSDegreeSamplesRule") }

    /// The width from which the plan screen shows the requirements beside the plan, from
    /// `-IOSDegreeSamplesSplitWidth`.
    static var splitWidth: CGFloat? {
        argument("IOSDegreeSamplesSplitWidth").flatMap { Double($0) }.map { CGFloat($0) }
    }

    /// Seeds the sample plans once the catalog is ready, then opens the requested screen. Does
    /// nothing without `-IOSDegreeSamples YES`.
    static func seedIfRequested(userData: UserDataStore, catalog: CatalogStore, router: AppRouter) {
        guard isRequested else { return }
        userData.preferences.hasCompletedOnboarding = true
        Task {
            // The plans take their titles and credits from the loaded term.
            for _ in 0..<120 where catalog.readyIndex == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Every launch starts from the same plans, whatever was changed in the last run.
            var primary = bscs(index: catalog.readyIndex)
            if argument("IOSDegreeSamplesVariant") == "open" {
                primary.substitutions.removeAll { $0.ruleID == empiricalMethods }
            }
            if argument("IOSDegreeSamplesVariant") == "listed" {
                primary.substitutions.append(RequirementSubstitution(
                    ruleID: security,
                    ruleTitle: "Security Required Course",
                    change: .countCourse(CourseKey(subject: "CY", number: "2550")),
                    note: "Approved by advising"
                ))
            }
            primary.id = planID
            var whatIf = whatIfPlan(from: primary)
            whatIf.id = whatIfPlanID
            for plan in [primary, whatIf] {
                if userData.degreePlan(id: plan.id) == nil {
                    userData.addDegreePlan(plan)
                } else {
                    userData.replaceDegreePlan(id: plan.id, with: plan)
                }
            }
            route(router)
        }
    }

    private static func route(_ router: AppRouter) {
        let id: UUID
        let requirements: Bool
        switch argument("IOSDegreeSamplesRoute") {
        case "plan": (id, requirements) = (planID, false)
        case "requirements": (id, requirements) = (planID, true)
        case "whatif": (id, requirements) = (whatIfPlanID, false)
        case "whatif-requirements": (id, requirements) = (whatIfPlanID, true)
        default: return
        }
        if let url = AppLink.url("degree-plan/\(id.uuidString)\(requirements ? "/requirements" : "")") {
            router.handle(url: url)
        }
    }

    // MARK: Plans

    private static func bscs(index: CatalogIndex?) -> DegreePlan {
        /// A course of the plan: the term's title and credits when it lists the course.
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
        plan.catalogYear = 2024
        plan.catalogProgramPath = programPath
        plan.catalogProgramTitle = "Computer Science, BSCS"
        plan.concentrationID = concentration

        plan.completed = [
            course("CS", "1200", "First Year Seminar", 1),
            course("CS", "1210", "Professional Development for Khoury Co-op", 1),
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
            course("EECE", "2310", "Introduction to Digital Design and Computer Architecture", 4),
            course("EECE", "2311", "Lab for EECE 2310", 1),
            course("CY", "2550", "Foundations of Cybersecurity", 4),
            // IS 4300 under its new number.
            course("CS", "2484", "Principles of Human-Computer Interaction", 4),
            course("COOP", "3946", "Co-op Work Experience", 0),
            course("CS", "3650", "Computer Systems", 4),
            course("DS", "3000", "Foundations of Data Science", 4),
        ]

        plan.terms = [
            DegreePlanTerm(season: .spring, year: 2027, courses: [
                course("CS", "3800", "Theory of Computation", 4),
                // Counts for "CS 4500 or CS 4530" by substitution.
                course("CS", "4535", "Professional Practicum Capstone", 4),
                // Counts for IS 4800 by substitution: really IS 4800 under its new number.
                course("CS", "3484", "Empirical Research Methods", 4),
                // Counts for the concentration's electives by substitution.
                course("CS", "4100", "Principles of Artificial Intelligence", 4),
            ]),
            DegreePlanTerm(season: .fall, year: 2027, courses: [
                course("CS", "4520", "Mobile Application Development", 4),
                course("CS", "4410", "Compilers", 4),
                course("CS", "4730", "Distributed Systems", 4),
                course("CS", "3200", "Introduction to Databases", 4),
                course("BIOL", "1111", "General Biology 1", 3),
                course("BIOL", "1112", "Lab for BIOL 1111", 1),
            ]),
            DegreePlanTerm(season: .spring, year: 2028, courses: [
                course("CS", "4550", "Web Development", 4),
                course("ENGW", "3302", "Advanced Writing in the Technical Professions", 4),
                course("HIST", "2220", "History of Technology", 4),
                course("MATH", "2331", "Linear Algebra", 4),
            ]),
            DegreePlanTerm(season: .fall, year: 2028, courses: [
                course("PSYC", "1101", "Foundations of Psychology", 4),
                course("SOCL", "1101", "Introduction to Sociology", 4),
                course("GAME", "1110", "Games and Society", 4),
                course("THTR", "1130", "Introduction to Acting", 4),
            ]),
            DegreePlanTerm(season: .spring, year: 2029, courses: [
                course("ENGL", "1700", "Global Literatures 1", 4),
                course("ARTH", "1111", "Global Art and Design History: Renaissance to Modern", 4),
                course("HIST", "1120", "Public History, Public Memory", 4),
            ]),
        ]

        plan.courseEquivalences = [
            CourseEquivalence(course: CourseKey(subject: "CS", number: "2484"), countsAs: CourseKey(subject: "IS", number: "4300"), note: "Renumbered"),
        ]
        plan.substitutions = [
            RequirementSubstitution(
                ruleID: eitherCourse,
                ruleTitle: "CS 4500 or CS 4530",
                change: .countCourse(CourseKey(subject: "CS", number: "4535")),
                note: "Approved by Khoury advising",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12))
            ),
            RequirementSubstitution(
                ruleID: empiricalMethods,
                ruleTitle: "IS 4800",
                change: .countCourse(CourseKey(subject: "CS", number: "3484")),
                note: "Course replaced IS 4800",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 14))
            ),
            RequirementSubstitution(
                ruleID: concentrationElectives,
                ruleTitle: "Human-Centered Computing concentration",
                change: .countCourse(CourseKey(subject: "CS", number: "4100")),
                note: "Concentration elective approved by advising",
                approvedOn: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))
            ),
        ]
        return plan
    }

    /// The same student without a co-op or PHIL 1145 (the only ethical reasoning NUpath course), the
    /// substitutions made, and CS 3484 already counted as IS 4800 (the way a renumbered course
    /// looks once it has been confirmed).
    private static func whatIfPlan(from plan: DegreePlan) -> DegreePlan {
        var whatIf = plan
        whatIf.name = "What-if: no co-op"
        whatIf.substitutions = []
        whatIf.completed.removeAll { $0.key?.subject == "COOP" || $0.key == CourseKey(subject: "PHIL", number: "1145") }
        whatIf.courseEquivalences.append(
            CourseEquivalence(course: CourseKey(subject: "CS", number: "3484"), countsAs: CourseKey(subject: "IS", number: "4800"), note: "Renumbered")
        )
        return whatIf
    }
}
#endif
