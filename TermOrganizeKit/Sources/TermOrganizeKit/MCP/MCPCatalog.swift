//
//  MCPCatalog.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// The two catalogs shipped with the app. Downloaded terms are ignored.
struct CatalogLibrary {
    static let allowedTermCodes = ["202730", "202710"]

    var indexes: [String: CatalogIndex]

    init(indexes: [String: CatalogIndex]) {
        self.indexes = indexes
    }

    func index(for term: String) -> CatalogIndex? { indexes[term] }

    static func loadBundled() -> CatalogLibrary {
        guard let directory = locateCatalogDirectory() else { return CatalogLibrary(indexes: [:]) }
        var indexes: [String: CatalogIndex] = [:]
        for code in allowedTermCodes {
            let url = directory.appendingPathComponent(CatalogArchive.fileName(forTerm: code))
            guard let catalog = try? CatalogArchive.read(from: url) else { continue }
            indexes[code] = CatalogIndex.build(catalog)
        }
        return CatalogLibrary(indexes: indexes)
    }

    static func locateCatalogDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["TERM_ORGANIZE_CATALOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var seeds = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        seeds.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL {
            seeds.append(executable.deletingLastPathComponent())
        }
        let relative = "NEUClassSearch/Resources/Catalog"
        for seed in seeds {
            var directory = seed
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent(relative)
                let marker = candidate.appendingPathComponent(CatalogArchive.fileName(forTerm: "202710"))
                if FileManager.default.fileExists(atPath: marker.path) { return candidate }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }
}

extension MCPTool {
    static let stringSchema: [String: Any] = ["type": "string"]
    static let intSchema: [String: Any] = ["type": "integer"]

    static let catalogTools: [MCPTool] = [
        MCPTool(
            name: "list_terms",
            description: "List the bundled terms (code and name). Unofficial Northeastern catalog data.",
            properties: [:],
            required: [],
            readOnly: true
        ) { _, server in
            try server.requireCatalog()
            let terms = CatalogLibrary.allowedTermCodes.compactMap { code -> [String: Any]? in
                guard let index = server.library.index(for: code) else { return nil }
                return ["term": code, "name": index.term.shortName]
            }
            return ["terms": terms]
        },
        MCPTool(
            name: "search_courses",
            description: "Search one bundled term. Returns matching courses with title, credits, and attributes.",
            properties: [
                "term": stringSchema,
                "query": stringSchema,
                "subject": stringSchema,
                "number": stringSchema,
                "attribute": stringSchema,
                "limit": intSchema,
            ],
            required: ["term"],
            readOnly: true
        ) { arguments, server in
            let index = try server.catalog(arguments)
            let query = stringArg(arguments, "query") ?? ""
            let subject = stringArg(arguments, "subject")?.uppercased()
            let number = stringArg(arguments, "number")?.uppercased()
            let attribute = stringArg(arguments, "attribute")?.uppercased()
            let limit = min(100, max(1, intArg(arguments, "limit") ?? 25))
            let pool: [Course]
            if query.isEmpty {
                pool = index.courses.sorted { $0.key < $1.key }
            } else {
                pool = SearchEngine.search(SearchQuery(text: query), in: index).results.map(\.course)
            }
            let matched = pool.filter { course in
                if let subject, course.subject.uppercased() != subject { return false }
                if let number, course.number.uppercased() != number { return false }
                if let attribute {
                    let codes = course.attributes.map { $0.uppercased() }
                    if !codes.contains(attribute) { return false }
                }
                return true
            }
            return [
                "term": index.term.code,
                "courses": matched.prefix(limit).map { courseJSON($0) },
            ]
        },
        MCPTool(
            name: "get_course",
            description: "Course details and every section: CRN, days and times, location, instructor names, and seats when the catalog has them.",
            properties: [
                "term": stringSchema,
                "subject": stringSchema,
                "number": stringSchema,
            ],
            required: ["term", "subject", "number"],
            readOnly: true
        ) { arguments, server in
            let index = try server.catalog(arguments)
            let key = try courseKey(arguments)
            guard let course = index.course(key) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(index.term.code).")
            }
            var payload = courseJSON(course)
            payload["term"] = index.term.code
            payload["description"] = course.description
            payload["sections"] = index.sections(for: key).map { sectionJSON($0) }
            return payload
        },
        MCPTool(
            name: "check_schedule",
            description: "Report time clashes among CRNs in one term, and any CRN the bundled catalog does not contain.",
            properties: [
                "term": stringSchema,
                "crns": ["type": "array", "items": stringSchema],
            ],
            required: ["term", "crns"],
            readOnly: true
        ) { arguments, server in
            let index = try server.catalog(arguments)
            let crns = stringList(arguments["crns"])
            var unknown: [String] = []
            var sections: [CourseSection] = []
            for crn in crns {
                if let section = index.section(crn: crn) {
                    sections.append(section)
                } else {
                    unknown.append(crn)
                }
            }
            var clashes: [[String: Any]] = []
            for left in 0..<sections.count {
                for right in (left + 1)..<sections.count where sections[left].conflicts(with: sections[right]) {
                    clashes.append([
                        "crn": sections[left].crn,
                        "other": sections[right].crn,
                        "reason": "Overlapping meeting",
                    ])
                }
            }
            return ["term": index.term.code, "clashes": clashes, "unknown_crns": unknown]
        },
        MCPTool(
            name: "suggest_schedule",
            description: "Conflict-free section combinations for the requested courses, best first. Constraints can keep classes after a time, before a time, or off certain days.",
            properties: [
                "term": stringSchema,
                "courses": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["subject": stringSchema, "number": stringSchema],
                    "required": ["subject", "number"],
                ]],
                "constraints": ["type": "object", "properties": [
                    "no_classes_before": stringSchema,
                    "no_classes_after": stringSchema,
                    "days_off": ["type": "array", "items": stringSchema],
                ]],
            ],
            required: ["term", "courses"],
            readOnly: true
        ) { arguments, server in
            let index = try server.catalog(arguments)
            let requested = courseList(arguments["courses"])
            guard !requested.isEmpty else {
                throw MCPToolError(code: "missing_courses", message: "courses must list at least one subject and number.")
            }
            var inputs: [ScheduleCourseInput] = []
            for key in requested {
                guard index.course(key) != nil else {
                    throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(index.term.code).")
                }
                let sections = index.sections(for: key)
                guard !sections.isEmpty else {
                    throw MCPToolError(code: "not_offered", message: "\(key.description) has no sections in term \(index.term.code).")
                }
                let course = index.course(key)
                inputs.append(ScheduleCourseInput(
                    key: key,
                    isRequired: true,
                    sections: sections,
                    minCredits: Int(course?.minCredits ?? 0),
                    maxCredits: Int(course?.maxCredits ?? 0)
                ))
            }
            var filters = ScheduleFilters()
            let constraints = arguments["constraints"] as? [String: Any] ?? [:]
            if let before = stringArg(constraints, "no_classes_before") {
                filters.earliestStart = try minutes(before)
            }
            if let after = stringArg(constraints, "no_classes_after") {
                filters.latestEnd = try minutes(after)
            }
            filters.freeDays = try daySet(stringList(constraints["days_off"]))
            var limits = ScheduleGenerator.Limits.standard
            limits.maxResults = 8
            let generated = ScheduleGenerator.generate(courses: inputs, filters: filters, sort: .best, limits: limits)
            let schedules: [[String: Any]] = generated.schedules.map { schedule in
                [
                    "crns": schedule.crns,
                    "score": schedule.score,
                    "sections": schedule.sections.map { sectionJSON($0) },
                ]
            }
            return ["term": index.term.code, "schedules": schedules]
        },
        MCPTool(
            name: "reorganize_plan",
            description: "Reorder a whole plan of terms and courses the way the app does when a semester cannot be scheduled: move a course to a later term where the bundled catalogs say it is taught, without breaking prerequisites. Nothing is saved.",
            properties: [
                "terms": ["type": "array", "items": [
                    "type": "object",
                    "properties": [
                        "term": stringSchema,
                        "courses": ["type": "array", "items": [
                            "type": "object",
                            "properties": ["subject": stringSchema, "number": stringSchema],
                            "required": ["subject", "number"],
                        ]],
                    ],
                    "required": ["term", "courses"],
                ]],
            ],
            required: ["terms"],
            readOnly: true
        ) { arguments, server in
            try server.requireCatalog()
            let input = try planTerms(arguments["terms"], library: server.library)
            return try reorganize(input, library: server.library)
        },
    ]
}

extension TermOrganizeMCPServer {
    func requireCatalog() throws {
        if library.indexes.isEmpty {
            throw MCPToolError(code: "catalog_unavailable", message: "The bundled Fall 2026 and Spring 2027 catalogs were not found.")
        }
    }

    func catalog(_ arguments: [String: Any]) throws -> CatalogIndex {
        try requireCatalog()
        let code = stringArg(arguments, "term") ?? ""
        guard CatalogLibrary.allowedTermCodes.contains(code) else {
            throw MCPToolError(code: "unknown_term", message: "Term \(code) is not a bundled catalog. Use 202710 or 202730.")
        }
        guard let index = library.index(for: code) else {
            throw MCPToolError(code: "catalog_unavailable", message: "The bundled catalog for \(code) is not available.")
        }
        return index
    }
}

func courseJSON(_ course: Course) -> [String: Any] {
    [
        "subject": course.subject,
        "number": course.number,
        "title": course.title,
        "credits": ["min": course.minCredits, "max": course.maxCredits],
        "attributes": course.attributes,
    ]
}

func sectionJSON(_ section: CourseSection) -> [String: Any] {
    var payload: [String: Any] = [
        "crn": section.crn,
        "section": section.sectionNumber,
        "type": section.classType,
        "meetings": section.weeklyMeetings.map { meetingJSON($0) },
        "instructors": (section.instructors ?? []).map { instructorJSON($0) },
    ]
    if section.seatCapacity > 0 || section.seatsRemaining > 0 {
        payload["seats"] = ["remaining": section.seatsRemaining, "capacity": section.seatCapacity]
    }
    return payload
}

func meetingJSON(_ meeting: Meeting) -> [String: Any] {
    var payload: [String: Any] = [
        "days": dayNames(meeting.days),
        "location": meeting.locationLabel,
    ]
    if let start = meeting.start { payload["start"] = clock(start) }
    if let end = meeting.end { payload["end"] = clock(end) }
    return payload
}

/// Keeps an address only when its domain is exactly northeastern.edu or neu.edu.
func instructorJSON(_ instructor: Instructor) -> [String: Any] {
    var payload: [String: Any] = ["name": instructor.displayName]
    if let email = InstructorEmail.institutional(instructor.email) {
        payload["email"] = email
    }
    return payload
}

func dayNames(_ days: DaySet) -> [String] {
    let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    return names.indices.compactMap { days.contains(day: $0) ? names[$0] : nil }
}

func clock(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

func minutes(_ text: String) throws -> Int {
    let parts = text.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0..<24).contains(hour), (0..<60).contains(minute) else {
        throw MCPToolError(code: "bad_time", message: "Times use 24-hour HH:MM, for example 09:30.")
    }
    return hour * 60 + minute
}

func daySet(_ names: [String]) throws -> DaySet {
    var set = DaySet()
    let table: [String: DaySet] = [
        "sunday": .sunday, "monday": .monday, "tuesday": .tuesday, "wednesday": .wednesday,
        "thursday": .thursday, "friday": .friday, "saturday": .saturday,
    ]
    for name in names {
        guard let day = table[name.lowercased()] else {
            throw MCPToolError(code: "bad_day", message: "Unknown day \(name). Use sunday through saturday.")
        }
        set.formUnion(day)
    }
    return set
}

func courseKey(_ arguments: [String: Any]) throws -> CourseKey {
    let subject = stringArg(arguments, "subject")?.uppercased() ?? ""
    let number = stringArg(arguments, "number")?.uppercased() ?? ""
    guard !subject.isEmpty, !number.isEmpty else {
        throw MCPToolError(code: "bad_course", message: "subject and number are required.")
    }
    return CourseKey(subject: subject, number: number)
}

func courseList(_ raw: Any?) -> [CourseKey] {
    guard let rows = raw as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        guard let subject = stringArg(row, "subject")?.uppercased(),
              let number = stringArg(row, "number")?.uppercased(),
              !subject.isEmpty, !number.isEmpty else { return nil }
        return CourseKey(subject: subject, number: number)
    }
}

func stringList(_ raw: Any?) -> [String] {
    if let values = raw as? [String] { return values }
    if let values = raw as? [Any] { return values.compactMap { $0 as? String } }
    return []
}

struct ReorganizeTerm {
    var term: String
    var courses: [CourseKey]
}

func planTerms(_ raw: Any?, library: CatalogLibrary) throws -> [ReorganizeTerm] {
    guard let rows = raw as? [[String: Any]], !rows.isEmpty else {
        throw MCPToolError(code: "bad_plan", message: "terms must list at least one term.")
    }
    return try rows.map { row in
        let code = stringArg(row, "term") ?? ""
        guard CatalogLibrary.allowedTermCodes.contains(code) else {
            throw MCPToolError(code: "unknown_term", message: "Term \(code) is not a bundled catalog. Use 202710 or 202730.")
        }
        guard library.index(for: code) != nil else {
            throw MCPToolError(code: "catalog_unavailable", message: "The bundled catalog for \(code) is not available.")
        }
        return ReorganizeTerm(term: code, courses: courseList(row["courses"]))
    }
}

func reorganize(_ input: [ReorganizeTerm], library: CatalogLibrary) throws -> [String: Any] {
    var plan = DegreePlan(name: "Plan")
    for item in input {
        let banner = Term(code: item.term, bannerDescription: "")
        var semester = DegreePlanTerm(season: PlanSeason(termSeason: banner.season), year: banner.calendarYear)
        for key in item.courses {
            let course = library.index(for: item.term)?.course(key)
            semester.courses.append(DegreePlanCourse(
                key: key,
                title: course?.title ?? key.description,
                credits: course?.maxCredits ?? 4
            ))
        }
        plan.terms.append(semester)
    }
    plan.sortTerms()
    let original = termMap(of: plan, library: library)

    var offered: [CourseKey: Set<String>] = [:]
    for (code, index) in library.indexes {
        for course in index.courses where !index.sections(for: course.key).isEmpty {
            offered[course.key, default: []].insert(code)
        }
    }
    let history = OfferingHistory(checkedTerms: library.indexes.keys.sorted(by: >), offered: offered, checkedKeys: nil)
    func prerequisites(_ key: CourseKey) -> Requisite?? {
        for index in library.indexes.values {
            if let course = index.course(key), course.detailsLoaded { return .some(course.prereqs) }
        }
        return nil
    }

    var notes: [String] = []
    for _ in 0..<8 {
        plan.sortTerms()
        var applied = false
        for semester in plan.terms {
            guard let code = bannerCode(season: semester.season, year: semester.year),
                  let index = library.index(for: code) else { continue }
            let blocking = semester.courses.compactMap(\.key).filter { index.sections(for: $0).isEmpty }
            guard !blocking.isEmpty else { continue }
            let suggestions = DegreePlanReordering.suggestions(
                for: plan,
                termID: semester.id,
                blocking: blocking,
                history: history,
                prerequisites: prerequisites,
                equivalences: .none
            )
            guard let best = suggestions.first else {
                notes.append("\(listKeys(blocking)) cannot move out of \(code) with the bundled catalogs.")
                continue
            }
            DegreePlanReordering.apply(best, to: &plan)
            notes.append(best.title)
            applied = true
            break
        }
        if !applied { break }
    }

    let updated = termMap(of: plan, library: library)
    var moves: [[String: Any]] = []
    let courses = Set(original.keys).union(updated.keys)
    for key in courses.sorted(by: { $0.description < $1.description }) {
        let from = original[key] ?? ""
        let to = updated[key] ?? ""
        if from != to {
            moves.append(["subject": key.subject, "number": key.number, "from_term": from, "to_term": to])
        }
    }
    let terms = updatedTerms(plan, library: library)
    return ["terms": terms, "moves": moves, "notes": notes]
}

func termMap(of plan: DegreePlan, library: CatalogLibrary) -> [CourseKey: String] {
    var map: [CourseKey: String] = [:]
    for semester in plan.terms {
        let code = bannerCode(season: semester.season, year: semester.year) ?? ""
        for key in semester.courses.compactMap(\.key) {
            map[key] = code
        }
    }
    _ = library
    return map
}

func updatedTerms(_ plan: DegreePlan, library: CatalogLibrary) -> [[String: Any]] {
    plan.terms.compactMap { semester in
        guard let code = bannerCode(season: semester.season, year: semester.year) else { return nil }
        let courses: [[String: Any]] = semester.courses.compactMap { course in
            guard let key = course.key else { return nil }
            return ["subject": key.subject, "number": key.number]
        }
        return ["term": code, "courses": courses]
    }
}

func bannerCode(season: PlanSeason, year: Int) -> String? {
    let code: String
    switch season {
    case .fall: code = String(format: "%d10", year + 1)
    case .winter: code = String(format: "%d20", year)
    case .spring: code = String(format: "%d30", year)
    case .summerA: code = String(format: "%d40", year)
    case .summerFull: code = String(format: "%d50", year)
    case .summerB: code = String(format: "%d60", year)
    }
    return CatalogLibrary.allowedTermCodes.contains(code) ? code : code
}

func listKeys(_ keys: [CourseKey]) -> String {
    keys.map(\.description).joined(separator: ", ")
}
