//
//  ScheduleBlockers.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A smallest set of required courses that, taken out, leaves schedules.
struct ScheduleBlockerOption: Identifiable, Hashable, Sendable {
    /// The required courses to let go of (one or two, plus any that can't be taken this term at all).
    var courses: [CourseKey]
    /// Schedules that exist without them, a lower bound when `isLowerBound`.
    var scheduleCount: Int
    var isLowerBound: Bool

    var id: String { courses.map(\.description).joined(separator: "+") }
}

/// Why no schedule contains every required course, and what would work without some of them.
struct ScheduleBlockerAnalysis: Sendable {
    var requiredCount = 0
    /// Required courses with no sections in the term.
    var notOffered: [CourseKey] = []
    /// Required courses whose every section the filters or preferences rule out.
    var filteredOut: [CourseKey] = []
    /// The smallest sets of required courses that leave schedules once they are optional, most schedules first.
    var options: [ScheduleBlockerOption] = []
    /// Pairs of required courses that can never be combined.
    var conflictingPairs: [ScheduleDiagnostics.ConflictPair] = []
    /// The search stopped (time or probe limit) before every candidate was tried.
    var isIncomplete = false

    /// Required courses nothing can be done about without changing the schedule's courses.
    var unschedulable: [CourseKey] { notOffered + filteredOut }

    /// The courses of the best option: the ones worth moving to another semester.
    var blockingCourses: [CourseKey] { options.first?.courses ?? [] }

    /// Courses that appear in some option, in order of appearance.
    var allBlockingCourses: [CourseKey] {
        var seen = Set<CourseKey>()
        return options.flatMap(\.courses).filter { seen.insert($0).inserted }
    }

    /// The other courses `key` can never be combined with.
    func clashes(of key: CourseKey) -> [CourseKey] {
        conflictingPairs.compactMap { pair in
            if pair.first == key { return pair.second }
            if pair.second == key { return pair.first }
            return nil
        }
    }
}

extension ScheduleGenerator.Limits {
    /// Cheap existence checks for the blocker analysis: a thousand schedules is proof (and a count) enough.
    static let blockerProbe = ScheduleGenerator.Limits(
        maxResults: 1, maxExhaustiveLeaves: 1_000, maxNodes: 250_000, timeBudget: 0.15,
        sampleLeaves: 0, sampleTimeBudget: 0, allowSampling: false
    )
}

extension ScheduleGenerator {
    /// Finds which required courses stop every schedule from containing all of them, by trying the
    /// generation without each one (then without each pair) as optional courses. Courses that have no
    /// sections, or none left after the filters, always have to go, so the candidates build on them.
    ///
    /// Cheap by design: every probe stops at the first few schedules, and the whole analysis gives up
    /// after `timeBudget` seconds or `maxProbes` probes (and says so in `isIncomplete`).
    static func analyzeBlockers(
        courses: [ScheduleCourseInput],
        filters: ScheduleFilters,
        preferences: SchedulePreferences = SchedulePreferences(),
        diagnostics: ScheduleDiagnostics? = nil,
        timeBudget: TimeInterval = 1.5,
        maxProbes: Int = 60
    ) -> ScheduleBlockerAnalysis {
        let started = ProcessInfo.processInfo.systemUptime
        var analysis = ScheduleBlockerAnalysis()
        let required = courses.indices.filter { courses[$0].isRequired }
        analysis.requiredCount = required.count
        guard !required.isEmpty else { return analysis }

        let base = diagnostics ?? generate(courses: courses, filters: filters, preferences: preferences, sort: .best, limits: .probe).diagnostics
        analysis.conflictingPairs = base.conflictingPairs
        // The count and credit rules explain themselves; letting courses go doesn't fix them.
        guard base.countProblem == nil, base.courses.count == courses.count else { return analysis }

        var dead: [Int] = []
        for index in required where base.courses[index].isBlocked {
            dead.append(index)
            if base.courses[index].totalSections == 0 {
                analysis.notOffered.append(courses[index].key)
            } else {
                analysis.filteredOut.append(courses[index].key)
            }
        }
        let others = required.filter { !dead.contains($0) }

        var probes = 0
        func overBudget() -> Bool {
            Task.isCancelled || probes >= maxProbes || ProcessInfo.processInfo.systemUptime - started > timeBudget
        }
        /// The schedules that exist when `drop` are optional (they can't be added, or all courses would fit).
        func probe(dropping drop: [Int]) -> ScheduleBlockerOption? {
            probes += 1
            var relaxed = courses
            for index in drop { relaxed[index].isRequired = false }
            let result = generate(courses: relaxed, filters: filters, preferences: preferences, sort: .best, limits: .blockerProbe)
            guard result.totalFound > 0 else { return nil }
            return ScheduleBlockerOption(
                courses: drop.sorted().map { courses[$0].key },
                scheduleCount: result.totalFound,
                isLowerBound: !result.isExhaustive
            )
        }

        var found: [ScheduleBlockerOption] = []
        // 1. Only the courses that can't be scheduled at all.
        if !dead.isEmpty, let option = probe(dropping: dead) { found = [option] }
        // 2. Those plus one more.
        if found.isEmpty {
            for index in others {
                if overBudget() { analysis.isIncomplete = true; break }
                if let option = probe(dropping: dead + [index]) { found.append(option) }
            }
        }
        // 3. Those plus two more.
        if found.isEmpty, analysis.isIncomplete == false, others.count >= 2 {
            search: for i in others.indices {
                for j in others.indices where j > i {
                    if overBudget() { analysis.isIncomplete = true; break search }
                    if let option = probe(dropping: dead + [others[i], others[j]]) { found.append(option) }
                }
            }
        }
        analysis.options = found.sorted {
            if $0.courses.count != $1.courses.count { return $0.courses.count < $1.courses.count }
            return $0.scheduleCount > $1.scheduleCount
        }
        return analysis
    }
}
