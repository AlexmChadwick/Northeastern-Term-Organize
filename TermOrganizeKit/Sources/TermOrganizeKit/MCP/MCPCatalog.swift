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

    static func locateCatalogDirectory(
        executable: URL? = Bundle.main.executableURL,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["TERM_ORGANIZE_CATALOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let executable, let bundled = catalogDirectoryBesideHelper(executable) {
            return bundled
        }
        var seeds = [currentDirectory, Bundle.main.bundleURL]
        if let executable {
            seeds.append(executable.deletingLastPathComponent())
        }
        let relative = "NEUClassSearch/Resources/Catalog"
        let marker = CatalogArchive.fileName(forTerm: "202710")
        for seed in seeds {
            var directory = seed
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(marker).path) {
                    return candidate
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    /// `Term Organize.app/Contents/Helpers/term-organize-mcp` keeps catalogs in
    /// `Contents/Resources` (or a folder under it).
    static func catalogDirectoryBesideHelper(_ executable: URL) -> URL? {
        let resources = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        return directoryContainingBundledCatalog(under: resources, depth: 3)
    }

    private static func directoryContainingBundledCatalog(under root: URL, depth: Int) -> URL? {
        let marker = root.appendingPathComponent(CatalogArchive.fileName(forTerm: "202710"))
        if FileManager.default.fileExists(atPath: marker.path) { return root }
        guard depth > 0 else { return nil }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            if let found = directoryContainingBundledCatalog(under: child, depth: depth - 1) { return found }
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
            description: "Move courses into terms the plan already has, when the bundled catalog for that term offers the course and prerequisites that are also in the plan stay in an earlier term. Does not add a semester and does not save.",
            properties: [
                "plan_id": stringSchema,
                "plan": ["type": "object", "properties": [
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
                ]],
            ],
            required: [],
            readOnly: true
        ) { arguments, server in
            try server.reorganizePlan(arguments)
        },
    ]
}

extension TermOrganizeMCPServer {
    func reorganizePlan(_ arguments: [String: Any]) throws -> [String: Any] {
        try requireCatalog()
        if arguments["plan"] != nil {
            let plan = arguments["plan"] as? [String: Any] ?? [:]
            let input = try planTerms(plan["terms"], library: library)
            return reorganize(input, library: library)
        }
        if arguments["plan_id"] != nil {
            let id = try planID(arguments)
            let saved = try getPlan(id: id)
            let input = try planTerms(saved["terms"], library: library)
            return reorganize(input, library: library)
        }
        throw MCPToolError(code: "invalid_argument", message: "reorganize_plan needs plan_id or plan.terms.")
    }

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

/// A course moves only into a term the plan already has. The target term must
/// offer at least one section. Prerequisites that are also in the plan must stay
/// in a strictly earlier term. Courses outside the plan do not constrain order.
/// Corequisites are ignored. Empty terms stay. No semester is added.
func reorganize(_ input: [ReorganizeTerm], library: CatalogLibrary) -> [String: Any] {
    var placement: [CourseKey: String] = [:]
    var order: [CourseKey] = []
    for term in input {
        for key in term.courses where placement[key] == nil {
            placement[key] = term.term
            order.append(key)
        }
    }
    let original = placement
    var termCodes: [String] = []
    var seenTerms = Set<String>()
    for term in input where seenTerms.insert(term.term).inserted {
        termCodes.append(term.term)
    }

    for _ in 0..<16 {
        var moved = false
        for key in order {
            let current = placement[key] ?? ""
            if termOffers(key, term: current, library: library) { continue }
            let candidates = termCodes
                .filter { $0 != current && termOffers(key, term: $0, library: library) }
                .sorted()
            for candidate in candidates {
                var trial = placement
                trial[key] = candidate
                if moveKeepsOrder(key, placement: trial, library: library) {
                    placement = trial
                    moved = true
                    break
                }
            }
        }
        if !moved { break }
    }

    var moves: [[String: Any]] = []
    var unresolved: [[String: Any]] = []
    for key in order {
        let from = original[key] ?? ""
        let to = placement[key] ?? from
        if from != to {
            moves.append([
                "subject": key.subject,
                "number": key.number,
                "from_term": from,
                "to_term": to,
                "reason": "Not offered in \(from). \(to) offers it, and prerequisites that are in this plan stay in an earlier term.",
            ])
        } else if !termOffers(key, term: to, library: library) {
            let offeredSomewhere = termCodes.contains { termOffers(key, term: $0, library: library) }
            let reason = offeredSomewhere
                ? "Moving \(key.description) would put it ahead of a prerequisite that is also in this plan."
                : "No term already in this plan offers \(key.description)."
            unresolved.append(["subject": key.subject, "number": key.number, "reason": reason])
        }
    }

    var coursesByTerm: [String: [CourseKey]] = [:]
    for key in order {
        coursesByTerm[placement[key] ?? "", default: []].append(key)
    }
    var emitted = Set<String>()
    let terms: [[String: Any]] = input.map { term in
        let courses: [[String: Any]]
        if emitted.insert(term.term).inserted {
            courses = (coursesByTerm[term.term] ?? []).map { ["subject": $0.subject, "number": $0.number] }
        } else {
            courses = []
        }
        return ["term": term.term, "courses": courses]
    }
    return ["moves": moves, "unresolved": unresolved, "plan": ["terms": terms]]
}

func termOffers(_ key: CourseKey, term: String, library: CatalogLibrary) -> Bool {
    guard let index = library.index(for: term) else { return false }
    return !index.sections(for: key).isEmpty
}

func bundledPrerequisite(_ key: CourseKey, library: CatalogLibrary) -> Requisite? {
    for code in CatalogLibrary.allowedTermCodes {
        guard let course = library.index(for: code)?.course(key), course.detailsLoaded else { continue }
        return course.prereqs
    }
    return nil
}

/// `moved` keeps its own prerequisites in an earlier term, and every other course
/// in the plan that depends on it still has that prerequisite earlier.
func moveKeepsOrder(_ moved: CourseKey, placement: [CourseKey: String], library: CatalogLibrary) -> Bool {
    if let requisite = bundledPrerequisite(moved, library: library),
       !prerequisiteHolds(requisite, courseTerm: placement[moved] ?? "", placement: placement) {
        return false
    }
    for (other, term) in placement where other != moved {
        guard let requisite = bundledPrerequisite(other, library: library),
              requisiteReferences(requisite, moved) else { continue }
        if !prerequisiteHolds(requisite, courseTerm: term, placement: placement) { return false }
    }
    return true
}

func prerequisiteHolds(_ requisite: Requisite, courseTerm: String, placement: [CourseKey: String]) -> Bool {
    switch requisite {
    case .course(let key):
        guard let earlier = placement[key] else { return true }
        return earlier < courseTerm
    case .test:
        return true
    case .and(let items):
        return items.allSatisfy { prerequisiteHolds($0, courseTerm: courseTerm, placement: placement) }
    case .or(let items):
        return items.isEmpty || items.contains { prerequisiteHolds($0, courseTerm: courseTerm, placement: placement) }
    }
}

func requisiteReferences(_ requisite: Requisite, _ key: CourseKey) -> Bool {
    switch requisite {
    case .course(let course): return course == key
    case .test: return false
    case .and(let items), .or(let items): return items.contains { requisiteReferences($0, key) }
    }
}
