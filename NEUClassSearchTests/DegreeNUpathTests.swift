//
//  DegreeNUpathTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// The catalog sentences the audit checks besides the requirement tables: NUpath, the
/// universitywide minimums and the program's total hours.
struct DegreeNUpathTests {
    static let program = CatalogProgram(title: "Computer Science, BSCS (Boston)", path: "undergraduate/computer-information-science/computer-science/bscs/")

    /// The shape of the BSCS page's sentences (2024–2025).
    static let page = """
    <div id="programrequirementstextcontainer" class="tab_content">
    <h2>Universitywide Requirements</h2>
    <p>All undergraduate students are required to complete the <a href="/archive/2024-2025/undergraduate/university-academics/university-wide-requirements/">Universitywide Requirements</a>.</p>
    <h2>NUpath Requirements</h2>
    <p>All undergraduate students are required to complete the <a href="/archive/2024-2025/undergraduate/university-academics/nupath/">NUpath Requirements</a>.</p>
    <h2>Major Requirements</h2>
    <table class="sc_courselist"><tbody>
    <tr class="even firstrow lastrow"><td class="codecol"><a class="bubblelink code">CS&#160;3000</a></td><td>Algorithms and Data</td><td class="hourscol">4</td></tr>
    </tbody></table>
    <h2>Khoury College GPA Requirement</h2>
    <p>Minimum cumulative 2.000 GPA required in all CS, CY, DS, and IS courses</p>
    <h2>NUpath Requirements Satisfied</h2>
    <p>Integrating Knowledge and Skills Through Experience is satisfied through co-op.</p>
    <h2>Program Requirement</h2>
    <p>134 total semester hours required</p>
    </div>
    """

    static func requirements(universitywide: UniversitywideRequirements? = nil) throws -> ProgramRequirements {
        var requirements = try #require(ProgramCatalogParser.requirements(fromHTML: page, year: CatalogYear(startYear: 2024), program: program))
        requirements.universitywide = universitywide
        return requirements
    }

    static func course(_ code: String, _ credits: Double = 4, _ title: String = "") -> DegreePlanCourse {
        DegreePlanCourse(key: CourseKey(string: code), title: title, credits: credits)
    }

    static func key(_ code: String) -> CourseKey { CourseKey(string: code)! }

    /// A plan that meets every NUpath requirement, some with planned courses.
    static func plan() -> DegreePlan {
        var plan = DegreePlan(name: "NUpath")
        plan.completed = ["ENGW 1111", "MATH 1341", "PHYS 1151", "CS 3200", "PHIL 1145", "ARTH 1111", "HIST 1130", "CS 3000"].map { course($0) }
            + [course("COOP 3946", 0, "Co-op Work Experience - HT")]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [course("ENGW 3302"), course("CS 4535"), course("CS 3484")]
        plan.terms = [spring]
        return plan
    }

    static let attributes: [String: Set<NUPath>] = [
        "ENGW 1111": [.wf], "MATH 1341": [.fq], "PHYS 1151": [.nd], "CS 3200": [.ad, .fq], "PHIL 1145": [.er, .si],
        "ARTH 1111": [.ic, .ei], "HIST 1130": [.dd, .si], "CS 3000": [.fq], "ENGW 3302": [.wd],
        "CS 4535": [.ce, .ex, .wi], "CS 3484": [.wi],
    ]

    static func attributes(_ table: [String: Set<NUPath>] = attributes, loading: [String] = []) -> DegreeCourseAttributes {
        DegreeCourseAttributes(nupaths: Dictionary(uniqueKeysWithValues: table.map { (key($0.key), $0.value) }),
                               loading: Set(loading.map(key)))
    }

    static func nupath(_ audit: DegreeAudit) -> DegreeAudit.NoteCheck? {
        audit.noteChecks.first { if case .nupath = $0.kind { true } else { false } }
    }

    static func item(_ check: DegreeAudit.NoteCheck?, _ path: NUPath) -> DegreeAudit.NoteCheck.Item? {
        check?.items.first { $0.id == path.rawValue }
    }

    // MARK: NUpath

    /// Writing-intensive needs two courses. Two sections of CS 4973 with different CRNs
    /// are two courses; the same title with no CRN is one.
    @Test func twoSectionsOfOneNumberCountAsTwoNUpathCourses() throws {
        let requirements = try Self.requirements()
        var separate = DegreePlan(name: "Seminars")
        separate.completed = [
            DegreePlanCourse(key: CourseKey(string: "CS 4973"), title: "Seminar", credits: 4, crn: "11111"),
            DegreePlanCourse(key: CourseKey(string: "CS 4973"), title: "Seminar", credits: 4, crn: "22222"),
        ]
        let both = DegreeAudit.run(plan: separate, requirements: requirements, attributes: Self.attributes(["CS 4973": [.wi]]))
        let writing = try #require(Self.item(Self.nupath(both), .wi))
        #expect(writing.status == .complete)
        #expect(writing.courses.sorted() == ["CS 4973", "CS 4973 (2)"])

        var plain = DegreePlan(name: "Seminars")
        plain.completed = [
            DegreePlanCourse(key: CourseKey(string: "CS 4973"), title: "Seminar", credits: 4),
            DegreePlanCourse(key: CourseKey(string: "CS 4973"), title: "Seminar", credits: 4),
        ]
        let twice = DegreeAudit.run(plan: plain, requirements: requirements, attributes: Self.attributes(["CS 4973": [.wi]]))
        let bothPlain = try #require(Self.item(Self.nupath(twice), .wi))
        #expect(bothPlain.courses.sorted() == ["CS 4973", "CS 4973 (2)"])
        #expect(bothPlain.status == .complete)
    }

    @Test func everyNUpathRequirementIsChecked() throws {
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements(), attributes: Self.attributes())
        let check = try #require(Self.nupath(audit))
        #expect(check.items.map(\.id) == NUpathRequirement.all.map(\.path.rawValue))
        #expect(check.items.allSatisfy { $0.status?.isSatisfied == true })
        #expect(check.status == .planned)
        #expect(check.counts)
        #expect(check.detail == "13 of 13 met")
        #expect(Self.item(check, .wf)?.detail == "ENGW 1111 completed")
        // Two writing-intensive courses; the capstone and experience aren't limited, so CS 4535
        // counts for them too. The co-op satisfies the experience, as the program says.
        #expect(Self.item(check, .wi)?.courses == ["CS 4535", "CS 3484"])
        #expect(Self.item(check, .wi)?.detail == "CS 4535 planned · Spring 2027 · CS 3484 planned · Spring 2027")
        #expect(Self.item(check, .ce)?.courses == ["CS 4535"])
        #expect(Self.item(check, .ex)?.courses == ["COOP 3946"])
        #expect(Self.item(check, .ex)?.status == .complete)
        // A course counts for at most two of the eight areas.
        var areas: [String: Int] = [:]
        for requirement in NUpathRequirement.all where requirement.isLimited {
            for id in Self.item(check, requirement.path)?.courses ?? [] { areas[id, default: 0] += 1 }
        }
        #expect(areas.values.allSatisfy { $0 <= 2 })
        #expect(audit.countedChecks.contains { if case .nupath = $0.kind { $0.status.isSatisfied } else { false } })
    }

    @Test func aCourseCountsForTwoAreasAtMost() throws {
        var table = Self.attributes
        // ARTH 1111 has three areas and HIST 1130 is gone: one of the three can't be met.
        table["ARTH 1111"] = [.ic, .ei, .dd]
        table["HIST 1130"] = []
        let baseline = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements(), attributes: Self.attributes())
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements(), attributes: Self.attributes(table))
        let check = try #require(Self.nupath(audit))
        let open = check.items.filter { $0.status?.isSatisfied != true }
        #expect(open.count == 1)
        #expect(open.first?.status == .missing)
        #expect(open.first?.detail == "No course in the plan has it")
        #expect(check.status == .partial && check.counts)
        #expect(check.detail.hasPrefix("12 of 13 met · missing "))
        #expect(audit.satisfiedCount == baseline.satisfiedCount - 1)
        #expect(audit.totalCount == baseline.totalCount)
    }

    @Test func unknownCoursesKeepAShortfallFromCounting() throws {
        var table = Self.attributes
        table["HIST 1130"] = nil
        let requirements = try Self.requirements()
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: requirements, attributes: Self.attributes(table))
        let check = try #require(Self.nupath(audit))
        // HIST 1130 may well have the DD attribute: not "missing", and not held against the plan.
        #expect(Self.item(check, .dd)?.status == nil)
        #expect(Self.item(check, .dd)?.detail == "Not found among the courses with NUpath data")
        #expect(!check.counts)
        #expect(check.detail == "12 of 13 met · no NUpath data for HIST 1130")
        #expect(!audit.countedChecks.contains { if case .nupath = $0.kind { true } else { false } })

        // While it's being looked up, say so.
        let loading = DegreeAudit.run(plan: Self.plan(), requirements: requirements, attributes: Self.attributes(table, loading: ["HIST 1130"]))
        let pending = try #require(Self.nupath(loading))
        #expect(Self.item(pending, .dd)?.detail == "Looking up the plan’s courses…")
        #expect(pending.detail == "12 of 13 met · looking up 1 course")

        // Met anyway: an unknown course doesn't matter.
        table["HIST 1130"] = nil
        table["ARTH 1111"] = [.ic, .dd]
        table["CS 3000"] = [.ei]
        let met = try #require(Self.nupath(DegreeAudit.run(plan: Self.plan(), requirements: requirements, attributes: Self.attributes(table))))
        #expect(met.counts && met.status == .planned)
    }

    @Test func withoutAttributesNUpathIsNotChecked() throws {
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements())
        #expect(Self.nupath(audit) == nil)
    }

    @Test func aRenumberedCourseUsesItsReplacementsAttributes() throws {
        var plan = Self.plan()
        plan.completed[2] = Self.course("PHYS 1145")   // retired, no data
        var table = Self.attributes
        table["PHYS 1151"] = nil
        table["PHYS 1149"] = [.nd]
        plan.courseEquivalences = [CourseEquivalence(course: Self.key("PHYS 1145"), countsAs: Self.key("PHYS 1149"), note: "Renumbered")]
        let check = try #require(Self.nupath(DegreeAudit.run(plan: plan, requirements: try Self.requirements(), attributes: Self.attributes(table))))
        #expect(Self.item(check, .nd)?.courses == ["PHYS 1145"])
        #expect(check.counts)
    }

    @Test func withoutACoopAnExperienceCourseCounts() throws {
        var plan = Self.plan()
        plan.completed.removeAll { $0.key?.subject == "COOP" }
        let audit = DegreeAudit.run(plan: plan, requirements: try Self.requirements(), attributes: Self.attributes())
        let coop = try #require(audit.noteChecks.first { if case .coop = $0.kind { true } else { false } })
        #expect(coop.status == .planned)
        #expect(coop.detail == "No co-op in the plan · CS 4535 (EX) planned")
        #expect(Self.item(Self.nupath(audit), .ex)?.courses == ["CS 4535"])
    }

    /// Against an obviously correct enumeration: the matching meets as many areas as any
    /// assignment can, and among those uses as many completed courses as any can.
    @Test func matchingIsOptimal() {
        var generator = NUpathSeededGenerator(seed: 2016)
        let areas = NUpathRequirement.all.filter(\.isLimited).map(\.path)
        for _ in 0..<600 {
            let wanted = Array(areas.shuffled(using: &generator).prefix(Int.random(in: 1...5, using: &generator)))
            let courses = (0..<Int.random(in: 1...5, using: &generator)).map { index in
                NUpathMatching.Course(id: "C\(index)", paths: Set(wanted.filter { _ in Int.random(in: 0..<10, using: &generator) < 4 }),
                                      isCompleted: Bool.random(using: &generator))
            }
            let matching = NUpathMatching(courses: courses, requirements: wanted.map { NUpathRequirement(path: $0, count: 1, isLimited: true) })
            let chosen = wanted.compactMap { area in matching.courses(for: area).first.map { (area, $0) } }
            let completed = chosen.filter { pair in courses.first { $0.id == pair.1 }?.isCompleted == true }.count
            // Valid: each course has the area, two areas a course at most.
            #expect(chosen.allSatisfy { pair in courses.first { $0.id == pair.1 }?.paths.contains(pair.0) == true })
            #expect(Dictionary(grouping: chosen, by: \.1).values.allSatisfy { $0.count <= 2 })

            var best = (met: 0, completed: 0)
            func search(_ position: Int, load: [Int], met: Int, done: Int) {
                guard position < wanted.count else {
                    if (met, done) > (best.met, best.completed) { best = (met, done) }
                    return
                }
                search(position + 1, load: load, met: met, done: done)
                for (index, course) in courses.enumerated() where course.paths.contains(wanted[position]) && load[index] < 2 {
                    var next = load
                    next[index] += 1
                    search(position + 1, load: next, met: met + 1, done: done + (course.isCompleted ? 1 : 0))
                }
            }
            search(0, load: Array(repeating: 0, count: courses.count), met: 0, done: 0)
            #expect(chosen.count == best.met)
            #expect(completed == best.completed)
        }
    }

    // MARK: Universitywide, total hours, unchecked sentences

    @Test func readsTheUniversitywideMinimums() throws {
        let archived = """
        <div id="textcontainer"><p>Note: Individual program requirements may exceed the following minima.</p>
        <ul><li>Minimum 128 total semester hours required</li><li>Minimum 2.000 GPA required</li></ul>
        <p>Students must earn a minimum of 64 Northeastern University semester hours in order to receive a bachelor’s degree.</p></div>
        """
        let minimums = try #require(ProgramCatalogParser.universitywideRequirements(fromHTML: archived))
        #expect(minimums.totalHours == 128 && minimums.gpa == 2 && minimums.residencyHours == 64)
        #expect(!minimums.requiresExperientialLearning)
        let current = archived.replacingOccurrences(
            of: "</div>", with: "<p>Students must complete all university and program requirements, including the experiential learning graduation requirement.</p></div>")
        #expect(ProgramCatalogParser.universitywideRequirements(fromHTML: current)?.requiresExperientialLearning == true)
        #expect(ProgramCatalogParser.universitywideRequirements(fromHTML: "<div id=\"textcontainer\"><p>Nothing here.</p></div>") == nil)
        #expect(ProgramCatalogParser.universitywideLink(in: Self.page) == "undergraduate/university-academics/university-wide-requirements/")
    }

    @Test func checksTheUniversitywideMinimumsItCan() throws {
        let minimums = UniversitywideRequirements(totalHours: 128, gpa: 2, residencyHours: 64, fetchedAt: .now)
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements(universitywide: minimums), attributes: Self.attributes())
        let check = try #require(audit.noteChecks.first { if case .universitywide = $0.kind { true } else { false } })
        #expect(check.items.map(\.id) == ["total-hours", "gpa", "residency"])
        #expect(check.items[0].status == .partial)
        #expect(check.items[0].detail == "32 of 128 semester hours · 12 planned")
        #expect(check.items[1].status == nil && check.items[1].detail == "Not checked: plans don’t include grades")
        #expect(check.items[2].status == nil)
        #expect(check.status == .partial && check.counts)
        #expect(check.detail == "32 of 128 semester hours · 12 planned · GPA and residency not checked")

        // Without the minimums, nothing to check.
        let unread = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements(), attributes: Self.attributes())
        #expect(!unread.noteChecks.contains { if case .universitywide = $0.kind { true } else { false } })
    }

    @Test func checksTheProgramsTotalHours() throws {
        let audit = DegreeAudit.run(plan: Self.plan(), requirements: try Self.requirements())
        let check = try #require(audit.noteChecks.first { if case .totalHours = $0.kind { true } else { false } })
        #expect(check.status == .partial)
        #expect(check.detail == "32 of 134 semester hours · 12 planned")
    }

    @Test func saysWhySomeSentencesArentChecked() {
        #expect(DegreeAudit.uncheckedReason(for: "Minimum cumulative 2.000 GPA required in all CS, CY, DS, and IS courses") == "Not checked: plans don’t include grades")
        #expect(DegreeAudit.uncheckedReason(for: "Students must earn a minimum of 64 Northeastern University semester hours.") == "Not checked: a plan doesn’t say where credits were earned")
        #expect(DegreeAudit.uncheckedReason(for: "Pick one of the following concentrations and complete four courses in that concentration.")
                == "Checked through the concentration you choose")
        #expect(DegreeAudit.uncheckedReason(for: "Courses may not be taken pass/fail.") == nil)
    }

    /// Alex's report: 105 earned and 30 planned. The header already said "105 of 134 credits
    /// done · 30 planned". The universitywide line said "135 of 128 semester hours · 30 planned",
    /// which is 105 + 30 in the first number and the 30 again. Every hours line uses
    /// `DegreeAudit.hoursStatus`: the first number is completed credits only.
    @Test func hoursLinesKeepCompletedSeparateFromPlanned() throws {
        #expect(DegreeAudit.hoursStatus(completed: 105, planned: 30, required: 128)
                == (.planned, "105 of 128 semester hours · 30 planned"))
        #expect(DegreeAudit.hoursStatus(completed: 105, planned: 30, required: 134)
                == (.planned, "105 of 134 semester hours · 30 planned"))
        #expect(DegreeAudit.hoursStatus(completed: 60, planned: 22, required: 72)
                == (.planned, "60 of 72 semester hours · 22 planned"))
        #expect(DegreeAudit.hoursStatus(completed: 128, planned: 0, required: 128)
                == (.complete, "128 of 128 semester hours"))
        #expect(DegreeAudit.hoursStatus(completed: 140, planned: 10, required: 128)
                == (.complete, "140 of 128 semester hours · 10 planned"))
        #expect(DegreeAudit.hoursStatus(completed: 90, planned: 20, required: 128)
                == (.partial, "90 of 128 semester hours · 20 planned"))
        #expect(DegreeAudit.hoursStatus(completed: 0, planned: 0, required: 128)
                == (.missing, "0 of 128 semester hours"))
        #expect(DegreeAudit.hoursStatus(completed: 0, planned: 128, required: 128)
                == (.planned, "0 of 128 semester hours · 128 planned"))

        let page = """
        <div id="programrequirementstextcontainer" class="tab_content">
        <h2>Universitywide Requirements</h2>
        <p>All undergraduate students are required to complete the Universitywide Requirements.</p>
        <h2>Major Requirements</h2>
        <table class="sc_courselist"><tbody>
        <tr class="even firstrow"><td class="codecol"><a class="bubblelink code">CS&#160;3000</a></td><td>Algorithms</td><td class="hourscol">4</td></tr>
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
        <h2>Credit Requirement</h2>
        <p>Complete 72 semester hours in the major.</p>
        <h2>Program Requirement</h2>
        <p>134 total semester hours required</p>
        </div>
        """
        var requirements = try #require(ProgramCatalogParser.requirements(fromHTML: page, year: CatalogYear(startYear: 2024), program: Self.program))
        requirements.universitywide = UniversitywideRequirements(totalHours: 128, gpa: 2, residencyHours: 64, fetchedAt: .now)
        var plan = DegreePlan(name: "BS CS")
        plan.completed = [
            Self.course("CS 3000", 40),
            Self.course("CS 2500", 20),
            Self.course("ENGW 1111", 4),
            Self.course("PHIL 1102", 41),
        ]
        var spring = DegreePlanTerm(season: .spring, year: 2027)
        spring.courses = [Self.course("CS 3500", 22), Self.course("MKTG 2201", 8)]
        plan.terms = [spring]

        let audit = DegreeAudit.run(plan: plan, requirements: requirements)
        #expect(audit.completedHours == 105)
        #expect(audit.plannedHours == 30)
        #expect(audit.requiredHours == 134)
        #expect(DegreeRequirementText.creditsLine(audit) == "105 of 134 credits done · 30 planned")

        let university = try #require(audit.noteChecks.first { if case .universitywide = $0.kind { true } else { false } })
        #expect(university.status == .planned)
        #expect(university.items[0].status == .planned)
        #expect(university.items[0].detail == "105 of 128 semester hours · 30 planned")
        #expect(university.detail == "105 of 128 semester hours · 30 planned · GPA and residency not checked")

        let total = try #require(audit.noteChecks.first { if case .totalHours = $0.kind { true } else { false } })
        #expect(total.status == .planned)
        #expect(total.detail == "105 of 134 semester hours · 30 planned")

        let major = try #require(audit.noteChecks.first { if case .majorHours = $0.kind { true } else { false } })
        // CS 3000 (40) and CS 2500 (20) earned, CS 3500 (22) planned. Writing and the general
        // electives are not hours in the major. 60 + 22 is not written as 82 and then 22 again.
        #expect(major.status == .planned)
        #expect(major.detail == "60 of 72 semester hours · 22 planned")
    }
}

// MARK: - Attribute lookups

struct CourseAttributeRepositoryTests {
    /// Banner's sections, without the network.
    private final class FakeSections: AttributeFetching, @unchecked Sendable {
        private let lock = NSLock()
        private let byTerm: [String: [CourseKey: Set<String>]]
        private var _calls: [(term: String, courses: [CourseKey])] = []
        var failing: Set<String> = []

        init(_ byTerm: [String: [String: Set<String>]]) {
            self.byTerm = byTerm.mapValues { Dictionary(uniqueKeysWithValues: $0.map { (CourseKey(string: $0.key)!, $0.value) }) }
        }

        var calls: [(term: String, courses: [CourseKey])] { lock.withLock { _calls } }

        func terms() async throws -> [Term] {
            ["202710", "202655", "202650", "202630", "202610", "202560", "202550", "202540", "202530", "202510"]
                .map { Term(code: $0, bannerDescription: "") }
        }

        func sectionAttributes(term: String, courses: [CourseKey]) async throws -> [CourseKey: Set<String>] {
            let shouldFail = lock.withLock {
                _calls.append((term, courses))
                return failing.contains(term)
            }
            if shouldFail { throw BannerError.http(503) }
            return (byTerm[term] ?? [:]).filter { courses.contains($0.key) }
        }
    }

    private func key(_ code: String) -> CourseKey { CourseKey(string: code)! }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attributes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loaded() -> CatalogIndex {
        let k = key("ENGW 1111")
        let course = Course(subject: k.subject, number: k.number, title: "First-Year Writing", description: "", minCredits: 4, maxCredits: 4,
                            attributes: ["NCW1"], prereqs: nil, coreqs: nil, postreqs: [], specialTopics: false, college: nil,
                            department: nil, detailsLoaded: true)
        let section = CourseSection(crn: "10001", subject: k.subject, number: k.number, title: "First-Year Writing", sectionNumber: "01",
                                    partOfTerm: "1", seatCapacity: 20, seatsRemaining: 2, enrollment: 18, waitlistCapacity: 0,
                                    waitlistCount: 0, waitlistRemaining: 0, classType: "Lecture", honors: false, campus: "Boston",
                                    instructionMethod: "Traditional", meetings: [], instructors: [], crossListCRNs: [],
                                    attributes: ["NCW1"], description: nil, prereqs: nil, coreqs: nil)
        return CatalogIndex.build(TermCatalog(term: Term(code: "202710", bannerDescription: "Fall 2026 Semester"),
                                              courses: [course], sections: [section], subjects: [], attributes: [], campuses: []))
    }

    @Test func searchesRecentTermsUntilACourseHasSections() async {
        let banner = FakeSections([
            "202630": ["CS 3386": ["NCFQ", "NCEI"]],
            "202610": ["HIST 1130": ["NCDD", "NCSI"], "CS 3386": ["NCFQ"]],
        ])
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CourseAttributeRepository(fetcher: banner, directory: directory)
        let keys = [key("ENGW 1111"), key("CS 3386"), key("HIST 1130"), key("ZZZZ 9999")]
        let results = await repository.lookup(keys, indexes: [loaded()])
        #expect(results[key("ENGW 1111")] == .found(["NCW1"], term: "202710"))
        // The newest term with sections wins.
        #expect(results[key("CS 3386")] == .found(["NCFQ", "NCEI"], term: "202630"))
        #expect(results[key("HIST 1130")] == .found(["NCDD", "NCSI"], term: "202610"))
        #expect(results[key("ZZZZ 9999")] == .notFound)
        // The loaded term and CPS terms aren't asked; a found course isn't asked about again.
        #expect(!banner.calls.contains { $0.term == "202710" || $0.term == "202655" })
        #expect(banner.calls.first { $0.term == "202610" }?.courses == [key("HIST 1130"), key("ZZZZ 9999")])
        #expect(banner.calls.first { $0.term == "202560" }?.courses == [key("ZZZZ 9999")])

        // Everything is cached, on disk too.
        let again = CourseAttributeRepository(fetcher: banner, directory: directory)
        let calls = banner.calls.count
        #expect(await again.lookup(keys, indexes: [loaded()]) == results)
        #expect(banner.calls.count == calls)
    }

    @Test func failuresAreNotCached() async {
        let banner = FakeSections(["202610": ["HIST 1130": ["NCDD"]]])
        banner.failing = ["202650"]
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CourseAttributeRepository(fetcher: banner, directory: directory)
        #expect(await repository.lookup([key("HIST 1130")]) == [key("HIST 1130"): .failed])
        banner.failing = []
        #expect(await repository.lookup([key("HIST 1130")]) == [key("HIST 1130"): .found(["NCDD"], term: "202610")])
    }
}

private struct NUpathSeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
