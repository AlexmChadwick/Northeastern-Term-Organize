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
        MCPTool(name: "list_plans", description: "List saved schedule plans: id, name, terms, updated time, and revision.", properties: [:], required: [], readOnly: true) { _, server in
            server.listPlans()
        },
        MCPTool(name: "get_plan", description: "One saved plan, with terms, courses, chosen sections, clashes, and courses the bundled catalog does not offer in that term.", properties: ["plan_id": stringSchema], required: ["plan_id"], readOnly: true) { arguments, server in
            try server.getPlan(id: try planID(arguments))
        },
        MCPTool(name: "create_plan", description: "Create a saved plan in the app's UserData.json. terms is optional.", properties: [
            "name": stringSchema,
            "terms": ["type": "array"],
        ], required: ["name"], readOnly: false) { arguments, server in
            try server.createPlan(arguments)
        },
        MCPTool(name: "rename_plan", description: "Rename a saved plan if expected_revision still matches.", properties: [
            "plan_id": stringSchema, "name": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "name", "expected_revision"], readOnly: false) { arguments, server in
            try server.renamePlan(arguments)
        },
        MCPTool(name: "add_course", description: "Add a catalog course to a term of a saved plan. crn is optional. Rejects unknown courses and CRNs.", properties: [
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
        MCPTool(name: "set_section", description: "Choose the CRN for a course already in a term of a saved plan.", properties: [
            "plan_id": stringSchema, "term": stringSchema, "subject": stringSchema, "number": stringSchema,
            "crn": stringSchema, "expected_revision": intSchema,
        ], required: ["plan_id", "term", "subject", "number", "crn", "expected_revision"], readOnly: false) { arguments, server in
            try server.setSection(arguments)
        },
        MCPTool(name: "apply_reorganize", description: "Run reorganize_plan on a saved plan and write the result. Returns the moves.", properties: [
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
    func listPlans() -> [String: Any] {
        let data = (try? UserDataFile.read(from: plansURL)) ?? UserData()
        let groups = PlanGroup.groups(in: data.plans)
        return ["plans": groups.map { $0.summary() }]
    }

    func getPlan(id: UUID) throws -> [String: Any] {
        let data = (try? UserDataFile.read(from: plansURL)) ?? UserData()
        guard let group = PlanGroup.groups(in: data.plans).first(where: { $0.id == id }) else {
            throw MCPToolError(code: "unknown_plan", message: "No saved plan \(id.uuidString).")
        }
        return try planPayload(group)
    }

    func createPlan(_ arguments: [String: Any]) throws -> [String: Any] {
        let name = stringArg(arguments, "name") ?? ""
        guard !name.isEmpty else { throw MCPToolError(code: "bad_name", message: "name is required.") }
        let requested = arguments["terms"] as? [[String: Any]] ?? []
        let folder = UUID()
        var created: PlanGroup?
        try UserDataFile.modify(at: plansURL) { data in
            var plans: [SchedulePlan] = []
            if requested.isEmpty {
                let code = CatalogLibrary.allowedTermCodes.first { library.index(for: $0) != nil } ?? "202730"
                plans.append(newSchedule(name: name, term: code, folder: folder, courses: [], data: data))
            } else {
                for row in requested {
                    let code = stringArg(row, "term") ?? ""
                    try validateTerm(code)
                    let courses = try coursesForSave(courseList(row["courses"]), term: code, crn: nil)
                    plans.append(newSchedule(name: name, term: code, folder: folder, courses: courses, data: data))
                }
            }
            data.plans.append(contentsOf: plans)
            created = PlanGroup(id: folder, plans: plans)
        }
        return try planPayload(created!)
    }

    func renamePlan(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let name = stringArg(arguments, "name") ?? ""
        guard !name.isEmpty else { throw MCPToolError(code: "bad_name", message: "name is required.") }
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { group in
            for index in group.plans.indices { group.plans[index].name = name }
        }
    }

    func addCourse(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let term = try termCode(arguments, key: "term")
        let key = try courseKey(arguments)
        let crn = stringArg(arguments, "crn")
        try validateCourse(key, term: term, crn: crn)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { group in
            if let index = group.plans.firstIndex(where: { $0.termCode == term }) {
                if !group.plans[index].contains(key) {
                    group.plans[index].courses.append(PlanCourse(key: key, colorIndex: group.plans[index].nextColorIndex))
                }
                if let crn { try select(crn, for: key, in: &group.plans[index], term: term) }
            } else {
                var plan = newSchedule(name: group.plans.first?.name ?? "Plan", term: term, folder: group.id, courses: [key], data: UserData())
                if let crn { try select(crn, for: key, in: &plan, term: term) }
                group.plans.append(plan)
            }
        }
    }

    func removeCourse(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let term = try termCode(arguments, key: "term")
        let key = try courseKey(arguments)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { group in
            guard let index = group.plans.firstIndex(where: { $0.termCode == term }) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(term) of this plan.")
            }
            let crns = Set((library.index(for: term)?.sections(for: key) ?? []).map(\.crn))
            group.plans[index].courses.removeAll { $0.key == key }
            group.plans[index].selectedCRNs.removeAll { crns.contains($0) }
            if !group.plans[index].contains(key) && group.plans[index].courses.isEmpty && group.plans.count > 1 {
                group.plans.remove(at: index)
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
        return try mutate(id: id, expected: expected) { group in
            guard let source = group.plans.firstIndex(where: { $0.termCode == from && $0.contains(key) }) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(from) of this plan.")
            }
            let color = group.plans[source].course(key)?.colorIndex ?? 0
            let sourceCRNs = Set((library.index(for: from)?.sections(for: key) ?? []).map(\.crn))
            let kept = group.plans[source].selectedCRNs.filter { sourceCRNs.contains($0) }
            group.plans[source].courses.removeAll { $0.key == key }
            group.plans[source].selectedCRNs.removeAll { sourceCRNs.contains($0) }
            if group.plans[source].courses.isEmpty && from != to {
                group.plans.remove(at: source)
            }
            if let destination = group.plans.firstIndex(where: { $0.termCode == to }) {
                if !group.plans[destination].contains(key) {
                    group.plans[destination].courses.append(PlanCourse(key: key, colorIndex: color))
                }
                for crn in kept where library.index(for: to)?.section(crn: crn)?.courseKey == key {
                    try select(crn, for: key, in: &group.plans[destination], term: to)
                }
            } else {
                var plan = newSchedule(name: group.plans.first?.name ?? "Plan", term: to, folder: group.id, courses: [key], data: UserData())
                plan.courses[0].colorIndex = color
                group.plans.append(plan)
            }
        }
    }

    func setSection(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let term = try termCode(arguments, key: "term")
        let key = try courseKey(arguments)
        let crn = stringArg(arguments, "crn") ?? ""
        try validateCourse(key, term: term, crn: crn)
        let expected = try expectedRevision(arguments)
        return try mutate(id: id, expected: expected) { group in
            guard let index = group.plans.firstIndex(where: { $0.termCode == term && $0.contains(key) }) else {
                throw MCPToolError(code: "unknown_course", message: "\(key.description) is not in term \(term) of this plan.")
            }
            try select(crn, for: key, in: &group.plans[index], term: term)
        }
    }

    func applyReorganize(_ arguments: [String: Any]) throws -> [String: Any] {
        let id = try planID(arguments)
        let expected = try expectedRevision(arguments)
        let before = try getPlan(id: id)
        let input = (before["terms"] as? [[String: Any]] ?? []).map { row in
            ReorganizeTerm(term: stringArg(row, "term") ?? "", courses: courseList(row["courses"]))
        }
        let reorganized = try reorganize(input, library: library)
        let moves = reorganized["moves"] as? [[String: Any]] ?? []
        let result = try mutate(id: id, expected: expected) { group in
            let name = group.plans.first?.name ?? "Plan"
            var rebuilt: [SchedulePlan] = []
            for row in reorganized["terms"] as? [[String: Any]] ?? [] {
                let code = stringArg(row, "term") ?? ""
                let keys = courseList(row["courses"])
                var plan = group.plans.first { $0.termCode == code } ?? newSchedule(name: name, term: code, folder: group.id, courses: [], data: UserData())
                plan.name = name
                plan.folderID = group.id
                plan.courses = keys.map { key in
                    plan.course(key) ?? PlanCourse(key: key, colorIndex: plan.nextColorIndex)
                }
                let allowed = Set(keys.flatMap { library.index(for: code)?.sections(for: $0).map(\.crn) ?? [] })
                plan.selectedCRNs = plan.selectedCRNs.filter { allowed.contains($0) }
                rebuilt.append(plan)
            }
            group.plans = rebuilt.isEmpty ? group.plans : rebuilt
        }
        var payload = result
        payload["moves"] = moves
        payload["notes"] = reorganized["notes"] ?? []
        return payload
    }

    func deletePlan(_ arguments: [String: Any]) throws -> [String: Any] {
        guard boolArg(arguments, "confirm") == true else {
            throw MCPToolError(code: "confirm_required", message: "delete_plan refuses unless confirm is true.")
        }
        let id = try planID(arguments)
        let expected = try expectedRevision(arguments)
        var removed = false
        try UserDataFile.modify(at: plansURL) { data in
            let groups = PlanGroup.groups(in: data.plans)
            guard let group = groups.first(where: { $0.id == id }) else {
                throw MCPToolError(code: "unknown_plan", message: "No saved plan \(id.uuidString).")
            }
            try group.requireRevision(expected)
            let ids = Set(group.plans.map(\.id))
            data.plans.removeAll { ids.contains($0.id) }
            removed = true
        }
        return ["deleted": removed, "plan_id": id.uuidString]
    }

    private func mutate(id: UUID, expected: Int, _ change: (inout PlanGroup) throws -> Void) throws -> [String: Any] {
        var updated: PlanGroup?
        try UserDataFile.modify(at: plansURL) { data in
            var groups = PlanGroup.groups(in: data.plans)
            guard let index = groups.firstIndex(where: { $0.id == id }) else {
                throw MCPToolError(code: "unknown_plan", message: "No saved plan \(id.uuidString).")
            }
            try groups[index].requireRevision(expected)
            try change(&groups[index])
            let next = expected + 1
            let now = Date()
            for planIndex in groups[index].plans.indices {
                groups[index].plans[planIndex].revision = next
                groups[index].plans[planIndex].updatedAt = now
                groups[index].plans[planIndex].folderID = groups[index].id
            }
            let ids = Set(groups[index].plans.map(\.id))
            data.plans.removeAll { plan in
                plan.folderID == id || ids.contains(plan.id)
            }
            // Also drop schedules that were in the group but removed by the edit.
            let previous = PlanGroup.groups(in: data.plans + groups[index].plans)
            _ = previous
            data.plans.removeAll { $0.folderID == id }
            data.plans.append(contentsOf: groups[index].plans)
            updated = groups[index]
        }
        return try planPayload(updated!)
    }

    private func planPayload(_ group: PlanGroup) throws -> [String: Any] {
        var terms: [[String: Any]] = []
        var clashes: [[String: Any]] = []
        var notOffered: [[String: Any]] = []
        for plan in group.plans.sorted(by: { $0.termCode < $1.termCode }) {
            let index = library.index(for: plan.termCode)
            var courses: [[String: Any]] = []
            var chosen: [CourseSection] = []
            for course in plan.courses {
                var row: [String: Any] = ["subject": course.key.subject, "number": course.key.number]
                let sections = index?.sections(for: course.key) ?? []
                if sections.isEmpty {
                    notOffered.append(["term": plan.termCode, "subject": course.key.subject, "number": course.key.number])
                }
                let selected = sections.filter { plan.selectedCRNs.contains($0.crn) }
                if let crn = selected.first?.crn { row["crn"] = crn }
                row["sections"] = selected.map { sectionJSON($0) }
                chosen.append(contentsOf: selected)
                courses.append(row)
            }
            for left in 0..<chosen.count {
                for right in (left + 1)..<chosen.count where chosen[left].conflicts(with: chosen[right]) {
                    clashes.append(["term": plan.termCode, "crn": chosen[left].crn, "other": chosen[right].crn, "reason": "Overlapping meeting"])
                }
            }
            terms.append(["term": plan.termCode, "courses": courses])
        }
        return [
            "id": group.id.uuidString,
            "name": group.plans.first?.name ?? "",
            "revision": group.revision,
            "updated": iso8601(group.updated),
            "terms": terms,
            "validation": ["clashes": clashes, "not_offered": notOffered],
        ]
    }

    private func newSchedule(name: String, term: String, folder: UUID, courses: [CourseKey], data: UserData) -> SchedulePlan {
        var plan = SchedulePlan(name: name, termCode: term)
        plan.folderID = folder
        plan.revision = 1
        plan.isPrimary = !data.plans.contains { $0.termCode == term && $0.isPrimary }
        plan.courses = courses.map { PlanCourse(key: $0, colorIndex: 0) }
        for (index, _) in plan.courses.enumerated() {
            plan.courses[index].colorIndex = index % CourseColorPalette.count
        }
        return plan
    }

    private func coursesForSave(_ keys: [CourseKey], term: String, crn: String?) throws -> [CourseKey] {
        for key in keys { try validateCourse(key, term: term, crn: crn) }
        return keys
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

    private func select(_ crn: String, for key: CourseKey, in plan: inout SchedulePlan, term: String) throws {
        guard let index = library.index(for: term) else { return }
        let courseCRNs = Set(index.sections(for: key).map(\.crn))
        plan.selectedCRNs.removeAll { courseCRNs.contains($0) }
        plan.selectedCRNs.append(crn)
    }
}

struct PlanGroup {
    var id: UUID
    var plans: [SchedulePlan]

    var revision: Int { plans.map { $0.revision ?? 0 }.max() ?? 0 }
    var updated: Date { plans.map(\.updatedAt).max() ?? .distantPast }

    func summary() -> [String: Any] {
        [
            "id": id.uuidString,
            "name": plans.first?.name ?? "",
            "terms": plans.map(\.termCode).sorted(),
            "updated": iso8601(updated),
            "revision": revision,
        ]
    }

    func requireRevision(_ expected: Int) throws {
        guard revision == expected else {
            throw MCPToolError(
                code: "revision_conflict",
                message: "The plan changed. expected_revision was \(expected) and the saved revision is \(revision).",
                extra: ["revision": revision]
            )
        }
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

func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
