//
//  MCPPlans.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

extension MCPTool {
    static let planTools: [MCPTool] = [
        MCPTool(name: "list_plans", description: "List saved degree plans: id, name, terms as {term, name} objects, updated_at, and revision. Schedules are returned separately and are not what the write tools edit.", properties: [:], required: [], readOnly: true) { _, server in
            try server.listPlans()
        },
        MCPTool(name: "get_plan", description: "One saved degree plan, with terms, courses, chosen sections, clashes, and courses the bundled catalog does not offer in that term.", properties: ["plan_id": stringSchema], required: ["plan_id"], readOnly: true) { arguments, server in
            try server.getPlan(id: try planID(arguments))
        },
        MCPTool(name: "create_plan", description: "Create a saved degree plan in the app's UserData.json. terms is an optional list of term strings such as 202730. Courses are added with add_course.", properties: [
            "name": stringSchema,
            "terms": ["type": "array", "items": stringSchema],
        ], required: ["name"], readOnly: false) { arguments, server in
            try server.createPlan(arguments)
        },
        MCPTool(name: "rename_plan", description: "Rename a saved plan if expected_revision still matches.", properties: [
            "plan_id": stringSchema, "name": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "name", "expected_revision"], readOnly: false) { arguments, server in
            try server.renamePlan(arguments)
        },
        MCPTool(name: "add_course", description: "Add a catalog course to a term of a saved plan. The same subject and number can be added again only when crn is set and differs from every row already stored. Without crn, a number already in the term is left unchanged. The same crn twice is not added.", properties: [
            "plan_id": stringSchema, "term": stringSchema, "subject": stringSchema, "number": stringSchema,
            "crn": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "term", "subject", "number", "expected_revision"], readOnly: false) { arguments, server in
            try server.addCourse(arguments)
        },
        MCPTool(name: "remove_course", description: "Remove a course from a term of a saved plan.", properties: [
            "plan_id": stringSchema, "term": stringSchema, "subject": stringSchema, "number": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "term", "subject", "number", "expected_revision"], readOnly: false, destructive: true) { arguments, server in
            try server.removeCourse(arguments)
        },
        MCPTool(name: "move_course", description: "Move a course from one term of a saved plan to another.", properties: [
            "plan_id": stringSchema, "subject": stringSchema, "number": stringSchema,
            "from_term": stringSchema, "to_term": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "subject", "number", "from_term", "to_term", "expected_revision"], readOnly: false) { arguments, server in
            try server.moveCourse(arguments)
        },
        MCPTool(name: "set_section", description: "Choose the CRN for one row of a course already in a term. When that subject and number appears more than once, from_crn names the row to change. A CRN already stored on another row is refused, and other rows keep their CRNs.", properties: [
            "plan_id": stringSchema, "term": stringSchema, "subject": stringSchema, "number": stringSchema,
            "crn": stringSchema, "from_crn": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "term", "subject", "number", "crn", "expected_revision"], readOnly: false) { arguments, server in
            try server.setSection(arguments)
        },
        MCPTool(name: "apply_reorganize", description: "Run reorganize_plan on a saved plan and write the result. Returns the moves and any unresolved courses.", properties: [
            "plan_id": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "expected_revision"], readOnly: false, destructive: true) { arguments, server in
            try server.applyReorganize(arguments)
        },
        MCPTool(name: "delete_plan", description: "Delete a saved plan. Refuses unless confirm is true.", properties: [
            "plan_id": stringSchema, "expected_revision": intSchema, "confirm": ["type": "boolean"],
        ], required: ["plan_id", "expected_revision", "confirm"], readOnly: false, destructive: true) { arguments, server in
            try server.deletePlan(arguments)
        },
    ]
}

extension TermOrganizeMCPServer {
    func listPlans() throws -> [String: Any] {
        let data = try storedPlans()
        let plans = data.degreePlans.sorted { $0.updatedAt > $1.updatedAt }.map { degreeSummary($0) }
        let schedules = PlanGroup.groups(in: data.plans).map { $0.summary() }
        return ["plans": plans, "schedules": schedules]
    }

    func getPlan(id: UUID) throws -> [String: Any] {
        let data = try storedPlans()
        guard let plan = data.degreePlans.first(where: { $0.id == id }) else {
            throw MCPToolError(code: "unknown_plan", message: "No saved degree plan \(id.uuidString).")
        }
        return planPayload(plan)
    }

    /// A missing file is an empty document. A file that exists but cannot be read
    /// is a storage error, including permission failures, malformed JSON, and a
    /// newer file version. It is never reported as zero plans.
    func storedPlans() throws -> UserData {
        try ensurePlansStorage()
        switch UserDataFile.inspect(at: plansURL) {
        case .missing:
            return UserData()
        case .ready(let data):
            return data
        case .unreadable(let path, let reason):
            let detail = reason.isEmpty ? "unreadable" : reason
            throw MCPToolError(code: "storage_error", message: "Cannot read \(path): \(detail)")
        }
    }

    func createPlan(_ arguments: [String: Any]) throws -> [String: Any] {
        let name = stringArg(arguments, "name") ?? ""
        guard !name.isEmpty else { throw MCPToolError(code: "bad_name", message: "name is required.") }
        let requested = try termStringList(arguments["terms"])
        var created: DegreePlan?
        try modifyPlans { data in
            let codes = requested.isEmpty
                ? [CatalogLibrary.allowedTermCodes.first { library.index(for: $0) != nil } ?? "202730"]
                : requested
            var plan = DegreePlan(name: name)
            plan.revision = 1
            plan.isPrimary = data.degreePlans.isEmpty
            for code in codes {
                try validateTerm(code)
                guard let term = degreeTerm(for: code) else {
                    throw MCPToolError(code: "unknown_term", message: "Term \(code) is not a bundled catalog. Use 202710 or 202730.")
                }
                plan.terms.append(term)
            }
            plan.sortTerms()
            data.degreePlans.append(plan)
            created = plan
        }
        return planPayload(created!)
    }

    func renamePlan(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let name = stringArg(arguments, "name") ?? ""
        guard !name.isEmpty else { throw MCPToolError(code: "bad_name", message: "name is required.") }
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { plan in
            plan.name = name
        }
    }

    func addCourse(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let term = try termCode(arguments, key: "term")
        let key = try courseKey(arguments)
        let crn = stringArg(arguments, "crn")
        try validateCourse(key, term: term, crn: crn)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { plan in
            let course = catalogCourse(key, crn: crn)
            if let index = plan.terms.firstIndex(where: { bannerCode($0) == term }) {
                plan.terms[index].include(course: course)
            } else {
                guard var created = degreeTerm(for: term) else {
                    throw MCPToolError(code: "unknown_term", message: "Term \(term) is not a bundled catalog. Use 202710 or 202730.")
                }
                created.include(course: course)
                plan.terms.append(created)
            }
        }
    }

    func removeCourse(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let term = try termCode(arguments, key: "term")
        let key = try courseKey(arguments)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { plan in
            guard let index = plan.terms.firstIndex(where: { bannerCode($0) == term && $0.courses.contains { $0.key == key } }) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(term) of this plan.")
            }
            plan.terms[index].courses.removeAll { $0.key == key }
            if plan.terms[index].courses.isEmpty && plan.terms.count > 1 {
                plan.terms.remove(at: index)
            }
        }
    }

    func moveCourse(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let key = try courseKey(arguments)
        let from = try termCode(arguments, key: "from_term")
        let to = try termCode(arguments, key: "to_term")
        try validateCourse(key, term: to, crn: nil)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { plan in
            guard let source = plan.terms.firstIndex(where: { bannerCode($0) == from && $0.courses.contains { $0.key == key } }) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(from) of this plan.")
            }
            let moving = plan.terms[source].courses.filter { $0.key == key }
            plan.terms[source].courses.removeAll { $0.key == key }
            if plan.terms[source].courses.isEmpty && from != to {
                plan.terms.remove(at: source)
            }
            if let destination = plan.terms.firstIndex(where: { bannerCode($0) == to }) {
                for course in moving {
                    let kept = course.crn.flatMap { crn in
                        library.index(for: to)?.section(crn: crn)?.courseKey == key ? crn : nil
                    }
                    var row = course
                    row.crn = kept
                    plan.terms[destination].include(course: row)
                }
            } else if var created = degreeTerm(for: to) {
                for course in moving {
                    let kept = course.crn.flatMap { crn in
                        library.index(for: to)?.section(crn: crn)?.courseKey == key ? crn : nil
                    }
                    var row = course
                    row.crn = kept
                    created.include(course: row)
                }
                plan.terms.append(created)
            }
        }
    }

    func setSection(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let term = try termCode(arguments, key: "term")
        let key = try courseKey(arguments)
        let crn = stringArg(arguments, "crn") ?? ""
        let fromCRN = stringArg(arguments, "from_crn")
        try validateCourse(key, term: term, crn: crn)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { plan in
            guard let index = plan.terms.firstIndex(where: { bannerCode($0) == term && $0.courses.contains { $0.key == key } }) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(term) of this plan.")
            }
            try assignSection(crn, from: fromCRN, for: key, in: &plan.terms[index])
        }
    }

    func applyReorganize(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let expected = try expectedRevision(arguments)
        let before = try getPlan(id: id)
        let rows = before["terms"] as? [[String: Any]] ?? []
        let bundled = rows.filter { CatalogLibrary.allowedTermCodes.contains(stringArg($0, "term") ?? "") }
        let input = try planTerms(bundled, library: library)
        let reorganized = reorganize(input, library: library)
        let moves = reorganized["moves"] as? [[String: Any]] ?? []
        let unresolved = reorganized["unresolved"] as? [[String: Any]] ?? []
        let planObject = reorganized["plan"] as? [String: Any] ?? [:]
        let result = try mutate(id: id, expected: expected) { plan in
            var rebuilt: [DegreePlanTerm] = []
            for row in planObject["terms"] as? [[String: Any]] ?? [] {
                let code = stringArg(row, "term") ?? ""
                let entries = courseEntries(row["courses"])
                var term = plan.terms.first { bannerCode($0) == code } ?? degreeTerm(for: code) ?? DegreePlanTerm(season: .spring, year: 2027)
                let existing = term.courses
                var used = Set<Int>()
                var courses: [DegreePlanCourse] = []
                for entry in entries {
                    let match = existing.indices.first { index in
                        guard !used.contains(index), existing[index].key == entry.key else { return false }
                        if let crn = entry.crn { return existing[index].crn == crn }
                        return existing[index].crn?.isEmpty != false
                    }
                    var course: DegreePlanCourse
                    if let match {
                        used.insert(match)
                        course = existing[match]
                    } else {
                        course = catalogCourse(entry.key, crn: entry.crn)
                    }
                    course.crn = entry.crn
                    courses.append(course)
                }
                term.courses = courses
                rebuilt.append(term)
            }
            // Semesters outside the bundled catalogs stay where the degree plan put them.
            for term in plan.terms where !CatalogLibrary.allowedTermCodes.contains(bannerCode(term)) {
                rebuilt.append(term)
            }
            if !rebuilt.isEmpty { plan.terms = rebuilt }
        }
        var payload = result
        payload["moves"] = moves
        payload["unresolved"] = unresolved
        return payload
    }

    func deletePlan(_ arguments: [String: Any]) throws -> [String: Any] {
        guard boolArg(arguments, "confirm") == true else {
            throw MCPToolError(code: "confirm_required", message: "delete_plan refuses unless confirm is true.")
        }
        let id = try planID(arguments)
        let expected = try expectedRevision(arguments)
        var removed = false
        try modifyPlans { data in
            guard let index = data.degreePlans.firstIndex(where: { $0.id == id }) else {
                throw MCPToolError(code: "unknown_plan", message: "No saved degree plan \(id.uuidString).")
            }
            let current = displayedRevision(data.degreePlans[index].revision)
            guard current == expected else {
                throw MCPToolError(
                    code: "revision_conflict",
                    message: "The plan changed. expected_revision was \(expected) and the saved revision is \(current).",
                    extra: ["revision": current]
                )
            }
            data.degreePlans.remove(at: index)
            removed = true
        }
        return ["deleted": removed, "plan_id": id.uuidString]
    }

    /// The helper never opens the app container. A missing group file is empty
    /// only when that container file is absent too. Otherwise the app still has
    /// to copy it.
    private func ensurePlansStorage() throws {
        if PlanFileLocation.blockedOnAppMigration(groupFile: plansURL, legacyFile: legacyPlanURL) {
            throw MCPToolError(code: "storage_error", message: PlanFileLocation.pendingMoveMessage)
        }
    }

    private func modifyPlans(_ change: (inout UserData) throws -> Void) throws {
        try ensurePlansStorage()
        try UserDataFile.modify(at: plansURL, change)
    }

    private func mutate(id: UUID, expected: Int, _ change: (inout DegreePlan) throws -> Void) throws -> [String: Any] {
        var updated: DegreePlan?
        try modifyPlans { data in
            guard let index = data.degreePlans.firstIndex(where: { $0.id == id }) else {
                throw MCPToolError(code: "unknown_plan", message: "No saved degree plan \(id.uuidString).")
            }
            let current = displayedRevision(data.degreePlans[index].revision)
            guard current == expected else {
                throw MCPToolError(
                    code: "revision_conflict",
                    message: "The plan changed. expected_revision was \(expected) and the saved revision is \(current).",
                    extra: ["revision": current]
                )
            }
            try change(&data.degreePlans[index])
            data.degreePlans[index].revision = expected + 1
            data.degreePlans[index].updatedAt = Date()
            data.degreePlans[index].sortTerms()
            updated = data.degreePlans[index]
        }
        return planPayload(updated!)
    }

    private func planPayload(_ plan: DegreePlan) -> [String: Any] {
        var terms: [[String: Any]] = []
        var clashes: [[String: Any]] = []
        var notOffered: [[String: Any]] = []
        for term in plan.terms.sorted(by: { $0.sortKey < $1.sortKey }) {
            let code = bannerCode(term)
            let index = library.index(for: code)
            var courses: [[String: Any]] = []
            var chosen: [CourseSection] = []
            for course in term.courses {
                guard let key = course.key else {
                    courses.append(["label": course.label, "title": course.title, "credits": course.credits])
                    continue
                }
                var row: [String: Any] = ["subject": key.subject, "number": key.number, "title": course.title, "credits": course.credits]
                let sections = index?.sections(for: key) ?? []
                if sections.isEmpty {
                    notOffered.append(["term": code, "subject": key.subject, "number": key.number])
                }
                let own: [CourseSection]
                if let pin = course.crn, !pin.isEmpty {
                    row["crn"] = pin
                    own = sections.filter { $0.crn == pin }
                } else {
                    own = []
                }
                row["sections"] = own.map { sectionJSON($0) }
                chosen.append(contentsOf: own)
                courses.append(row)
            }
            for left in 0..<chosen.count {
                for right in (left + 1)..<chosen.count where chosen[left].conflicts(with: chosen[right]) {
                    clashes.append(["term": code, "crn": chosen[left].crn, "other": chosen[right].crn, "reason": "Overlapping meeting"])
                }
            }
            var termRow = termObject(code: code, name: term.name)
            termRow["courses"] = courses
            terms.append(termRow)
        }
        var payload = degreeSummary(plan)
        payload["terms"] = terms
        payload["validation"] = ["clashes": clashes, "not_offered": notOffered]
        return payload
    }

    private func degreeSummary(_ plan: DegreePlan) -> [String: Any] {
        [
            "id": plan.id.uuidString,
            "name": plan.name,
            "terms": plan.terms.sorted { $0.sortKey < $1.sortKey }.map { termObject(code: bannerCode($0), name: $0.name) },
            "updated_at": iso8601(plan.updatedAt),
            "revision": displayedRevision(plan.revision),
        ]
    }

    private func catalogCourse(_ key: CourseKey, crn: String?) -> DegreePlanCourse {
        let listed = library.indexes.values.compactMap { $0.course(key) }.first
        return DegreePlanCourse(key: key, title: listed?.title ?? key.description, credits: listed?.maxCredits ?? 0, crn: crn)
    }

    private func validateTerm(_ code: String) throws {
        guard CatalogLibrary.allowedTermCodes.contains(code), library.index(for: code) != nil else {
            throw MCPToolError(code: "unknown_term", message: "Term \(code) is not a bundled catalog. Use 202710 or 202730.")
        }
    }

    private func termCode(_ arguments: [String: Any], key: String) throws -> String {
        let code = stringArg(arguments, key) ?? ""
        try validateTerm(code)
        return code
    }

    private func validateCourse(_ key: CourseKey, term: String, crn: String?) throws {
        try validateTerm(term)
        let known = library.indexes.values.contains { $0.course(key) != nil }
        guard known else {
            throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in the bundled catalogs.")
        }
        if let crn {
            guard let section = library.index(for: term)?.section(crn: crn) else {
                throw MCPToolError(code: "unknown_crn", message: "CRN \(crn) is not in term \(term).")
            }
            guard section.courseKey == key else {
                throw MCPToolError(code: "unknown_crn", message: "CRN \(crn) is not a section of \(key.description).")
            }
        }
    }

    /// Replaces the CRN on one row. Other rows of the same number keep theirs.
    /// `from` is required when more than one row of `key` is already in the term.
    private func assignSection(_ crn: String, from: String?, for key: CourseKey, in term: inout DegreePlanTerm) throws {
        let matches = term.courses.indices.filter { term.courses[$0].key == key }
        guard !matches.isEmpty else {
            throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in this term of the plan.")
        }
        let target: Int
        if let from {
            guard let index = matches.first(where: { term.courses[$0].crn == from }) else {
                throw MCPToolError(code: "unknown_crn", message: "CRN \(from) is not a chosen section of \(key.description) in this term.")
            }
            target = index
        } else if matches.count == 1 {
            target = matches[0]
        } else {
            throw MCPToolError(code: "invalid_argument", message: "\(key.description) is in this term more than once. Pass from_crn to name the section to replace.")
        }
        if term.courses.contains(where: { $0.crn == crn && term.courses[target].crn != crn }) {
            throw MCPToolError(code: "invalid_argument", message: "CRN \(crn) is already chosen for another \(key.description) in this term.")
        }
        if term.courses[target].crn == crn { return }
        term.courses[target].crn = crn
    }
}

struct PlanGroup {
    var id: UUID
    var plans: [SchedulePlan]

    var revision: Int { plans.map { displayedRevision($0.revision) }.max() ?? 1 }
    var updated: Date { plans.map(\.updatedAt).max() ?? .distantPast }

    func summary() -> [String: Any] {
        let terms = plans.map { termObject(code: $0.termCode, name: termName(for: $0.termCode)) }
            .sorted { ($0["term"] as? String ?? "") < ($1["term"] as? String ?? "") }
        return [
            "id": id.uuidString,
            "name": plans.first?.name ?? "",
            "terms": terms,
            "updated_at": iso8601(updated),
            "revision": revision,
        ]
    }

    static func groups(in plans: [SchedulePlan]) -> [PlanGroup] {
        var byFolder: [UUID: [SchedulePlan]] = [:]
        var singles: [PlanGroup] = []
        for plan in plans {
            if let folder = plan.folderID {
                byFolder[folder, default: []].append(plan)
            } else {
                singles.append(PlanGroup(id: plan.id, plans: [plan]))
            }
        }
        let grouped = byFolder.map { PlanGroup(id: $0.key, plans: $0.value) }
        return (grouped + singles).sorted { $0.updated > $1.updated }
    }
}

func termStringList(_ raw: Any?) throws -> [String] {
    guard let raw else { return [] }
    let values: [Any]
    if let list = raw as? [String] {
        values = list
    } else if let list = raw as? [Any] {
        values = list
    } else {
        throw MCPToolError(code: "invalid_argument", message: "terms must be a list of term strings such as \"202730\".")
    }
    var codes: [String] = []
    for value in values {
        guard let code = value as? String else {
            throw MCPToolError(code: "invalid_argument", message: "terms must be a list of term strings such as \"202730\".")
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPToolError(code: "invalid_argument", message: "terms must be a list of term strings such as \"202730\".")
        }
        codes.append(trimmed)
    }
    return codes
}

func planID(_ arguments: [String: Any]) throws -> UUID {
    guard let text = stringArg(arguments, "plan_id"), let id = UUID(uuidString: text) else {
        throw MCPToolError(code: "bad_plan", message: "plan_id must be a UUID.")
    }
    return id
}

func expectedRevision(_ arguments: [String: Any]) throws -> Int {
    guard let revision = intArg(arguments, "expected_revision") else {
        throw MCPToolError(code: "bad_revision", message: "expected_revision is required.")
    }
    return revision
}

/// A stored revision below 1, including a missing value, is revision 1.
func displayedRevision(_ stored: Int?) -> Int {
    let value = stored ?? 0
    return value < 1 ? 1 : value
}

/// Banner semester code for a degree-plan semester. Fall of calendar year Y
/// is `(Y+1)10`. Spring is `Y30`, Summer Session A `Y40`, Summer Full `Y50`,
/// Summer Session B `Y60`, Winter `Y20`. The college digit is 0.
func bannerCode(_ term: DegreePlanTerm) -> String {
    let academic: Int
    let digit: String
    switch term.season {
    case .fall:
        academic = term.year + 1
        digit = "1"
    case .winter:
        academic = term.year
        digit = "2"
    case .spring:
        academic = term.year
        digit = "3"
    case .summerA:
        academic = term.year
        digit = "4"
    case .summerFull:
        academic = term.year
        digit = "5"
    case .summerB:
        academic = term.year
        digit = "6"
    }
    return String(format: "%04d%@0", academic, digit)
}

/// The degree-plan semester for a Banner code such as `202730`. Nil when the
/// season digit is not one this app stores.
func degreeTerm(for code: String) -> DegreePlanTerm? {
    guard code.count == 6, let academic = Int(code.prefix(4)) else { return nil }
    let digit = code[code.index(code.startIndex, offsetBy: 4)]
    let season: PlanSeason
    let year: Int
    switch digit {
    case "1":
        season = .fall
        year = academic - 1
    case "2":
        season = .winter
        year = academic
    case "3":
        season = .spring
        year = academic
    case "4":
        season = .summerA
        year = academic
    case "5":
        season = .summerFull
        year = academic
    case "6":
        season = .summerB
        year = academic
    default:
        return nil
    }
    return DegreePlanTerm(season: season, year: year)
}

func termName(for code: String) -> String {
    degreeTerm(for: code)?.name ?? code
}

func termObject(code: String, name: String) -> [String: Any] {
    ["term": code, "name": name]
}

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
