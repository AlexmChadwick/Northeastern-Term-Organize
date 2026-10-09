//
//  DegreeNUpath.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// The NUpath attributes of courses, as Banner gives their sections, for checking a plan's
/// NUpath requirements (`DegreeAudit.run(…attributes:)`).
struct DegreeCourseAttributes: Hashable, Sendable {
    /// By course, the NUpath attributes its sections carry (empty when none do).
    var nupaths: [CourseKey: Set<NUPath>] = [:]
    /// Courses still being looked up.
    var loading: Set<CourseKey> = []

    static let none = DegreeCourseAttributes()

    /// Nothing was looked up, so NUpath isn't checked at all.
    var isEmpty: Bool { nupaths.isEmpty && loading.isEmpty }
}

/// Northeastern's NUpath requirements, as the catalog states them (they apply to students who
/// entered in fall 2016 or later):
///
/// - one course each for eight areas (ND, EI, IC, FQ, SI, AD, DD, ER), where "a single course can
///   count for up to two" of them;
/// - writing across audiences and genres, "met by four courses": first-year writing, advanced
///   writing in the disciplines and two writing-intensive courses in the major;
/// - integrating knowledge and skills through experience, and a capstone.
///
/// The writing-intensive, capstone and experience requirements "are not limited": a course that
/// counts for two areas can count for them too.
struct NUpathRequirement: Identifiable, Hashable, Sendable {
    var path: NUPath
    /// Courses needed (two writing-intensive courses, one of everything else).
    var count: Int
    /// One of the eight areas a course counts for at most two of.
    var isLimited: Bool

    var id: NUPath { path }

    /// In catalog order.
    static let all: [NUpathRequirement] =
        [NUPath.nd, .ei, .ic, .fq, .si, .ad, .dd, .er].map { NUpathRequirement(path: $0, count: 1, isLimited: true) }
        + [NUpathRequirement(path: .wf, count: 1, isLimited: false),
           NUpathRequirement(path: .wi, count: 2, isLimited: false),
           NUpathRequirement(path: .wd, count: 1, isLimited: false),
           NUpathRequirement(path: .ex, count: 1, isLimited: false),
           NUpathRequirement(path: .ce, count: 1, isLimited: false)]

    /// How many of the limited areas one course can count for.
    static let areasPerCourse = 2

    /// `Interpreting Culture (IC)`.
    var title: String { "\(path.name) (\(path.short))" }

    /// The requirement a catalog sentence says is satisfied through co-op ("Integrating Knowledge
    /// and Skills Through Experience is satisfied through co-op."), by its catalog name or code.
    static func satisfiedThroughCoop(in note: String) -> NUPath? {
        guard DegreeAudit.isCoopNote(note) else { return nil }
        let names: [NUPath: [String]] = [
            .ex: ["Integrating Knowledge and Skills Through Experience", "Integration Experience", "Integration of Experience"],
            .ce: ["Demonstrating Thought and Action in a Capstone", "Capstone Experience"],
        ]
        for (path, candidates) in names where candidates.contains(where: { note.localizedCaseInsensitiveContains($0) }) {
            return path
        }
        return NUPath.allCases.first { note.range(of: "\\b\($0.short)\\b", options: .regularExpression) != nil }
    }
}

/// Which plan courses meet which NUpath requirements: every requirement that can be met is, with
/// completed courses wherever they can be used.
///
/// The eight limited areas are a matching of areas to courses where each course has two places:
/// first with completed courses alone, then adding planned ones along augmenting paths, which
/// never take an area away from a completed course without giving it another. So no assignment
/// meets more areas, and none that meets as many uses more completed courses. The other
/// requirements take the first completed course that has the attribute, else the first planned.
struct NUpathMatching {
    struct Course: Sendable {
        var id: String
        var paths: Set<NUPath>
        var isCompleted: Bool
    }

    /// By requirement, the courses (ids) counted for it, completed ones first.
    private(set) var assigned: [NUPath: [String]] = [:]

    /// - Parameters:
    ///   - courses: the plan's courses in plan order (completed first).
    ///   - coopCounts: requirements a co-op satisfies (the program says so), with the plan's co-ops.
    init(courses: [Course], requirements: [NUpathRequirement] = NUpathRequirement.all, coopCounts: [NUPath: [Course]] = [:]) {
        let limited = requirements.filter(\.isLimited).map(\.path)
        assigned = Self.matchLimited(limited, courses: courses)
        for requirement in requirements where !requirement.isLimited {
            let candidates = courses.filter { $0.paths.contains(requirement.path) } + (coopCounts[requirement.path] ?? [])
            var seen = Set<String>()
            let ordered = (candidates.filter(\.isCompleted) + candidates.filter { !$0.isCompleted })
                .filter { seen.insert($0.id).inserted }
            assigned[requirement.path] = Array(ordered.prefix(requirement.count).map(\.id))
        }
    }

    func courses(for path: NUPath) -> [String] { assigned[path] ?? [] }

    /// Kuhn's augmenting paths from areas to course places (two per course).
    private static func matchLimited(_ areas: [NUPath], courses: [Course]) -> [NUPath: [String]] {
        // Places taken: course index → the areas it counts for.
        var load: [[NUPath]] = Array(repeating: [], count: courses.count)
        var owner: [NUPath: Int] = [:]

        func augment(_ area: NUPath, allowed: (Int) -> Bool, visited: inout Set<Int>) -> Bool {
            for index in courses.indices where allowed(index) && courses[index].paths.contains(area) && !visited.contains(index) {
                visited.insert(index)
                if load[index].count < NUpathRequirement.areasPerCourse {
                    load[index].append(area)
                    owner[area] = index
                    return true
                }
                // The course is full: move one of its areas to another course.
                for other in load[index] where augment(other, allowed: allowed, visited: &visited) {
                    load[index].removeAll { $0 == other }
                    load[index].append(area)
                    owner[area] = index
                    return true
                }
            }
            return false
        }

        // Completed courses first, then everything.
        for allowed in [{ (index: Int) in courses[index].isCompleted }, { (_: Int) in true }] {
            for area in areas where owner[area] == nil {
                var visited = Set<Int>()
                _ = augment(area, allowed: allowed, visited: &visited)
            }
        }
        return owner.mapValues { [courses[$0].id] }
    }
}
