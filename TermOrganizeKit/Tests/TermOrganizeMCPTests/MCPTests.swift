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

    @Test func reorganizePlanMovesACourseThatIsNotOffered() throws {
        let result = try call("reorganize_plan", [
            "terms": [
                ["term": "202710", "courses": [["subject": "CS", "number": "3500"]]],
                ["term": "202730", "courses": [["subject": "CS", "number": "3000"]]],
            ],
        ])
        let moves = result["moves"] as? [[String: Any]] ?? []
        #expect(moves.contains { $0["number"] as? String == "3500" && $0["to_term"] as? String == "202730" })
    }

    @Test func createListAndGetPlan() throws {
        let created = try call("create_plan", [
            "name": "Spring",
            "terms": [["term": "202730", "courses": [["subject": "CS", "number": "3000"]]]],
        ])
        let id = try #require(created["id"] as? String)
        #expect(created["revision"] as? Int == 1)
        let listed = try call("list_plans", [:])
        let plans = listed["plans"] as? [[String: Any]] ?? []
        #expect(plans.contains { $0["id"] as? String == id && ($0["terms"] as? [String]) == ["202730"] })
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
        let id = try planID(try call("create_plan", ["name": "Spring", "terms": [["term": "202730"]]]))
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
        let id = try planID(try call("create_plan", [
            "name": "Spring",
            "terms": [["term": "202730", "courses": [["subject": "CS", "number": "3000"], ["subject": "CS", "number": "3500"]]]],
        ]))
        let removed = try call("remove_course", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3500", "expected_revision": 1,
        ])
        let courses = ((removed["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        #expect(courses.map { $0["number"] as? String } == ["3000"])
    }

    @Test func moveCourse() throws {
        let id = try planID(try call("create_plan", [
            "name": "Year",
            "terms": [
                ["term": "202710", "courses": [["subject": "CS", "number": "3000"]]],
                ["term": "202730", "courses": []],
            ],
        ]))
        let moved = try call("move_course", [
            "plan_id": id, "subject": "CS", "number": "3000", "from_term": "202710", "to_term": "202730", "expected_revision": 1,
        ])
        let terms = moved["terms"] as? [[String: Any]] ?? []
        let spring = try #require(terms.first { $0["term"] as? String == "202730" })
        let courses = spring["courses"] as? [[String: Any]] ?? []
        #expect(courses.contains { $0["number"] as? String == "3000" })
    }

    @Test func setSection() throws {
        let id = try planID(try call("create_plan", [
            "name": "Spring",
            "terms": [["term": "202730", "courses": [["subject": "CS", "number": "3000"]]]],
        ]))
        let updated = try call("set_section", [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "crn": "2001", "expected_revision": 1,
        ])
        let courses = ((updated["terms"] as? [[String: Any]])?.first?["courses"] as? [[String: Any]]) ?? []
        #expect(courses.first?["crn"] as? String == "2001")
        let bad = server.call(name: "set_section", arguments: [
            "plan_id": id, "term": "202730", "subject": "CS", "number": "3000", "crn": "2003", "expected_revision": 2,
        ])
        #expect(bad["isError"] as? Bool == true)
    }

    @Test func revisionConflictLeavesTheFileAlone() throws {
        let id = try planID(try call("create_plan", ["name": "Spring", "terms": [["term": "202730"]]]))
        _ = try call("rename_plan", ["plan_id": id, "name": "First", "expected_revision": 1])
        let conflict = server.call(name: "rename_plan", arguments: [
            "plan_id": id, "name": "Stale", "expected_revision": 1,
        ])
        #expect(conflict["isError"] as? Bool == true)
        let text = ((conflict["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("revision_conflict"))
        let loaded = try call("get_plan", ["plan_id": id])
        #expect(loaded["name"] as? String == "First")
        #expect(loaded["revision"] as? Int == 2)
    }

    @Test func deletePlanRequiresConfirm() throws {
        let id = try planID(try call("create_plan", ["name": "Gone", "terms": [["term": "202730"]]]))
        let refused = server.call(name: "delete_plan", arguments: ["plan_id": id, "expected_revision": 1, "confirm": false])
        #expect(refused["isError"] as? Bool == true)
        let deleted = try call("delete_plan", ["plan_id": id, "expected_revision": 1, "confirm": true])
        #expect(deleted["deleted"] as? Bool == true)
        let listed = try call("list_plans", [:])
        #expect((listed["plans"] as? [Any])?.isEmpty == true)
    }

    @Test func applyReorganizeSavesTheMove() throws {
        let id = try planID(try call("create_plan", [
            "name": "Year",
            "terms": [
                ["term": "202710", "courses": [["subject": "CS", "number": "3500"]]],
                ["term": "202730", "courses": [["subject": "CS", "number": "3000"]]],
            ],
        ]))
        let applied = try call("apply_reorganize", ["plan_id": id, "expected_revision": 1])
        let moves = applied["moves"] as? [[String: Any]] ?? []
        #expect(moves.contains { $0["number"] as? String == "3500" && $0["to_term"] as? String == "202730" })
        #expect(applied["revision"] as? Int == 2)
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
        let created = try call("create_plan", [
            "name": "Spring",
            "terms": [["term": "202730", "courses": [["subject": "CS", "number": "3000"]]]],
        ])
        _ = try call("rename_plan", ["plan_id": try planID(created), "name": "Renamed", "expected_revision": 1])
        let backup = URL(fileURLWithPath: plansURL.path + ".bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        // `UserDataStore` loads the file with `UserDataFile.read`.
        let stored = try UserDataFile.read(from: plansURL)
        let plan = try #require(stored.plans.first { $0.name == "Renamed" })
        #expect(plan.courses.map(\.key) == [CourseKey(subject: "CS", number: "3000")])
        #expect(plan.termCode == "202730")
        #expect(plan.revision == 2)
    }

    @Test func presentedEmailsStayOnInstitutionalDomains() throws {
        let mixed = Instructor(name: "Lovelace, Ada", primary: true, email: "ada@gmail.com ada@northeastern.edu")
        #expect(instructorJSON(mixed)["email"] as? String == "ada@northeastern.edu")
        let personal = Instructor(name: "Lovelace, Ada", primary: true, email: "ada@gmail.com")
        #expect(instructorJSON(personal)["email"] == nil)
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

    private func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let result = server.call(name: name, arguments: arguments)
        #expect(result["isError"] as? Bool != true, "\(name) failed: \(result)")
        return (result["structuredContent"] as? [String: Any]) ?? [:]
    }

    private func planID(_ payload: [String: Any]) throws -> String {
        try #require(payload["id"] as? String)
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
            let body = try JSONSerialization.data(withJSONObject: object)
            let header = "Content-Length: \(body.count)\r\n\r\n"
            input.fileHandleForWriting.write(Data(header.utf8))
            input.fileHandleForWriting.write(body)
        }
        func receive() throws -> [String: Any] {
            let handle = output.fileHandleForReading
            var header = Data()
            while !header.contains(Data("\r\n\r\n".utf8)) {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty { break }
                header.append(byte)
            }
            let headerText = String(data: header, encoding: .utf8) ?? ""
            var length = 0
            for line in headerText.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            }
            var body = Data()
            while body.count < length {
                let chunk = handle.readData(ofLength: length - body.count)
                if chunk.isEmpty { break }
                body.append(chunk)
            }
            return (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
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
    static func library() -> CatalogLibrary {
        CatalogLibrary(indexes: [
            "202710": CatalogIndex.build(catalog(term: "202710", courses: [
                course("CS", "3000", "Algorithms", ["NCFQ"]),
            ], sections: [
                section(crn: "1001", subject: "CS", number: "3000", day: .monday, email: "ada@northeastern.edu"),
            ])),
            "202730": CatalogIndex.build(catalog(term: "202730", courses: [
                course("CS", "3000", "Algorithms", ["NCFQ"]),
                course("CS", "3500", "OOD", ["NCFQ"]),
            ], sections: [
                section(crn: "2001", subject: "CS", number: "3000", day: .monday, email: "ada@gmail.com ada@northeastern.edu"),
                section(crn: "2002", subject: "CS", number: "3000", day: .tuesday, email: "ada@gmail.com"),
                section(crn: "2003", subject: "CS", number: "3500", day: .monday, email: "ada@neu.edu"),
                section(crn: "2004", subject: "CS", number: "3500", day: .wednesday, email: nil),
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

    private static func section(crn: String, subject: String, number: String, day: DaySet, email: String?) -> CourseSection {
        let meeting = Meeting(
            days: day, start: 9 * 60, end: 10 * 60,
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
