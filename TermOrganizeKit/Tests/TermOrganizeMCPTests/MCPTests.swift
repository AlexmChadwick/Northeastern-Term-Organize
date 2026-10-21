//
//  MCPTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import TermOrganizeKit

@Suite(.serialized)
struct MCPToolTests {
    let library = MCPFixture.library()
    let plansURL: URL
    let server: TermOrganizeMCPServer

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("term-organize-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        plansURL = directory.appendingPathComponent("UserData.json")
        server = TermOrganizeMCPServer(library: library, plansURL: plansURL, readOnly: false)
    }

    @Test func listTerms() throws {
        let result = try call("list_terms", [:])
        let terms = result["terms"] as? [[String: Any]] ?? []
        #expect(terms.map { $0["term"] as? String } == ["202730", "202710"])
        #expect(terms.map { $0["name"] as? String } == ["Spring 2027", "Fall 2026"])
    }

    @Test func searchCourses() throws {
        let result = try call("search_courses", ["term": "202730", "query": "algorithms", "limit": 5])
        let courses = result["courses"] as? [[String: Any]] ?? []
        #expect(courses.first?["subject"] as? String == "CS")
        #expect(courses.first?["number"] as? String == "3000")
        #expect(courses.first?["title"] as? String == "Algorithms")
        let credits = courses.first?["credits"] as? [String: Any]
        #expect(credits?["min"] as? Double == 4)
        #expect((courses.first?["attributes"] as? [String]) == ["NCFQ"])
    }

    @Test func searchBySubjectNumberAndAttribute() throws {
        let result = try call("search_courses", ["term": "202730", "subject": "cs", "number": "3500", "attribute": "ncfq"])
        let courses = result["courses"] as? [[String: Any]] ?? []
        #expect(courses.count == 1)
        #expect(courses[0]["number"] as? String == "3500")
    }

    @Test func getCourseIncludesSectionsAndDropsOtherEmails() throws {
        let result = try call("get_course", ["term": "202730", "subject": "CS", "number": "3000"])
        #expect(result["title"] as? String == "Algorithms")
        let sections = result["sections"] as? [[String: Any]] ?? []
        #expect(sections.count == 2)
        let monday = try #require(sections.first { $0["crn"] as? String == "2001" })
        let meetings = monday["meetings"] as? [[String: Any]] ?? []
        #expect(meetings.first?["days"] as? [String] == ["monday"])
        #expect(meetings.first?["start"] as? String == "09:00")
        #expect(meetings.first?["location"] as? String == "WVH 210")
        let seats = monday["seats"] as? [String: Any]
        #expect(seats?["remaining"] as? Int == 3)
        let instructors = monday["instructors"] as? [[String: Any]] ?? []
        #expect(instructors.first?["name"] as? String == "Ada Lovelace")
        #expect(instructors.first?["email"] as? String == "ada@northeastern.edu")
        let gmailOnly = try #require(sections.first { $0["crn"] as? String == "2002" })
        let hidden = (gmailOnly["instructors"] as? [[String: Any]] ?? []).first
        #expect(hidden?["email"] == nil)
    }

    @Test func checkScheduleReportsClashesAndUnknownCRNs() throws {
        let result = try call("check_schedule", ["term": "202730", "crns": ["2001", "2003", "99999"]])
        let clashes = result["clashes"] as? [[String: Any]] ?? []
        #expect(clashes.count == 1)
        #expect(result["unknown_crns"] as? [String] == ["99999"])
    }

    @Test func suggestScheduleIsConflictFreeAndHonorsDaysOff() throws {
        let open = try call("suggest_schedule", [
            "term": "202730",
            "courses": [["subject": "CS", "number": "3000"], ["subject": "CS", "number": "3500"]],
        ])
        let schedules = open["schedules"] as? [[String: Any]] ?? []
        #expect(!schedules.isEmpty)
        let first = try #require(schedules.first?["crns"] as? [String])
        #expect(!first.contains("2001") || !first.contains("2003"))
        let offMonday = try call("suggest_schedule", [
            "term": "202730",
            "courses": [["subject": "CS", "number": "3000"], ["subject": "CS", "number": "3500"]],
            "constraints": ["days_off": ["monday"], "no_classes_before": "08:00", "no_classes_after": "18:00"],
        ])
        let limited = offMonday["schedules"] as? [[String: Any]] ?? []
        let crns = Set(limited.flatMap { $0["crns"] as? [String] ?? [] })
        #expect(!crns.contains("2001"))
        #expect(!crns.contains("2003"))
        #expect(crns.contains("2002"))
        #expect(crns.contains("2004"))
    }

    /// CS 4973 is two topics. A request that names one CRN must not get the other,
    /// including when a constraint would fit the other topic and not the pin.
    @Test func suggestScheduleDoesNotReplaceAPinnedCRN() throws {
        let pinned = try call("suggest_schedule", [
            "term": "202730",
            "courses": [["subject": "CS", "number": "4973", "crn": "11111"]],
        ])
        let schedules = pinned["schedules"] as? [[String: Any]] ?? []
        let crns = schedules.flatMap { $0["crns"] as? [String] ?? [] }
        #expect(crns == ["11111"])
        #expect(!crns.contains("22222"))
        #expect(!crns.contains("33333"))

        let filtered = try call("suggest_schedule", [
            "term": "202730",
            "courses": [["subject": "CS", "number": "4973", "crn": "11111"]],
            "constraints": ["no_classes_before": "10:00"],
        ])
        let blocked = filtered["schedules"] as? [[String: Any]] ?? []
        #expect(blocked.isEmpty)

        let open = try call("suggest_schedule", [
            "term": "202730",
            "courses": [["subject": "CS", "number": "4973"]],
            "constraints": ["no_classes_before": "10:00"],
        ])
        let openCRNs = Set((open["schedules"] as? [[String: Any]] ?? []).flatMap { $0["crns"] as? [String] ?? [] })
        #expect(openCRNs.contains("22222"))
        #expect(openCRNs.contains("33333"))
        #expect(!openCRNs.contains("11111"))

        let wrong = server.call(name: "suggest_schedule", arguments: [
            "term": "202730",
            "courses": [["subject": "CS", "number": "4973", "crn": "2001"]],
        ])
        #expect(wrong["isError"] as? Bool == true)
    }

    /// Two special-topics sections share a number. Reorganize keeps each pin, and
    /// does not treat a different section of that number as the pinned one.
    @Test func reorganizeKeepsPinnedSpecialTopicsSections() throws {
        let kept = try call("reorganize_plan", [
            "plan": [
                "terms": [
                    ["term": "202710", "courses": [["subject": "CS", "number": "4973", "crn": "11111"]]],
                    ["term": "202730", "courses": [["subject": "CS", "number": "4973", "crn": "22222"]]],
                ],
            ],
        ])
        #expect((kept["moves"] as? [Any])?.isEmpty == true)
        let terms = (kept["plan"] as? [String: Any])?["terms"] as? [[String: Any]] ?? []
        let fall = try #require(terms.first { $0["term"] as? String == "202710" })
        let spring = try #require(terms.first { $0["term"] as? String == "202730" })
        let fallCourses = fall["courses"] as? [[String: Any]] ?? []
        let springCourses = spring["courses"] as? [[String: Any]] ?? []
        #expect(fallCourses.map { $0["crn"] as? String } == ["11111"])
        #expect(springCourses.map { $0["crn"] as? String } == ["22222"])

        // 33333 is only in the spring catalog. Fall still offers other CS 4973 sections.
        let moved = try call("reorganize_plan", [
            "plan": [
                "terms": [
                    ["term": "202710", "courses": [["subject": "CS", "number": "4973", "crn": "33333"]]],
                    ["term": "202730", "courses": []],
                ],
            ],
        ])
        let moves = moved["moves"] as? [[String: Any]] ?? []
        #expect(moves.count == 1)
        #expect(moves.first?["crn"] as? String == "33333")
        #expect(moves.first?["to_term"] as? String == "202730")
        let movedTerms = (moved["plan"] as? [String: Any])?["terms"] as? [[String: Any]] ?? []
        let movedSpring = try #require(movedTerms.first { $0["term"] as? String == "202730" })
        let movedFall = try #require(movedTerms.first { $0["term"] as? String == "202710" })
        #expect((movedFall["courses"] as? [Any])?.isEmpty == true)
        #expect((movedSpring["courses"] as? [[String: Any]])?.map { $0["crn"] as? String } == ["33333"])
    }

    @Test func applyReorganizeDoesNotReplaceAPinnedCRN() throws {
        let id = try planID(try call("create_plan", ["name": "Topics", "terms": ["202710", "202730"]]))
        _ = try call("add_course", [
            "plan_id": id, "term": "202710", "subject": "CS", "number": "4973", "crn": "11111", "expected_revision": 1,
        ])
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "crn": "22222", "expected_revision": 2,
        ])
        let changed = try call("set_section", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "crn": "33333", "expected_revision": 3,
        ])
        let before = (changed["terms"] as? [[String: Any]] ?? []).first { $0["term"] as? String == "202730" }
        let beforeCRN = ((before?["courses"] as? [[String: Any]])?.first)?["crn"] as? String
        #expect(beforeCRN == "33333")

        let applied = try call("apply_reorganize", ["plan_id": id, "expected_revision": 4])
        let terms = applied["terms"] as? [[String: Any]] ?? []
        let fall = try #require(terms.first { $0["term"] as? String == "202710" })
        let spring = try #require(terms.first { $0["term"] as? String == "202730" })
        #expect(((fall["courses"] as? [[String: Any]])?.first)?["crn"] as? String == "11111")
        #expect(((spring["courses"] as? [[String: Any]])?.first)?["crn"] as? String == "33333")
        #expect((applied["moves"] as? [Any])?.isEmpty == true)
    }

    @Test func reorganizePlanMovesACourseThatIsNotOffered() throws {
        let result = try call("reorganize_plan", [
            "plan": [
                "terms": [
                    ["term": "202710", "courses": [["subject": "CS", "number": "3500"]]],
                    ["term": "202730", "courses": [["subject": "CS", "number": "3000"]]],
                ],
            ],
        ])
        let moves = result["moves"] as? [[String: Any]] ?? []
        #expect(moves.contains { $0["number"] as? String == "3500" && $0["to_term"] as? String == "202730" })
        #expect((moves.first?["reason"] as? String)?.isEmpty == false)
        #expect((result["unresolved"] as? [Any])?.isEmpty == true)
        let plan = result["plan"] as? [String: Any]
        let terms = plan?["terms"] as? [[String: Any]] ?? []
        let spring = try #require(terms.first { $0["term"] as? String == "202730" })
        let courses = spring["courses"] as? [[String: Any]] ?? []
        #expect(courses.contains { $0["number"] as? String == "3500" })
    }

    @Test func reorganizeFixtureMatchesBundledSpringCatalog() throws {
        let url = try #require(MCPFixture.reorganizeFixtureURL())
        let raw = try Data(contentsOf: url)
        let fixture = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let plan = try #require(fixture["plan"] as? [String: Any])
        let directory = try #require(MCPFixture.bundledCatalogDirectory())
        var indexes: [String: CatalogIndex] = [:]
        for code in CatalogLibrary.allowedTermCodes {
            let catalogURL = directory.appendingPathComponent(CatalogArchive.fileName(forTerm: code))
            let catalog = try CatalogArchive.read(from: catalogURL)
            indexes[code] = CatalogIndex.build(catalog)
        }
        let library = CatalogLibrary(indexes: indexes)
        let server = TermOrganizeMCPServer(library: library, plansURL: plansURL, readOnly: true)
        let result = server.call(name: "reorganize_plan", arguments: ["plan": plan])
        #expect(result["isError"] as? Bool != true)
        let body = try #require(result["structuredContent"] as? [String: Any])
        let expected = try #require(fixture["expected"] as? [String: Any])
        #expect(moveKeys(body["moves"]) == moveKeys(expected["moves"]))
        #expect(moveKeys(body["unresolved"]) == moveKeys(expected["unresolved"]))
    }

    @Test func createListAndGetPlan() throws {
        let created = try call("create_plan", ["name": "Spring", "terms": ["202730"]])
        let id = try #require(created["id"] as? String)
        #expect(created["revision"] as? Int == 1)
        let added = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 1,
        ])
        #expect(added["revision"] as? Int == 2)
        let listed = try call("list_plans", [:])
        let plans = listed["plans"] as? [[String: Any]] ?? []
        let match = plans.first { $0["id"] as? String == id }
        let listedTerms = match?["terms"] as? [[String: Any]]
        #expect(listedTerms?.map { $0["term"] as? String } == ["202730"])
        #expect(listedTerms?.map { $0["name"] as? String } == ["Spring 2027"])
        #expect(match?["updated_at"] != nil)
        #expect(match?["updated"] == nil)
        #expect(match?["revision"] as? Int == 2)
        #expect((listed["schedules"] as? [Any])?.isEmpty == true)
        let loaded = try call("get_plan", ["plan_id": id])
        let terms = loaded["terms"] as? [[String: Any]] ?? []
        let courses = terms.first?["courses"] as? [[String: Any]] ?? []
        #expect(courses.first?["number"] as? String == "3000")
        let validation = loaded["validation"] as? [String: Any]
        #expect((validation?["clashes"] as? [Any])?.isEmpty == true)
    }

    @Test func renamePlan() throws {
        let id = try planID(try call("create_plan", ["name": "Old"]))
        let renamed = try call("rename_plan", ["plan_id": id, "name": "New", "expected_revision": 1])
        #expect(renamed["name"] as? String == "New")
        #expect(renamed["revision"] as? Int == 2)
    }

    @Test func addCourseRejectsUnknownAndKeepsKnown() throws {
        let id = try planID(try call("create_plan", ["name": "Spring", "terms": ["202730"]]))
        let added = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "crn": "2002", "expected_revision": 1,
        ])
        #expect(added["revision"] as? Int == 2)
        let courses = ((added["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        #expect(courses.first?["crn"] as? String == "2002")
        let missing = server.call(name: "add_course", arguments: [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "9999", "expected_revision": 2,
        ])
        #expect(missing["isError"] as? Bool == true)
    }

    @Test func removeCourse() throws {
        let id = try planID(try call("create_plan", ["name": "Spring", "terms": ["202730"]]))
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 1,
        ])
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3500", "expected_revision": 2,
        ])
        let removed = try call("remove_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3500", "expected_revision": 3,
        ])
        let courses = ((removed["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        #expect(courses.map { $0["number"] as? String } == ["3000"])
    }

    @Test func moveCourse() throws {
        let id = try planID(try call("create_plan", ["name": "Year", "terms": ["202710", "202730"]]))
        _ = try call("add_course", [
            "plan_id": id, "term": "202710", "subject": "CS", "number": "3000", "expected_revision": 1,
        ])
        let moved = try call("move_course", [
            "plan_id": id, "subject": "CS", "number": "3000", "from_term": "202710", "to_term": "202730", "expected_revision": 2,
        ])
        let terms = moved["terms"] as? [[String: Any]] ?? []
        let spring = try #require(terms.first { $0["term"] as? String == "202730" })
        let courses = spring["courses"] as? [[String: Any]] ?? []
        #expect(courses.contains { $0["number"] as? String == "3000" })
    }

    @Test func setSection() throws {
        let id = try planID(try call("create_plan", ["name": "Spring", "terms": ["202730"]]))
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 1,
        ])
        let updated = try call("set_section", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "crn": "2001", "expected_revision": 2,
        ])
        let courses = ((updated["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        #expect(courses.first?["crn"] as? String == "2001")
        let bad = server.call(name: "set_section", arguments: [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "crn": "2003", "expected_revision": 3,
        ])
        #expect(bad["isError"] as? Bool == true)
    }

    /// The same subject and number is two rows only when each row has its own CRN.
    @Test func duplicateCourseNumbersNeedDistinctCRNs() throws {
        let id = try planID(try call("create_plan", ["name": "Topics", "terms": ["202730"]]))
        let plain = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 1,
        ])
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 2,
        ])
        let plainCourses = ((plain["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        let stillPlain = try call("get_plan", ["plan_id": id])
        let plainAfter = ((stillPlain["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        #expect(plainCourses.count == 1)
        #expect(plainAfter.count == 1)
        #expect(plainAfter.first?["crn"] == nil)

        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "expected_revision": 3,
        ])
        let pinned = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "crn": "11111", "expected_revision": 4,
        ])
        let oneTopic = courses(in: pinned, term: "202730").filter { $0["number"] as? String == "4973" }
        #expect(oneTopic.count == 1)
        #expect(oneTopic.first?["crn"] as? String == "11111")

        let same = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "crn": "11111", "expected_revision": 5,
        ])
        #expect(courses(in: same, term: "202730").filter { $0["number"] as? String == "4973" }.count == 1)

        let both = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "crn": "22222", "expected_revision": 6,
        ])
        let topics = courses(in: both, term: "202730").filter { $0["number"] as? String == "4973" }
        #expect(Set(topics.compactMap { $0["crn"] as? String }) == ["11111", "22222"])

        let ambiguous = server.call(name: "set_section", arguments: [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973", "crn": "33333", "expected_revision": 7,
        ])
        #expect(ambiguous["isError"] as? Bool == true)
        let untouched = try call("get_plan", ["plan_id": id])
        #expect(untouched["revision"] as? Int == 7)
        #expect(Set(courses(in: untouched, term: "202730").filter { $0["number"] as? String == "4973" }.compactMap { $0["crn"] as? String }) == ["11111", "22222"])

        let changed = try call("set_section", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973",
            "crn": "33333", "from_crn": "22222", "expected_revision": 7,
        ])
        #expect(Set(courses(in: changed, term: "202730").filter { $0["number"] as? String == "4973" }.compactMap { $0["crn"] as? String }) == ["11111", "33333"])

        let stolen = server.call(name: "set_section", arguments: [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "4973",
            "crn": "11111", "from_crn": "33333", "expected_revision": 8,
        ])
        #expect(stolen["isError"] as? Bool == true)
        let kept = try call("get_plan", ["plan_id": id])
        #expect(kept["revision"] as? Int == 8)
        #expect(Set(courses(in: kept, term: "202730").filter { $0["number"] as? String == "4973" }.compactMap { $0["crn"] as? String }) == ["11111", "33333"])

        let suggested = try call("suggest_schedule", [
            "term": "202730",
            "courses": [
                ["subject": "CS", "number": "4973", "crn": "11111"],
                ["subject": "CS", "number": "4973", "crn": "33333"],
            ],
        ])
        let schedules = suggested["schedules"] as? [[String: Any]] ?? []
        let crns = schedules.first?["crns"] as? [String] ?? []
        #expect(Set(crns) == ["11111", "33333"])
        #expect(crns.count == 2)

        let applied = try call("apply_reorganize", ["plan_id": id, "expected_revision": 8])
        let appliedTopics = courses(in: applied, term: "202730").filter { $0["number"] as? String == "4973" }
        #expect(Set(appliedTopics.compactMap { $0["crn"] as? String }) == ["11111", "33333"])
        #expect(appliedTopics.count == 2)
    }

    /// Degree plans are the plans. Schedules are listed beside them and are not writable.
    /// A missing or zero revision is reported as 1.
    @Test func listPlansExposesDegreePlansAndNormalizesRevision() throws {
        var stored = UserData()
        var schedule = SchedulePlan(name: "Plan A", termCode: "202730")
        schedule.revision = 0
        stored.plans = [schedule]
        var truth = DegreePlan(name: "True Plan")
        truth.revision = nil
        truth.terms = [DegreePlanTerm(season: .spring, year: 2027, courses: [
            DegreePlanCourse(key: CourseKey(subject: "CS", number: "3000"), title: "Algorithms", credits: 4),
        ])]
        var summer = DegreePlan(name: "Summer Internship")
        summer.revision = 0
        summer.terms = [DegreePlanTerm(season: .summerFull, year: 2027)]
        stored.degreePlans = [truth, summer]
        try UserDataFile.write(stored, to: plansURL)

        let listed = try call("list_plans", [:])
        let plans = listed["plans"] as? [[String: Any]] ?? []
        let schedules = listed["schedules"] as? [[String: Any]] ?? []
        #expect(plans.compactMap { $0["name"] as? String }.sorted() == ["Summer Internship", "True Plan"])
        #expect(plans.allSatisfy { $0["revision"] as? Int == 1 && $0["updated_at"] != nil && $0["updated"] == nil })
        let truthRow = try #require(plans.first { $0["name"] as? String == "True Plan" })
        let truthTerms = truthRow["terms"] as? [[String: Any]]
        #expect(truthTerms?.first?["term"] as? String == "202730")
        #expect(truthTerms?.first?["name"] as? String == "Spring 2027")
        let summerRow = try #require(plans.first { $0["name"] as? String == "Summer Internship" })
        let summerTerms = summerRow["terms"] as? [[String: Any]]
        #expect(summerTerms?.first?["term"] as? String == "202750")
        #expect(summerTerms?.first?["name"] as? String == "Summer Full 2027")
        #expect(schedules.compactMap { $0["name"] as? String } == ["Plan A"])
        #expect(schedules.first?["revision"] as? Int == 1)
        let scheduleTerms = schedules.first?["terms"] as? [[String: Any]]
        #expect(scheduleTerms?.first?["term"] as? String == "202730")
        #expect(scheduleTerms?.first?["name"] as? String == "Spring 2027")

        let scheduleID = try #require(schedules.first?["id"] as? String)
        let refused = server.call(name: "get_plan", arguments: ["plan_id": scheduleID])
        #expect(refused["isError"] as? Bool == true)

        let id = try #require(truthRow["id"] as? String)
        let added = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3500", "expected_revision": 1,
        ])
        #expect(added["revision"] as? Int == 2)
        let numbers = courses(in: added, term: "202730").compactMap { $0["number"] as? String }.sorted()
        #expect(numbers == ["3000", "3500"])
        let reloaded = try UserDataFile.read(from: plansURL)
        #expect(reloaded.plans.map(\.name) == ["Plan A"])
        #expect(reloaded.degreePlans.first { $0.name == "True Plan" }?.revision == 2)
    }

    @Test func revisionConflictLeavesTheFileAlone() throws {
        let id = try planID(try call("create_plan", ["name": "Spring", "terms": ["202730"]]))
        _ = try call("rename_plan", ["plan_id": id, "name": "First", "expected_revision": 1])
        let conflict = server.call(name: "rename_plan", arguments: [
            "plan_id": id, "name": "Stale", "expected_revision": 1,
        ])
        #expect(conflict["isError"] as? Bool == true)
        let text = ((conflict["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("revision_conflict"))
        let error = (conflict["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "revision_conflict")
        #expect((error?["message"] as? String)?.isEmpty == false)
        #expect((conflict["structuredContent"] as? [String: Any])?["revision"] == nil)
        let loaded = try call("get_plan", ["plan_id": id])
        #expect(loaded["name"] as? String == "First")
        #expect(loaded["revision"] as? Int == 2)
    }

    @Test func deletePlanRequiresConfirm() throws {
        let id = try planID(try call("create_plan", ["name": "Gone", "terms": ["202730"]]))
        let refused = server.call(name: "delete_plan", arguments: ["plan_id": id, "expected_revision": 1, "confirm": false])
        #expect(refused["isError"] as? Bool == true)
        let deleted = try call("delete_plan", ["plan_id": id, "expected_revision": 1, "confirm": true])
        #expect(deleted["deleted"] as? Bool == true)
        let listed = try call("list_plans", [:])
        #expect((listed["plans"] as? [Any])?.isEmpty == true)
    }

    @Test func applyReorganizeSavesTheMove() throws {
        let id = try planID(try call("create_plan", ["name": "Year", "terms": ["202710", "202730"]]))
        _ = try call("add_course", [
            "plan_id": id, "term": "202710", "subject": "CS", "number": "3500", "expected_revision": 1,
        ])
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 2,
        ])
        let applied = try call("apply_reorganize", ["plan_id": id, "expected_revision": 3])
        let moves = applied["moves"] as? [[String: Any]] ?? []
        #expect(moves.contains { $0["number"] as? String == "3500" && $0["to_term"] as? String == "202730" })
        #expect((applied["unresolved"] as? [Any])?.isEmpty == true)
        #expect(applied["revision"] as? Int == 4)
    }

    @Test func readOnlyHidesWriteTools() throws {
        let quiet = TermOrganizeMCPServer(library: library, plansURL: plansURL, readOnly: true)
        let listed = quiet.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.contains("search_courses"))
        #expect(names.contains("list_plans"))
        #expect(names.contains("get_plan"))
        #expect(!names.contains("create_plan"))
        #expect(!names.contains("delete_plan"))
        #expect(!names.contains("apply_reorganize"))
        let denied = quiet.call(name: "delete_plan", arguments: ["plan_id": UUID().uuidString, "expected_revision": 1, "confirm": true])
        #expect(denied["isError"] as? Bool == true)
        let error = (denied["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "read_only")
        #expect((error?["message"] as? String)?.isEmpty == false)
    }

    @Test func destructiveToolsAreAnnotated() throws {
        let listed = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        func hint(_ name: String, _ key: String) -> Bool? {
            let tool = tools.first { $0["name"] as? String == name }
            let annotations = tool?["annotations"] as? [String: Any]
            return annotations?[key] as? Bool
        }
        #expect(hint("get_course", "readOnlyHint") == true)
        #expect(hint("delete_plan", "destructiveHint") == true)
        #expect(hint("remove_course", "destructiveHint") == true)
        #expect(hint("apply_reorganize", "destructiveHint") == true)
        #expect(hint("add_course", "readOnlyHint") == false)
    }

    @Test func appLoaderReadsTheSavedFileAndABackupIsKept() throws {
        let created = try call("create_plan", ["name": "Spring", "terms": ["202730"]])
        let id = try planID(created)
        _ = try call("add_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "expected_revision": 1,
        ])
        _ = try call("rename_plan", ["plan_id": id, "name": "Renamed", "expected_revision": 2])
        let backup = URL(fileURLWithPath: plansURL.path + ".bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        // `UserDataStore` loads the file with `UserDataFile.read`.
        let stored = try UserDataFile.read(from: plansURL)
        let plan = try #require(stored.degreePlans.first { $0.name == "Renamed" })
        #expect(plan.terms.flatMap(\.courses).map(\.key) == [CourseKey(subject: "CS", number: "3000")])
        #expect(plan.terms.map { bannerCode($0) } == ["202730"])
        #expect(plan.revision == 3)
    }

    @Test func presentedEmailsStayOnInstitutionalDomains() throws {
        let mixed = Instructor(name: "Lovelace, Ada", primary: true, email: "ada@gmail.com ada@northeastern.edu")
        #expect(instructorJSON(mixed)["email"] as? String == "ada@northeastern.edu")
        let personal = Instructor(name: "Lovelace, Ada", primary: true, email: "ada@gmail.com")
        #expect(instructorJSON(personal)["email"] == nil)
        let upper = Instructor(name: "Lovelace, Ada", primary: true, email: "ADA@Northeastern.EDU")
        #expect(instructorJSON(upper)["email"] as? String == "ADA@Northeastern.EDU")
        let subdomain = Instructor(name: "Lovelace, Ada", primary: true, email: "a@husky.neu.edu")
        #expect(instructorJSON(subdomain)["email"] == nil)
        if let directory = CatalogLibrary.locateCatalogDirectory() {
            let url = directory.appendingPathComponent("term-202730.catalog")
            if let catalog = try? CatalogArchive.read(from: url) {
                for section in catalog.sections {
                    for instructor in section.instructors ?? [] {
                        guard let email = instructorJSON(instructor)["email"] as? String else { continue }
                        let domain = email.split(separator: "@").last?.lowercased()
                        #expect(domain == "northeastern.edu" || domain == "neu.edu")
                    }
                }
            }
        }
    }

    @Test func objectTermsAreInvalidArgument() throws {
        let rejected = server.call(name: "create_plan", arguments: [
            "name": "Spring",
            "terms": [["term": "202730", "courses": [["subject": "CS", "number": "3000"]]]],
        ])
        let error = (rejected["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "invalid_argument")
        #expect(!FileManager.default.fileExists(atPath: plansURL.path))
    }

    @Test func malformedPlanFileIsStorageError() throws {
        let bytes = Data("{".utf8)
        try bytes.write(to: plansURL)
        try expectStorageErrorLeavesBytes(bytes, reason: "malformed JSON")
    }

    @Test func newerPlanFileVersionIsStorageError() throws {
        let bytes = Data("{\"version\":2,\"plans\":[]}".utf8)
        try bytes.write(to: plansURL)
        try expectStorageErrorLeavesBytes(bytes, reason: "unknown newer version 2")
    }

    @Test func permissionDeniedPlanFileIsStorageError() throws {
        let bytes = Data("{\"version\":1,\"plans\":[]}".utf8)
        try bytes.write(to: plansURL)
        #expect(chmod(plansURL.path, 0) == 0)
        defer { chmod(plansURL.path, 0o644) }
        let listed = server.call(name: "list_plans", arguments: [:])
        let created = server.call(name: "create_plan", arguments: ["name": "Nope", "terms": ["202730"]])
        chmod(plansURL.path, 0o644)
        for result in [listed, created] {
            #expect(result["isError"] as? Bool == true)
            let error = (result["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
            #expect(error?["code"] as? String == "storage_error")
            let message = error?["message"] as? String ?? ""
            #expect(message.contains(plansURL.path))
            #expect(message.contains("permission denied"))
        }
        #expect(try Data(contentsOf: plansURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: plansURL.path + ".bak"))
    }

    private func expectStorageErrorLeavesBytes(_ bytes: Data, reason: String) throws {
        let listed = server.call(name: "list_plans", arguments: [:])
        let created = server.call(name: "create_plan", arguments: ["name": "Nope", "terms": ["202730"]])
        for result in [listed, created] {
            #expect(result["isError"] as? Bool == true)
            let error = (result["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
            #expect(error?["code"] as? String == "storage_error")
            let message = error?["message"] as? String ?? ""
            #expect(message.contains(plansURL.path))
            #expect(message.contains(reason))
        }
        #expect(try Data(contentsOf: plansURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: plansURL.path + ".bak"))
    }

    private func moveKeys(_ raw: Any?) -> [[String]] {
        let rows = raw as? [[String: Any]] ?? []
        return rows.map { row in
            [row["subject"] as? String ?? "", row["number"] as? String ?? "", row["from_term"] as? String ?? "", row["to_term"] as? String ?? ""]
        }
    }

    private func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let result = server.call(name: name, arguments: arguments)
        #expect(result["isError"] as? Bool != true, "\(name) failed: \(result)")
        return (result["structuredContent"] as? [String: Any]) ?? [:]
    }

    private func planID(_ payload: [String: Any]) throws -> String {
        try #require(payload["id"] as? String)
    }

    private func courses(in payload: [String: Any], term: String) -> [[String: Any]] {
        let terms = payload["terms"] as? [[String: Any]] ?? []
        let row = terms.first { $0["term"] as? String == term }
        return row?["courses"] as? [[String: Any]] ?? []
    }
}

@Suite
struct MCPHelperSafetyTests {
    private let pending = "Open Term Organize once to finish moving your plans"

    @Test func missingGroupFileWithLegacyContainerIsStorageErrorWithoutReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-legacy-\(UUID().uuidString)", isDirectory: true)
        let plans = root.appendingPathComponent("group/UserData.json")
        let legacy = root.appendingPathComponent("container/UserData.json")
        try FileManager.default.createDirectory(at: plans.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("{\"version\":1,\"plans\":[{\"name\":\"DoNotRead\"}]}".utf8)
        try bytes.write(to: legacy)
        #expect(chmod(legacy.path, 0) == 0)
        defer { chmod(legacy.path, 0o644) }

        let server = TermOrganizeMCPServer(
            library: MCPFixture.library(), plansURL: plans, readOnly: false, legacyPlanURL: legacy
        )
        let calls: [(String, [String: Any])] = [
            ("list_plans", [:]),
            ("create_plan", ["name": "Nope", "terms": ["202730"]]),
            ("delete_plan", ["plan_id": UUID().uuidString, "expected_revision": 1, "confirm": true]),
            ("rename_plan", ["plan_id": UUID().uuidString, "name": "Nope", "expected_revision": 1]),
        ]
        for (name, arguments) in calls {
            let result = server.call(name: name, arguments: arguments)
            #expect(result["isError"] as? Bool == true)
            let error = (result["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
            #expect(error?["code"] as? String == "storage_error")
            #expect(error?["message"] as? String == pending)
        }
        chmod(legacy.path, 0o644)
        #expect(try Data(contentsOf: legacy) == bytes)
        #expect(!FileManager.default.fileExists(atPath: plans.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path + ".premigration.bak"))
        #expect(!FileManager.default.fileExists(atPath: plans.path + ".bak"))
        #expect(PlanFileLocation.pendingMoveMessage == pending)
    }

    @Test func missingGroupAndMissingLegacyIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-empty-\(UUID().uuidString)", isDirectory: true)
        let plans = root.appendingPathComponent("group/UserData.json")
        let legacy = root.appendingPathComponent("container/UserData.json")
        let server = TermOrganizeMCPServer(
            library: MCPFixture.library(), plansURL: plans, readOnly: false, legacyPlanURL: legacy
        )
        let result = server.call(name: "list_plans", arguments: [:])
        #expect(result["isError"] as? Bool != true)
        let payload = result["structuredContent"] as? [String: Any]
        let listed = payload?["plans"] as? [[String: Any]] ?? []
        #expect(listed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plans.path))
    }

    @Test func existingGroupFileIsUsedAndTheLegacyFileIsNotRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-group-\(UUID().uuidString)", isDirectory: true)
        let plans = root.appendingPathComponent("group/UserData.json")
        let legacy = root.appendingPathComponent("container/UserData.json")
        try FileManager.default.createDirectory(at: plans.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        var stored = UserData()
        var plan = SchedulePlan(name: "FromGroup", termCode: "202730")
        plan.revision = 1
        stored.plans = [plan]
        try UserDataFile.write(stored, to: plans)
        let legacyBytes = Data("{\"version\":1,\"plans\":[{\"name\":\"LegacySecret\"}]}".utf8)
        try legacyBytes.write(to: legacy)
        #expect(chmod(legacy.path, 0) == 0)
        defer { chmod(legacy.path, 0o644) }

        let server = TermOrganizeMCPServer(
            library: MCPFixture.library(), plansURL: plans, readOnly: false, legacyPlanURL: legacy
        )
        let result = server.call(name: "list_plans", arguments: [:])
        #expect(result["isError"] as? Bool != true)
        let payload = result["structuredContent"] as? [String: Any]
        let listed = payload?["plans"] as? [[String: Any]] ?? []
        let schedules = payload?["schedules"] as? [[String: Any]] ?? []
        #expect(listed.isEmpty)
        #expect(schedules.count == 1)
        #expect(schedules.first?["name"] as? String == "FromGroup")
        chmod(legacy.path, 0o644)
        #expect(try Data(contentsOf: legacy) == legacyBytes)
        #expect(!FileManager.default.fileExists(atPath: legacy.path + ".premigration.bak"))
    }
}

@Suite
struct MCPCatalogLocationTests {
    @Test func helperFindsCatalogsBesideItsOwnBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-bundle-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Term Organize.app/Contents/Resources", isDirectory: true)
        let executable = root.appendingPathComponent("Term Organize.app/Contents/Helpers/term-organize-mcp")
        let empty = root.appendingPathComponent("empty-cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data(MCPFixture.jsonCatalog(term: "202710").utf8).write(
            to: resources.appendingPathComponent(CatalogArchive.fileName(forTerm: "202710"))
        )

        let found = CatalogLibrary.locateCatalogDirectory(
            executable: executable, currentDirectory: empty, environment: [:]
        )
        #expect(found?.standardizedFileURL.path == resources.standardizedFileURL.path)

        let nested = resources.appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.removeItem(at: resources.appendingPathComponent(CatalogArchive.fileName(forTerm: "202710")))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(MCPFixture.jsonCatalog(term: "202710").utf8).write(
            to: nested.appendingPathComponent(CatalogArchive.fileName(forTerm: "202710"))
        )
        let nestedFound = CatalogLibrary.locateCatalogDirectory(
            executable: executable, currentDirectory: empty, environment: [:]
        )
        #expect(nestedFound?.standardizedFileURL.path == nested.standardizedFileURL.path)

        let override = root.appendingPathComponent("override-catalogs", isDirectory: true)
        let overridden = CatalogLibrary.locateCatalogDirectory(
            executable: executable,
            currentDirectory: empty,
            environment: ["TERM_ORGANIZE_CATALOG_DIR": override.path]
        )
        #expect(overridden?.standardizedFileURL.path == override.standardizedFileURL.path)
    }
}

@Suite
struct MCPStdioTests {
    @Test func initializeToolsListAndCall() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binary = root.appendingPathComponent(".build/debug/term-organize-mcp")
        let catalog = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-stdio-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let plans = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-stdio-\(UUID().uuidString).json")
        try Data(MCPFixture.jsonCatalog(term: "202710").utf8).write(to: catalog.appendingPathComponent("term-202710.catalog"))
        try Data(MCPFixture.jsonCatalog(term: "202730").utf8).write(to: catalog.appendingPathComponent("term-202730.catalog"))

        let process = Process()
        process.executableURL = binary
        process.environment = [
            "TERM_ORGANIZE_CATALOG_DIR": catalog.path,
            "TERM_ORGANIZE_USER_DATA": plans.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        func send(_ object: [String: Any]) throws {
            var body = try JSONSerialization.data(withJSONObject: object)
            body.append(0x0A)
            #expect(body.filter { $0 == 0x0A }.count == 1)
            input.fileHandleForWriting.write(body)
        }
        func receive() throws -> [String: Any] {
            let handle = output.fileHandleForReading
            var line = Data()
            while true {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty { break }
                if byte[0] == 0x0A { break }
                if byte[0] != 0x0D { line.append(byte) }
            }
            return (try JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
        }

        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "test", "version": "0"],
        ]])
        let initialized = try receive()
        let initResult = try #require(initialized["result"] as? [String: Any])
        #expect(initResult["protocolVersion"] as? String == "2025-06-18")
        let info = try #require(initResult["serverInfo"] as? [String: Any])
        #expect((info["title"] as? String)?.contains("not affiliated with Northeastern") == true)
        #expect((initResult["instructions"] as? String)?.contains("not affiliated with Northeastern") == true)

        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let listed = try receive()
        let tools = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        #expect(tools.contains { $0["name"] as? String == "list_terms" })

        try send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
            "name": "list_terms",
            "arguments": [String: Any](),
        ]])
        let called = try receive()
        let payload = (called["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        let terms = payload?["terms"] as? [[String: Any]] ?? []
        #expect(terms.contains { $0["term"] as? String == "202730" })

        input.fileHandleForWriting.closeFile()
        process.terminate()
    }
}

enum MCPFixture {
    static func reorganizeFixtureURL() -> URL? {
        walkUp(#filePath, relative: "tests/fixtures/mcp-reorganize-fixture.json")
    }

    static func bundledCatalogDirectory() -> URL? {
        walkUp(#filePath, relative: "NEUClassSearch/Resources/Catalog")
    }

    private static func walkUp(_ file: String, relative: String) -> URL? {
        var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    static func library() -> CatalogLibrary {
        CatalogLibrary(indexes: [
            "202710": CatalogIndex.build(catalog(term: "202710", courses: [
                course("CS", "3000", "Algorithms", ["NCFQ"]),
                course("CS", "4973", "Special Topics", []),
            ], sections: [
                section(crn: "1001", subject: "CS", number: "3000", day: .monday, email: "ada@northeastern.edu"),
                section(crn: "11111", subject: "CS", number: "4973", day: .monday, email: nil),
                section(crn: "22222", subject: "CS", number: "4973", day: .wednesday, email: nil),
            ])),
            "202730": CatalogIndex.build(catalog(term: "202730", courses: [
                course("CS", "3000", "Algorithms", ["NCFQ"]),
                course("CS", "3500", "OOD", ["NCFQ"]),
                course("CS", "4973", "Special Topics", []),
            ], sections: [
                section(crn: "2001", subject: "CS", number: "3000", day: .monday, email: "ada@gmail.com ada@northeastern.edu"),
                section(crn: "2002", subject: "CS", number: "3000", day: .tuesday, email: "ada@gmail.com"),
                section(crn: "2003", subject: "CS", number: "3500", day: .monday, email: "ada@neu.edu"),
                section(crn: "2004", subject: "CS", number: "3500", day: .wednesday, email: nil),
                section(crn: "11111", subject: "CS", number: "4973", day: .monday, email: nil),
                section(crn: "22222", subject: "CS", number: "4973", day: .wednesday, start: 14, email: nil),
                section(crn: "33333", subject: "CS", number: "4973", day: .tuesday, start: 10, email: nil),
            ])),
        ])
    }

    static func jsonCatalog(term: String) -> String {
        let name = term == "202710" ? "Fall 2026 Semester" : "Spring 2027 Semester"
        return """
        {"version":1,"term":{"code":"\(term)","bannerDescription":"\(name)"},"generatedAt":0,"sectionsUpdatedAt":0,"courses":[],"sections":[],"subjects":[],"attributes":[],"campuses":[]}
        """
    }

    private static func catalog(term: String, courses: [Course], sections: [CourseSection]) -> TermCatalog {
        let name = term == "202710" ? "Fall 2026 Semester" : "Spring 2027 Semester"
        return TermCatalog(
            term: Term(code: term, bannerDescription: name),
            courses: courses,
            sections: sections,
            subjects: [Subject(code: "CS", name: "Computer Science")],
            attributes: [AttributeInfo(code: "NCFQ", name: "Formal and Quantitative Reasoning")],
            campuses: [Campus(code: "BOS", name: "Boston")]
        )
    }

    private static func course(_ subject: String, _ number: String, _ title: String, _ attributes: [String]) -> Course {
        Course(
            subject: subject, number: number, title: title, description: title,
            minCredits: 4, maxCredits: 4, attributes: attributes,
            prereqs: nil, coreqs: nil, postreqs: [], specialTopics: false,
            college: nil, department: nil, detailsLoaded: true
        )
    }

    private static func section(crn: String, subject: String, number: String, day: DaySet, start: Int = 9, email: String?) -> CourseSection {
        let meeting = Meeting(
            days: day, start: start * 60, end: (start + 1) * 60,
            buildingCode: "WVH", building: "West Village H", room: "210",
            campusCode: "BOS", kind: "Class", startDate: nil, endDate: nil
        )
        return CourseSection(
            crn: crn, subject: subject, number: number, title: subject,
            sectionNumber: "01", partOfTerm: "1",
            seatCapacity: 40, seatsRemaining: 3, enrollment: 37,
            waitlistCapacity: 0, waitlistCount: 0, waitlistRemaining: 0,
            classType: "Lecture", honors: false, campus: "Boston",
            instructionMethod: "Traditional", meetings: [meeting],
            instructors: [Instructor(name: "Lovelace, Ada", primary: true, email: email)],
            crossListCRNs: [], attributes: ["NCFQ"], description: nil, prereqs: nil, coreqs: nil
        )
    }
}
