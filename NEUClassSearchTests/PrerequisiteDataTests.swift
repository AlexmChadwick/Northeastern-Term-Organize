//
//  PrerequisiteDataTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

// MARK: - Helpers

private func key(_ code: String) -> CourseKey {
    guard let key = CourseKey(string: code) else { preconditionFailure("bad course code \(code)") }
    return key
}

private func requisite(_ code: String) -> Requisite { .course(key(code)) }

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PrerequisiteDataTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func terms(_ codes: [String]) -> [Term] {
    codes.map { Term(code: $0, bannerDescription: "") }
}

private func course(_ code: String, title: String = "", prereqs: Requisite? = nil, detailed: Bool = true, topics: Bool = false) -> Course {
    let k = key(code)
    return Course(subject: k.subject, number: k.number, title: title.isEmpty ? code : title, description: "",
                  minCredits: 4, maxCredits: 4, attributes: [], prereqs: prereqs, coreqs: nil, postreqs: [],
                  specialTopics: topics, college: nil, department: nil, detailsLoaded: detailed)
}

private func index(_ courses: [Course], sections: [CourseSection] = [], term: String = "202710") -> CatalogIndex {
    CatalogIndex.build(TermCatalog(
        term: Term(code: term, bannerDescription: "Fall 2026 Semester"),
        courses: courses, sections: sections, subjects: [], attributes: [], campuses: []
    ))
}

private func section(_ crn: String, _ code: String, title: String = "", crossList: [String] = []) -> CourseSection {
    let k = key(code)
    return CourseSection(crn: crn, subject: k.subject, number: k.number, title: title.isEmpty ? code : title, sectionNumber: "01",
                         partOfTerm: "1", seatCapacity: 40, seatsRemaining: 10, enrollment: 30,
                         waitlistCapacity: 0, waitlistCount: 0, waitlistRemaining: 0, classType: "Lecture",
                         honors: false, campus: "Boston", instructionMethod: "Traditional", meetings: [],
                         instructors: [], crossListCRNs: crossList, attributes: [], description: nil, prereqs: nil, coreqs: nil)
}

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(days: Double) {
        lock.withLock { current = current.addingTimeInterval(days * 86_400) }
    }
}

/// Banner, without the network: answers from dictionaries and records what it was asked.
private final class FakeBanner: CourseInfoFetching, OfferingFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    private var _terms: [Term]
    private var _catalog: [String: [CourseKey: CourseInfo]] = [:]
    private var _offered: [String: Set<CourseKey>] = [:]
    private var _failing: Set<String> = []
    private var _failingCourses: [String: CourseKey] = [:]
    private var _entryCalls: [(key: CourseKey, term: String)] = []
    private var _offeredCalls: [(term: String, courses: [CourseKey])] = []
    private var inFlight = 0
    private var _maxInFlight = 0
    var delay: UInt64 = 0

    init(clock: TestClock, terms: [Term]) {
        self.clock = clock
        _terms = terms
    }

    /// Lists a course in a term's catalog.
    func list(_ info: CourseInfo, term: String) {
        lock.withLock { _catalog[term, default: [:]][info.key] = info }
    }

    /// Says the courses had sections in a term.
    func offer(term: String, courses: [String]) {
        lock.withLock { _offered[term, default: []].formUnion(courses.map(key)) }
    }

    /// Makes a term's questions that include this course fail.
    func failQuestions(in term: String, including course: CourseKey?) {
        lock.withLock { _failingCourses[term] = course }
    }

    func setTerms(_ terms: [Term]) {
        lock.withLock { _terms = terms }
    }

    func fail(_ term: String, _ failing: Bool = true) {
        lock.withLock { if failing { _failing.insert(term) } else { _failing.remove(term) } }
    }

    var entryCalls: [(key: CourseKey, term: String)] { lock.withLock { _entryCalls } }
    var offeredCalls: [(term: String, courses: [CourseKey])] { lock.withLock { _offeredCalls } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    func resetCalls() { lock.withLock { _entryCalls = []; _offeredCalls = [] } }

    func terms() async throws -> [Term] { lock.withLock { _terms } }

    func catalogEntry(for key: CourseKey, term: String) async throws -> CourseInfo? {
        lock.withLock {
            _entryCalls.append((key, term))
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if lock.withLock({ _failing.contains(term) }) { throw BannerError.http(503) }
        guard var info = lock.withLock({ _catalog[term]?[key] }) else { return nil }
        info.fetchedAt = clock.now
        return info
    }

    func offeredCourses(term: String, courses: [CourseKey]) async throws -> Set<CourseKey> {
        lock.withLock { _offeredCalls.append((term, courses)) }
        if lock.withLock({ _failing.contains(term) }) { throw BannerError.http(503) }
        if let failing = lock.withLock({ _failingCourses[term] }), courses.contains(failing) { throw BannerError.http(503) }
        let all = lock.withLock { _offered[term] ?? [] }
        return Set(courses.filter(all.contains))
    }
}

private func courseInfo(_ code: String, term: String, prerequisites: Requisite? = nil, equivalents: [CourseKey] = []) -> CourseInfo {
    CourseInfo(key: key(code), title: "Title of \(code)", minCredits: 4, maxCredits: 4, prerequisites: prerequisites,
               equivalents: equivalents, sourceTerm: term)
}

/// Neu semester terms newest first, with a few CPS and law terms mixed in.
private let bannerTerms = terms(["202710", "202655", "202650", "202632", "202630", "202610", "202560", "202550", "202540",
                                 "202530", "202510", "202460"])

// MARK: - Banner parsers

struct CourseCatalogParserTests {
    private let subjects = BannerParsers.SubjectLookup([
        Subject(code: "CS", name: "Computer Science"),
        Subject(code: "ENGL", name: "English"),
        Subject(code: "MATH", name: "Mathematics"),
    ])

    @Test func typeaheadCodesMustMatchExactly() throws {
        let json = #"[{"code":"CS3386","description":"CS3386 Computer Science"},{"code":"CS33860","description":"CS33860 Computer Science"}]"#
        let items = try JSONDecoder().decode([BannerCodeDescription].self, from: Data(json.utf8))
        #expect(BannerParsers.catalogCodes(items, contain: key("CS 3386")))
        // The endpoint matches by prefix: CS 3386 is not CS 338 or CS 33.
        #expect(!BannerParsers.catalogCodes(items, contain: key("CS 338")))
        #expect(!BannerParsers.catalogCodes([], contain: key("CS 3386")))
    }

    @Test func readsCatalogDetailsAndCredits() {
        let html = """
        <section aria-labelledby="catalog">
        <span class="status-bold">Title:</span><span>Directed Study</span><br/>
        <span class="status-bold">College:</span>
        <span>Coll of Soc Sci &amp; Humanities  SH</span>
        <br/>
        <span class="status-bold">Department:</span>
        <span>Sociology and Anthropology  SOCL</span><br/>
        <span class="status-bold">Hours:</span><br/>
        <span class="indent-left">Credit Hours:</span><span
        class="credit-hours-direction">1 TO 4</span><br/>
        <div class="indent-left"><span class="credit-hours-direction">Lecture: 1 TO 4</span><br/></div>
        <span class="status-bold">Levels:</span><br/>
        </section>
        """
        let details = BannerParsers.catalogDetails(fromHTML: html)
        #expect(details.title == "Directed Study")
        #expect(details.department == "Sociology and Anthropology")
        #expect(details.minCredits == 1 && details.maxCredits == 4)

        let fixed = BannerParsers.catalogDetails(fromHTML: #"<span class="indent-left">Credit Hours:</span><span class="credit-hours-direction">4</span><br/>"#)
        #expect(fixed.minCredits == 4 && fixed.maxCredits == 4)
        #expect(BannerParsers.creditRange(from: "1.000 TO 4.000")?.high == 4)
        #expect(BannerParsers.creditRange(from: "0.5")?.low == 0.5)
        #expect(BannerParsers.creditRange(from: "TBA") == nil)
    }

    /// A catalog entry's prerequisites come in the same table as a section's, so one parser
    /// reads both. "No prerequisites" is an empty answer, which only means something once the
    /// course is known to be in the catalog.
    @Test func readsCoursePrerequisites() throws {
        func row(_ andOr: String = "", open: Bool = false, subject: String = "", number: String = "", close: Bool = false) -> String {
            "<tr><td>\(andOr)</td><td>\(open ? "(" : "")</td><td></td><td></td><td>\(subject)</td><td>\(number)</td><td>Undergraduate</td><td>D-</td><td>\(close ? ")" : "")</td></tr>"
        }
        // ((CS 2100 or CS 201M) or CS 2510) and (CS 2386 or CS 3540), the renumbering in the open.
        let html = "<section><table class=\"basePreqTable\"><thead><tr><th>And/Or</th></tr></thead><tbody>" + [
            row(open: true),
            row(open: true, subject: "Computer Science", number: "2100"),
            row("Or", subject: "Computer Science - MMC", number: "201M", close: true),
            row("Or", subject: "Computer Science", number: "2510", close: true),
            row("And", open: true, subject: "Computer Science", number: "2386"),
            row("Or", subject: "Computer Science", number: "3540", close: true),
        ].joined() + "</tbody></table></section>"
        let parsed = try #require(BannerParsers.prerequisites(fromHTML: html, subjects: subjects))
        // The Mills campus listing ("Computer Science - MMC") is the same subject, CS.
        #expect(parsed.referencedCourses.map { $0.description } == ["CS 2100", "CS 201M", "CS 2510", "CS 2386", "CS 3540"])
        #expect(parsed.isSatisfied(by: [key("CS 2510"), key("CS 3540")]))
        #expect(!parsed.isSatisfied(by: [key("CS 2510")]))

        let empty = "<section aria-labelledby=\"preReqs\"><h3>Catalog Prerequisites</h3> No prerequisite information available.</section>"
        #expect(BannerParsers.prerequisites(fromHTML: empty, subjects: subjects) == nil)
    }

    @Test func readsMutualExclusions() {
        let none = """
        <section aria-labelledby="mexc">
            No Mutual Exclusion information available.
        </section>
        """
        #expect(BannerParsers.mutualExclusions(fromHTML: none, subjects: subjects).isEmpty)

        // The shape of a populated list hasn't been seen (every course sampled had none), so a
        // table with a subject and a number per row is read, with or without a leading column.
        let table = """
        <section aria-labelledby="mexc"><table><thead><tr><th>Subject</th><th>Course Number</th><th>Title</th></tr></thead><tbody>
        <tr><td>Computer Science</td><td>2510</td><td>Fundamentals of Computer Science 2</td></tr>
        <tr><td>Mathematics</td><td>1341</td><td>Calculus 1</td></tr>
        </tbody></table></section>
        """
        #expect(BannerParsers.mutualExclusions(fromHTML: table, subjects: subjects) == [key("CS 2510"), key("MATH 1341")])
        let withLeadingColumn = "<section><table><tbody><tr><td>Or</td><td>Computer Science</td><td>2500</td></tr></tbody></table></section>"
        #expect(BannerParsers.mutualExclusions(fromHTML: withLeadingColumn, subjects: subjects) == [key("CS 2500")])
        // And course codes written out in running text.
        let text = "<section>Credit cannot be earned for both CS 2510 and CS 2100.</section>"
        #expect(BannerParsers.mutualExclusions(fromHTML: text, subjects: subjects) == [key("CS 2510"), key("CS 2100")])
    }

    @Test func readsCrossListedSections() {
        let html = """
        <section aria-labelledby="xlstSections">
            <span class="status-bold">Section Enrollment:</span> 4<br/>
            Sections:<br/>
        <table>
            <thead><tr><th>CRN</th><th>Subject</th><th>Course Number</th><th>Title</th><th>Section</th></tr></thead>
            <tbody>
                <tr><td>22773</td><td>English</td><td>2690</td><td>Boston in Literature</td><td>01</td></tr>
            </tbody>
        </table>
        </section>
        """
        let sections = BannerParsers.crossListedSections(fromHTML: html, subjects: subjects)
        #expect(sections == [BannerParsers.CrossListedSection(crn: "22773", course: key("ENGL 2690"), title: "Boston in Literature", section: "01")])
        #expect(BannerParsers.crossListedSections(fromHTML: "<section>No cross list sections</section>", subjects: subjects).isEmpty)
    }

    @Test func courseInfoNormalizesEquivalents() {
        let info = CourseInfo(key: key("CS 2100"), title: "PDI 1", minCredits: 4, maxCredits: 4,
                              equivalents: [key("CS 2510"), key("CS 2100"), key("CS 2510"), key("CS 2000")], sourceTerm: "202710")
        #expect(info.equivalents == [key("CS 2000"), key("CS 2510")])
        #expect(info.creditsLabel == "4 credits")
        #expect(CourseInfo(key: key("CS 4973"), title: "Topics", minCredits: 1, maxCredits: 4, sourceTerm: "202710").creditsLabel == "1–4 credits")
        #expect(CourseInfo(key: key("CS 4973"), title: "Topics", sourceTerm: "202710").creditsLabel == nil)
    }
}

// MARK: - Equivalences

struct CourseEquivalencesTests {
    private let cs2000 = CourseKey(subject: "CS", number: "2000")
    private let cs2100 = CourseKey(subject: "CS", number: "2100")
    private let cs2500 = CourseKey(subject: "CS", number: "2500")
    private let cs2510 = CourseKey(subject: "CS", number: "2510")
    private let cs3100 = CourseKey(subject: "CS", number: "3100")
    private let cs3500 = CourseKey(subject: "CS", number: "3500")
    private let engl1102 = CourseKey(subject: "ENGL", number: "1102")
    private let engw1102 = CourseKey(subject: "ENGW", number: "1102")

    @Test func groupsAreSymmetric() {
        let equivalences = CourseEquivalences(pairs: [(cs2100, cs2510), (engw1102, engl1102)])
        #expect(equivalences.equivalents(of: cs2100) == [cs2510])
        #expect(equivalences.equivalents(of: cs2510) == [cs2100])
        #expect(equivalences.areEquivalent(engl1102, engw1102))
        #expect(equivalences.areEquivalent(cs2100, cs2100))
        #expect(!equivalences.areEquivalent(cs2100, engl1102))
        // A course is not its own equivalent, and a course without any has none.
        #expect(!equivalences.equivalents(of: cs2100).contains(cs2100))
        #expect(equivalences.equivalents(of: cs3100).isEmpty)
        #expect(equivalences.group(of: cs3100) == [cs3100])
        #expect(CourseEquivalences.none.isEmpty)
    }

    /// CS 2500 = CS 2000 and CS 2000 = CS 2100 make one group, whatever order they're given in.
    @Test func chainsAreOneGroup() {
        let forward = CourseEquivalences(pairs: [(cs2500, cs2000), (cs2000, cs2100)])
        let backward = CourseEquivalences(pairs: [(cs2100, cs2000), (cs2000, cs2500)])
        #expect(forward == backward)
        #expect(forward.groups.count == 1)
        #expect(forward.equivalents(of: cs2500) == [cs2000, cs2100])
        #expect(forward.areEquivalent(cs2500, cs2100))
        #expect(forward.group(of: cs2100) == [cs2000, cs2100, cs2500])
    }

    @Test func overlappingGroupsMergeAndSingletonsAreDropped() {
        let equivalences = CourseEquivalences(groups: [[cs2500, cs2000], [cs3100, cs3500], [cs2000, cs2100], [cs2510], [], [cs2510, cs2510]])
        #expect(equivalences.groups == [[cs2000, cs2100, cs2500], [cs3100, cs3500]])
        #expect(equivalences.courses == [cs2000, cs2100, cs2500, cs3100, cs3500])
        #expect(!equivalences.courses.contains(cs2510))
    }

    @Test func expandingWhatWasTaken() {
        let equivalences = CourseEquivalences(pairs: [(cs2100, cs2510), (cs3100, cs3500)])
        let taken: Set<CourseKey> = [cs2510, engl1102]
        #expect(equivalences.expanding(taken) == [cs2510, cs2100, engl1102])
        #expect(equivalences.expanding([]).isEmpty)
        #expect(CourseEquivalences.none.expanding(taken) == taken)
    }

    @Test func satisfierIsTheTakenCourse() {
        let equivalences = CourseEquivalences(pairs: [(cs2500, cs2000), (cs2000, cs2100)])
        // The course itself, when it was taken.
        #expect(equivalences.satisfier(of: cs2100, in: [cs2100, cs2500]) == cs2100)
        // Otherwise an equivalent that was: here the old number.
        #expect(equivalences.satisfier(of: cs2100, in: [cs2500]) == cs2500)
        // The lowest-numbered one when several were.
        #expect(equivalences.satisfier(of: cs2100, in: [cs2500, cs2000]) == cs2000)
        #expect(equivalences.satisfiers(of: cs2100, in: [cs2500, cs2000]) == [cs2000, cs2500])
        #expect(equivalences.satisfier(of: cs2100, in: [cs3100]) == nil)
        #expect(equivalences.satisfier(of: cs3100, in: [cs3100]) == cs3100)
        #expect(CourseEquivalences.none.satisfier(of: cs2100, in: [cs2510]) == nil)
    }

    @Test func mergingTwoSources() {
        let banner = CourseEquivalences(pairs: [(cs2100, cs2510)])
        let student = CourseEquivalences(pairs: [(cs2510, cs2500), (cs3100, cs3500)])
        let merged = banner.merging(student)
        #expect(merged.areEquivalent(cs2100, cs2500))
        #expect(merged.areEquivalent(cs3100, cs3500))
        #expect(banner.merging(.none) == banner)
        #expect(CourseEquivalences.none.merging(student) == student)
        #expect(banner.adding(cs2000, cs2100).areEquivalent(cs2000, cs2510))
    }

    @Test func roundTripsThroughJSON() throws {
        let equivalences = CourseEquivalences(pairs: [(cs2100, cs2510), (cs3100, cs3500)])
        let decoded = try JSONDecoder().decode(CourseEquivalences.self, from: JSONEncoder().encode(equivalences))
        #expect(decoded == equivalences)
    }

    @Test func studentDeclarationsBecomeGroups() {
        let declared = [
            CourseEquivalence(course: cs2510, countsAs: cs2100, note: "Renumbered"),
            CourseEquivalence(course: cs2500, countsAs: cs2000),
            CourseEquivalence(course: cs2000, countsAs: cs2100),
        ]
        let equivalences = CourseEquivalences(declared: declared)
        #expect(equivalences.groups == [[cs2000, cs2100, cs2500, cs2510]])

        var plan = DegreePlan(name: "Plan")
        let added = plan.declareEquivalence(course: cs2510, countsAs: cs2100, note: "Renumbered")
        // Already equivalent, or the same course: nothing to add.
        let reversed = plan.declareEquivalence(course: cs2100, countsAs: cs2510)
        let same = plan.declareEquivalence(course: cs2100, countsAs: cs2100)
        #expect(added && !reversed && !same)
        #expect(plan.courseEquivalences.count == 1)
        #expect(plan.declaredEquivalences.areEquivalent(cs2100, cs2510))
        plan.removeEquivalence(id: plan.courseEquivalences[0].id)
        #expect(plan.declaredEquivalences.isEmpty)
    }

    /// Declared equivalences sync with the plan, and plans saved before they existed still load.
    @Test func plansKeepTheirEquivalences() throws {
        var plan = DegreePlan(name: "Plan")
        plan.declareEquivalence(course: cs2510, countsAs: cs2100, note: "Renumbered")
        let roundTrip = try JSONDecoder().decode(DegreePlan.self, from: JSONEncoder().encode(plan))
        #expect(roundTrip == plan)
        #expect(roundTrip.courseEquivalences.first?.note == "Renumbered")

        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json.removeValue(forKey: "courseEquivalences")
        let older = try JSONDecoder().decode(DegreePlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.courseEquivalences.isEmpty && older.name == "Plan")
        // And a broken value doesn't lose the plan.
        json["courseEquivalences"] = "not a list"
        let broken = try JSONDecoder().decode(DegreePlan.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(broken.courseEquivalences.isEmpty && broken.name == "Plan")

        // A new plan made from another keeps the student's equivalences, as new items.
        let draft = DegreePlanAutofill.newDegreePlanDraft(name: "Draft", basedOn: plan, schedulePlans: [], catalogIndex: { _ in nil })
        #expect(draft.courseEquivalences.map { $0.course } == [cs2510])
        #expect(draft.courseEquivalences.first?.id != plan.courseEquivalences.first?.id)
    }

    /// Banner cross-lists combined undergraduate and graduate sections and special topics too, so
    /// only the same course under several subjects counts: same number, same title.
    @Test func crossListedCoursesAreEquivalentOnlyWhenTheyAreTheSameCourse() {
        let courses = [
            course("AFCS 1225", title: "Gender, Race, and Medicine"), course("HIST 1225", title: "Gender, Race, and Medicine "),
            course("WMNS 1225", title: "Gender, Race, and Medicine"),
            course("ALY 6983", title: "Special Topics", topics: true), course("CS 6983", title: "Special Topics", topics: true),
            course("CS 3000", title: "Algorithms and Data"), course("CS 5800", title: "Algorithms"),
            course("ARCH 5310", title: "Design Tactics"), course("LARC 5310", title: "Urban Landscape Seminar"),
        ]
        let sections = [
            section("1", "AFCS 1225", crossList: ["2", "3"]), section("2", "HIST 1225", crossList: ["1", "3"]),
            section("3", "WMNS 1225", crossList: ["1", "2"]),
            section("4", "ALY 6983", crossList: ["5"]), section("5", "CS 6983", crossList: ["4"]),
            section("6", "CS 3000", crossList: ["7"]), section("7", "CS 5800", crossList: ["6"]),
            section("8", "ARCH 5310", crossList: ["9"]), section("9", "LARC 5310", crossList: ["8"]),
        ]
        let equivalences = CourseEquivalences(crossListedIn: index(courses, sections: sections))
        #expect(equivalences.groups == [[key("AFCS 1225"), key("HIST 1225"), key("WMNS 1225")]])
    }
}

// MARK: - Prerequisite checks

struct PrerequisiteCheckTests {
    private let cs1800 = CourseKey(subject: "CS", number: "1800")
    private let cs2100 = CourseKey(subject: "CS", number: "2100")
    private let cs2510 = CourseKey(subject: "CS", number: "2510")
    private let cs3386 = CourseKey(subject: "CS", number: "3386")
    private let cs4050 = CourseKey(subject: "CS", number: "4050")

    private var renumbered: CourseEquivalences { CourseEquivalences(pairs: [(cs2100, cs2510)]) }

    @Test func equivalentCoursesSatisfyARequisite() {
        let needed = Requisite.and([.course(cs2100), .course(cs1800)])
        #expect(DegreePlanAnalysis.status(of: needed, satisfiedBy: [cs2510, cs1800]) == .missing("CS 2100"))
        #expect(DegreePlanAnalysis.status(of: needed, satisfiedBy: [cs2510, cs1800], equivalences: renumbered) == .met)
        // Still missing what nothing covers.
        #expect(DegreePlanAnalysis.status(of: needed, satisfiedBy: [cs2510], equivalences: renumbered) == .missing("CS 1800"))
        // Chains: CS 2500 = CS 2000 = CS 2100.
        let chain = CourseEquivalences(pairs: [(CourseKey(subject: "CS", number: "2500"), CourseKey(subject: "CS", number: "2000")), (CourseKey(subject: "CS", number: "2000"), cs2100)])
        #expect(DegreePlanAnalysis.status(of: .course(cs2100), satisfiedBy: [CourseKey(subject: "CS", number: "2500")], equivalences: chain) == .met)
    }

    @Test func summariesAndCountsKnowEquivalents() {
        let needed = Requisite.and([.or([.course(cs2100), .course(key("CS 201M"))]), .course(cs1800)])
        #expect(DegreePlanAnalysis.unmetSummary(needed, satisfied: [cs2510]) == "(CS 2100 or CS 201M) and CS 1800")
        #expect(DegreePlanAnalysis.unmetSummary(needed, satisfied: [cs2510], equivalences: renumbered) == "CS 1800")
        #expect(DegreePlanAnalysis.unmetSummary(needed, satisfied: [cs2510, cs1800], equivalences: renumbered) == nil)
        #expect(DegreePlanAnalysis.missingCount(needed, satisfied: [cs2510]) == 2)
        #expect(DegreePlanAnalysis.missingCount(needed, satisfied: [cs2510], equivalences: renumbered) == 1)
    }

    @Test func saysWhichEquivalentCoveredACourse() {
        let needed = Requisite.or([.course(cs2100), .course(cs1800)])
        let covering = DegreePlanAnalysis.coveringEquivalents(of: needed, taken: [cs2510], equivalences: renumbered)
        #expect(covering == [cs2100: cs2510])
        // A course that was taken itself isn't "via" anything.
        #expect(DegreePlanAnalysis.coveringEquivalents(of: needed, taken: [cs2510, cs2100], equivalences: renumbered).isEmpty)
    }

    private func plan(completed: [String], planned: [String], declared: [CourseEquivalence] = []) -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.completed = completed.map { DegreePlanCourse(key: key($0), title: $0, credits: 4) }
        plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: planned.map { DegreePlanCourse(key: key($0), title: $0, credits: 4) })]
        plan.courseEquivalences = declared
        return plan
    }

    /// CS 3386 isn't taught in the loaded term, so the catalog doesn't list it: its prerequisites
    /// come from Banner's course catalog, through `lookup`.
    @Test func coursesTheTermDoesNotListAreCheckedThroughTheLookup() {
        let plan = plan(completed: ["CS 1800", "CS 2510"], planned: ["CS 3386", "CS 4050", "CS 2963"])
        let needs3386 = Requisite.and([.or([.course(cs2100), .course(cs2510)]), .course(key("CS 2386"))])
        let table: [CourseKey: Requisite?] = [cs3386: needs3386, cs4050: nil]
        let lookup: (CourseKey) -> Requisite?? = { table[$0] }
        let termIndex = index([course("CS 1800")])

        // Before: not in the catalog, so nothing is known.
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs3386, termIndex: 0, in: plan, catalog: termIndex) == .unknown)
        // With the lookup: CS 3386 needs CS 2386, which the plan doesn't have.
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs3386, termIndex: 0, in: plan, catalog: termIndex, lookup: lookup) == .missing("CS 2386"))
        // Known to have no prerequisites.
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs4050, termIndex: 0, in: plan, catalog: termIndex, lookup: lookup) == .met)
        // Unknown to the lookup too (never found in any catalog): still unknown.
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: key("CS 2963"), termIndex: 0, in: plan, catalog: termIndex, lookup: lookup) == .unknown)
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs3386, termIndex: 0, in: plan, catalog: nil, lookup: lookup) == .missing("CS 2386"))
    }

    @Test func theTermsOwnRequisitesWinWhenItHasDetails() {
        let plan = plan(completed: ["CS 1800"], planned: ["CS 3000"])
        let listed = index([course("CS 3000", prereqs: .course(cs1800))])
        let wrong: (CourseKey) -> Requisite?? = { _ in .some(.course(CourseKey(subject: "CS", number: "9999"))) }
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: key("CS 3000"), termIndex: 0, in: plan, catalog: listed, lookup: wrong) == .met)

        // A course synced without details has no requisites yet: use the lookup, else say unknown
        // (not "met").
        let stub = index([course("CS 3000", detailed: false)])
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: key("CS 3000"), termIndex: 0, in: plan, catalog: stub) == .unknown)
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: key("CS 3000"), termIndex: 0, in: plan, catalog: stub, lookup: wrong) == .missing("CS 9999"))
    }

    @Test func equivalencesApplyToPlannedCourses() {
        let needsRenumbered = Requisite.course(cs2100)
        let plan = plan(completed: ["CS 2510"], planned: ["CS 3386"])
        let lookup: (CourseKey) -> Requisite?? = { $0 == cs3386 ? .some(needsRenumbered) : nil }
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs3386, termIndex: 0, in: plan, catalog: nil, lookup: lookup) == .missing("CS 2100"))
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs3386, termIndex: 0, in: plan, catalog: nil, lookup: lookup, equivalences: renumbered) == .met)

        // The student's own declaration applies without being passed in.
        var declaring = plan
        declaring.declareEquivalence(course: cs2510, countsAs: cs2100)
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: cs3386, termIndex: 0, in: declaring, catalog: nil, lookup: lookup) == .met)
    }

    @Test func theLoadedCatalogsPrerequisitesStillWorkWithoutNewArguments() {
        // The old call shape keeps compiling and behaving.
        let plan = plan(completed: ["CS 2510"], planned: ["CS 3000"])
        let listed = index([course("CS 3000", prereqs: .or([.course(cs2100), .course(cs2510)]))])
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: key("CS 3000"), termIndex: 0, in: plan, catalog: listed) == .met)
    }
}

// MARK: - Degree audit with equivalences

struct EquivalentCourseAuditTests {
    private let cs3000 = CourseKey(subject: "CS", number: "3000")
    private let cs3990 = CourseKey(subject: "CS", number: "3990")
    private let cs3991 = CourseKey(subject: "CS", number: "3991")
    private let cs4530 = CourseKey(subject: "CS", number: "4530")
    private let cs4999 = CourseKey(subject: "CS", number: "4999")

    private func plan(_ completed: [String], planned: [String] = []) -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.completed = completed.map { DegreeRequirementsTests.course($0, $0 == "CS 1802" ? 1 : 4) }
        if !planned.isEmpty {
            plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: planned.map { DegreeRequirementsTests.course($0) })]
        }
        plan.catalogYear = 2023
        plan.catalogProgramPath = DegreeRequirementsTests.program.path
        plan.concentrationID = "concentration-in-human-centered-computing"
        return plan
    }

    private func result(_ audit: DegreeAudit, _ label: String) -> DegreeAudit.RuleResult? {
        audit.ruleResults.first { $0.rule.label == label }
    }

    /// CS 3000 was CS 3990 before the department renumbered it.
    @Test func aRequirementIsMetByAnEquivalentCourse() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let student = plan(["CS 1800", "CS 1802", "CS 3990"])

        let without = DegreeAudit.run(plan: student, requirements: requirements)
        #expect(result(without, "CS 3000")?.status == .missing)

        let renumbered = CourseEquivalences(pairs: [(cs3000, cs3990)])
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: renumbered)
        let rule = try #require(result(audit, "CS 3000"))
        #expect(rule.status == .complete)
        let use = try #require(rule.used.first)
        #expect(use.key == cs3990)
        #expect(use.satisfies == cs3000)
        #expect(use.viaEquivalence)
        #expect(use.countsAsLabel == "counts as CS 3000")
        #expect(use.isCompleted)
        // Rows that list the requirement's courses find the one that satisfies each.
        #expect(rule.use(for: cs3000)?.key == cs3990)
        #expect(rule.use(for: cs3990)?.key == nil)
        // Courses that count as themselves are not marked.
        let plainRule = try #require(result(audit, "CS 1800 and CS 1802"))
        #expect(plainRule.used.allSatisfy { $0.satisfies == nil && !$0.viaEquivalence && $0.countsAsLabel == nil })
        #expect(plainRule.use(for: key("CS 1800"))?.key == key("CS 1800"))
    }

    @Test func theStudentsDeclaredEquivalencesApplyOnTheirOwn() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        var student = plan(["CS 1800", "CS 1802", "CS 3990"])
        student.declareEquivalence(course: cs3990, countsAs: cs3000)
        let audit = DegreeAudit.run(plan: student, requirements: requirements)
        #expect(result(audit, "CS 3000")?.status == .complete)
        #expect(result(audit, "CS 3000")?.used.first?.satisfies == cs3000)
    }

    @Test func plannedEquivalentsCountAsPlanned() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let student = plan(["CS 1800", "CS 1802"], planned: ["CS 3990"])
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: CourseEquivalences(pairs: [(cs3000, cs3990)]))
        let rule = try #require(result(audit, "CS 3000"))
        #expect(rule.status == .planned)
        #expect(rule.used.first?.isCompleted == false)
        #expect(rule.used.first?.satisfies == cs3000)
    }

    /// Every course counts once, and a course that is itself the requirement is preferred to an
    /// equivalent that could stand in for it.
    @Test func everyCourseStillCountsOnce() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let student = plan(["CS 1800", "CS 1802", "CS 3000", "CS 3990"])
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: CourseEquivalences(pairs: [(cs3000, cs3990)]))
        let rule = try #require(result(audit, "CS 3000"))
        #expect(rule.used.map { $0.key } == [cs3000])
        #expect(rule.used.first?.satisfies == nil)
        let counted = audit.ruleResults.flatMap { $0.used.map(\.key) }
        #expect(counted.count == Set(counted).count)
        // The other one is free to count elsewhere (here toward the Khoury electives), once.
        let elsewhere = audit.ruleResults.filter { $0.rule.label != "CS 3000" }.flatMap { $0.used.map(\.key) }
            + audit.generalElectives.map(\.key) + audit.unused.map(\.key)
        #expect(elsewhere.filter { $0 == cs3990 }.count == 1)
    }

    @Test func aChainOfRenumberingsReachesTheRequirement() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let student = plan(["CS 1800", "CS 1802", "CS 3991"])
        let chain = CourseEquivalences(pairs: [(cs3000, cs3990), (cs3990, cs3991)])
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: chain)
        #expect(result(audit, "CS 3000")?.status == .complete)
        #expect(result(audit, "CS 3000")?.used.first?.key == cs3991)
    }

    @Test func alternativesAcceptEquivalents() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let student = plan(["CS 1800", "CS 1802", "CS 4999"])
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: CourseEquivalences(pairs: [(cs4530, cs4999)]))
        let rule = try #require(result(audit, "CS 4500 or CS 4530"))
        #expect(rule.status == .complete)
        #expect(rule.used.first?.satisfies == cs4530)
    }

    /// "CS 2500 or higher": a course that is equivalent to a course in the range counts, even
    /// though its own number is lower.
    @Test func rangesAcceptEquivalentsOfCoursesInThem() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        let student = plan(["CS 1800", "CS 1802", "CS 2100", "CS 4973"])
        func electives(_ audit: DegreeAudit) -> DegreeAudit.RuleResult? {
            audit.ruleResults.first { $0.rule.label.hasPrefix("Complete 8 semester hours of CS") }
        }

        let without = DegreeAudit.run(plan: student, requirements: requirements)
        #expect(electives(without)?.status == .partial)
        #expect(electives(without)?.used.map { $0.key } == [CourseKey(subject: "CS", number: "4973")])

        let renumbered = CourseEquivalences(pairs: [(CourseKey(subject: "CS", number: "2100"), CourseKey(subject: "CS", number: "2510"))])
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: renumbered)
        let rule = try #require(electives(audit))
        #expect(rule.status == .complete)
        let use = try #require(rule.used.first { $0.key.description == "CS 2100" })
        #expect(use.satisfies?.description == "CS 2510")
    }

    @Test func substitutionsAcceptEquivalentsToo() throws {
        let requirements = try DegreeRequirementsTests.requirements()
        var student = plan(["CS 1800", "CS 1802", "CS 3990"])
        let rule = try #require(requirements.allRules.first { $0.label == "CS 4500 or CS 4530" })
        student.substitutions = [RequirementSubstitution(ruleID: rule.id, ruleTitle: "Software development", change: .countCourse(cs3000))]
        let audit = DegreeAudit.run(plan: student, requirements: requirements, equivalences: CourseEquivalences(pairs: [(cs3000, cs3990)]))
        let result = try #require(audit.result(for: rule.id))
        #expect(result.used.first?.key == cs3990)
        #expect(result.used.first?.bySubstitution == true)
        #expect(audit.unmatchedSubstitutions.isEmpty)
    }
}

// MARK: - Finding course information

struct CourseInfoRepositoryTests {
    private let clock = TestClock()

    private func repository(_ banner: FakeBanner, directory: URL, maxTermsBack: Int = 8, concurrency: Int = 2) -> CourseInfoRepository {
        let clock = self.clock
        return CourseInfoRepository(fetcher: banner, directory: directory, now: { clock.now }, maxTermsBack: maxTermsBack, concurrency: concurrency)
    }

    @Test func searchesTheNewestTermThenEarlierFallsAndSprings() {
        let codes = CourseInfoRepository.catalogTerms(from: bannerTerms, maxBack: 3)
        // Summers, CPS (…55) and law (…32) terms are skipped; the newest term always is searched.
        #expect(codes == ["202710", "202630", "202610", "202530"])
        #expect(CourseInfoRepository.catalogTerms(from: bannerTerms, maxBack: 0) == ["202710"])
        #expect(CourseInfoRepository.catalogTerms(from: terms(["202650", "202630", "202610"]), maxBack: 8) == ["202650", "202630", "202610"])
        #expect(CourseInfoRepository.catalogTerms(from: terms(["202655", "202632"]), maxBack: 8).isEmpty)
    }

    /// The order is: the loaded catalogs, the cache, Banner.
    @Test func looksInTheLoadedCatalogsFirst() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 3000", term: "202710"), term: "202710")
        banner.list(courseInfo("CS 4050", term: "202630"), term: "202630")
        let repository = repository(banner, directory: directory)
        let loaded = index([course("CS 3000", prereqs: requisite("CS 1800")), course("CS 4050", detailed: false)])

        let results = await repository.lookup([key("CS 3000"), key("CS 4050")], indexes: [loaded])
        guard case .found(let fromIndex)? = results[key("CS 3000")] else { Issue.record("CS 3000 not found"); return }
        #expect(fromIndex.prerequisites == requisite("CS 1800"))
        #expect(fromIndex.sourceTerm == "202710")
        // The newest loaded term lists it, so it is current.
        #expect(fromIndex.isRetired == false)
        // CS 3000 needed no request. CS 4050 is in the loaded catalog only as a stub, which has no
        // requisites to offer, so Banner is asked, walking back to the term that lists it.
        #expect(banner.entryCalls.map { $0.key } == [key("CS 4050"), key("CS 4050")])
        #expect(banner.entryCalls.map { $0.term } == ["202710", "202630"])
        guard case .found(let fromBanner)? = results[key("CS 4050")] else { Issue.record("CS 4050 not found"); return }
        #expect(fromBanner.sourceTerm == "202630")
        // Only the older catalog lists it: it has been retired.
        #expect(fromBanner.isRetired == true)
    }

    @Test func walksBackThroughPreviousYearsAndRemembersTheTerm() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        // CS 2510 was retired by the renumbering: only the Spring 2025 catalog and earlier list it.
        banner.list(courseInfo("CS 2510", term: "202530", equivalents: [key("CS 2100")]), term: "202530")
        let repository = repository(banner, directory: directory)

        let result = await repository.lookup(key("CS 2510"))
        guard case .found(let info) = result else { Issue.record("not found: \(result)"); return }
        #expect(info.sourceTerm == "202530")
        #expect(info.isRetired == true)
        #expect(info.equivalents == [key("CS 2100")])
        #expect(banner.entryCalls.map { $0.term } == ["202710", "202630", "202610", "202530"])
    }

    @Test func foundCoursesAreCachedOnDiskForALongTime() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 3386", term: "202710", prerequisites: requisite("CS 2386")), term: "202710")
        let first = repository(banner, directory: directory)
        _ = await first.lookup(key("CS 3386"))
        #expect(banner.entryCalls.count == 1)

        // A new instance (the app relaunched) reads the file: no request, a month later too.
        clock.advance(days: 30)
        let second = repository(FakeBanner(clock: clock, terms: bannerTerms), directory: directory)
        guard case .found(let cached)? = await second.cachedLookup(key("CS 3386")) else { Issue.record("not cached"); return }
        #expect(cached.prerequisites == requisite("CS 2386"))
        #expect(cached.isRetired == false)
        let again = await second.lookup(key("CS 3386"))
        #expect(again == .found(cached))
        #expect(banner.entryCalls.count == 1)

        // After the cache's lifetime it is read again, and an expired entry survives a failure.
        clock.advance(days: 200)
        let failing = FakeBanner(clock: clock, terms: bannerTerms)
        failing.fail("202710")
        let third = repository(failing, directory: directory)
        #expect(await third.cachedLookup(key("CS 3386")) == nil)
        guard case .found(let stale) = await third.lookup(key("CS 3386")) else { Issue.record("stale entry not used"); return }
        #expect(stale.prerequisites == requisite("CS 2386"))
        banner.list(courseInfo("CS 3386", term: "202710", prerequisites: requisite("CS 2000")), term: "202710")
        guard case .found(let fresh) = await repository(banner, directory: directory).lookup(key("CS 3386")) else { Issue.record("not refreshed"); return }
        #expect(fresh.prerequisites == requisite("CS 2000"))
    }

    @Test func missingCoursesAreRememberedForAWeek() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        let repository = repository(banner, directory: directory, maxTermsBack: 3)

        #expect(await repository.lookup(key("CS 2963")) == .notFound)
        // The newest term and three earlier ones were searched, no more.
        #expect(banner.entryCalls.map { $0.term } == ["202710", "202630", "202610", "202530"])
        banner.resetCalls()

        clock.advance(days: 6)
        #expect(await repository.lookup(key("CS 2963")) == .notFound)
        #expect(banner.entryCalls.isEmpty)
        // It survives a relaunch too.
        #expect(await self.repository(banner, directory: directory).cachedLookup(key("CS 2963")) == .notFound)

        clock.advance(days: 2)
        #expect(await repository.cachedLookup(key("CS 2963")) == nil)
        #expect(await repository.lookup(key("CS 2963")) == .notFound)
        #expect(banner.entryCalls.count == 4)

        // If it has appeared in a catalog by then, it is found.
        clock.advance(days: 8)
        banner.list(courseInfo("CS 2963", term: "202710"), term: "202710")
        guard case .found = await repository.lookup(key("CS 2963")) else { Issue.record("not found after it appeared"); return }
    }

    @Test func failuresAreNotCached() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 4050", term: "202630"), term: "202630")
        banner.fail("202630")
        let repository = repository(banner, directory: directory)

        // The older term can't be reached, so "not found" would be a guess.
        #expect(await repository.lookup(key("CS 4050")) == .failed)
        #expect(await repository.cachedLookup(key("CS 4050")) == nil)

        banner.fail("202630", false)
        guard case .found(let info) = await repository.lookup(key("CS 4050")) else { Issue.record("not found after the network came back"); return }
        #expect(info.sourceTerm == "202630")
    }

    @Test func termListFailureIsAFailureToo() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = repository(FakeBanner(clock: clock, terms: []), directory: directory)
        #expect(await repository.lookup(key("CS 3386")) == .failed)
    }

    @Test func fewCoursesAreLookedUpAtATime() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.delay = 20_000_000
        let codes = (1...6).map { "CS 30\(10 + $0)" }
        for code in codes { banner.list(courseInfo(code, term: "202710"), term: "202710") }
        let repository = repository(banner, directory: directory, concurrency: 2)

        let results = await repository.lookup(codes.map(key))
        #expect(results.count == 6)
        #expect(results.values.allSatisfy { if case .found = $0 { true } else { false } })
        #expect(banner.maxInFlight == 2)
        // The same course asked for twice is one request.
        banner.resetCalls()
        _ = await repository.lookup([key("CS 9001"), key("CS 9001")])
        #expect(banner.entryCalls.filter { $0.term == "202710" }.count == 1)
    }
}

// MARK: - The store

@MainActor
struct CourseInfoStoreTests {
    private let clock = TestClock()

    private func store(_ banner: FakeBanner, directory: URL) -> CourseInfoStore {
        let clock = self.clock
        return CourseInfoStore(
            repository: CourseInfoRepository(fetcher: banner, directory: directory, now: { clock.now }),
            offeringRepository: OfferingHistoryRepository(fetcher: banner, directory: directory, now: { clock.now })
        )
    }

    @Test func loadsInfoForCoursesTheTermDoesNotList() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 3386", term: "202710", prerequisites: requisite("CS 2386")), term: "202710")
        banner.list(courseInfo("CS 4050", term: "202630"), term: "202630")
        let store = store(banner, directory: directory)
        let loaded = index([course("CS 3000", prereqs: requisite("CS 1800"))])

        #expect(store.state(for: key("CS 3386")) == .unknown)
        #expect(store.info(for: key("CS 3386")) == nil)
        await store.load([key("CS 3386"), key("CS 4050"), key("CS 2963"), key("CS 3000")], indexes: [loaded])

        #expect(store.info(for: key("CS 3386"))?.prerequisites == requisite("CS 2386"))
        #expect(store.info(for: key("CS 4050"))?.sourceTerm == "202630")
        #expect(store.info(for: key("CS 3000"))?.prerequisites == requisite("CS 1800"))
        #expect(store.state(for: key("CS 2963")) == .notFound)
        #expect(store.info(for: key("CS 2963")) == nil)

        // The lookup tells "unknown" (nil), "known, no prerequisites" (.some(nil)) and the requisite apart.
        let lookup = store.requisiteLookup()
        #expect(lookup(key("CS 3386")) == .some(requisite("CS 2386")))
        #expect(lookup(key("CS 4050")) == .some(nil))
        #expect(lookup(key("CS 2963")) == nil)
        #expect(lookup(key("MATH 1")) == nil)

        // …which is what the degree plan analysis takes.
        var plan = DegreePlan(name: "Plan")
        plan.completed = [DegreePlanCourse(key: key("CS 2386"), title: "", credits: 4)]
        plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: [DegreePlanCourse(key: key("CS 3386"), title: "", credits: 4)])]
        #expect(DegreePlanAnalysis.prerequisiteStatus(of: key("CS 3386"), termIndex: 0, in: plan, catalog: loaded, lookup: lookup) == .met)
    }

    @Test func loadingAgainChangesNothing() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 3386", term: "202710"), term: "202710")
        let store = store(banner, directory: directory)
        let keys = [key("CS 3386"), key("CS 2963")]

        await store.load(keys, indexes: [])
        let version = store.version
        #expect(version > 0)
        let calls = banner.entryCalls.count
        // A view that loads whenever the version changes must settle: nothing is asked twice.
        await store.load(keys, indexes: [])
        #expect(store.version == version)
        #expect(banner.entryCalls.count == calls)
    }

    @Test func failedLoadsCanBeRetried() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 3386", term: "202710"), term: "202710")
        banner.fail("202710")
        let store = store(banner, directory: directory)

        await store.load([key("CS 3386")], indexes: [])
        #expect(store.state(for: key("CS 3386")) == .failed)
        // Right away nothing is retried; after a minute it is.
        banner.fail("202710", false)
        await store.load([key("CS 3386")], indexes: [])
        #expect(store.state(for: key("CS 3386")) == .failed)
        // (The store waits 60 seconds in real time; a store with fresh state shows the retry works.)
        let again = self.store(banner, directory: directory)
        await again.load([key("CS 3386")], indexes: [])
        if case .found = again.state(for: key("CS 3386")) {} else { Issue.record("not found after the network came back") }
    }

    @Test func equivalencesMergeBannerDeclaredAndCrossListed() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        // Banner: CS 2100 can't be taken for credit with CS 2510.
        banner.list(courseInfo("CS 2100", term: "202710", equivalents: [key("CS 2510")]), term: "202710")
        let store = store(banner, directory: directory)
        // The loaded term has HIST 1225 and WMNS 1225 as one cross-listed course.
        let loaded = index(
            [course("HIST 1225", title: "Gender, Race, and Medicine"), course("WMNS 1225", title: "Gender, Race, and Medicine")],
            sections: [section("1", "HIST 1225", crossList: ["2"]), section("2", "WMNS 1225", crossList: ["1"])]
        )
        await store.load([key("CS 2100")], indexes: [loaded])

        let fromBanner = store.equivalences(for: nil)
        #expect(fromBanner.areEquivalent(key("CS 2100"), key("CS 2510")))
        #expect(fromBanner.areEquivalent(key("HIST 1225"), key("WMNS 1225")))
        #expect(!fromBanner.areEquivalent(key("CS 3100"), key("CS 3500")))

        var plan = DegreePlan(name: "Plan")
        plan.declareEquivalence(course: key("CS 3500"), countsAs: key("CS 3100"))
        plan.declareEquivalence(course: key("CS 2500"), countsAs: key("CS 2510"))
        let merged = store.equivalences(for: plan)
        #expect(merged.areEquivalent(key("CS 3100"), key("CS 3500")))
        // The student's CS 2500 = CS 2510 joins Banner's CS 2510 = CS 2100.
        #expect(merged.areEquivalent(key("CS 2500"), key("CS 2100")))
        #expect(merged.areEquivalent(key("HIST 1225"), key("WMNS 1225")))
    }
}

// MARK: - The reported cases, end to end

/// A degree plan with courses the loaded term doesn't offer (CS 3386, CS 4050, CS 2963), checked
/// against the bundled Fall 2026 catalog and a pretend Banner.
@MainActor
struct ReportedCasesTests {
    private let clock = TestClock()

    @Test func coursesTheTermDoesNotOfferAreCheckedFromPreviousYears() async throws {
        let loaded = try #require(SearchEngineTests.index)  // bundled Fall 2026 catalog
        let cs3386 = key("CS 3386"), cs4050 = key("CS 4050"), cs2963 = key("CS 2963")
        // None of them has sections in Fall 2026, so the plan could not check them before.
        #expect(loaded.course(cs3386) == nil && loaded.course(cs4050) == nil && loaded.course(cs2963) == nil)

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        // Banner's catalog lists CS 3386 in Fall 2026 and CS 4050 only in Spring 2026; CS 2963 in no term.
        let needs3386 = Requisite.and([.or([requisite("CS 2100"), requisite("CS 201M"), requisite("CS 2510")]), .or([requisite("CS 2386"), requisite("CS 3540")])])
        banner.list(courseInfo("CS 3386", term: "202710", prerequisites: needs3386), term: "202710")
        banner.list(courseInfo("CS 4050", term: "202630"), term: "202630")
        let clock = self.clock
        let store = CourseInfoStore(
            repository: CourseInfoRepository(fetcher: banner, directory: directory, now: { clock.now }),
            offeringRepository: OfferingHistoryRepository(fetcher: banner, directory: directory, now: { clock.now })
        )

        var plan = DegreePlan(name: "Plan")
        plan.completed = ["CS 1800", "CS 2000", "CS 2386"].map { DegreePlanCourse(key: key($0), title: $0, credits: 4) }
        plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: ["CS 3386", "CS 4050", "CS 2963"].map { DegreePlanCourse(key: key($0), title: $0, credits: 4) })]
        let planned = [cs3386, cs4050, cs2963]
        await store.load(planned, indexes: [loaded])

        func status(of course: CourseKey, in plan: DegreePlan) -> DegreePlanAnalysis.PrerequisiteStatus {
            DegreePlanAnalysis.prerequisiteStatus(of: course, termIndex: 0, in: plan, catalog: loaded,
                                                  lookup: store.requisiteLookup(), equivalences: store.equivalences(for: plan))
        }
        // CS 3386 needs CS 2100 (or CS 201M or CS 2510): CS 2000 isn't one of them.
        #expect(status(of: cs3386, in: plan) == .missing("CS 2100 or CS 201M or CS 2510"))
        // CS 4050 is only in last spring's catalog and has no prerequisites.
        #expect(status(of: cs4050, in: plan) == .met)
        #expect(store.info(for: cs4050)?.isRetired == true)
        // CS 2963 isn't in any catalog Banner has: it stays unchecked, and the store says why.
        #expect(status(of: cs2963, in: plan) == .unknown)
        #expect(store.state(for: cs2963) == .notFound)

        // The student says CS 2000 counts as CS 2100: the prerequisite is covered, whatever the department.
        plan.declareEquivalence(course: key("CS 2000"), countsAs: key("CS 2100"), note: "Curriculum change")
        #expect(status(of: cs3386, in: plan) == .met)
        #expect(store.equivalences(for: plan).satisfier(of: key("CS 2100"), in: plan.completedKeys) == key("CS 2000"))
    }
}

// MARK: - Suggesting what a retired course became

struct CourseTitleMatcherTests {
    private typealias Title = CourseTitleMatcher.Title

    private func similarity(_ a: String, _ b: String) -> Double? {
        CourseTitleMatcher.similarity(of: a, to: b)
    }

    @Test func titlesAreReducedToTheirTellingWords() {
        #expect(Title("Principles of Human-Computer Interaction").words == ["human", "computer", "interaction"])
        // Banner's abbreviations of the filler words, case and ampersands.
        #expect(Title("PRNCPLES of Human Computer Interaction").words == ["human", "computer", "interaction"])
        #expect(Title("Intr to Data Structures & Algorithms").words == ["data", "structure", "algorithm"])
        #expect(Title("Introduction to Women’s Studies").words == ["women", "study"])
        #expect(Title("Fundamentals of Software Engineering").words == ["software", "engineering"])
        // Part numbers are kept apart from the words.
        #expect(Title("Fundamentals of Computer Science 2").parts == ["2"])
        #expect(Title("Computer Science II").parts == ["2"] && Title("Computer Science II").words == ["computer", "science"])
        #expect(Title("Topics").words.isEmpty)
    }

    /// The reported case: the catalog's IS 4300 became CS 2484, and no prerequisite lists the two.
    @Test func aRenumberedCourseKeepsItsTitleAlike() {
        #expect(similarity("Human Computer Interaction", "Principles of Human-Computer Interaction") == 1)
        #expect(similarity("Principles of Human-Computer Interaction", "Human Computer Interaction") == 1)
        #expect(similarity("Prncples of Human-Computer Interaction", "Human Computer Interaction") == 1)
        #expect(similarity("First-Year Writing", "First Year Writing") == 1)
    }

    @Test func titlesThatOnlyShareAWordAreNotAlike() {
        #expect(similarity("Human Computer Interaction", "Computer Systems") == nil)
        #expect(similarity("Human Computer Interaction", "Human Factors in Computing") == nil)
        #expect(similarity("Data Science", "Data Structures") == nil)
        #expect(similarity("Cell Biology", "Cell Culture Techniques") == nil)
        #expect(similarity("Computer Systems", "Computer Networks") == nil)
    }

    @Test func similarityIsTheShareOfWordsOrContainment() throws {
        // 3 of 4 words are shared.
        let studio = try #require(similarity("Object-Oriented Design", "Object-Oriented Design Studio"))
        #expect(abs(studio - 0.75) < 0.0001)
        // 2 of 3 words: over the 0.6 bar.
        let theory = try #require(similarity("Machine Learning", "Machine Learning Theory"))
        #expect(abs(theory - 2.0 / 3.0) < 0.0001)
        // 2 of 4 words, and neither title's words all appear in the other: under the bar.
        #expect(similarity("Machine Learning Theory", "Machine Learning Practice") == nil)
        // All the words of one title appear in the other: alike, at the lowest score.
        #expect(similarity("Cell Biology", "Cell Biology of Cancer Metastasis") == 0.6)
        // The bar can be changed.
        #expect(CourseTitleMatcher.similarity(of: "Cell Biology", to: "Cell Biology of Cancer Metastasis", minimum: 0.8) == 0.8)
        #expect(CourseTitleMatcher.similarity(of: "Machine Learning Theory", to: "Machine Learning Practice", minimum: 0.4) == 0.5)
    }

    /// Courses of a sequence differ only by their number, so they are never alike.
    @Test func courseSequencesAreNotAlike() {
        #expect(similarity("Fundamentals of Computer Science 1", "Fundamentals of Computer Science 2") == nil)
        #expect(similarity("Calculus 1 for Science and Engineering", "Calculus 2 for Science and Engineering") == nil)
        #expect(similarity("General Chemistry I", "General Chemistry II") == nil)
        #expect(similarity("Physics for Engineering 1", "Physics for Engineering 3") == nil)
        // The same number, or a number on one side only, still matches.
        #expect(similarity("Fundamentals of Computer Science 2", "Computer Science 2") == 1)
        #expect(similarity("Computer Science I", "Computer Science") == 1)
        // A roman numeral is the same number: "I" is "1", "II" is "2".
        #expect(similarity("Computer Science 1", "Computer Science I") == 1)
        #expect(similarity("Computer Science 2", "Computer Science I") == nil)
    }

    /// A lab or an advanced version is a course of its own, however much of the title it shares.
    @Test func aCourseAndItsLabOrAdvancedVersionAreNotAlike() {
        #expect(similarity("Sensation and Perception", "Laboratory in Sensation and Perception") == nil)
        #expect(similarity("General Chemistry 1", "General Chemistry 1 Lab") == nil)
        #expect(similarity("Fundamentals of Computer Science 2", "Lab for Fundamentals of Computer Science 2") == nil)
        #expect(similarity("Machine Learning", "Advanced Machine Learning") == nil)
        // Both have it, or neither does: still compared.
        #expect(similarity("Advanced Machine Learning", "Advanced Machine Learning Methods") != nil)
        #expect(similarity("General Chemistry Lab", "General Chemistry Laboratory") == 1)
        #expect(Title("Lab for Computer Systems").qualifiers == ["lab"])
    }

    /// Titles of one word, or of kinds of course, are too generic to say two courses are one.
    @Test func shortAndGenericTitlesAreNeverAlike() {
        #expect(similarity("Seminar", "Seminar") == nil)
        #expect(similarity("Algorithms", "Algorithms and Data") == nil)
        #expect(similarity("Calculus", "Calculus for Engineers") == nil)
        #expect(similarity("Special Topics", "Special Topics") == nil)
        #expect(similarity("Directed Study", "Directed Study") == nil)
        #expect(similarity("Research Seminar", "Research Seminar") == nil)
        #expect(similarity("Co-op Work Experience", "Co-op Work Experience") == nil)
        #expect(similarity("Topics", "Topics in Computer Science") == nil)
        #expect(similarity("Introduction to", "Introduction to Computer Science") == nil)
        #expect(similarity("", "Human Computer Interaction") == nil)
        #expect(similarity("", "") == nil)
        #expect(!Title("Seminar").isDistinctive && !Title("Directed Study").isDistinctive && Title("Machine Learning").isDistinctive)
        // Two telling words are enough.
        #expect(similarity("Machine Learning", "Machine Learning") == 1)
        #expect(similarity("Seminar in Human Computer Interaction", "Human Computer Interaction") == 0.75)
    }

    /// The degree audit cuts titles at 30 characters, so the last word may be a fragment.
    @Test func cutOffAuditTitlesStillMatch() {
        #expect(similarity("Fundamentals of Software Engin", "Fundamentals of Software Engineering") == 1)
        #expect(similarity("Fundamentals of Software Engineering", "Fundamentals of Software Engin") == 1)
        // "Principles of Human-Computer I" lost "nteraction"; the stray "I" is not a word.
        let cut = similarity("Principles of Human-Computer I", "Human Computer Interaction")
        #expect(cut != nil && (cut ?? 0) > 0.66)
        // A fragment doesn't make unlike titles alike.
        #expect(similarity("Fundamentals of Software Engin", "Fundamentals of Software Testing") == nil)
        #expect(Title("Fundamentals of Software Engin").cutOffWord == "engin")
        #expect(Title("Software Engineering").cutOffWord == nil)
    }
}

struct EquivalenceSuggesterTests {
    private func prerequisites(_ items: [(String, Requisite)]) -> [(course: CourseKey, requisite: Requisite)] {
        items.map { (course: key($0.0), requisite: $0.1) }
    }

    private func either(_ codes: String...) -> Requisite { .or(codes.map(requisite)) }

    /// CS 2510 was retired for CS 2100: the courses that needed it now list both.
    private var catalog: [(course: CourseKey, requisite: Requisite)] {
        prerequisites([
            ("CS 3000", .and([either("CS 2100", "CS 2510", "DS 2500"), either("CS 1800", "MATH 1365")])),
            ("CS 3200", either("CS 2100", "CS 2510")),
            ("CS 3386", .and([.or([.or([requisite("CS 2100"), requisite("CS 201M")]), requisite("CS 2510")]), either("CS 2386", "CS 3540")])),
            // Still names only the old number.
            ("CS 4100", requisite("CS 2510")),
            ("CS 4200", .and([requisite("CS 2510"), requisite("MATH 1365")])),
            // Unrelated alternatives.
            ("ANTH 2000", either("ANTH 1101", "POLS 1160")),
        ])
    }

    private let current: Set<CourseKey> = [key("CS 2100"), key("DS 2500"), key("CS 3000"), key("ANTH 1101")]

    @Test func suggestsTheCurrentCoursesListedBesideTheRetiredOne() throws {
        let found = EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: catalog, isCurrent: { current.contains($0) })
        // CS 2100 is beside CS 2510 in 3 of the 5 prerequisites that name it. DS 2500 is in one
        // (not enough), and CS 201M is no longer in the catalog.
        #expect(found.map { $0.candidate } == [key("CS 2100")])
        let suggestion = try #require(found.first)
        #expect(suggestion.course == key("CS 2510"))
        #expect(suggestion.together == 3 && suggestion.total == 5)
        #expect(suggestion.confidence == 0.6)
        #expect(suggestion.evidence == "Listed together in 3 of the 5 prerequisites that name CS 2510")
        #expect(suggestion.id == "CS 2510|CS 2100")
    }

    @Test func thresholdsAndLimitsApply() {
        let wide = EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: catalog, isCurrent: { current.contains($0) },
                                                    minimumTogether: 1, minimumShare: 0.2)
        // Most often listed first, then by course.
        #expect(wide.map { $0.candidate } == [key("CS 2100"), key("DS 2500")])
        #expect(EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: catalog, isCurrent: { current.contains($0) },
                                                 minimumTogether: 1, minimumShare: 0.2, limit: 1).map { $0.candidate } == [key("CS 2100")])
        // A share too high for the evidence.
        #expect(EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: catalog, isCurrent: { current.contains($0) },
                                                 minimumShare: 0.8).isEmpty)
    }

    @Test func leavesOutWhatIsKnownOrNotCurrent() {
        let known = CourseEquivalences(pairs: [(key("CS 2510"), key("CS 2100"))])
        #expect(EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: catalog, isCurrent: { current.contains($0) }, excluding: known).isEmpty)
        #expect(EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: catalog, isCurrent: { _ in false }).isEmpty)
        // A course nothing needs has no evidence; neither does one that isn't alongside anything.
        #expect(EquivalenceSuggester.suggestions(for: key("CS 9999"), prerequisites: catalog, isCurrent: { _ in true }).isEmpty)
        #expect(EquivalenceSuggester.suggestions(for: key("CS 4100"), prerequisites: catalog, isCurrent: { _ in true }).isEmpty)
        // A course isn't its own replacement, and its own prerequisites don't count.
        let own = prerequisites([("CS 2510", either("CS 2510", "CS 2100"))])
        #expect(EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: own, isCurrent: { _ in true }).isEmpty)
    }

    @Test func aSingleDependentReadsNaturally() {
        let one = prerequisites([("CS 3000", either("CS 2100", "CS 2510")), ("CS 3001", either("CS 2100", "CS 2510"))])
        let found = EquivalenceSuggester.suggestions(for: key("CS 2510"), prerequisites: one, isCurrent: { _ in true })
        #expect(found.first?.evidence == "Listed together in 2 of the 2 prerequisites that name CS 2510")
        let lone = EquivalenceSuggestion(course: key("CS 2510"), candidate: key("CS 2100"), together: 1, total: 1)
        #expect(lone.evidence == "Listed together in the prerequisites of the 1 course that names CS 2510")
    }

    // MARK: Titles

    private let titles: [CourseKey: String] = [
        key("IS 4300"): "Human Computer Interaction",
        key("CS 2484"): "Principles of Human-Computer Interaction",
        key("CS 3000"): "Algorithms and Data",
        key("CS 3650"): "Computer Systems",
        key("CS 2510"): "Fundamentals of Computer Science 2",
        key("CS 2515"): "Computer Science 2 Honors",
        key("CS 2100"): "Program Design and Implementation 1",
        key("CS 4550"): "Web Development",
    ]

    private func byTitle(_ retired: String, among candidates: [String], titles: [CourseKey: String]? = nil,
                         prerequisites: [(course: CourseKey, requisite: Requisite)] = [],
                         isCurrent: @escaping (CourseKey) -> Bool = { _ in true },
                         excluding known: CourseEquivalences = .none, limit: Int = 3) -> [EquivalenceSuggestion] {
        let table = titles ?? self.titles
        return EquivalenceSuggester.suggestions(for: key(retired), prerequisites: prerequisites, isCurrent: isCurrent, excluding: known,
                                                limit: limit, title: { table[$0] }, titleCandidates: candidates.map(key))
    }

    /// The reported case: the degree requires IS 4300, retired; the student took CS 2484. No
    /// prerequisite names IS 4300 next to CS 2484, so only the titles can say.
    @Test func suggestsAStudentCourseWithASimilarTitle() throws {
        let found = byTitle("IS 4300", among: ["CS 3000", "CS 2484", "CS 3650", "CS 2510"])
        #expect(found.map { $0.candidate } == [key("CS 2484")])
        let suggestion = try #require(found.first)
        #expect(suggestion.course == key("IS 4300"))
        #expect(suggestion.together == 0 && suggestion.total == 0 && !suggestion.isListedTogether && suggestion.confidence == 0)
        #expect(suggestion.similarTitle == "Principles of Human-Computer Interaction" && suggestion.titleScore == 1)
        #expect(suggestion.evidence == "Similar title: Principles of Human-Computer Interaction")
        #expect(suggestion.id == "IS 4300|CS 2484")
    }

    @Test func aTrueNegativeIsNotSuggested() {
        // "Human Computer Interaction" and "Computer Systems" share only a word.
        #expect(byTitle("IS 4300", among: ["CS 3650", "CS 3000", "CS 4550"]).isEmpty)
    }

    @Test func genericTitlesGiveNoTitleEvidence() {
        func suggestions(retiredTitle: String, candidateTitle: String) -> [EquivalenceSuggestion] {
            byTitle("IS 4300", among: ["CS 3000"], titles: [key("IS 4300"): retiredTitle, key("CS 3000"): candidateTitle])
        }
        // A one-word title, a kind of course, nothing left after the filler, or no title at all.
        for generic in ["Seminar", "Special Topics", "Directed Study", "Topics", "Introduction to", ""] {
            #expect(suggestions(retiredTitle: generic, candidateTitle: generic).isEmpty)
            #expect(suggestions(retiredTitle: generic, candidateTitle: "Human Computer Interaction").isEmpty)
            #expect(suggestions(retiredTitle: "Human Computer Interaction", candidateTitle: generic).isEmpty)
        }
        #expect(byTitle("IS 4300", among: ["CS 3000"], titles: [key("CS 3000"): "Human Computer Interaction"]).isEmpty)
        #expect(byTitle("IS 4300", among: ["CS 3000"], titles: [key("IS 4300"): "Human Computer Interaction"]).isEmpty)
        // Sequences are different courses.
        #expect(byTitle("CS 2510", among: ["CS 2501"], titles: [key("CS 2510"): "Fundamentals of Computer Science 2",
                                                                key("CS 2501"): "Fundamentals of Computer Science 1"]).isEmpty)
    }

    @Test func leavesOutTheRetiredCourseAndWhatIsKnown() {
        #expect(byTitle("IS 4300", among: ["IS 4300"]).isEmpty)
        let known = CourseEquivalences(pairs: [(key("IS 4300"), key("CS 2484"))])
        #expect(byTitle("IS 4300", among: ["CS 2484"], excluding: known).isEmpty)
        // Equivalent through a chain too.
        let chain = CourseEquivalences(pairs: [(key("IS 4300"), key("CS 9000")), (key("CS 9000"), key("CS 2484"))])
        #expect(byTitle("IS 4300", among: ["CS 2484"], excluding: chain).isEmpty)
    }

    /// The student's courses need not be current: they are the student's.
    @Test func titleCandidatesNeedNotBeCurrent() {
        #expect(byTitle("IS 4300", among: ["CS 2484"], isCurrent: { _ in false }).map { $0.candidate } == [key("CS 2484")])
    }

    @Test func titleSuggestionsAreRankedByHowAlikeTheTitlesAre() {
        var table = titles
        table[key("CS 5100")] = "Human Computer Interaction Methods and Practice"   // 3 of 6 words: contained, 0.6
        table[key("CS 5200")] = "Human-Computer Interaction Studio"                // 3 of 4 words
        let found = byTitle("IS 4300", among: ["CS 5100", "CS 2484", "CS 5200"], titles: table)
        #expect(found.map { $0.candidate } == [key("CS 2484"), key("CS 5200"), key("CS 5100")])
        #expect(found.map { $0.titleScore } == [1, 0.75, 0.6])
    }

    /// Both kinds are returned, the prerequisites' first; a candidate both point at is one suggestion.
    @Test func titlesRankBelowListedTogetherAndBothKindsAreReturned() throws {
        // IS 4300 was replaced by CS 2484 and the courses needing it list both; CS 3000's
        // prerequisites also list CS 4550, which has an unrelated title.
        let prerequisites = prerequisites([
            ("CS 4520", either("IS 4300", "CS 2484", "CS 4550")),
            ("CS 4540", either("IS 4300", "CS 2484", "CS 4550")),
            ("CS 4600", requisite("IS 4300")),
        ])
        var table = titles
        table[key("CS 5100")] = "Human Computer Interaction Studio"
        let found = byTitle("IS 4300", among: ["CS 5100", "CS 2484"], titles: table, prerequisites: prerequisites)
        // CS 2484 is listed beside it in 2 of 3 prerequisites and has the similar title, too.
        #expect(found.map { $0.candidate } == [key("CS 2484"), key("CS 4550"), key("CS 5100")])
        let both = try #require(found.first)
        #expect(both.together == 2 && both.total == 3 && both.isListedTogether)
        #expect(both.similarTitle == "Principles of Human-Computer Interaction" && both.titleScore == 1)
        #expect(both.evidence == "Listed together in 2 of the 3 prerequisites that name IS 4300 · similar title")
        // Listed together without a similar title, and a similar title without being listed.
        #expect(found[1].similarTitle == nil && found[1].evidence == "Listed together in 2 of the 3 prerequisites that name IS 4300")
        #expect(found[2].together == 0 && found[2].total == 3 && found[2].evidence == "Similar title: Human Computer Interaction Studio")
    }

    @Test func aTitleSuggestionKeepsAPlaceWhenThePrerequisitesWouldFillTheList() {
        let listing = (1...4).map { number -> (course: CourseKey, requisite: Requisite) in
            (course: key("CS 40\(number)0"), requisite: either("IS 4300", "CS 2110", "CS 2210", "CS 2310"))
        }
        let all = listing + prerequisites([("CS 4500", either("IS 4300", "CS 2484"))])
        // Three prerequisite suggestions would fill the list of 3 (CS 2110, 2210 and 2310 are each beside
        // IS 4300 in 4 of the 5 prerequisites naming it); CS 2484 is beside it once, so it comes only
        // through its title, and still gets a place.
        let found = byTitle("IS 4300", among: ["CS 2484"], prerequisites: all, limit: 3)
        #expect(found.count == 3)
        #expect(found.last?.candidate == key("CS 2484") && found.last?.together == 0)
        #expect(found.dropLast().allSatisfy { $0.isListedTogether })
        // With room for one, the stronger evidence wins.
        let one = byTitle("IS 4300", among: ["CS 2484"], prerequisites: all, limit: 1)
        #expect(one.count == 1 && one.first?.isListedTogether == true)
        // A list of two keeps one of each.
        let two = byTitle("IS 4300", among: ["CS 2484"], prerequisites: all, limit: 2)
        #expect(two.map { $0.isListedTogether } == [true, false])
        #expect(byTitle("IS 4300", among: ["CS 2484"], prerequisites: all, limit: 0).isEmpty)
    }
}

@MainActor
struct EquivalenceSuggestionStoreTests {
    private let clock = TestClock()

    private func store(_ banner: FakeBanner, directory: URL) -> CourseInfoStore {
        let clock = self.clock
        return CourseInfoStore(
            repository: CourseInfoRepository(fetcher: banner, directory: directory, now: { clock.now }),
            offeringRepository: OfferingHistoryRepository(fetcher: banner, directory: directory, now: { clock.now })
        )
    }

    private func newest() -> CatalogIndex {
        let alternatives = Requisite.or([requisite("CS 2100"), requisite("CS 2510")])
        return index([
            course("CS 2100"), course("CS 3000", prereqs: alternatives), course("CS 3200", prereqs: alternatives),
            course("CS 3300", prereqs: .or([requisite("CS 2100"), requisite("CS 2510"), requisite("DS 2500")])),
        ])
    }

    @Test func suggestsReplacementsForRetiredCoursesOnly() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 2510", term: "202530"), term: "202530")
        banner.list(courseInfo("CS 3386", term: "202710"), term: "202710")
        let store = store(banner, directory: directory)
        let loaded = newest()

        // Nothing is known before the lookup.
        #expect(store.equivalenceSuggestions(for: key("CS 2510")).isEmpty)
        await store.load([key("CS 2510"), key("CS 3386"), key("CS 3000"), key("CS 2963")], indexes: [loaded])
        #expect(store.info(for: key("CS 2510"))?.isRetired == true)

        let found = store.equivalenceSuggestions(for: key("CS 2510"))
        #expect(found.map { $0.candidate } == [key("CS 2100")])
        #expect(found.first?.together == 3 && found.first?.total == 3)
        // A course the newest term lists, or that Banner's catalog still lists, isn't retired.
        #expect(store.equivalenceSuggestions(for: key("CS 3000")).isEmpty)
        #expect(store.equivalenceSuggestions(for: key("CS 3386")).isEmpty)
        // A course no catalog lists has nothing to go on here.
        #expect(store.state(for: key("CS 2963")) == .notFound)
        #expect(store.equivalenceSuggestions(for: key("CS 2963")).isEmpty)

        // Once the student says so, it isn't suggested again.
        var plan = DegreePlan(name: "Plan")
        plan.declareEquivalence(course: key("CS 2510"), countsAs: key("CS 2100"))
        #expect(store.equivalenceSuggestions(for: key("CS 2510"), plan: plan).isEmpty)
    }

    /// The reported case, end to end: the degree requires IS 4300, which Banner's catalog lists only
    /// up to Spring 2025; the student's plan has CS 2484 (its audit title cut at 30 characters).
    @Test func suggestsTheStudentsCourseWithASimilarTitle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(CourseInfo(key: key("IS 4300"), title: "Human Computer Interaction", minCredits: 4, maxCredits: 4, sourceTerm: "202530"), term: "202530")
        let store = store(banner, directory: directory)

        var plan = DegreePlan(name: "Plan")
        plan.completed = [DegreePlanCourse(key: key("CS 2484"), title: "Principles of Human-Computer I", credits: 4),
                          DegreePlanCourse(key: key("CS 3650"), title: "Computer Systems", credits: 4)]
        plan.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: [DegreePlanCourse(key: key("CS 4550"), title: "Web Development", credits: 4)])]
        await store.load([key("IS 4300"), key("CS 2484"), key("CS 3650")], indexes: [newest()])
        #expect(store.info(for: key("IS 4300"))?.isRetired == true)

        // The plan's own (cut off) title is the last resort, and is enough.
        let found = store.equivalenceSuggestions(for: key("IS 4300"), plan: plan)
        #expect(found.map { $0.candidate } == [key("CS 2484")])
        let suggestion = try #require(found.first)
        #expect(suggestion.similarTitle == "Principles of Human-Computer I" && !suggestion.isListedTogether)
        #expect(suggestion.evidence == "Similar title: Principles of Human-Computer I")

        // Without a plan there are no courses of the student's to compare.
        #expect(store.equivalenceSuggestions(for: key("IS 4300")).isEmpty)
        // …but a requirement's courses can be compared: titles come from the catalog's, first.
        let catalog: [CourseKey: String] = [key("CS 2484"): "Principles of Human-Computer Interaction", key("CS 4550"): "Web Development"]
        let listed = store.equivalenceSuggestions(for: key("IS 4300"), catalogTitles: catalog, alsoComparing: [key("CS 2484"), key("CS 4550")])
        #expect(listed.map { $0.candidate } == [key("CS 2484")])
        #expect(listed.first?.similarTitle == "Principles of Human-Computer Interaction")
        // The catalog's title also stands for the retired course when Banner has none.
        let titled = store.equivalenceSuggestions(for: key("IS 4300"), plan: plan, catalogTitles: [key("IS 4300"): "Computer Systems"])
        #expect(titled.map { $0.candidate } == [key("CS 3650")])

        // Once the student says so, it isn't suggested again.
        plan.declareEquivalence(course: key("CS 2484"), countsAs: key("IS 4300"))
        #expect(store.equivalenceSuggestions(for: key("IS 4300"), plan: plan).isEmpty)
    }

    /// Titles come from the catalog's, then Banner's entries, then the loaded terms, then the plan.
    @Test func titlesComeFromTheBestSource() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(CourseInfo(key: key("IS 4300"), title: "Human Computer Interaction", sourceTerm: "202530"), term: "202530")
        banner.list(CourseInfo(key: key("CS 2484"), title: "Principles of Human-Computer Interaction (Banner)", sourceTerm: "202710"), term: "202710")
        let store = store(banner, directory: directory)
        var plan = DegreePlan(name: "Plan")
        plan.completed = [DegreePlanCourse(key: key("CS 2484"), title: "Principles of Human-Computer I", credits: 4)]
        await store.load([key("IS 4300"), key("CS 2484")], indexes: [newest()])

        #expect(store.equivalenceSuggestions(for: key("IS 4300"), plan: plan).first?.similarTitle == "Principles of Human-Computer Interaction (Banner)")
        let catalog = [key("CS 2484"): "Human-Computer Interaction Principles (catalog)"]
        #expect(store.equivalenceSuggestions(for: key("IS 4300"), plan: plan, catalogTitles: catalog).first?.similarTitle == "Human-Computer Interaction Principles (catalog)")
    }

    /// A course the newest term lists, or Banner's catalog still lists, is not retired: no titles either.
    @Test func currentCoursesGetNoTitleSuggestions() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(CourseInfo(key: key("IS 4300"), title: "Human Computer Interaction", sourceTerm: "202710"), term: "202710")
        let store = store(banner, directory: directory)
        var plan = DegreePlan(name: "Plan")
        plan.completed = [DegreePlanCourse(key: key("CS 2484"), title: "Principles of Human-Computer Interaction", credits: 4)]
        await store.load([key("IS 4300"), key("CS 2484")], indexes: [newest()])
        #expect(store.info(for: key("IS 4300"))?.isRetired == false)
        #expect(store.equivalenceSuggestions(for: key("IS 4300"), plan: plan).isEmpty)
    }

    /// A course that a loaded term has since started to list keeps what only Banner's catalog
    /// entry knows: its mutual exclusions.
    @Test func loadedCatalogsDoNotDropBannerEquivalents() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        banner.list(courseInfo("CS 2100", term: "202710", equivalents: [key("CS 2510")]), term: "202710")
        let store = store(banner, directory: directory)

        await store.load([key("CS 2100")], indexes: [])
        #expect(store.equivalences(for: nil).areEquivalent(key("CS 2100"), key("CS 2510")))

        await store.load([key("CS 2100")], indexes: [index([course("CS 2100", prereqs: requisite("CS 1800"))])])
        #expect(store.info(for: key("CS 2100"))?.prerequisites == requisite("CS 1800"))
        #expect(store.info(for: key("CS 2100"))?.isRetired == false)
        #expect(store.equivalences(for: nil).areEquivalent(key("CS 2100"), key("CS 2510")))

        // An older term's schedule never replaces newer information.
        await store.load([key("CS 2100")], indexes: [index([course("CS 2100", prereqs: requisite("CS 1000"))], term: "202610")])
        #expect(store.info(for: key("CS 2100"))?.prerequisites == requisite("CS 1800"))
    }
}

// MARK: - Offering history

struct OfferingHistoryTests {
    private let clock = TestClock()
    /// Two years of terms, newest first: Fall 2026 back to Fall 2024, with the summers.
    private let checked = ["202710", "202650", "202630", "202610", "202550", "202530", "202510"]

    private func history(_ offered: [String: [String]], checked: [String]? = nil, keys: [String]? = nil) -> OfferingHistory {
        OfferingHistory(
            checkedTerms: checked ?? self.checked,
            offered: Dictionary(uniqueKeysWithValues: offered.map { (key($0.key), Set($0.value)) }),
            checkedKeys: keys.map { Set($0.map(key)) }
        )
    }

    @Test func seasonsAndLikelyOfferings() {
        let history = history([
            "CS 3386": ["202630", "202530"],                // every spring
            "CS 3800": ["202710", "202610", "202510"],      // every fall
            "CS 2500": ["202650", "202550"],                // every summer (the full summer term)
        ])
        #expect(history.seasons(of: key("CS 3386")) == [.spring])
        #expect(history.seasons(of: key("CS 2500")) == [.summerFull])
        #expect(history.isLikelyOffered(key("CS 3386"), in: .spring) == true)
        #expect(history.isLikelyOffered(key("CS 3386"), in: .fall) == false)
        // Summer 1, Summer 2 and the full summer all match the summer term that was checked.
        #expect(history.isLikelyOffered(key("CS 2500"), in: .summerA) == true)
        #expect(history.isLikelyOffered(key("CS 2500"), in: .summerB) == true)
        #expect(history.isLikelyOffered(key("CS 3386"), in: .summerA) == false)
        // No winter term was checked, so that can't be said.
        #expect(history.isLikelyOffered(key("CS 3386"), in: .winter) == nil)
        // A course that had no sections at all in the window.
        #expect(history.isLikelyOffered(key("CS 9999"), in: .spring) == false)
    }

    @Test func unknownWhenNothingWasChecked() {
        #expect(OfferingHistory.empty.isLikelyOffered(key("CS 3386"), in: .spring) == nil)
        #expect(OfferingHistory.empty.summary(of: key("CS 3386")) == "Offering history unknown")
        // A history made for some courses says nothing about others.
        let partial = history(["CS 3386": ["202630"]], keys: ["CS 3386"])
        #expect(partial.isLikelyOffered(key("CS 3386"), in: .spring) == true)
        #expect(partial.isLikelyOffered(key("CS 3800"), in: .spring) == nil)
        #expect(partial.summary(of: key("CS 3800")) == "Offering history unknown")
        #expect(partial.summary(of: key("CS 3800"), in: .spring) == "Offering history unknown")
    }

    @Test func summaries() {
        let history = history([
            "CS 3386": ["202630", "202530"],
            "CS 3800": ["202710", "202610", "202510", "202630", "202530"],
            "CS 4100": ["202530"],
            "CS 2500": ["202650", "202550"],
            "CS 2510": ["202650", "202630"],
        ])
        #expect(history.summary(of: key("CS 3386")) == "Offered every spring")
        #expect(history.summary(of: key("CS 3800")) == "Offered every fall and spring")
        #expect(history.summary(of: key("CS 4100")) == "Last offered Spring 2025")
        #expect(history.summary(of: key("CS 2500")) == "Offered every summer")
        #expect(history.summary(of: key("CS 2510")) == "Last offered Summer 2026")
        #expect(history.summary(of: key("CS 9999")) == "Not offered in the last 2 years")

        // Every fall, and one spring of two.
        let mixed = self.history(["CS 3800": ["202710", "202610", "202510", "202630"]])
        #expect(mixed.summary(of: key("CS 3800")) == "Offered every fall, and sometimes in the spring")
        #expect(self.history(["CS 3800": ["202710", "202610", "202510", "202630", "202550"]]).summary(of: key("CS 3800"))
                == "Offered every fall, and sometimes in the spring and summer")

        #expect(history.summary(of: key("CS 3386"), in: .spring) == "Offered every spring")
        #expect(history.summary(of: key("CS 4100"), in: .spring) == "Offered in Spring 2025")
        #expect(history.summary(of: key("CS 3386"), in: .fall) == "Not offered in a fall term in the last 2 years")
        #expect(history.summary(of: key("CS 2500"), in: .summerA) == "Offered every summer")
    }

    @Test func historiesMergeAndRoundTrip() throws {
        let first = history(["CS 3386": ["202630"]], checked: ["202710", "202630"], keys: ["CS 3386"])
        let second = history(["CS 3800": ["202710"]], checked: ["202710", "202610"], keys: ["CS 3800"])
        let merged = first.merging(second)
        #expect(merged.checkedTerms == ["202710", "202630", "202610"])
        #expect(merged.offered[key("CS 3386")] == ["202630"] && merged.offered[key("CS 3800")] == ["202710"])
        #expect(merged.checkedKeys == [key("CS 3386"), key("CS 3800")])
        // Merging with a history that checked every course leaves none unchecked.
        #expect(first.merging(history([:])).checkedKeys == nil)

        for original in [merged, history(["CS 3386": ["202630", "202530"]]), .empty] {
            let decoded = try JSONDecoder().decode(OfferingHistory.self, from: JSONEncoder().encode(original))
            #expect(decoded == original)
        }
    }
}

struct OfferingHistoryRepositoryTests {
    private let clock = TestClock()

    private func repository(_ banner: FakeBanner, directory: URL) -> OfferingHistoryRepository {
        let clock = self.clock
        return OfferingHistoryRepository(fetcher: banner, directory: directory, now: { clock.now })
    }

    private func banner() -> FakeBanner {
        let banner = FakeBanner(clock: clock, terms: bannerTerms)
        // CS 3386 is taught in the spring, CS 3800 in the fall, MATH 2331 in both.
        for term in ["202710", "202610", "202510"] { banner.offer(term: term, courses: ["CS 3800", "MATH 2331"]) }
        for term in ["202630", "202530"] { banner.offer(term: term, courses: ["CS 3386", "MATH 2331"]) }
        banner.offer(term: "202650", courses: ["CS 2500"])
        return banner
    }

    @Test func coversTwoYearsOfTermsSummersIncluded() {
        let window = OfferingHistoryRepository.window(of: bannerTerms.filter { $0.college == .neu }, months: 24).map(\.code)
        // Fall 2026 back to Fall 2024; Summer 2 2024 (202460) is a little older.
        #expect(window == ["202710", "202650", "202630", "202610", "202560", "202550", "202540", "202530", "202510"])
        #expect(OfferingHistoryRepository.window(of: [], months: 24).isEmpty)
    }

    @Test func asksOncePerTermAboutTheCoursesAndCachesThePast() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = banner()
        let repository = repository(banner, directory: directory)
        let keys = [key("CS 3386"), key("CS 3800"), key("MATH 2331"), key("CS 2500")]

        let history = await repository.history(for: keys)
        #expect(history.checkedTerms == ["202710", "202650", "202630", "202610", "202560", "202550", "202540", "202530", "202510"])
        // One batched question per term about all four courses, not one per course.
        #expect(banner.offeredCalls.count == 9)
        #expect(banner.offeredCalls.allSatisfy { Set($0.courses) == Set(keys) })
        #expect(history.isLikelyOffered(key("CS 3386"), in: .spring) == true)
        #expect(history.isLikelyOffered(key("CS 3386"), in: .fall) == false)
        #expect(history.isLikelyOffered(key("CS 3800"), in: .fall) == true)
        #expect(history.isLikelyOffered(key("CS 2500"), in: .summerA) == true)
        #expect(history.summary(of: key("MATH 2331")) == "Offered every fall and spring")
        #expect(history.checkedKeys == Set(keys))

        // The same courses again cost nothing, and a month later only the newest term is asked
        // again; the past is cached forever, across launches too.
        banner.resetCalls()
        _ = await repository.history(for: keys)
        #expect(banner.offeredCalls.isEmpty)
        clock.advance(days: 30)
        let relaunched = self.repository(banner, directory: directory)
        _ = await relaunched.history(for: keys)
        #expect(banner.offeredCalls.map { $0.term } == ["202710"])

        // A new course is asked about in every term, and only that course.
        banner.resetCalls()
        _ = await relaunched.history(for: [key("PHYS 1151"), key("CS 3386")])
        #expect(banner.offeredCalls.count == 9)
        #expect(banner.offeredCalls.allSatisfy { $0.courses == [key("PHYS 1151")] })
    }

    /// Many courses are asked about a few at a time, and what earlier batches found is kept when
    /// a later one fails.
    @Test func bigQuestionsAreBatchedAndKeepWhatWasFound() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = banner()
        let numbers = (1...12).map { "CS 30\(10 + $0)" }
        banner.offer(term: "202630", courses: numbers)
        let repository = repository(banner, directory: directory)
        let keys = numbers.map(key)

        // The second batch of Spring 2026 (CS 3021 and CS 3022) fails.
        banner.failQuestions(in: "202630", including: key("CS 3022"))
        let partial = await repository.history(for: keys)
        #expect(!partial.checkedTerms.contains("202630") && partial.checkedTerms.contains("202530"))
        #expect(banner.offeredCalls.filter { $0.term == "202630" }.map { $0.courses.count } == [10, 2])
        #expect(banner.offeredCalls.filter { $0.term == "202710" }.map { $0.courses.count } == [10, 2])

        // Next time Spring 2026 only asks about the batch that failed.
        banner.failQuestions(in: "202630", including: nil)
        banner.resetCalls()
        let full = await repository.history(for: keys)
        #expect(banner.offeredCalls.map { $0.term } == ["202630"])
        #expect(banner.offeredCalls.first?.courses == [key("CS 3021"), key("CS 3022")])
        #expect(full.checkedTerms.contains("202630"))
        #expect(keys.allSatisfy { full.isLikelyOffered($0, in: .spring) == true })
    }

    @Test func theCurrentTermIsRefreshedWeekly() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = banner()
        let repository = repository(banner, directory: directory)
        _ = await repository.history(for: [key("CS 3800")])
        banner.resetCalls()

        clock.advance(days: 6)
        _ = await repository.history(for: [key("CS 3800")])
        #expect(banner.offeredCalls.isEmpty)
        clock.advance(days: 2)
        _ = await repository.history(for: [key("CS 3800")])
        #expect(banner.offeredCalls.map { $0.term } == ["202710"])
    }

    /// A term read before its classes began (the schedule was still being built) is read again
    /// once a newer term has replaced it as the newest, then it is settled.
    @Test func aTermReadBeforeItStartedIsReadAgain() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Summer 2026: Fall 2026 (202710) is the newest term, and it starts in September.
        let spring = Date(timeIntervalSince1970: 1_780_000_000)    // late May 2026
        let early = TestClock(start: spring)
        let banner = FakeBanner(clock: early, terms: bannerTerms)
        banner.offer(term: "202710", courses: ["CS 3800"])
        let first = OfferingHistoryRepository(fetcher: banner, directory: directory, now: { early.now })
        _ = await first.history(for: [key("CS 3800")])
        #expect(banner.offeredCalls.contains { $0.term == "202710" })

        // By January 2027 a newer term is posted, and Fall 2026 is over. What was read in May
        // was read before classes began, so Fall 2026 is read again; the older, settled terms aren't.
        early.advance(days: 230)
        banner.resetCalls()
        banner.setTerms(terms(["202730"]) + bannerTerms)
        let second = OfferingHistoryRepository(fetcher: banner, directory: directory, now: { early.now })
        _ = await second.history(for: [key("CS 3800")])
        let asked = Set(banner.offeredCalls.map { $0.term })
        #expect(asked.contains("202730") && asked.contains("202710"))
        #expect(!asked.contains("202630") && !asked.contains("202610"))

        // Read after it began: settled for good.
        early.advance(days: 60)
        banner.resetCalls()
        banner.setTerms(terms(["202750", "202730"]) + bannerTerms)
        _ = await OfferingHistoryRepository(fetcher: banner, directory: directory, now: { early.now }).history(for: [key("CS 3800")])
        #expect(!banner.offeredCalls.contains { $0.term == "202710" })
    }

    @Test func aTermThatCouldNotBeReachedIsNotReportedAsNotOffered() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = banner()
        banner.fail("202630")
        let repository = repository(banner, directory: directory)

        let history = await repository.history(for: [key("CS 3386")])
        #expect(!history.checkedTerms.contains("202630"))
        #expect(history.checkedTerms.contains("202530"))
        // Spring 2025 still says it is taught in the spring.
        #expect(history.isLikelyOffered(key("CS 3386"), in: .spring) == true)

        // Nothing reachable at all: unknown, not "never offered".
        let offline = FakeBanner(clock: clock, terms: bannerTerms)
        for term in bannerTerms { offline.fail(term.code) }
        let none = await self.repository(offline, directory: temporaryDirectory()).history(for: [key("CS 3386")])
        #expect(none.checkedTerms.isEmpty)
        #expect(none.isLikelyOffered(key("CS 3386"), in: .spring) == nil)
    }

    @Test func loadedCatalogsAnswerWithoutARequest() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let banner = banner()
        let repository = repository(banner, directory: directory)
        let fall2026 = index([course("CS 3386"), course("CS 3800")], sections: [section("1", "CS 3800")], term: "202710")

        let history = await repository.history(for: [key("CS 3386"), key("CS 3800")], indexes: [fall2026])
        #expect(!banner.offeredCalls.contains { $0.term == "202710" })
        #expect(history.checkedTerms.contains("202710"))
        #expect(history.offered[key("CS 3800")]?.contains("202710") == true)
        #expect(history.offered[key("CS 3386")]?.contains("202710") != true)
    }
}

// MARK: - Reordering a plan

struct DegreePlanReorderingTests {
    private typealias Reordering = DegreePlanReordering

    private let allTerms = ["202710", "202650", "202630", "202610", "202550", "202530", "202510"]
    private let fall = ["202710", "202610", "202510"]
    private let spring = ["202630", "202530"]

    private func planned(_ code: String, _ credits: Double = 4) -> DegreePlanCourse {
        DegreePlanCourse(key: key(code), title: code, credits: credits)
    }

    private func semester(_ season: PlanSeason, _ year: Int, _ codes: [String], credits: Double = 4) -> DegreePlanTerm {
        DegreePlanTerm(season: season, year: year, courses: codes.map { planned($0, credits) })
    }

    private func plan(_ terms: [DegreePlanTerm], completed: [String] = []) -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.completed = completed.map { planned($0) }
        plan.terms = terms
        return plan
    }

    /// Course codes to the terms they were taught in, two dictionaries together.
    private func and(_ first: [String: [String]], _ second: [String: [String]]) -> [String: [String]] {
        first.merging(second) { $1 }
    }

    private func taught(_ codes: [String], in terms: [String]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: codes.map { ($0, terms) })
    }

    private func history(_ offered: [String: [String]], keys: [String]? = nil) -> OfferingHistory {
        OfferingHistory(
            checkedTerms: allTerms,
            offered: Dictionary(uniqueKeysWithValues: offered.map { (key($0.key), Set($0.value)) }),
            checkedKeys: keys.map { Set($0.map(key)) }
        )
    }

    private func none(_: CourseKey) -> Requisite?? { .some(nil) }

    private func needs(_ table: [String: Requisite]) -> (CourseKey) -> Requisite?? {
        let byKey = Dictionary(uniqueKeysWithValues: table.map { (key($0.key), $0.value) })
        return { byKey[$0].map { .some($0) } ?? .some(nil) }
    }

    private func suggestions(_ plan: DegreePlan, in term: Int = 0, blocking: [String], history: OfferingHistory,
                             prerequisites: (CourseKey) -> Requisite?? = { _ in .some(nil) },
                             equivalences: CourseEquivalences = .none, maxCredits: Double = 20) -> [Reordering.Suggestion] {
        var sorted = plan
        sorted.sortTerms()
        return Reordering.suggestions(for: plan, termID: sorted.terms[term].id, blocking: blocking.map(key), history: history,
                                      prerequisites: prerequisites, equivalences: equivalences, maxCreditsPerTerm: maxCredits)
    }

    private func titles(_ suggestions: [Reordering.Suggestion]) -> [String] { suggestions.map { $0.title } }

    // MARK: Seasons

    /// CS 3386 is only taught in the spring: it moves to a spring, never to the fall in between.
    @Test func aCourseOnlyMovesToASeasonItIsTaughtIn() {
        let plan = plan([
            semester(.fall, 2026, ["CS 3386", "CS 3800"]), semester(.spring, 2027, ["CS 4100"]),
            semester(.fall, 2027, []), semester(.spring, 2028, []),
        ])
        let history = history(["CS 3386": spring, "CS 3800": fall, "CS 4100": fall + spring])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history)

        // The earliest later spring comes first; Fall 2027 is skipped.
        #expect(found.first?.title == "Move CS 3386 to Spring 2027")
        #expect(found.first?.moves == [Reordering.Move(course: key("CS 3386"), from: plan.terms[0].id, to: plan.terms[1].id)])
        #expect(!titles(found).contains { $0.contains("Fall 2027") })
        let singles = found.filter { $0.moves.count == 1 }
        #expect(titles(singles) == ["Move CS 3386 to Spring 2027", "Move CS 3386 to Spring 2028"])
        #expect(found.first?.reasons.first == "Offered every spring")
        #expect(found.first?.reasons.last == "Spring 2027 would have 8 credits")
        #expect(found.first?.addsSemester == nil)
    }

    @Test func aCourseNeverTaughtAnywhereHasNoSuggestions() {
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, [])])
        #expect(suggestions(plan, blocking: ["CS 3386"], history: history([:])).isEmpty)
    }

    @Test func unknownHistoryIsAllowedButRankedLower() throws {
        let plan = plan([semester(.fall, 2026, ["CS 9001", "CS 3386"]), semester(.spring, 2027, [])])
        // Nothing is known about CS 9001; CS 3386 is taught in the spring.
        let history = history(["CS 3386": spring], keys: ["CS 3386"])
        let found = suggestions(plan, blocking: ["CS 9001", "CS 3386"], history: history)

        #expect(titles(found) == ["Move CS 3386 to Spring 2027", "Move CS 9001 to Spring 2027"])
        try #require(found.count == 2)
        #expect(found[1].reasons.first == "Offering history unknown")
        #expect(found[0].reasons.first == "Offered every spring")
    }

    // MARK: Prerequisites and dependents

    @Test func aCourseNeedsItsPrerequisitesBeforeTheSemester() {
        // CS 3386 needs CS 2386, which is planned for Spring 2027.
        let plan = plan([
            semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, ["CS 2386"]),
            semester(.fall, 2027, []), semester(.spring, 2028, []),
        ])
        let history = history(["CS 3386": spring, "CS 2386": fall + spring])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history, prerequisites: needs(["CS 3386": requisite("CS 2386")]))

        // Not Spring 2027 (CS 2386 would be taken at the same time), but Spring 2028.
        let singles = found.filter { $0.moves.count == 1 }
        #expect(titles(singles) == ["Move CS 3386 to Spring 2028"])
        #expect(singles.first?.reasons.contains("Prerequisites met by then") == true)
        // …or swapping the two: CS 2386 comes first, in the fall, when it is taught.
        #expect(titles(found).contains("Move CS 3386 to Spring 2027 and CS 2386 to Fall 2026"))
    }

    @Test func nothingThatNeedsACourseMayBePlannedAtOrBeforeItsNewSemester() {
        // CS 4500 needs CS 3386 and is planned for Spring 2028.
        let plan = plan([
            semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, []),
            semester(.fall, 2027, []), semester(.spring, 2028, ["CS 4500"]),
        ])
        let history = history(["CS 3386": spring, "CS 4500": spring])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history, prerequisites: needs(["CS 4500": requisite("CS 3386")]))
        // Spring 2027 is before it; Spring 2028 is the same semester, so it's out.
        #expect(titles(found) == ["Move CS 3386 to Spring 2027"])

        // With CS 4500 in Spring 2027 every later spring is too late, a new semester as well.
        let tight = self.plan([
            semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, ["CS 4500"]),
            semester(.fall, 2027, []), semester(.spring, 2028, []),
        ])
        #expect(suggestions(tight, blocking: ["CS 3386"], history: history, prerequisites: needs(["CS 4500": requisite("CS 3386")])).isEmpty)
    }

    @Test func equivalentCoursesCountForPrerequisites() {
        // CS 3386 needs CS 2100; the student took the old CS 2510.
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, [])], completed: ["CS 2510"])
        let history = history(["CS 3386": spring])
        let prerequisites = needs(["CS 3386": requisite("CS 2100")])

        #expect(suggestions(plan, blocking: ["CS 3386"], history: history, prerequisites: prerequisites).isEmpty)
        let renumbered = CourseEquivalences(pairs: [(key("CS 2100"), key("CS 2510"))])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history, prerequisites: prerequisites, equivalences: renumbered)
        #expect(titles(found) == ["Move CS 3386 to Spring 2027"])
        #expect(found.first?.reasons.contains("Prerequisites still met") == true)

        // The student's own declaration works without being passed in.
        var declared = plan
        declared.declareEquivalence(course: key("CS 2510"), countsAs: key("CS 2100"))
        #expect(suggestions(declared, blocking: ["CS 3386"], history: history, prerequisites: prerequisites).count == 1)
    }

    @Test func unknownPrerequisitesAreAllowedButRankedLower() throws {
        let plan = plan([semester(.fall, 2026, ["CS 3386", "CS 3387"]), semester(.spring, 2027, [])])
        let history = history(["CS 3386": spring, "CS 3387": spring])
        // Banner has no answer for CS 3386.
        let prerequisites: (CourseKey) -> Requisite?? = { $0 == key("CS 3386") ? nil : .some(nil) }
        let found = suggestions(plan, blocking: ["CS 3386", "CS 3387"], history: history, prerequisites: prerequisites)
        #expect(titles(found) == ["Move CS 3387 to Spring 2027", "Move CS 3386 to Spring 2027"])
        try #require(found.count == 2)
        #expect(found[1].reasons.contains("Prerequisites couldn’t be checked"))
    }

    // MARK: Credits

    @Test func aSemesterStaysUnderTheCreditLimit() {
        let full = ["CS 4100", "CS 4200", "CS 4300", "CS 4400", "CS 4500"]   // 20 credits
        let plan = plan([
            semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, full),
            semester(.fall, 2027, []), semester(.spring, 2028, []),
        ])
        let history = history(and(["CS 3386": spring], taught(full, in: fall + spring)))

        let found = suggestions(plan, blocking: ["CS 3386"], history: history)
        let singles = found.filter { $0.moves.count == 1 }
        #expect(titles(singles) == ["Move CS 3386 to Spring 2028"])

        // A higher limit lets it in, and says how heavy the semester gets.
        let relaxed = suggestions(plan, blocking: ["CS 3386"], history: history, maxCredits: 24)
        #expect(titles(relaxed.filter { $0.moves.count == 1 }).first == "Move CS 3386 to Spring 2027")
        #expect(relaxed.first?.reasons.last == "Spring 2027 would have 24 credits")
    }

    // MARK: Swaps

    /// When the later semester is full, swapping keeps both at their size.
    @Test func swapsTradeACourseThatIsTaughtNow() throws {
        let full = ["CS 3800", "CS 4200", "CS 4300", "CS 4400", "CS 4500"]
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, full)])
        // Only CS 3800 is taught in the fall.
        let history = history(and(["CS 3386": spring, "CS 3800": fall + spring], taught(Array(full.dropFirst()), in: spring)))
        let found = suggestions(plan, blocking: ["CS 3386"], history: history)

        #expect(titles(found) == ["Move CS 3386 to Spring 2027 and CS 3800 to Fall 2026"])
        let swap = try #require(found.first)
        #expect(swap.moves == [
            Reordering.Move(course: key("CS 3386"), from: plan.terms[0].id, to: plan.terms[1].id),
            Reordering.Move(course: key("CS 3800"), from: plan.terms[1].id, to: plan.terms[0].id),
        ])
        #expect(swap.reasons.contains("CS 3386: offered every spring"))
        #expect(swap.reasons.contains("CS 3800: offered every fall"))
        #expect(swap.reasons.contains("Fall 2026 would have 4 credits"))
        #expect(swap.reasons.contains("Spring 2027 would have 20 credits"))
    }

    @Test func swapsRankAfterSingleMoves() {
        let plan = plan([
            semester(.fall, 2026, ["CS 3386", "CS 3800"]), semester(.spring, 2027, ["CS 4100"]), semester(.spring, 2028, []),
        ])
        let history = history(["CS 3386": spring, "CS 3800": fall, "CS 4100": fall + spring])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history)
        #expect(titles(found) == [
            "Move CS 3386 to Spring 2027",
            "Move CS 3386 to Spring 2028",
            "Move CS 3386 to Spring 2027 and CS 4100 to Fall 2026",
        ])
        #expect(found.map { $0.moves.count } == [1, 1, 2])
    }

    @Test func swapPartnersMustBeTaughtInTheSemesterTheyMoveTo() {
        // CS 4100 is only taught in the spring, so it can't take CS 3386's fall place.
        let full = ["CS 4100", "CS 4200", "CS 4300", "CS 4400", "CS 4500"]
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, full)])
        let history = history(and(["CS 3386": spring], taught(full, in: spring)))
        #expect(suggestions(plan, blocking: ["CS 3386"], history: history).filter { $0.moves.count == 2 }.isEmpty)
    }

    @Test func swapPartnersKeepTheirOwnPrerequisites() {
        // CS 3800 needs CS 3700, planned in Spring 2027 with it: moving CS 3800 to Fall 2026 would
        // put it before CS 3700. (Spring 2027 is full, so only swaps work.)
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, ["CS 3800", "CS 3700"])])
        let history = history(["CS 3386": spring, "CS 3800": fall + spring, "CS 3700": fall + spring])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history,
                                prerequisites: needs(["CS 3800": requisite("CS 3700")]), maxCredits: 8)
        // CS 3700 itself can take the place, and then CS 3800 still comes after it.
        #expect(titles(found) == ["Move CS 3386 to Spring 2027 and CS 3700 to Fall 2026"])
    }

    // MARK: Adding a semester

    @Test func aSemesterIsAddedWhenNoExistingOneWorks() throws {
        // The plan only has a later fall; CS 3386 is a spring course.
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.fall, 2027, ["CS 3800"])])
        let history = history(["CS 3386": spring, "CS 3800": fall])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history)

        try #require(found.count == 1)
        let suggestion = found[0]
        let added = suggestion.addsSemester
        #expect(added?.season == .spring && added?.year == 2028)
        #expect(suggestion.title == "Move CS 3386 to a new Spring 2028 semester")
        #expect(suggestion.moves == [Reordering.Move(course: key("CS 3386"), from: plan.terms[0].id, to: added?.id ?? UUID())])
        #expect(suggestion.reasons.last == "Adds Spring 2028 to your plan, with 4 credits")
        // The same suggestion has the same ids every time.
        let again = suggestions(plan, blocking: ["CS 3386"], history: history)
        #expect(again.first?.id == suggestion.id && again.first?.addsSemester?.id == added?.id)
    }

    @Test func theAddedSemesterIsInASeasonTheCourseIsTaughtIn() {
        // A fall course, with the plan ending in a spring: the next fall is the one added.
        let plan = plan([semester(.spring, 2027, ["CS 3800"])])
        let found = suggestions(plan, blocking: ["CS 3800"], history: history(["CS 3800": fall]))
        #expect(found.first?.addsSemester?.season == .fall && found.first?.addsSemester?.year == 2027)
    }

    // MARK: Applying

    @Test func applyingAMoveChangesThePlan() throws {
        var plan = plan([
            semester(.fall, 2026, ["CS 3386", "CS 3800"]), semester(.spring, 2027, ["CS 4100"]), semester(.spring, 2028, []),
        ])
        let original = plan
        let found = suggestions(plan, blocking: ["CS 3386"], history: history(["CS 3386": spring, "CS 3800": fall, "CS 4100": fall + spring]))
        let move = try #require(found.first)
        let moved = original.terms[0].courses[0]
        Reordering.apply(move, to: &plan)

        #expect(plan.terms[0].courses.map { $0.label } == ["CS 3800"])
        #expect(plan.terms[1].courses.map { $0.label } == ["CS 4100", "CS 3386"])
        // The same planned course, not a copy.
        #expect(plan.terms[1].courses.last?.id == moved.id)
        #expect(plan.terms.count == 3)

        // A suggestion that no longer fits the plan changes nothing.
        let before = plan
        Reordering.apply(move, to: &plan)
        #expect(plan == before)
    }

    @Test func applyingASwapMovesBothCourses() throws {
        let full = ["CS 3800", "CS 4200", "CS 4300", "CS 4400", "CS 4500"]
        var plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, full)])
        let swap = try #require(suggestions(plan, blocking: ["CS 3386"], history: history(and(["CS 3386": spring, "CS 3800": fall], taught(Array(full.dropFirst()), in: spring)))).first)
        Reordering.apply(swap, to: &plan)
        #expect(plan.terms[0].courses.map { $0.label } == ["CS 3800"])
        #expect(plan.terms[1].courses.map { $0.label } == ["CS 4200", "CS 4300", "CS 4400", "CS 4500", "CS 3386"])
    }

    @Test func applyingAddsTheNewSemester() throws {
        var plan = plan([semester(.fall, 2026, ["CS 3386", "CS 3800"]), semester(.fall, 2027, [])])
        let original = plan
        let suggestion = try #require(suggestions(plan, blocking: ["CS 3386"], history: history(["CS 3386": spring, "CS 3800": fall])).first)
        Reordering.apply(suggestion, to: &plan)

        #expect(plan.terms.map { $0.name } == ["Fall 2026", "Fall 2027", "Spring 2028"])
        #expect(plan.terms.last?.courses.map { $0.label } == ["CS 3386"])
        #expect(plan.terms[0].courses.map { $0.label } == ["CS 3800"])

        // Applied to a plan that got the semester in the meantime, it joins that one.
        var other = original
        other.terms.append(semester(.spring, 2028, ["CS 4100"]))
        Reordering.apply(suggestion, to: &other)
        #expect(other.terms.count == 3)
        #expect(other.terms.last?.courses.map { $0.label } == ["CS 4100", "CS 3386"])
    }

    @Test func staleOrUnknownRequestsAreIgnored() {
        let plan = plan([semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, [])])
        let history = history(["CS 3386": spring])
        // A semester that isn't in the plan, a course that isn't in the semester.
        #expect(Reordering.suggestions(for: plan, termID: UUID(), blocking: [key("CS 3386")], history: history, prerequisites: none, equivalences: .none).isEmpty)
        #expect(suggestions(plan, blocking: ["CS 1234"], history: history).isEmpty)
        #expect(suggestions(plan, blocking: [], history: history).isEmpty)
    }

    @Test func atMostAFewSuggestionsAreReturned() {
        let plan = plan([
            semester(.fall, 2026, ["CS 3386"]), semester(.spring, 2027, []), semester(.spring, 2028, []),
            semester(.spring, 2029, []), semester(.spring, 2030, []), semester(.spring, 2031, []), semester(.spring, 2032, []),
        ])
        let found = suggestions(plan, blocking: ["CS 3386"], history: history(["CS 3386": spring]))
        #expect(found.count == Reordering.maxSuggestions)
        #expect(titles(found).first == "Move CS 3386 to Spring 2027")
    }
}
