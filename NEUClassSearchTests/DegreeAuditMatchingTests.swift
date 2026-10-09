//
//  DegreeAuditMatchingTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// The degree audit never shows a plan short of requirements it can meet: on random programs
/// and plans, whenever some matching of courses to requirements meets every requirement, the
/// audit meets every requirement, and it always meets as many of the specific (not general
/// elective) requirements as any matching — checked against an exhaustive search over every
/// way of matching courses to requirements (written separately from the engine, with the same rules: each
/// course counts once, labs and seminars don't count as courses for "N courses in a range",
/// hours come from credits, a course a substitution counts toward a requirement stays there).
/// Programs mix required courses, lecture-and-lab pairs, alternatives, "N of the following"
/// lists (with pairs), courses or hours in ranges, petitions with specific courses plus ranges,
/// and general electives.
struct DegreeAuditMatchingTests {
    /// A course that can be in a random plan.
    private struct PoolCourse {
        var key: CourseKey
        var credits: Double
    }

    private static let catalog: [(String, Double)] = [
        ("CS 1200", 1), ("CS 1800", 4), ("CS 1802", 1), ("CS 2500", 4), ("CS 2501", 1), ("CS 2510", 4),
        ("CS 3000", 4), ("CS 3200", 4), ("CS 3500", 4), ("CS 3501", 1), ("CS 3650", 4), ("CS 4100", 4),
        ("CS 4400", 4), ("CS 4530", 4), ("DS 3000", 4), ("DS 4400", 4), ("MATH 1341", 4), ("MATH 2331", 4),
    ]
    private static let pool: [PoolCourse] = catalog.map { PoolCourse(key: CourseKey(string: $0.0)!, credits: $0.1) }

    @Test func matchesAsManyRequirementsAsPossible() throws {
        var generator = SeededGenerator(seed: 2026)
        var checked = 0
        for _ in 0..<160 {
            var plan = Self.randomPlan(using: &generator)
            let rules = Self.randomRules(from: plan.courses, using: &generator)
            let pins = Self.randomPins(rules: rules, courses: plan.courses, using: &generator)
            plan.degreePlan.substitutions = pins.map { RequirementSubstitution(ruleID: rules[$0.rule].id, ruleTitle: rules[$0.rule].id, change: .countCourse(plan.courses[$0.course].key)) }
            let requirements = Self.requirements(rules)
            let audit = DegreeAudit.run(plan: plan.degreePlan, requirements: requirements)
            let possible = Self.mostThatCanBeMet(rules: rules, courses: plan.courses, pins: pins)
            let context = "\(Self.describe(rules: rules, courses: plan.courses)); pins: \(pins.map { "\(plan.courses[$0.course].key)→\(rules[$0.rule].id)" })"
            let specificMet = audit.ruleResults.filter { !$0.rule.degreeIsGeneralElectives && $0.status.isSatisfied }.count
            #expect(specificMet == possible.specific, "\(context)")
            if possible.everything {
                #expect(audit.satisfiedCount == audit.totalCount, "\(context)")
            }
            // Every course counts once, toward a requirement it fits.
            let counted = audit.ruleResults.flatMap(\.used).map(\.id)
            #expect(counted.count == Set(counted).count)
            checked += 1
        }
        #expect(checked == 160)
    }

    /// A big plan with many courses that fit several requirements still audits quickly.
    @Test func largePlansStayFast() throws {
        var rules: [RequirementRule] = []
        let cs = Self.pool.filter { $0.key.subject == "CS" && $0.credits >= 4 }.map(\.key)
        for index in 0..<6 {
            rules.append(Self.rule("list-\(index)", .choose(count: 2, hours: nil, options: cs.shuffledDeterministically(seed: UInt64(index)).prefix(5).map { CourseOption(alternatives: [[$0]]) }, ranges: [])))
        }
        rules.append(Self.rule("electives", .choose(count: nil, hours: 12, options: [], ranges: [CourseRange(subject: "CS", lowest: 2000, highest: nil, except: [], label: "CS 2000 or higher")])))
        rules.append(Self.rule("petition", .choose(count: 3, hours: nil, options: [], ranges: [CourseRange(subject: "CS", lowest: 0, highest: nil, except: [], label: "Any CS course")])))
        rules.append(Self.rule("general", .generalElectives(hours: 16)))
        var plan = DegreePlan(name: "Big")
        plan.completed = Self.pool.map { DegreePlanCourse(key: $0.key, title: "", credits: $0.credits) }
        let start = Date.now
        let audit = DegreeAudit.run(plan: plan, requirements: Self.requirements(rules))
        #expect(Date.now.timeIntervalSince(start) < 2)
        #expect(audit.totalCount == rules.count)
    }

    // MARK: Random programs and plans

    private struct RandomPlan {
        var courses: [PoolCourse]
        var degreePlan: DegreePlan
    }

    private static func randomPlan(using generator: inout SeededGenerator) -> RandomPlan {
        let count = Int.random(in: 3...6, using: &generator)
        let courses = Array(pool.shuffled(using: &generator).prefix(count))
        var plan = DegreePlan(name: "Random")
        var term = DegreePlanTerm(season: .spring, year: 2027)
        for course in courses {
            let line = DegreePlanCourse(key: course.key, title: "", credits: course.credits)
            if Bool.random(using: &generator) { plan.completed.append(line) } else { term.courses.append(line) }
        }
        plan.terms = [term]
        return RandomPlan(courses: courses, degreePlan: plan)
    }

    /// Two to four requirements over the plan's courses (and a few it doesn't have), sharing
    /// courses so that they compete.
    private static func randomRules(from courses: [PoolCourse], using generator: inout SeededGenerator) -> [RequirementRule] {
        let keys = courses.map(\.key)
        func someKey() -> CourseKey {
            // Mostly the plan's courses, sometimes one it lacks.
            Int.random(in: 0..<5, using: &generator) == 0 ? pool.randomElement(using: &generator)!.key : keys.randomElement(using: &generator)!
        }
        var rules: [RequirementRule] = []
        let total = Int.random(in: 2...4, using: &generator)
        let withElectives = Bool.random(using: &generator)
        for index in 0..<(withElectives ? total - 1 : total) {
            let kind: RequirementRule.Kind
            switch Int.random(in: 0..<8, using: &generator) {
            case 0: kind = .required(CourseOption(alternatives: [[someKey()]]))
            case 1: kind = .required(CourseOption(alternatives: [distinct([someKey(), someKey()])]))
            case 2: kind = .required(CourseOption(alternatives: [[someKey()], [someKey()]]))
            case 3:
                let options = distinct((0..<Int.random(in: 2...4, using: &generator)).map { _ in someKey() })
                kind = .choose(count: Int.random(in: 1...2, using: &generator), hours: nil,
                               options: options.map { CourseOption(alternatives: [[$0]]) }, ranges: [])
            case 4:
                let lowest = [2000, 3000].randomElement(using: &generator)!
                kind = .choose(count: Int.random(in: 1...2, using: &generator), hours: nil, options: [],
                               ranges: [CourseRange(subject: "CS", lowest: lowest, highest: nil, except: [], label: "CS \(lowest) or higher")])
            case 5:
                kind = .choose(count: nil, hours: [5, 8].randomElement(using: &generator)!, options: [],
                               ranges: [CourseRange(subject: "CS", lowest: 2000, highest: nil, except: [], label: "CS 2000 or higher"),
                                        CourseRange(subject: "DS", lowest: 2000, highest: nil, except: [], label: "DS 2000 or higher")])
            case 6:
                // A list whose first option is a lecture with its lab.
                let pair = distinct([someKey(), someKey()])
                let singles = distinct((0..<Int.random(in: 1...2, using: &generator)).map { _ in someKey() }).filter { !pair.contains($0) }
                kind = .choose(count: Int.random(in: 1...2, using: &generator), hours: nil,
                               options: [CourseOption(alternatives: [pair])] + singles.map { CourseOption(alternatives: [[$0]]) }, ranges: [])
            default:
                // A petition: courses like a range, plus a course an adviser approved.
                let approved = [someKey()]
                let ranges = [CourseRange(subject: "CS", lowest: 2500, highest: nil, except: [], label: "CS 2500 or higher")]
                kind = Bool.random(using: &generator)
                    ? .choose(count: Int.random(in: 1...2, using: &generator), hours: nil, options: [CourseOption(alternatives: [approved])], ranges: ranges)
                    : .choose(count: nil, hours: [4, 8].randomElement(using: &generator)!, options: [CourseOption(alternatives: [approved])], ranges: ranges)
            }
            rules.append(rule("rule-\(index)", kind))
        }
        if withElectives {
            rules.append(rule("general", .generalElectives(hours: [4, 8].randomElement(using: &generator)!)))
        }
        return rules
    }

    /// The keys without repeats, in order (sets would make runs differ).
    private static func distinct(_ keys: [CourseKey]) -> [CourseKey] {
        var seen = Set<CourseKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// Sometimes a substitution counts one of the plan's courses toward a requirement.
    private static func randomPins(rules: [RequirementRule], courses: [PoolCourse], using generator: inout SeededGenerator) -> [(course: Int, rule: Int)] {
        guard Int.random(in: 0..<10, using: &generator) < 3 else { return [] }
        return [(Int.random(in: 0..<courses.count, using: &generator), Int.random(in: 0..<rules.count, using: &generator))]
    }

    private static func rule(_ id: String, _ kind: RequirementRule.Kind) -> RequirementRule {
        RequirementRule(id: id, kind: kind, label: id, hours: nil, notes: [])
    }

    private static func requirements(_ rules: [RequirementRule]) -> ProgramRequirements {
        let groups = rules.map { RequirementGroup(id: "group-\($0.id)", title: $0.id, rules: [$0], notes: []) }
        return ProgramRequirements(
            year: CatalogYear(startYear: 2024),
            program: CatalogProgram(title: "Random, BS", path: "undergraduate/random/"),
            sections: [RequirementSection(id: "major", title: "Major", isConcentration: false, groups: groups, notes: [])],
            totalHours: nil,
            fetchedAt: .now
        )
    }

    // MARK: Exhaustive search

    /// The most specific (not general elective) requirements any matching meets, and whether
    /// one meets them all, general electives included. Every course goes to one requirement or
    /// none, except courses a substitution placed (`pins`), which count toward their requirement.
    private static func mostThatCanBeMet(rules: [RequirementRule], courses: [PoolCourse], pins: [(course: Int, rule: Int)] = []) -> (specific: Int, everything: Bool) {
        var assignment = [Int](repeating: rules.count, count: courses.count)
        let pinned = Dictionary(pins.map { ($0.course, $0.rule) }, uniquingKeysWith: { first, _ in first })
        var bestSpecific = 0
        var everything = false
        /// Whether the requirement at `r` is met by the courses matched to it.
        func isMet(_ r: Int) -> Bool {
            let rule = rules[r]
            let mine = courses.indices.filter { assignment[$0] == r && pinned[$0] == nil }.map { courses[$0] }
            let placed = courses.indices.filter { pinned[$0] == r }.map { courses[$0] }
            let keys = Set(mine.map(\.key))
            let placedKeys = Set(placed.map(\.key))
            func complete(_ alternative: [CourseKey]) -> Bool { Set(alternative).isSubset(of: keys) }
            switch rule.kind {
            case .required(let option):
                return !placed.isEmpty || option.alternatives.contains(where: complete)
            case .choose(let count, let hours, let options, let ranges):
                // An option a placed course belongs to doesn't count again.
                let open = options.filter { $0.allCourses.allSatisfy { !placedKeys.contains($0) } }
                let listed = Set(open.flatMap(\.allCourses))
                let optionUnits = open.filter { $0.alternatives.contains(where: complete) }.count
                let inRanges = mine.filter { course in !listed.contains(course.key) && ranges.contains { $0.contains(course.key) } }
                if let count {
                    return placed.count + optionUnits + inRanges.filter { $0.credits >= 2 }.count >= count
                } else if let hours {
                    let fromOptions = mine.filter { course in
                        open.contains { option in option.allCourses.contains(course.key) && option.alternatives.contains(where: complete) }
                    }
                    return (placed + fromOptions + inRanges).reduce(0) { $0 + $1.credits } >= hours
                } else {
                    return placed.count + optionUnits >= 1
                }
            case .generalElectives(let hours):
                return (mine + placed).reduce(0) { $0 + $1.credits } >= hours
            }
        }
        func assign(_ position: Int) {
            guard position < courses.count else {
                let met = rules.indices.filter(isMet)
                let specific = met.filter { !rules[$0].degreeIsGeneralElectives }.count
                bestSpecific = max(bestSpecific, specific)
                if met.count == rules.count { everything = true }
                return
            }
            if let rule = pinned[position] {
                assignment[position] = rule
                assign(position + 1)
                return
            }
            for bucket in 0...rules.count {
                assignment[position] = bucket
                assign(position + 1)
            }
        }
        assign(0)
        return (bestSpecific, everything)
    }

    private static func describe(rules: [RequirementRule], courses: [PoolCourse]) -> String {
        let plan = courses.map { "\($0.key) (\($0.credits.formatted()))" }.joined(separator: ", ")
        let listed = rules.map { rule -> String in
            switch rule.kind {
            case .required(let option): "required \(option.label)"
            case .choose(let count, let hours, let options, let ranges):
                "choose \(count.map(String.init) ?? "-")/\(hours.map { $0.formatted() } ?? "-") of \(options.map(\.label)) \(ranges.map(\.label))"
            case .generalElectives(let hours): "general \(hours.formatted())"
            }
        }
        return "plan: \(plan); rules: \(listed)"
    }
}

/// A small, fast, reproducible random number generator (SplitMix64).
private struct SeededGenerator: RandomNumberGenerator {
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

private extension Array {
    func shuffledDeterministically(seed: UInt64) -> [Element] {
        var generator = SeededGenerator(seed: seed)
        return shuffled(using: &generator)
    }
}
