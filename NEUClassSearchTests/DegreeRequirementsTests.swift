//
//  DegreeRequirementsTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// Catalog parsing and the degree audit, against a small made-up program page written in the
/// academic catalog's markup.
struct DegreeRequirementsTests {
    static let programPage = """
    <html><body>
    <div id="textcontainer" class="page_content"><p>About the program.</p></div>
    <div id="programrequirementstextcontainer" class="tab_content">
    <p>Complete all courses listed below unless otherwise indicated.</p>
    <h2>Major Requirements</h2>
    <table class="sc_courselist"><tbody>
    <tr class="hidden noscript"><th scope="col">Code</th><th scope="col">Title</th><th scope="col" class="hourscol">Hours</th></tr>
    <tr class="even areaheader firstrow"><td colspan="2"><span class="courselistcomment areaheader">Required Courses</span></td><td class="hourscol"></td></tr>
    <tr class="odd"><td class="codecol"><a href="/search/?P=CS%201800" title="CS 1800" class="bubblelink code">CS&#160;1800</a><span style="margin-left:20px;" class="blockindent">and <a href="/search/?P=CS%201802" class="bubblelink code">CS&#160;1802</a></span></td><td>Discrete Structures</td><td class="hourscol">5</td></tr>
    <tr class="even"><td class="codecol"><a class="bubblelink code">CS&#160;3000</a></td><td>Algorithms and Data</td><td class="hourscol">4</td></tr>
    <tr class="odd"><td class="codecol"><a class="bubblelink code">CS&#160;4500</a></td><td>Software Development</td><td class="hourscol">4</td></tr>
    <tr class="orclass odd"><td class="codecol orclass">or <a class="bubblelink code">CS&#160;4530</a></td><td colspan="2"> Fundamentals of Software Engineering</td></tr>
    <tr class="even areaheader"><td colspan="2"><span class="courselistcomment areaheader">Security Course</span></td><td class="hourscol"></td></tr>
    <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete one of the following:</span></td><td class="hourscol">4</td></tr>
    <tr class="even"><td class="codecol"><a class="bubblelink code">CY&#160;2550</a></td><td>Foundations of Cybersecurity</td><td class="hourscol"></td></tr>
    <tr class="odd"><td class="codecol"><a class="bubblelink code">CY&#160;3740</a></td><td>Systems Security</td><td class="hourscol"></td></tr>
    <tr class="even areaheader"><td colspan="2"><span class="courselistcomment areaheader">Khoury Elective Courses</span></td><td class="hourscol"></td></tr>
    <tr class="odd"><td colspan="2"><span class="courselistcomment">With adviser approval, directed study may also be taken as an elective.</span></td><td class="hourscol"></td></tr>
    <tr class="even"><td colspan="2"><span class="courselistcomment">Complete 8 semester hours of CS, CY, DS, or IS classes that are not already required. Choose courses within the following ranges:</span></td><td class="hourscol">8</td></tr>
    <tr class="odd"><td colspan="2"><div style="margin-left:20px;" class="blockindent"><span class="courselistcomment commentindent"><a class="bubblelink code">CS&#160;2500</a> or higher, except <a class="bubblelink code">CS&#160;5010</a></span></div></td><td class="hourscol"></td></tr>
    <tr class="even lastrow"><td colspan="2"><div style="margin-left:20px;" class="blockindent"><span class="courselistcomment commentindent"><a class="bubblelink code">DS&#160;2500</a> to DS 4999 but not <a class="bubblelink code">DS&#160;4900</a></span></div></td><td class="hourscol"></td></tr>
    </tbody></table>
    <h2>Supporting Courses</h2>
    <table class="sc_courselist"><tbody>
    <tr class="even areaheader firstrow"><td colspan="2"><span class="courselistcomment areaheader">Science Requirement</span></td><td class="hourscol"></td></tr>
    <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete two courses (and any required labs) from the following science categories:</span></td><td class="hourscol">8</td></tr>
    <tr class="even areasubheader undefined subheader "><td colspan="2"><span class="courselistcomment areasubheader undefined"><i>Biology</i></span></td><td class="hourscol"></td></tr>
    <tr class="odd"><td class="codecol"><a class="bubblelink code">BIOL&#160;1111</a><br/><span class="blockindent">and <a class="bubblelink code">BIOL&#160;1112</a></span></td><td>General Biology 1<br/><span class="blockindent">and Lab for BIOL 1111</span></td><td class="hourscol"></td></tr>
    <tr class="even areasubheader undefined subheader "><td colspan="2"><span class="courselistcomment areasubheader undefined"><i>Mathematics</i></span></td><td class="hourscol"></td></tr>
    <tr class="odd lastrow"><td class="codecol"><a class="bubblelink code">MATH&#160;2331</a></td><td>Linear Algebra</td><td class="hourscol"></td></tr>
    </tbody></table>
    <h2>Required General Electives</h2>
    <table class="sc_courselist"><tbody>
    <tr class="even lastrow firstrow"><td colspan="2"><span class="courselistcomment">Complete 8 semester hours of general electives.</span></td><td class="hourscol">8</td></tr>
    </tbody></table>
    <h2>Major GPA Requirement</h2>
    <p>Minimum 2.000 GPA required in the major.</p>
    <h2>Program Requirement</h2>
    <p>52 total semester hours required</p>
    <h2>Concentration in Human-Centered Computing*</h2>
    <table class="sc_courselist"><tbody>
    <tr class="even firstrow"><td class="codecol"><a class="bubblelink code">CS&#160;2484</a></td><td>Principles of Human-Computer Interaction</td><td class="hourscol">4</td></tr>
    <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete two of the following not already taken:</span></td><td class="hourscol">8</td></tr>
    <tr class="even"><td class="codecol"><a class="bubblelink code">CS&#160;4520</a></td><td>Mobile Application Development</td><td class="hourscol"></td></tr>
    <tr class="odd"><td class="codecol"><a class="bubblelink code">CS&#160;4550</a></td><td>Web Development</td><td class="hourscol"></td></tr>
    <tr class="even lastrow"><td class="codecol"><a class="bubblelink code">DS&#160;4200</a></td><td>Information Presentation and Visualization</td><td class="hourscol"></td></tr>
    </tbody></table>
    <p>*This concentration requires a fall co-op pattern.</p>
    <h2>Software Concentration</h2>
    <table class="sc_courselist"><tbody>
    <tr class="even firstrow lastrow"><td class="codecol"><a class="bubblelink code">CS&#160;4400</a></td><td>Programming Languages</td><td class="hourscol">4</td></tr>
    </tbody></table>
    </div>
    <div id="planofstudytextcontainer" class="tab_content">
    <table class="sc_courselist"><tbody><tr><td class="codecol"><a>CS&#160;9999</a></td><td>Not a requirement</td><td class="hourscol">4</td></tr></tbody></table>
    </div>
    </body></html>
    """

    static let program = CatalogProgram(title: "Computer Science, BSCS (Boston)", path: "undergraduate/computer-information-science/computer-science/bscs/")

    static func requirements() throws -> ProgramRequirements {
        try #require(ProgramCatalogParser.requirements(fromHTML: programPage, year: CatalogYear(startYear: 2023), program: program))
    }

    static func course(_ code: String, _ credits: Double = 4, _ title: String = "", crn: String? = nil) -> DegreePlanCourse {
        DegreePlanCourse(key: CourseKey(string: code), title: title, credits: credits, crn: crn)
    }

    /// A student in the human-centered computing concentration.
    static func plan() -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.completed = [
            course("CS 1800"), course("CS 1802", 1), course("CS 3000"), course("CY 2550"),
            course("CS 4973", 4, "Topics in Computer Science"), course("CS 2484"), course("CS 4520"),
            course("CS 4535", 4, "Prof Practicum Capstone"), course("CS 2501", 1), course("MATH 1341"),
            course("CS 3000", 0),
        ]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [course("CS 3800"), course("CS 4100"), course("DS 3000"), course("CS 4410")]
        plan.terms = [spring]
        plan.catalogYear = 2023
        plan.catalogProgramPath = program.path
        plan.concentrationID = "concentration-in-human-centered-computing"
        return plan
    }

    // MARK: Parsing

    @Test func parsesRequirementTables() throws {
        let requirements = try Self.requirements()
        #expect(requirements.totalHours == 52)
        #expect(requirements.sections.map(\.title) == [
            "Major Requirements", "Supporting Courses", "Required General Electives", "Major GPA Requirement",
            "Program Requirement", "Concentration in Human-Centered Computing", "Software Concentration",
        ])
        #expect(requirements.concentrations.map(\.concentrationName) == ["Human-Centered Computing", "Software"])
        // The plan of study tab isn't part of the requirements.
        #expect(!requirements.allRules.contains { $0.listedCourses.contains(CourseKey(subject: "CS", number: "9999")) })

        let major = try #require(requirements.sections.first)
        #expect(major.groups.map(\.title) == ["Required Courses", "Security Course", "Khoury Elective Courses"])
        let required = major.groups[0].rules
        #expect(required.map(\.label) == ["CS 1800 and CS 1802", "CS 3000", "CS 4500 or CS 4530"])
        #expect(required[0].kind == .required(CourseOption(alternatives: [[CourseKey(subject: "CS", number: "1800"), CourseKey(subject: "CS", number: "1802")]])))
        #expect(required[2].hours == 4)

        let security = try #require(major.groups[1].rules.first)
        guard case .choose(let count, _, let options, let ranges) = security.kind else { Issue.record("not a choice"); return }
        #expect(count == 1 && options.count == 2 && ranges.isEmpty)

        let electives = try #require(major.groups[2].rules.first)
        guard case .choose(nil, let hours, _, let electiveRanges) = electives.kind else { Issue.record("not hours"); return }
        #expect(hours == 8)
        #expect(electiveRanges.map(\.label) == ["CS 2500 or higher, except CS 5010", "DS 2500 to DS 4999 but not DS 4900"])
        #expect(electiveRanges[0].contains(CourseKey(subject: "CS", number: "4973")))
        #expect(!electiveRanges[0].contains(CourseKey(subject: "CS", number: "5010")))
        #expect(!electiveRanges[0].contains(CourseKey(subject: "CS", number: "2100")))
        #expect(!electiveRanges[1].contains(CourseKey(subject: "DS", number: "4900")))
        #expect(!electiveRanges[1].contains(CourseKey(subject: "DS", number: "5110")))
        #expect(major.groups[2].notes.count == 1)

        let science = try #require(requirements.sections[1].groups.first?.rules.first)
        guard case .choose(2, _, let scienceOptions, _) = science.kind else { Issue.record("science"); return }
        #expect(scienceOptions.map(\.label) == ["BIOL 1111 and BIOL 1112", "MATH 2331"])
        #expect(science.notes == ["Biology", "Mathematics"])
        #expect(science.optionCategories == ["Biology", "Mathematics"])
        #expect(requirements.title(ofRule: science.id) == "Science Requirement")

        guard case .generalElectives(8)? = requirements.sections[2].groups.first?.rules.first?.kind else {
            Issue.record("general electives"); return
        }
        #expect(requirements.sections[3].notes == ["Minimum 2.000 GPA required in the major."])

        // Titles from the catalog's title column, including "and" rows and alternatives.
        func title(_ code: String) -> String? { CourseKey(string: code).flatMap { requirements.courseTitles[$0] } }
        #expect(title("CS 3000") == "Algorithms and Data")
        #expect(title("CS 4530") == "Fundamentals of Software Engineering")
        #expect(title("BIOL 1111") == "General Biology 1")
        #expect(title("BIOL 1112") == "Lab for BIOL 1111")
        #expect(title("CS 4550") == "Web Development")
    }

    @Test func ruleIDsAreStable() throws {
        let first = try Self.requirements().allRules.map(\.id)
        let second = try Self.requirements().allRules.map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count)
        #expect(first.contains("major-requirements/required-courses/cs-4500-or-cs-4530"))
    }

    @Test func readsEditionsFromTheSite() {
        let page = """
        <header><span class="edition">Academic Catalog 2031-2032</span></header>
        <a href="/archive/2030-2031">2030-2031 Catalog</a>
        <a href="https://catalog.northeastern.edu/archive/2029-2030/">2029-2030 Catalog</a>
        <a href="https://catalog.northeastern.edu/pdf/2029-2030.pdf">PDF</a>
        """
        #expect(ProgramCatalogParser.currentEdition(fromHTML: page) == CatalogYear(startYear: 2031))
        #expect(ProgramCatalogParser.archivedEditions(fromHTML: page) == [CatalogYear(startYear: 2030), CatalogYear(startYear: 2029)])
    }

    /// No year is built in: the current edition is served from the root and every other one
    /// from its archive, whatever the years are.
    @Test func editionURLsFollowTheSite() {
        let editions = CatalogEditions(current: CatalogYear(startYear: 2031), archived: [CatalogYear(startYear: 2030)], fetchedAt: .now)
        let path = "undergraduate/computer-information-science/computer-science/bscs/"
        #expect(editions.url(for: CatalogYear(startYear: 2031), path: path).absoluteString
                == "https://catalog.northeastern.edu/undergraduate/computer-information-science/computer-science/bscs/")
        #expect(editions.url(for: CatalogYear(startYear: 2030), path: path).absoluteString
                == "https://catalog.northeastern.edu/archive/2030-2031/undergraduate/computer-information-science/computer-science/bscs/")
        #expect(CatalogYear(string: "2030–2031") == CatalogYear(startYear: 2030))
        #expect(CatalogYear(string: "2030-31")?.description == "2030–2031")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let june = calendar.date(from: DateComponents(year: 2040, month: 6, day: 1))!
        let october = calendar.date(from: DateComponents(year: 2040, month: 10, day: 1))!
        #expect(CatalogYear.containing(june, calendar: calendar) == CatalogYear(startYear: 2039))
        #expect(CatalogYear.containing(october, calendar: calendar) == CatalogYear(startYear: 2040))
        #expect(CatalogEditions.estimated(now: october).archived.last == CatalogYear(startYear: 2016))
    }

    @Test func listsProgramsFromTheIndex() {
        let index = """
        <a href="/archive/2023-2024/undergraduate/computer-information-science/computer-science/bscs/">Computer Science, BSCS</a>
        <a href="/graduate/computer-information-science/computer-science/computer-science-ms/">Computer Science, MS (Boston)</a>
        <a href="/undergraduate/computer-information-science/computer-science/computer-science-minor/">Computer Science Minor</a>
        <a href="/undergraduate/about/">About, The University</a>
        <a href="#programs">Programs, AZ</a>
        """
        let programs = ProgramCatalogParser.programs(fromAZIndexHTML: index)
        #expect(programs.map(\.title) == ["Computer Science, BSCS", "Computer Science, MS (Boston)"])
        #expect(programs[0].path == "undergraduate/computer-information-science/computer-science/bscs/")
        #expect(programs[1].level == .graduate && programs[1].degree == "MS" && programs[1].campus == "Boston")
        #expect(ProgramCatalogStore.suggestedPrograms(forAuditCode: "CS-B-CSCI-BSCS", in: programs).map(\.degree) == ["BSCS"])
    }

    // MARK: Audit

    @Test func auditMatchesCoursesToRequirements() throws {
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements())
        func status(_ label: String) -> DegreeAudit.Status? {
            audit.ruleResults.first { $0.rule.label == label }?.status
        }
        #expect(!audit.needsConcentration)
        #expect(status("CS 1800 and CS 1802") == .complete)
        #expect(status("CS 3000") == .complete)
        #expect(status("CS 4500 or CS 4530") == .missing)
        #expect(status("Complete one of the following:") == .complete)
        #expect(status("CS 2484") == .complete)
        // Only CS 4520 of the concentration's list is planned.
        let hcc = try #require(audit.ruleResults.first { $0.rule.label == "Complete two of the following not already taken:" })
        #expect(hcc.status == .partial && hcc.remainingCount == 1)
        // The completed CS 4973 and CS 4535 fill the Khoury electives.
        let electives = try #require(audit.ruleResults.first { $0.rule.label.hasPrefix("Complete 8 semester hours of CS") })
        #expect(electives.status == .complete)
        #expect(Set(electives.used.map(\.key.description)) == ["CS 4973", "CS 4535"])
        #expect(status("Complete two courses (and any required labs) from the following science categories:") == .missing)
        // The software concentration isn't chosen.
        #expect(!audit.sections.contains { $0.section.title == "Software Concentration" })
        // CS 3000 is counted once, with its credits.
        #expect(audit.completedHours == 34)
        #expect(audit.plannedHours == 16)
        #expect(audit.requiredHours == 52)
    }

    @Test func substitutionsAndPetitions() throws {
        let requirements = try Self.requirements()
        var plan = Self.plan()
        let hccRule = try #require(requirements.allRules.first { $0.label == "Complete two of the following not already taken:" })
        let softwareEngineering = try #require(requirements.allRules.first { $0.label == "CS 4500 or CS 4530" })
        let science = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete two courses") })
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        let softwareOnly = try #require(requirements.allRules.first { $0.label == "CS 4400" })
        plan.substitutions = [
            // A special topics course as an HCI elective.
            RequirementSubstitution(ruleID: hccRule.id, ruleTitle: "HCI electives", change: .countCourse(CourseKey(subject: "CS", number: "4973"))),
            // The capstone for the software engineering requirement.
            RequirementSubstitution(ruleID: softwareEngineering.id, ruleTitle: "Software engineering", change: .countCourse(CourseKey(subject: "CS", number: "4535"))),
            // Petition: the science requirement replaced by two Khoury electives.
            RequirementSubstitution(ruleID: science.id, ruleTitle: "Science Requirement",
                                    change: .replace(RequirementReplacement(count: 2, likeRuleID: electives.id, likeRuleTitle: "Khoury Elective Courses")),
                                    note: "Petition approved"),
            // Doesn't apply: another concentration, and a course that isn't in the plan.
            RequirementSubstitution(ruleID: softwareOnly.id, ruleTitle: "CS 4400", change: .waive),
            RequirementSubstitution(ruleID: electives.id, ruleTitle: "Electives", change: .countCourse(CourseKey(subject: "CS", number: "4999"))),
        ]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)

        let hcc = try #require(audit.result(for: hccRule.id))
        #expect(hcc.status == .complete)
        #expect(hcc.used.contains { $0.key.description == "CS 4973" && $0.bySubstitution })

        let engineering = try #require(audit.result(for: softwareEngineering.id))
        #expect(engineering.status == .complete && engineering.used.map(\.key.description) == ["CS 4535"])

        // The replaced science requirement counts whole courses, so it picks first: CS 3800 and
        // CS 4100 (a 1-credit lab wouldn't count as a course). Electives, counted in hours, then
        // take DS 3000 and CS 4410: exactly 8, so the 1-credit CS 2501 isn't needed there.
        let electiveResult = try #require(audit.result(for: electives.id))
        #expect(electiveResult.status == .planned)
        #expect(Set(electiveResult.used.map(\.key.description)) == ["DS 3000", "CS 4410"])
        let scienceResult = try #require(audit.result(for: science.id))
        #expect(scienceResult.status == .planned)
        #expect(Set(scienceResult.used.map(\.key.description)) == ["CS 3800", "CS 4100"])
        #expect(scienceResult.substitutions.first?.note == "Petition approved")

        #expect(Set(audit.unmatchedSubstitutions.map(\.ruleTitle)) == ["CS 4400", "Electives"])
        // Every course counts once.
        let counted = audit.ruleResults.flatMap { $0.used.map(\.key) }
        #expect(counted.count == Set(counted).count)
    }

    /// When courses run short, requirements that need whole courses (a petition's "two Khoury
    /// electives") are filled first and the shortfall lands on the hours-based requirement,
    /// which small courses can also help with. Mirrors a real plan that was two courses short.
    @Test func shortfallLandsOnTheHoursRequirement() throws {
        let requirements = try Self.requirements()
        var plan = DegreePlan(name: "Short")
        plan.completed = [Self.course("CS 1800"), Self.course("CS 1802", 1), Self.course("CS 3000"), Self.course("CY 2550")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [Self.course("CS 3386"), Self.course("CS 4050"), Self.course("CS 2963", 1)]
        plan.terms = [spring]
        plan.concentrationID = "concentration-in-human-centered-computing"
        let science = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete two courses") })
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        plan.substitutions = [RequirementSubstitution(ruleID: science.id, ruleTitle: "Science Requirement",
                                                      change: .replace(RequirementReplacement(count: 2, likeRuleID: electives.id, likeRuleTitle: "Khoury Elective Courses")))]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)

        let scienceResult = try #require(audit.result(for: science.id))
        #expect(scienceResult.status == .planned)
        #expect(Set(scienceResult.used.map { $0.key.description }) == ["CS 3386", "CS 4050"])
        let electiveResult = try #require(audit.result(for: electives.id))
        #expect(electiveResult.status == .partial)
        #expect(electiveResult.used.map { $0.key.description } == ["CS 2963"])
        #expect(electiveResult.remainingHours == 7)
    }

    /// A course one list can do without moves to a requirement that needs it: HIST 2220 fills
    /// "Computing and Social Issues" so that CY 4170 can be a Khoury elective — even when
    /// HIST 2220 first has to be replaced in another list. Mirrors a real plan that the first
    /// pass left 3 semester hours short.
    @Test func rebalancesToMeetShortRequirements() throws {
        let page = """
        <div id="programrequirementstextcontainer" class="tab_content">
        <h2>Major Requirements</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even areaheader firstrow"><td colspan="2"><span class="courselistcomment areaheader">Computing and Social Issues</span></td><td class="hourscol"></td></tr>
        <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete one of the following:</span></td><td class="hourscol">4</td></tr>
        <tr class="even"><td class="codecol"><a class="bubblelink code">CY&#160;4170</a></td><td>The Law, Ethics, and Policy of Data and Digital Technologies</td><td class="hourscol"></td></tr>
        <tr class="odd"><td class="codecol"><a class="bubblelink code">HIST&#160;2220</a></td><td>History of Technology</td><td class="hourscol"></td></tr>
        <tr class="even areaheader"><td colspan="2"><span class="courselistcomment areaheader">Humanities</span></td><td class="hourscol"></td></tr>
        <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete one of the following:</span></td><td class="hourscol">4</td></tr>
        <tr class="even"><td class="codecol"><a class="bubblelink code">HIST&#160;2220</a></td><td>History of Technology</td><td class="hourscol"></td></tr>
        <tr class="odd"><td class="codecol"><a class="bubblelink code">PHIL&#160;1145</a></td><td>Technology and Human Values</td><td class="hourscol"></td></tr>
        <tr class="even areaheader"><td colspan="2"><span class="courselistcomment areaheader">Khoury Elective Courses</span></td><td class="hourscol"></td></tr>
        <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete 8 semester hours of CS, CY, DS, or IS classes that are not already required. Choose courses within the following ranges:</span></td><td class="hourscol">8</td></tr>
        <tr class="even"><td colspan="2"><div style="margin-left:20px;" class="blockindent"><span class="courselistcomment commentindent"><a class="bubblelink code">CS&#160;2500</a> or higher</span></div></td><td class="hourscol"></td></tr>
        <tr class="odd lastrow"><td colspan="2"><div style="margin-left:20px;" class="blockindent"><span class="courselistcomment commentindent"><a class="bubblelink code">CY&#160;2000</a> or higher</span></div></td><td class="hourscol"></td></tr>
        </tbody></table>
        <h2>Required General Electives</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even lastrow firstrow"><td colspan="2"><span class="courselistcomment">Complete 4 semester hours of general electives.</span></td><td class="hourscol">4</td></tr>
        </tbody></table>
        </div>
        """
        let requirements = try #require(ProgramCatalogParser.requirements(fromHTML: page, year: CatalogYear(startYear: 2024), program: Self.program))
        let rules = requirements.allRules
        try #require(rules.count == 4)
        let (socialIssues, humanities, electives) = (rules[0], rules[1], rules[2])

        func audit(completed: [String], planned: [String]) -> DegreeAudit {
            var plan = DegreePlan(name: "Plan")
            plan.completed = completed.map { Self.course($0) }
            var spring = DegreePlanTerm(season: .spring, year: 2027)
            spring.courses = planned.map { Self.course($0) }
            plan.terms = [spring]
            return DegreeAudit.run(plan: plan, requirements: requirements)
        }
        func courses(_ audit: DegreeAudit, _ rule: RequirementRule) -> Set<String> {
            Set(audit.result(for: rule.id)?.used.map(\.key.description) ?? [])
        }

        // The first pass counts the completed CY 4170 for social issues, leaving the electives
        // 4 hours short; the planned HIST 2220 takes its place.
        let swap = audit(completed: ["CY 4170", "CS 3200", "PHIL 1145"], planned: ["HIST 2220", "MKTG 4510"])
        #expect(swap.satisfiedCount == swap.totalCount)
        #expect(courses(swap, electives) == ["CS 3200", "CY 4170"])
        #expect(courses(swap, socialIssues) == ["HIST 2220"])
        #expect(courses(swap, humanities) == ["PHIL 1145"])
        #expect(swap.generalElectives.map(\.key.description) == ["MKTG 4510"])

        // Here HIST 2220 counts for the humanities first, so PHIL 1145 takes over there.
        let chain = audit(completed: ["CY 4170", "CS 3200", "HIST 2220"], planned: ["PHIL 1145", "MKTG 4510"])
        #expect(chain.satisfiedCount == chain.totalCount)
        #expect(courses(chain, electives) == ["CS 3200", "CY 4170"])
        #expect(chain.result(for: electives.id)?.status == .complete)
        #expect(courses(chain, socialIssues) == ["HIST 2220"])
        #expect(courses(chain, humanities) == ["PHIL 1145"])
        let counted = chain.ruleResults.flatMap { $0.used.map(\.key) }
        #expect(counted.count == Set(counted).count)

        // Nothing to swap: the shortfall stays where it is.
        let short = audit(completed: ["CY 4170", "CS 3200"], planned: ["MKTG 4510"])
        #expect(short.result(for: socialIssues.id)?.status == .complete)
        #expect(short.result(for: electives.id)?.remainingHours == 4)
    }

    /// A petition taking courses "like" a requirement with a minimum course number must say
    /// whether that minimum applies; the app asks when the answer changes what's met. Mirrors a
    /// real plan: Electrical Engineering replaced by any Khoury elective, which an adviser
    /// confirmed includes CS 2386 (below the electives' CS 2500).
    @Test func petitionsAskWhetherCourseNumberMinimumsApply() throws {
        let requirements = try Self.requirements()
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        let science = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete two courses") })
        var plan = DegreePlan(name: "Petition")
        plan.completed = [Self.course("CS 1800"), Self.course("CS 1802", 1), Self.course("CS 3000"), Self.course("CS 4500"), Self.course("CY 2550"),
                          Self.course("CS 2386", 4, "Game Programming 1"), Self.course("CS 2484"), Self.course("CS 4520"), Self.course("CS 4550")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [Self.course("CS 3386", 4, "Game Programming 2"), Self.course("CS 3200"), Self.course("CS 4100"), Self.course("MKTG 2602"), Self.course("PHIL 1102")]
        plan.terms = [spring]
        plan.concentrationID = "concentration-in-human-centered-computing"
        func petition(_ limit: CourseNumberLimit?) -> RequirementSubstitution {
            RequirementSubstitution(ruleID: science.id, ruleTitle: "Science Requirement",
                                    change: .replace(RequirementReplacement(count: 2, likeRuleID: electives.id, likeRuleTitle: "Khoury Elective Courses", courseNumbers: limit)))
        }

        // Unanswered: the catalog's "CS 2500 or higher" applies, so the electives come up short
        // (CS 3386 and CS 3200 go to the petition) — and the app asks.
        plan.substitutions = [petition(nil)]
        let unanswered = DegreeAudit.run(plan: plan, requirements: requirements)
        #expect(unanswered.result(for: electives.id)?.status == .partial)
        let questions = DegreePetitionQuestions.questions(plan: plan, requirements: requirements, audit: unanswered)
        let question = try #require(questions.first)
        #expect(questions.count == 1)
        #expect(question.courses == [CourseKey(subject: "CS", number: "2386")])
        #expect(question.question == "Does your Science Requirement petition accept any CS or DS course?")
        #expect(question.explanation.contains("start at CS 2500 or DS 2500"))
        #expect(question.explanation.contains("CS 2386 counts"))

        // Any number: CS 2386 counts for the petition, the electives are met.
        plan.substitutions = [petition(.anyNumber)]
        let anyNumber = DegreeAudit.run(plan: plan, requirements: requirements)
        #expect(anyNumber.result(for: science.id)?.used.contains { $0.key.description == "CS 2386" } == true)
        #expect(anyNumber.result(for: electives.id)?.status == .planned)
        #expect(DegreePetitionQuestions.questions(plan: plan, requirements: requirements).isEmpty)
        if case .choose(_, _, _, let ranges)? = anyNumber.result(for: science.id)?.effectiveKind {
            #expect(ranges.map(\.label) == ["Any CS course, except CS 5010", "DS courses up to DS 4999, except DS 4900"])
        } else {
            Issue.record("the petition should take courses like the electives")
        }

        // A different minimum: CS 2000 or higher still takes CS 2386; CS 3000 or higher doesn't.
        plan.substitutions = [petition(.atLeast(2000))]
        #expect(DegreeAudit.run(plan: plan, requirements: requirements).result(for: electives.id)?.status == .planned)
        plan.substitutions = [petition(.atLeast(3000))]
        #expect(DegreeAudit.run(plan: plan, requirements: requirements).result(for: electives.id)?.status == .partial)

        // Answered "same as the requirement": no more questions, and the near miss is explained.
        plan.substitutions = [petition(.sameAsRequirement)]
        #expect(DegreePetitionQuestions.questions(plan: plan, requirements: requirements).isEmpty)
        let same = DegreeAudit.run(plan: plan, requirements: requirements)
        let miss = try #require(same.nearMisses(for: electives.id).first)
        #expect(miss.course.key.description == "CS 2386" && miss.reason == "Below CS 2500")

        // Older petitions without the answer still decode.
        let old = #"{"count":2,"likeRuleID":"x","likeRuleTitle":"Khoury Elective Courses","courses":[]}"#
        let decoded = try JSONDecoder().decode(RequirementReplacement.self, from: Data(old.utf8))
        #expect(decoded.courseNumbers == nil)
        #expect(RequirementReplacement(count: 1, likeRuleTitle: "Khoury Elective Courses", courseNumbers: .anyNumber).summary
                == "1 course like Khoury Elective Courses, any course number")
    }

    /// A topics course taken again on another topic counts each time; the same course listed
    /// twice counts once.
    @Test func topicsCoursesCountEachTime() throws {
        let requirements = try Self.requirements()
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        var plan = DegreePlan(name: "Topics")
        plan.completed = [Self.course("CS 1800"), Self.course("CS 1802", 1), Self.course("CS 3000"), Self.course("CS 4500"), Self.course("CY 2550"),
                          Self.course("CS 4973", 4, "Topics in Computer Science"), Self.course("MKTG 2602", 4, "Marketing Management")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [Self.course("CS 4973", 4, "Topics in Computer Science"), Self.course("MKTG 2602", 4, "Marketing Management")]
        plan.terms = [spring]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)
        let result = try #require(audit.result(for: electives.id))
        #expect(result.status == .planned)
        #expect(result.used.map(\.id).sorted() == ["CS 4973", "CS 4973 (2)"])
        // The second MKTG 2602 is a repeat: it counts once, as a general elective.
        let counted = audit.ruleResults.flatMap(\.used) + audit.unused
        #expect(counted.filter { $0.key.description == "MKTG 2602" }.count == 1)
        #expect(Set(counted.map(\.id)).count == counted.count)
        // The plan flags the repeat, not the topics course taken again.
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan) == [CourseKey(subject: "MKTG", number: "2602")])
    }

    /// The same number counts twice when each row has its own CRN, once when it does not,
    /// and once when both rows name the same CRN. Titles here are "Seminar", not a topics title.
    @Test func distinctCRNsCountSeparately() throws {
        let requirements = try Self.requirements()
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        let key = CourseKey(subject: "CS", number: "4973")

        var separate = DegreePlan(name: "Seminars")
        separate.completed = [
            Self.course("CS 4973", 4, "Seminar", crn: "11111"),
            Self.course("CS 4973", 4, "Seminar", crn: "22222"),
        ]
        let both = DegreeAudit.run(plan: separate, requirements: requirements)
        let counted = try #require(both.result(for: electives.id))
        #expect(counted.status == .complete)
        #expect(counted.used.map(\.id).sorted() == ["CS 4973", "CS 4973 (2)"])
        #expect(counted.used.reduce(0) { $0 + $1.credits } == 8)
        #expect(DegreePlanAnalysis.duplicateKeys(in: separate).isEmpty)

        var plain = DegreePlan(name: "Seminars")
        plain.completed = [Self.course("CS 4973", 4, "Seminar"), Self.course("CS 4973", 4, "Seminar")]
        let once = try #require(DegreeAudit.run(plan: plain, requirements: requirements).result(for: electives.id))
        #expect(once.used.map(\.id) == ["CS 4973"])
        #expect(once.used.reduce(0) { $0 + $1.credits } == 4)
        #expect(DegreePlanAnalysis.duplicateKeys(in: plain) == [key])

        var repeated = DegreePlan(name: "Seminars")
        repeated.completed = [
            Self.course("CS 4973", 4, "Seminar", crn: "11111"),
            Self.course("CS 4973", 4, "Seminar", crn: "11111"),
        ]
        let same = try #require(DegreeAudit.run(plan: repeated, requirements: requirements).result(for: electives.id))
        #expect(same.used.map(\.id) == ["CS 4973"])
        #expect(DegreePlanAnalysis.duplicateKeys(in: repeated) == [key])
    }

    /// A required course with alternatives gives up the one another list needs when the plan
    /// has the other alternative too.
    @Test func requiredAlternativesMakeRoom() throws {
        let page = """
        <div id="programrequirementstextcontainer" class="tab_content">
        <h2>Major Requirements</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even areaheader firstrow"><td colspan="2"><span class="courselistcomment areaheader">Software Engineering</span></td><td class="hourscol"></td></tr>
        <tr class="odd"><td class="codecol"><a class="bubblelink code">CS&#160;4500</a></td><td>Software Development</td><td class="hourscol">4</td></tr>
        <tr class="orclass even"><td class="codecol orclass">or <a class="bubblelink code">CS&#160;4530</a></td><td colspan="2">Fundamentals of Software Engineering</td></tr>
        <tr class="odd areaheader"><td colspan="2"><span class="courselistcomment areaheader">Concentration Courses</span></td><td class="hourscol"></td></tr>
        <tr class="even"><td colspan="2"><span class="courselistcomment">Complete two of the following:</span></td><td class="hourscol">8</td></tr>
        <tr class="odd"><td class="codecol"><a class="bubblelink code">CS&#160;4530</a></td><td>Fundamentals of Software Engineering</td><td class="hourscol"></td></tr>
        <tr class="even lastrow"><td class="codecol"><a class="bubblelink code">CS&#160;4550</a></td><td>Web Development</td><td class="hourscol"></td></tr>
        </tbody></table>
        </div>
        """
        let requirements = try #require(ProgramCatalogParser.requirements(fromHTML: page, year: CatalogYear(startYear: 2024), program: Self.program))
        let rules = requirements.allRules
        try #require(rules.count == 2)
        var plan = DegreePlan(name: "Plan")
        plan.completed = [Self.course("CS 4530"), Self.course("CS 4550")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [Self.course("CS 4500")]
        plan.terms = [spring]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)
        #expect(audit.satisfiedCount == 2)
        #expect(audit.result(for: rules[0].id)?.used.map(\.key.description) == ["CS 4500"])
        #expect(Set(audit.result(for: rules[1].id)?.used.map(\.key.description) ?? []) == ["CS 4530", "CS 4550"])
    }

    /// Substitutions saved under another catalog year, where the requirements' wording (and so
    /// their ids) changed, follow the requirements' names.
    @Test func substitutionsFollowRequirementsAcrossCatalogYears() throws {
        let requirements = try Self.requirements()
        let science = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete two courses") })
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        var plan = Self.plan()
        plan.substitutions = [
            RequirementSubstitution(ruleID: "supporting-courses/science-requirement/complete-any-two-courses-from-last-year",
                                    ruleTitle: "Science Requirement",
                                    change: .replace(RequirementReplacement(count: 2, likeRuleID: "major-requirements/khoury-elective-courses/older-wording",
                                                                           likeRuleTitle: "Khoury Elective Courses", courseNumbers: .sameAsRequirement))),
            RequirementSubstitution(ruleID: "gone", ruleTitle: "A requirement this year doesn't have", change: .waive),
        ]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)
        let result = try #require(audit.result(for: science.id))
        #expect(result.substitutions.count == 1)
        // Two courses like the electives (found by name too): CS 4973 and CS 4535, taken.
        #expect(result.status == .complete)
        #expect(Set(result.used.map(\.key.description)) == ["CS 4973", "CS 4535"])
        #expect(audit.placements[plan.substitutions[0].id] == science.id)
        #expect(audit.unmatchedSubstitutions.map(\.ruleTitle) == ["A requirement this year doesn't have"])
        if case .replace(let replacement) = plan.substitutions[0].change {
            #expect(replacement.likeRanges(in: requirements).count == 2)
        }
        #expect(audit.result(for: electives.id)?.status == .planned)
    }

    /// A requirement counted in hours shows only the courses it needs: no 1-credit course on top
    /// of two 4-credit ones for 8 hours. General electives likewise take the fewest credits that
    /// make their hours; what's left is an extra course.
    @Test func hourRequirementsKeepOnlyWhatTheyNeed() throws {
        let requirements = try Self.requirements()
        let electives = try #require(requirements.allRules.first { $0.label.hasPrefix("Complete 8 semester hours of CS") })
        var plan = DegreePlan(name: "Hours")
        plan.completed = [Self.course("CS 1800"), Self.course("CS 1802", 1), Self.course("CS 3000"), Self.course("CS 4500"), Self.course("CY 2550"),
                          Self.course("CS 4100"), Self.course("MATH 1341"), Self.course("PHIL 1102")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [Self.course("CS 2963", 1, "Topics")]
        var summer = DegreePlanTerm(season: .summerB, year: 2027)
        summer.courses = [Self.course("CS 3200")]
        plan.terms = [spring, summer]
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)

        let result = try #require(audit.result(for: electives.id))
        #expect(result.status == .planned)
        #expect(Set(result.used.map(\.key.description)) == ["CS 4100", "CS 3200"])
        #expect(result.used.reduce(0) { $0 + $1.credits } == 8)
        #expect(Set(audit.generalElectives.map(\.key.description)) == ["MATH 1341", "PHIL 1102"])
        #expect(audit.unused.map(\.key.description) == ["CS 2963"])

        // The least to spare across sizes: 4 + 4 for 8, not 5 + 4.
        let uses = [("A", 5.0, true), ("B", 4.0, false), ("C", 4.0, false)].enumerated().map { index, item in
            DegreeAudit.CourseUse(key: CourseKey(subject: "CS", number: "\(4000 + index)"), title: item.0, credits: item.1,
                                  semester: item.2 ? nil : "Spring 2027", order: index)
        }
        #expect(DegreeAudit.fewestCreditsChoice(uses, reaching: 8) == ["CS 4001", "CS 4002"])
    }

    /// Sentences the plan can answer are checked: hours in the major (the program's requirements,
    /// not general electives or writing) and co-op. A GPA stays unchecked.
    @Test func checksHoursInTheMajorAndCoop() throws {
        let page = """
        <div id="programrequirementstextcontainer" class="tab_content">
        <h2>Major Requirements</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even firstrow"><td class="codecol"><a class="bubblelink code">CS&#160;3000</a></td><td>Algorithms and Data</td><td class="hourscol">4</td></tr>
        <tr class="odd"><td colspan="2"><span class="courselistcomment">Complete 8 semester hours of CS classes. Choose courses within the following ranges:</span></td><td class="hourscol">8</td></tr>
        <tr class="even lastrow"><td colspan="2"><div style="margin-left:20px;" class="blockindent"><span class="courselistcomment commentindent"><a class="bubblelink code">CS&#160;2500</a> or higher</span></div></td><td class="hourscol"></td></tr>
        </tbody></table>
        <h2>Writing Requirement</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even firstrow lastrow"><td class="codecol"><a class="bubblelink code">ENGW&#160;1111</a></td><td>First-Year Writing</td><td class="hourscol">4</td></tr>
        </tbody></table>
        <h2>Required General Electives</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even lastrow firstrow"><td colspan="2"><span class="courselistcomment">Complete 4 semester hours of general electives.</span></td><td class="hourscol">4</td></tr>
        </tbody></table>
        <h2>GPA Requirement</h2>
        <p>Minimum 2.000 GPA required in the major.</p>
        <h2>Credit Requirement</h2>
        <p>Complete 16 semester hours in the major.</p>
        <h2>NUpath Requirements Satisfied</h2>
        <p>Integrating Knowledge and Skills Through Experience is satisfied through co-op.</p>
        </div>
        """
        let requirements = try #require(ProgramCatalogParser.requirements(fromHTML: page, year: CatalogYear(startYear: 2024), program: Self.program))
        func audit(_ completed: [String], planned: [String] = []) -> DegreeAudit {
            var plan = DegreePlan(name: "Checks")
            plan.completed = completed.map { code in
                code == "COOP 3946" ? Self.course(code, 0, "Co-op Work Experience - HT") : Self.course(code)
            }
            var fall = DegreePlanTerm(season: .fall, year: 2027)
            fall.courses = planned.map { Self.course($0) }
            plan.terms = [fall]
            return DegreeAudit.run(plan: plan, requirements: requirements)
        }

        // 4 (CS 3000) + 8 (electives) + 4 more CS in the ranges = 16; ENGW and the general elective
        // don't count. CS 1210 is about co-op, not one.
        let done = audit(["CS 3000", "CS 3200", "CS 3500", "CS 4100", "ENGW 1111", "MKTG 2602", "COOP 3946", "CS 1210"])
        #expect(done.noteChecks.count == 2)
        let hours = try #require(done.noteChecks.first { if case .majorHours = $0.kind { true } else { false } })
        #expect(hours.status == .complete)
        #expect(hours.detail == "16 of 16 semester hours")
        let coop = try #require(done.noteChecks.first { if case .coop = $0.kind { true } else { false } })
        #expect(coop.status == .complete && coop.detail == "COOP 3946 completed")
        #expect(done.satisfiedCount == done.totalCount)

        let short = audit(["CS 3000", "CS 3200", "CS 1210"], planned: ["CS 3500"])
        let shortHours = try #require(short.noteChecks.first { if case .majorHours = $0.kind { true } else { false } })
        // 4 (CS 3000) + 4 (CS 3200) earned, 4 (CS 3500) planned. Not 12 of 16 with the 4 planned again.
        #expect(shortHours.status == .partial)
        #expect(shortHours.detail == "8 of 16 semester hours · 4 planned")
        #expect(short.noteChecks.first { if case .coop = $0.kind { true } else { false } }?.detail == "No co-op in the plan")
        #expect(short.satisfiedCount < short.totalCount)
    }

    @Test func waiversAndConcentrationChoice() throws {
        let requirements = try Self.requirements()
        var plan = Self.plan()
        let security = try #require(requirements.allRules.first { $0.label == "Complete one of the following:" })
        plan.substitutions = [RequirementSubstitution(ruleID: security.id, ruleTitle: "Security Course", change: .waive)]
        plan.concentrationID = nil
        let audit = DegreeAudit.run(plan: plan, requirements: requirements)
        #expect(audit.result(for: security.id)?.status == .waived)
        #expect(audit.needsConcentration)
        #expect(!audit.sections.contains { $0.section.isConcentration })
        // CY 2550 is free again and ends up as a general elective or unused.
        #expect(audit.ruleCounting(CourseKey(subject: "CY", number: "2550"))?.rule.id != security.id)
    }

    /// One unreadable entry (e.g. written by a newer app version) doesn't cost the others.
    @Test func userDataSkipsUnreadableEntries() throws {
        var data = UserData()
        data.degreePlans = [Self.plan(), DegreePlan(name: "Second")]
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        var plans = try #require(json["degreePlans"] as? [[String: Any]])
        plans[0]["completed"] = "not a list"   // breaks the first plan only
        json["degreePlans"] = plans
        json["searchHistory"] = ["cs 3000", 42, "orgo"]
        let decoded = try JSONDecoder().decode(UserData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.degreePlans.map { $0.name } == ["Second"])
        #expect(decoded.searchHistory == ["cs 3000", "orgo"])
    }

    /// Plans saved before degree requirements existed still load.
    @Test func olderSavedPlansStillDecode() throws {
        var plan = Self.plan()
        plan.substitutions = [RequirementSubstitution(ruleID: "x", ruleTitle: "X", change: .waive)]
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        for key in ["substitutions", "catalogYear", "catalogProgramPath", "catalogProgramTitle", "concentrationID"] {
            json.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(DegreePlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.name == "Plan" && decoded.completed.count == plan.completed.count)
        #expect(decoded.substitutions.isEmpty && decoded.catalogYear == nil)

        let roundTrip = try JSONDecoder().decode(DegreePlan.self, from: JSONEncoder().encode(plan))
        #expect(roundTrip == plan)
    }
}
