//
//  DegreePlanReorganization.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Proposes a new arrangement of every remaining semester so the plan can actually be taken.
///
/// Keeping the graduation date comes first. The search reorders courses across the remaining
/// semesters, then tries summer semesters, then substitutes another course that meets the same
/// requirement (an elective, a NUpath course, a concentration option). Only when none of that
/// finishes on time does it add later semesters, one at a time, and it says what forced the
/// delay. Among arrangements with the same finish date it keeps courses where they already
/// work: a course moves only when leaving it would not.
///
/// A placement has to be a season the course is actually taught in (`OfferingHistory`, or the
/// term's own sections when that catalog is loaded), the prerequisites and corequisites have
/// to be met (`DegreePlanAnalysis`), a loaded term needs a conflict-free set of sections
/// (`DegreePlanFeasibility`), and the credit load stays within `DegreePlanLoad`. When a degree
/// audit is available the result still satisfies every requirement the current plan satisfies.
///
/// Nothing here changes the plan. `applying` does, and only the changes the caller kept.
enum DegreePlanReorganization {
    /// What is known about a course's prerequisites or corequisites.
    enum RequisiteKnowledge: Hashable, Sendable {
        case unknown
        case none
        case needs(Requisite)
    }

    /// A course the search may substitute for one that is already planned.
    struct Candidate: Hashable, Sendable {
        var key: CourseKey
        var title: String
        var credits: Double
        var nupaths: Set<NUPath> = []
    }

    /// Everything the search needs. Built once so it can run off the main actor.
    struct Context: Sendable {
        var plan: DegreePlan
        var history: OfferingHistory
        var prerequisites: [CourseKey: RequisiteKnowledge]
        var corequisites: [CourseKey: RequisiteKnowledge]
        var equivalences: CourseEquivalences
        var requirements: ProgramRequirements?
        var attributes: DegreeCourseAttributes
        /// `"fall-2027"` → sections, present only when that term's catalog is loaded.
        var catalogs: [String: [CourseKey: [CourseSection]]]
        var candidates: [Candidate]
        var now: Date

        static func catalogKey(season: PlanSeason, year: Int) -> String { "\(season.rawValue)-\(year)" }
    }

    struct Change: Hashable, Identifiable, Sendable {
        enum Kind: Hashable, Sendable {
            case move(courseID: UUID, course: CourseKey, from: DegreePlanTerm, to: DegreePlanTerm)
            case replace(courseID: UUID, removed: CourseKey, added: DegreePlanCourse, to: DegreePlanTerm)
        }

        var id: String
        var kind: Kind
        /// One line, e.g. `CS 3386 has only been offered in fall, so it moved to Fall 2027`.
        var reason: String

        var course: CourseKey {
            switch kind {
            case .move(_, let course, _, _): course
            case .replace(_, _, let added, _): added.key ?? CourseKey(subject: "?", number: "?")
            }
        }

        var fromName: String {
            switch kind {
            case .move(_, _, let from, _): from.shortName
            case .replace: ""
            }
        }

        var toName: String {
            switch kind {
            case .move(_, _, _, let to): to.shortName
            case .replace(_, _, _, let to): to.shortName
            }
        }

        /// `CS 3386  Spring 2027 → Fall 2027`, or `CY 2550 → CY 3740 in Spring 2027`.
        var headline: String {
            switch kind {
            case .move(_, let course, let from, let to):
                "\(course.description)  \(from.shortName) → \(to.shortName)"
            case .replace(_, let removed, let added, let to):
                "\(removed.description) → \(added.key?.description ?? added.label) in \(to.shortName)"
            }
        }
    }

    struct Delay: Hashable, Sendable {
        var fromName: String
        var toName: String
        /// What made an on-time arrangement impossible.
        var because: String
    }

    struct Proposal: Hashable, Sendable {
        var changes: [Change]
        var proposed: DegreePlan
        /// `Finishes after Fall 2027, the same as now.`
        var outcomeTitle: String
        /// The delay, when the finish had to move, in one sentence.
        var outcomeDetail: String?
        var delay: Delay?
        var delaysFinish: Bool { delay != nil }
    }

    /// One semester as a list of course codes, for the before-and-after diff.
    struct TermColumn: Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        var before: [String]
        var after: [String]
    }

    // MARK: - Context

    /// Freezes lookups, the loaded catalogs and the courses that could replace a planned one.
    static func makeContext(
        plan: DegreePlan,
        history: OfferingHistory,
        prerequisites: (CourseKey) -> Requisite??,
        corequisites: (CourseKey) -> Requisite??,
        equivalences: CourseEquivalences,
        requirements: ProgramRequirements?,
        attributes: DegreeCourseAttributes,
        snapshot: DegreePlanCatalogSnapshot,
        indexes: [CatalogIndex],
        now: Date = .now
    ) -> Context {
        let candidates = gatherCandidates(plan: plan, requirements: requirements, indexes: indexes, attributes: attributes)
        var keys = plan.degreePlanPlannedKeys + candidates.map(\.key)
        var seen = Set<CourseKey>()
        keys = keys.filter { seen.insert($0).inserted }
        return Context(
            plan: plan,
            history: history,
            prerequisites: knowledge(for: keys, lookup: prerequisites),
            corequisites: knowledge(for: keys, lookup: corequisites),
            equivalences: equivalences,
            requirements: requirements,
            attributes: attributes,
            catalogs: catalogs(for: plan, keys: keys, snapshot: snapshot, now: now),
            candidates: candidates,
            now: now
        )
    }

    /// Prerequisites from a loaded catalog first (when its details were fetched), then the
    /// course-info lookup. `corequisites` reads corequisites instead.
    static func lookup(
        indexes: [CatalogIndex],
        store: (CourseKey) -> Requisite??,
        corequisites: Bool = false
    ) -> (CourseKey) -> Requisite?? {
        { key in
            for index in indexes {
                if let course = index.course(key), course.detailsLoaded {
                    return .some(corequisites ? course.coreqs : course.prereqs)
                }
            }
            return store(key)
        }
    }

    // MARK: - Proposing

    static func propose(_ context: Context) -> Proposal? {
        Engine(context).propose()
    }

    /// Loads offering history for the planned courses and for courses that could replace them,
    /// then searches off the main actor. Detection on the plan screen uses planned courses only;
    /// this also checks substitutes, so a swap isn't placed in a season the course was never taught.
    @MainActor
    static func propose(
        plan: DegreePlan,
        info: CourseInfoStore,
        requirements: ProgramRequirements?,
        snapshot: DegreePlanCatalogSnapshot,
        now: Date = .now
    ) async -> Proposal? {
        let indexes = snapshot.indexes
        let attributes = info.degreeAttributes(for: plan)
        let extra = gatherCandidates(
            plan: plan, requirements: requirements, indexes: indexes, attributes: attributes
        ).map(\.key)
        var seen = Set<CourseKey>()
        let keys = (plan.degreePlanPlannedKeys + extra).filter { seen.insert($0).inserted }
        let history = await info.offeringHistory(for: keys, indexes: indexes)
        let context = makeContext(
            plan: plan,
            history: history,
            prerequisites: lookup(indexes: indexes, store: info.requisiteLookup()),
            corequisites: lookup(indexes: indexes, store: info.corequisiteLookup(), corequisites: true),
            equivalences: info.equivalences(for: plan),
            requirements: requirements,
            attributes: attributes,
            snapshot: snapshot,
            indexes: indexes,
            now: now
        )
        return await Task.detached(priority: .userInitiated) { propose(context) }.value
    }

    /// The plan after `changes`. A change whose course is no longer where it was is skipped,
    /// so a stale or partial selection can't apply halfway.
    static func applying(_ changes: [Change], to plan: DegreePlan) -> DegreePlan {
        var plan = plan
        for change in changes {
            switch change.kind {
            case .move(let courseID, _, let from, let dest):
                guard plan.terms.first(where: { $0.id == from.id })?.courses.contains(where: { $0.id == courseID }) == true
                        || plan.terms.contains(where: { $0.courses.contains { $0.id == courseID } }) else { continue }
                DegreePlanEditing.addTerm(dest, to: &plan)
                guard let termID = plan.terms.first(where: { $0.season == dest.season && $0.year == dest.year })?.id else { continue }
                DegreePlanEditing.move(courseID, toTerm: termID, in: &plan)
            case .replace(let courseID, _, let added, let dest):
                guard plan.terms.contains(where: { $0.courses.contains { $0.id == courseID } }) else { continue }
                DegreePlanEditing.addTerm(dest, to: &plan)
                guard let termID = plan.terms.first(where: { $0.season == dest.season && $0.year == dest.year })?.id else { continue }
                let home = plan.terms.first { $0.courses.contains { $0.id == courseID } }?.id
                if home == termID {
                    DegreePlanEditing.replacePlannedCourse(courseID, with: added, in: &plan)
                } else {
                    DegreePlanEditing.removePlannedCourse(courseID, from: &plan)
                    DegreePlanEditing.add(added, toTerm: termID, in: &plan)
                }
            }
        }
        plan.sortTerms()
        return plan
    }

    static func applying(selected ids: Set<String>, of proposal: Proposal, to plan: DegreePlan) -> DegreePlan {
        applying(proposal.changes.filter { ids.contains($0.id) }, to: plan)
    }

    /// Semesters whose course list changed, in order.
    static func diffs(from base: DegreePlan, to proposed: DegreePlan) -> [TermColumn] {
        var basePlan = base
        var next = proposed
        basePlan.sortTerms()
        next.sortTerms()
        var keys: [String] = []
        var name: [String: String] = [:]
        var before: [String: [String]] = [:]
        var after: [String: [String]] = [:]
        func key(_ term: DegreePlanTerm) -> String { "\(term.season.rawValue)-\(term.year)" }
        for term in basePlan.terms where !term.courses.isEmpty {
            let id = key(term)
            if !keys.contains(id) { keys.append(id) }
            name[id] = term.name
            before[id] = term.courses.map { $0.key?.description ?? $0.label }
        }
        for term in next.terms where !term.courses.isEmpty {
            let id = key(term)
            if !keys.contains(id) { keys.append(id) }
            name[id] = term.name
            after[id] = term.courses.map { $0.key?.description ?? $0.label }
        }
        return keys.compactMap { id in
            let left = before[id] ?? []
            let right = after[id] ?? []
            guard left != right else { return nil }
            return TermColumn(id: id, name: name[id] ?? id, before: left, after: right)
        }
    }

    // MARK: - Candidates

    /// Listed alternatives, courses inside a requirement's ranges, and — for a general
    /// elective — courses that carry a NUpath the plan already uses. Capped, so the search
    /// stays small.
    static func gatherCandidates(
        plan: DegreePlan,
        requirements: ProgramRequirements?,
        indexes: [CatalogIndex],
        attributes: DegreeCourseAttributes
    ) -> [Candidate] {
        guard let requirements else { return [] }
        let inPlan = Set(plan.degreePlanCourseKeys)
        var found: [CourseKey: Candidate] = [:]

        func consider(_ key: CourseKey, title: String? = nil, credits: Double? = nil, paths: Set<NUPath>? = nil) {
            guard !inPlan.contains(key), found[key] == nil else { return }
            var title = title ?? requirements.courseTitles[key] ?? key.description
            var credits = credits ?? 4
            var paths = paths ?? attributes.nupaths[key] ?? []
            for index in indexes {
                guard let course = index.course(key) else { continue }
                if !course.title.isEmpty { title = course.title }
                if course.maxCredits > 0 { credits = course.maxCredits }
                if !course.nupaths.isEmpty { paths = Set(course.nupaths) }
                break
            }
            found[key] = Candidate(key: key, title: title, credits: credits, nupaths: paths)
        }

        for section in requirements.applicableSections(concentrationID: plan.concentrationID) {
            for group in section.groups {
                for rule in group.rules {
                    switch rule.kind {
                    case .required(let option):
                        for key in option.allCourses { consider(key) }
                    case .choose(_, _, let options, let ranges):
                        for key in options.flatMap(\.allCourses) { consider(key) }
                        for range in ranges {
                            let matches = indexes.flatMap { $0.courses(inSubject: range.subject) }
                                .filter { range.contains($0.key) && !inPlan.contains($0.key) }
                            var seen = Set<CourseKey>()
                            for course in matches where seen.insert(course.key).inserted {
                                consider(course.key, title: course.title, credits: course.maxCredits, paths: Set(course.nupaths))
                                if seen.count >= 8 { break }
                            }
                        }
                    case .generalElectives:
                        let wanted = Set(plan.degreePlanPlannedKeys.flatMap { attributes.nupaths[$0] ?? [] })
                        guard !wanted.isEmpty else { continue }
                        var added = 0
                        for index in indexes {
                            for path in wanted {
                                for course in index.courses(with: path) where !inPlan.contains(course.key) && found[course.key] == nil {
                                    consider(course.key, title: course.title, credits: course.maxCredits, paths: Set(course.nupaths))
                                    added += 1
                                    if added >= 8 { break }
                                }
                                if added >= 8 { break }
                            }
                            if added >= 8 { break }
                        }
                    }
                }
            }
        }
        return found.values.sorted { $0.key < $1.key }
    }

    // MARK: - Private

    private static func knowledge(for keys: [CourseKey], lookup: (CourseKey) -> Requisite??) -> [CourseKey: RequisiteKnowledge] {
        var table: [CourseKey: RequisiteKnowledge] = [:]
        for key in keys {
            switch lookup(key) {
            case nil: table[key] = .unknown
            case .some(nil): table[key] = .none
            case .some(let requisite?): table[key] = .needs(requisite)
            }
        }
        return table
    }

    private static func catalogs(
        for plan: DegreePlan,
        keys: [CourseKey],
        snapshot: DegreePlanCatalogSnapshot,
        now: Date
    ) -> [String: [CourseKey: [CourseSection]]] {
        var terms = plan.terms
        let years = plan.terms.map(\.year)
        let start = years.min() ?? Calendar(identifier: .gregorian).component(.year, from: now)
        let end = (years.max() ?? start) + 2
        for year in start...end {
            for season in [PlanSeason.spring, .summerA, .summerFull, .summerB, .fall] {
                guard !terms.contains(where: { $0.season == season && $0.year == year }) else { continue }
                terms.append(DegreePlanTerm(season: season, year: year))
            }
        }
        var catalogs: [String: [CourseKey: [CourseSection]]] = [:]
        for term in terms {
            guard let map = DegreePlanFeasibility.sectionMap(in: snapshot, for: term, keys: keys) else { continue }
            catalogs[Context.catalogKey(season: term.season, year: term.year)] = map.byCourse
        }
        return catalogs
    }
}

// MARK: - Search

private extension DegreePlanReorganization {
    struct Slot {
        var term: DegreePlanTerm
        var isNew: Bool
        var sortKey: Int { term.sortKey }
    }

    struct Item {
        var id: UUID
        var key: CourseKey
        var title: String
        var credits: Double
        var home: UUID
        var homeSort: Int
        var index: Int
        /// The course this one stands in for, when it is a substitute.
        var replaces: CourseKey?
        var isReplacement: Bool { replaces != nil }
    }

    final class Engine {
        var context: DegreePlanReorganization.Context
        var plan: DegreePlan
        var originalAudit: DegreeAudit?
        var movableIDs: Set<UUID> = []

        init(_ context: DegreePlanReorganization.Context) {
            self.context = context
            var plan = context.plan
            plan.sortTerms()
            self.plan = plan
            if let requirements = context.requirements {
                originalAudit = DegreeAudit.run(
                    plan: plan, requirements: requirements, equivalences: context.equivalences, attributes: context.attributes
                )
            }
        }

        func propose() -> DegreePlanReorganization.Proposal? {
            let items = expandedItems()
            guard !items.isEmpty else { return nil }
            let existing = existingSlots()
            let finish = finishSort(plan)
            let limit = finish ?? existing.map(\.sortKey).max() ?? 0
            let summers = summerSlots(through: limit, existing: plan.terms)

            if let found = phases(items: items, existing: existing, summers: summers, finishLimit: limit) {
                return proposal(found, delayed: false, previousFinish: finish)
            }

            var added: [DegreePlanTerm] = []
            var probe = plan
            for _ in 0..<8 {
                guard let next = DegreePlanAutofill.nextSemesters(after: probe, count: 1, now: context.now).first else { break }
                var term = next
                term.id = DegreePlanReordering.stableID(for: "degree-plan-term-\(term.season.rawValue)-\(term.year)")
                added.append(term)
                probe.terms.append(term)
                probe.sortTerms()
                let horizon = term.sortKey
                let moreSummers = summerSlots(through: horizon, existing: plan.terms + added)
                let slots = existing + added.map { Slot(term: $0, isNew: true) }
                if let found = phases(items: items, existing: slots, summers: moreSummers, finishLimit: horizon) {
                    return proposal(found, delayed: true, previousFinish: finish)
                }
            }
            return nil
        }

        // MARK: What can move

        /// Courses the current plan can't take as they stand, plus courses that depend on one
        /// of those (a prerequisite moving can push the course that needs it). Co-op work
        /// experiences stay where they are.
        func expandedItems() -> [Item] {
            var ids = problemIDs()
            let courses = plan.terms.flatMap { term in term.courses.map { (term, $0) } }
            for _ in 0..<8 {
                let before = ids
                for (term, course) in courses {
                    guard let key = course.key, !DegreePlanLoad.isCoop(course), !term.degreePlanHasEnded(now: context.now) else { continue }
                    let depends = referenced(by: key)
                    if depends.contains(where: { dep in courses.contains { $0.1.key == dep && ids.contains($0.1.id) } }) {
                        ids.insert(course.id)
                    }
                }
                if ids == before { break }
            }
            movableIDs = ids
            var items: [Item] = []
            var index = 0
            for term in plan.terms where !term.degreePlanHasEnded(now: context.now) {
                for course in term.courses where ids.contains(course.id) {
                    guard let key = course.key, !DegreePlanLoad.isCoop(course) else { continue }
                    items.append(Item(
                        id: course.id, key: key, title: course.title, credits: course.credits,
                        home: term.id, homeSort: term.sortKey, index: index, replaces: nil
                    ))
                    index += 1
                }
            }
            return items
        }

        func problemIDs() -> Set<UUID> {
            let report = DegreePlanFeasibility.assess(plan: plan, history: context.history, sections: sections(for:), now: context.now)
            var ids = Set(report.terms.flatMap(\.coursesToMove))
            var taken = plan.completedKeys
            for term in plan.terms {
                if term.degreePlanHasEnded(now: context.now) {
                    taken.formUnion(term.courses.compactMap(\.key))
                    continue
                }
                let same = Set(term.courses.compactMap(\.key))
                for course in term.courses {
                    guard let key = course.key, !DegreePlanLoad.isCoop(course) else { continue }
                    if !requisiteMet(context.prerequisites[key] ?? .unknown, taken: taken) { ids.insert(course.id) }
                    if !requisiteMet(context.corequisites[key] ?? .unknown, taken: taken.union(same)) { ids.insert(course.id) }
                }
                taken.formUnion(same)
            }
            return ids
        }

        func sections(for term: DegreePlanTerm) -> DegreePlanFeasibility.TermSections? {
            guard let map = context.catalogs[DegreePlanReorganization.Context.catalogKey(season: term.season, year: term.year)] else { return nil }
            return DegreePlanFeasibility.TermSections(byCourse: map)
        }

        // MARK: Phases

        struct Found {
            var assignment: [UUID: Int]
            var items: [Item]
            var slots: [Slot]
        }

        /// Existing semesters first, then summers, then a single substitute. The first success
        /// is the least disruptive one that still finishes by `finishLimit`.
        func phases(items: [Item], existing: [Slot], summers: [Slot], finishLimit: Int) -> Found? {
            if let found = search(items: items, slots: existing, finishLimit: finishLimit) { return found }
            let withSummers = existing + summers.sorted { $0.sortKey < $1.sortKey }
            if !summers.isEmpty, let found = search(items: items, slots: withSummers, finishLimit: finishLimit) { return found }
            for index in items.indices {
                for alternative in alternatives(for: items[index]).prefix(6) {
                    var replaced = items
                    replaced[index].key = alternative.key
                    replaced[index].title = alternative.title
                    replaced[index].credits = alternative.credits
                    replaced[index].replaces = items[index].key
                    if let found = search(items: replaced, slots: withSummers, finishLimit: finishLimit) { return found }
                }
            }
            return nil
        }

        func search(items: [Item], slots: [Slot], finishLimit: Int) -> Found? {
            let ordered = order(items, slots: slots)
            let floor = items.filter(\.isReplacement).count
            for budget in floor...items.count {
                var nodes = 0
                var assignment: [UUID: Int] = [:]
                if dfs(0, ordered: ordered, slots: slots, budget: budget, spent: 0, assignment: &assignment, nodes: &nodes, finishLimit: finishLimit) {
                    return Found(assignment: assignment, items: items, slots: slots)
                }
            }
            return nil
        }

        func dfs(
            _ index: Int, ordered: [Item], slots: [Slot], budget: Int, spent: Int,
            assignment: inout [UUID: Int], nodes: inout Int, finishLimit: Int
        ) -> Bool {
            if index == ordered.count {
                let built = materialize(items: ordered, assignment: assignment, slots: slots)
                return acceptable(built, finishLimit: finishLimit)
            }
            nodes += 1
            if nodes > 60_000 { return false }
            let item = ordered[index]
            for (slotIndex, slot) in orderedSlots(for: item, slots: slots).enumerated() {
                let actual = slots.firstIndex { $0.term.id == slot.term.id } ?? slotIndex
                let cost = item.isReplacement || slot.term.id != item.home ? 1 : 0
                guard spent + cost <= budget else { continue }
                guard canPlace(item, in: slots[actual], slots: slots, assignment: assignment, items: ordered) else { continue }
                assignment[item.id] = actual
                if dfs(index + 1, ordered: ordered, slots: slots, budget: budget, spent: spent + cost, assignment: &assignment, nodes: &nodes, finishLimit: finishLimit) {
                    return true
                }
                assignment[item.id] = nil
            }
            return false
        }

        /// `orderedSlots` returns slots that may not share indexes with `slots` when filtered.
        /// The search above looks the index up again. Placement checks use `slots[actual]`.
        func orderedSlots(for item: Item, slots: [Slot]) -> [Slot] {
            slots.sorted { a, b in
                let aHome = a.term.id == item.home
                let bHome = b.term.id == item.home
                if aHome != bHome { return aHome }
                if a.isNew != b.isNew { return !a.isNew }
                return a.sortKey < b.sortKey
            }
        }

        func canPlace(_ item: Item, in slot: Slot, slots: [Slot], assignment: [UUID: Int], items: [Item]) -> Bool {
            guard isOffered(item.key, slot: slot) else { return false }
            guard creditsFit(item, in: slot, slots: slots, assignment: assignment, items: items) else { return false }
            let before = taken(before: slot, slots: slots, assignment: assignment, items: items)
            guard requisiteMet(context.prerequisites[item.key] ?? .unknown, taken: before) else { return false }
            if coreqsReady(item, items: items, assignment: assignment) {
                let concurrent = before.union(keys(in: slot, slots: slots, assignment: assignment, items: items, plus: item))
                guard requisiteMet(context.corequisites[item.key] ?? .unknown, taken: concurrent) else { return false }
            }
            return scheduleFits(item, in: slot, slots: slots, assignment: assignment, items: items)
        }

        // MARK: Constraints

        func isOffered(_ key: CourseKey, slot: Slot) -> Bool {
            let id = DegreePlanReorganization.Context.catalogKey(season: slot.term.season, year: slot.term.year)
            if let catalog = context.catalogs[id] {
                return !(catalog[key] ?? []).isEmpty
            }
            return context.history.isLikelyOffered(key, in: slot.term.season) != false
        }

        func creditsFit(_ item: Item, in slot: Slot, slots: [Slot], assignment: [UUID: Int], items: [Item]) -> Bool {
            let occupants = occupants(in: slot, slots: slots, assignment: assignment, items: items, plus: item)
            let coop = occupants.contains { DegreePlanLoad.isCoop($0) }
            let academic = occupants.filter { !DegreePlanLoad.isCoop($0) }.reduce(0.0) { $0 + $1.credits }
            let total = occupants.reduce(0.0) { $0 + $1.credits }
            if coop { return academic <= DegreePlanLoad.coopClassCredits }
            let anchored = anchoredCredits(in: slot)
            return total <= max(DegreePlanLoad.maxCreditsPerTerm, anchored)
        }

        func scheduleFits(_ item: Item, in slot: Slot, slots: [Slot], assignment: [UUID: Int], items: [Item]) -> Bool {
            let id = DegreePlanReorganization.Context.catalogKey(season: slot.term.season, year: slot.term.year)
            guard let catalog = context.catalogs[id] else { return true }
            let keys = self.keys(in: slot, slots: slots, assignment: assignment, items: items, plus: item)
            let groups = keys.map { catalog[$0] ?? [] }
            guard !groups.contains(where: \.isEmpty) else { return false }
            return DegreePlanFeasibility.hasConflictFreeCombination(groups)
        }

        func taken(before slot: Slot, slots: [Slot], assignment: [UUID: Int], items: [Item]) -> Set<CourseKey> {
            var keys = plan.completedKeys
            for term in plan.terms where term.degreePlanHasEnded(now: context.now) {
                keys.formUnion(term.courses.compactMap(\.key))
            }
            for (index, other) in slots.enumerated() where other.sortKey < slot.sortKey {
                keys.formUnion(anchoredKeys(in: other))
                for item in items where assignment[item.id] == index { keys.insert(item.key) }
            }
            return context.equivalences.merging(plan.declaredEquivalences).expanding(keys)
        }

        func requisiteMet(_ knowledge: DegreePlanReorganization.RequisiteKnowledge, taken: Set<CourseKey>) -> Bool {
            switch knowledge {
            case .unknown, .none: return true
            case .needs(let requisite):
                return DegreePlanAnalysis.status(of: requisite, satisfiedBy: taken, equivalences: context.equivalences) == .met
            }
        }

        /// Corequisites can be checked once every course they name that this search is placing
        /// has a semester. Until then the placement is allowed and the finished plan is checked.
        func coreqsReady(_ item: Item, items: [Item], assignment: [UUID: Int]) -> Bool {
            guard case .needs(let requisite) = context.corequisites[item.key] ?? .unknown else { return true }
            let pending = items.contains { other in
                other.id != item.id && requisite.referencedCourses.contains(other.key) && assignment[other.id] == nil
            }
            return !pending
        }

        // MARK: Occupants

        func occupants(in slot: Slot, slots: [Slot], assignment: [UUID: Int], items: [Item], plus extra: Item?) -> [DegreePlanCourse] {
            var courses = anchoredCourses(in: slot)
            guard let index = slots.firstIndex(where: { $0.term.id == slot.term.id }) else { return courses }
            for item in items where assignment[item.id] == index && item.id != extra?.id {
                courses.append(DegreePlanCourse(id: item.id, key: item.key, title: item.title, credits: item.credits))
            }
            if let extra {
                courses.append(DegreePlanCourse(id: extra.id, key: extra.key, title: extra.title, credits: extra.credits))
            }
            return courses
        }

        func keys(in slot: Slot, slots: [Slot], assignment: [UUID: Int], items: [Item], plus extra: Item?) -> [CourseKey] {
            occupants(in: slot, slots: slots, assignment: assignment, items: items, plus: extra).compactMap(\.key)
        }

        func anchoredCourses(in slot: Slot) -> [DegreePlanCourse] {
            guard let term = plan.terms.first(where: { $0.id == slot.term.id }) else { return [] }
            return term.courses.filter { !movableIDs.contains($0.id) }
        }

        func anchoredKeys(in slot: Slot) -> Set<CourseKey> { Set(anchoredCourses(in: slot).compactMap(\.key)) }

        func anchoredCredits(in slot: Slot) -> Double { anchoredCourses(in: slot).reduce(0) { $0 + $1.credits } }

        // MARK: Ordering and alternatives

        func order(_ items: [Item], slots: [Slot]) -> [Item] {
            var pool = items
            var placed: [Item] = []
            var placedKeys = Set<CourseKey>()
            while !pool.isEmpty {
                let ready = pool.filter { item in
                    referenced(by: item.key).allSatisfy { dep in !pool.contains { $0.key == dep } || placedKeys.contains(dep) }
                }
                let choices = ready.isEmpty ? pool : ready
                let next = choices.min { a, b in
                    let aSeasons = slots.filter { isOffered(a.key, slot: $0) }.count
                    let bSeasons = slots.filter { isOffered(b.key, slot: $0) }.count
                    return (aSeasons, a.homeSort, a.index) < (bSeasons, b.homeSort, b.index)
                } ?? choices[0]
                placed.append(next)
                placedKeys.insert(next.key)
                pool.removeAll { $0.id == next.id }
            }
            return placed
        }

        struct Alternative {
            var key: CourseKey
            var title: String
            var credits: Double
            var requirement: String
        }

        func alternatives(for item: Item) -> [Alternative] {
            guard let requirements = context.requirements else { return [] }
            let rule = originalAudit?.ruleCounting(item.key)?.rule
                ?? requirements.allRules.first { $0.listedCourses.contains(item.key) }
            guard let rule else { return [] }
            let name = requirements.title(ofRule: rule.id) ?? rule.displayLabel
            let inPlan = Set(plan.degreePlanCourseKeys).subtracting([item.key])
            var found: [Alternative] = []
            var seen = Set<CourseKey>()

            func add(_ key: CourseKey, title: String?, credits: Double?) {
                guard key != item.key, !inPlan.contains(key), seen.insert(key).inserted else { return }
                let known = context.candidates.first { $0.key == key }
                found.append(Alternative(
                    key: key,
                    title: title ?? known?.title ?? requirements.courseTitles[key] ?? key.description,
                    credits: credits ?? known?.credits ?? item.credits,
                    requirement: name
                ))
            }

            switch rule.kind {
            case .required(let option):
                for alternative in option.alternatives where alternative.count == 1 {
                    if let key = alternative.first { add(key, title: nil, credits: nil) }
                }
            case .choose(_, _, let options, let ranges):
                for alternative in options.flatMap(\.alternatives) where alternative.count == 1 {
                    if let key = alternative.first { add(key, title: nil, credits: nil) }
                }
                for candidate in context.candidates where ranges.contains(where: { $0.contains(candidate.key) }) {
                    add(candidate.key, title: candidate.title, credits: candidate.credits)
                }
            case .generalElectives:
                let paths = context.attributes.nupaths[item.key] ?? []
                for candidate in context.candidates {
                    let candidatePaths = candidate.nupaths.union(context.attributes.nupaths[candidate.key] ?? [])
                    guard paths.isEmpty || !paths.isDisjoint(with: candidatePaths) else { continue }
                    add(candidate.key, title: candidate.title, credits: candidate.credits)
                }
            }
            return found
        }

        func referenced(by key: CourseKey) -> [CourseKey] {
            var keys: [CourseKey] = []
            if case .needs(let requisite) = context.prerequisites[key] ?? .unknown { keys += requisite.referencedCourses }
            if case .needs(let requisite) = context.corequisites[key] ?? .unknown { keys += requisite.referencedCourses }
            return keys
        }

        // MARK: Slots

        func existingSlots() -> [Slot] {
            plan.terms.filter { !$0.degreePlanHasEnded(now: context.now) }.map { Slot(term: $0, isNew: false) }
        }

        func summerSlots(through limit: Int, existing: [DegreePlanTerm]) -> [Slot] {
            guard let first = existing.filter({ !$0.degreePlanHasEnded(now: context.now) }).map(\.sortKey).min() else { return [] }
            let startYear = (first / 4) / 12
            let endYear = (limit / 4) / 12
            guard endYear >= startYear else { return [] }
            var slots: [Slot] = []
            for year in startYear...endYear {
                for season in [PlanSeason.summerA, .summerFull, .summerB] {
                    guard !existing.contains(where: { $0.season == season && $0.year == year }) else { continue }
                    var term = DegreePlanTerm(season: season, year: year)
                    guard term.sortKey >= first, term.sortKey <= limit, !term.degreePlanHasEnded(now: context.now) else { continue }
                    term.id = DegreePlanReordering.stableID(for: "degree-plan-term-\(season.rawValue)-\(year)")
                    slots.append(Slot(term: term, isNew: true))
                }
            }
            return slots
        }

        // MARK: A finished plan

        func materialize(items: [Item], assignment: [UUID: Int], slots: [Slot]) -> DegreePlan {
            var built = plan
            let moving = Set(items.map(\.id))
            for index in built.terms.indices {
                built.terms[index].courses.removeAll { moving.contains($0.id) }
            }
            let used = Set(assignment.values)
            for (index, slot) in slots.enumerated() where slot.isNew && used.contains(index) {
                DegreePlanEditing.addTerm(slot.term, to: &built)
            }
            for item in items {
                guard let index = assignment[item.id] else { continue }
                let slot = slots[index]
                guard let termID = built.terms.first(where: { $0.season == slot.term.season && $0.year == slot.term.year })?.id else { continue }
                let course = DegreePlanCourse(id: item.id, key: item.key, title: item.title, credits: item.credits)
                DegreePlanEditing.add(course, toTerm: termID, in: &built)
            }
            built.sortTerms()
            return built
        }

        func acceptable(_ built: DegreePlan, finishLimit: Int) -> Bool {
            guard preserves(built), scheduleWorks(built), ends(built, by: finishLimit) else { return false }
            return true
        }

        func preserves(_ built: DegreePlan) -> Bool {
            guard let requirements = context.requirements, let originalAudit else { return true }
            let next = DegreeAudit.run(
                plan: built, requirements: requirements, equivalences: context.equivalences, attributes: context.attributes
            )
            for result in originalAudit.ruleResults where result.status.isSatisfied {
                guard let now = next.ruleResults.first(where: { $0.rule.id == result.rule.id }), now.status.isSatisfied else { return false }
            }
            for check in originalAudit.countedChecks where check.status.isSatisfied {
                guard let now = next.countedChecks.first(where: { $0.id == check.id }), now.status.isSatisfied else { return false }
            }
            return true
        }

        /// Offerings, clashes, prerequisites, corequisites and credit caps on the finished plan.
        func scheduleWorks(_ built: DegreePlan) -> Bool {
            let report = DegreePlanFeasibility.assess(plan: built, history: context.history, sections: sections(for:), now: context.now)
            guard report.infeasibleTerms.isEmpty else { return false }
            var taken = built.completedKeys
            for term in built.terms {
                if term.degreePlanHasEnded(now: context.now) {
                    taken.formUnion(term.courses.compactMap(\.key))
                    continue
                }
                if DegreePlanLoad.isCoopTerm(term), DegreePlanLoad.classCredits(in: term) > DegreePlanLoad.coopClassCredits { return false }
                if !DegreePlanLoad.isCoopTerm(term), term.credits > max(DegreePlanLoad.maxCreditsPerTerm, plan.terms.first { $0.id == term.id }?.credits ?? 0) {
                    return false
                }
                let same = Set(term.courses.compactMap(\.key))
                for course in term.courses {
                    guard let key = course.key else { continue }
                    let counting = context.equivalences.merging(built.declaredEquivalences).expanding(taken)
                    if !requisiteMet(context.prerequisites[key] ?? .unknown, taken: counting) { return false }
                    if !requisiteMet(context.corequisites[key] ?? .unknown, taken: counting.union(same)) { return false }
                }
                taken.formUnion(same)
            }
            return true
        }

        func ends(_ built: DegreePlan, by limit: Int) -> Bool {
            if context.requirements != nil, let finish = finishSort(built) { return finish <= limit }
            let last = built.terms.filter { !$0.courses.isEmpty }.map(\.sortKey).max() ?? 0
            return last <= limit
        }

        func finishSort(_ built: DegreePlan) -> Int? {
            guard let requirements = context.requirements else {
                return built.terms.filter { !$0.courses.isEmpty }.map(\.sortKey).max()
            }
            switch DegreeMilestone.find(plan: built, requirements: requirements, equivalences: context.equivalences, attributes: context.attributes) {
            case nil: return nil
            case .completed: return Int.min
            case .after(let id, _): return built.terms.first { $0.id == id }?.sortKey
            }
        }

        func finishName(_ built: DegreePlan) -> String? {
            guard let requirements = context.requirements else {
                return built.terms.last { !$0.courses.isEmpty }?.shortName
            }
            switch DegreeMilestone.find(plan: built, requirements: requirements, equivalences: context.equivalences, attributes: context.attributes) {
            case nil: return built.terms.last { !$0.courses.isEmpty }?.shortName
            case .completed: return nil
            case .after(_, let name): return name
            }
        }

        // MARK: The proposal

        func proposal(_ found: Found, delayed: Bool, previousFinish: Int?) -> DegreePlanReorganization.Proposal? {
            let built = materialize(items: found.items, assignment: found.assignment, slots: found.slots)
            var changes: [DegreePlanReorganization.Change] = []
            for item in found.items {
                guard let index = found.assignment[item.id] else { continue }
                let slot = found.slots[index]
                let home = plan.terms.first { $0.id == item.home }
                let destination = built.terms.first { $0.season == slot.term.season && $0.year == slot.term.year } ?? slot.term
                if item.isReplacement, let removed = item.replaces, let home {
                    let added = DegreePlanCourse(key: item.key, title: item.title, credits: item.credits)
                    let requirement = alternatives(for: Item(
                        id: item.id, key: removed, title: item.title, credits: item.credits,
                        home: item.home, homeSort: item.homeSort, index: item.index, replaces: nil
                    )).first { $0.key == item.key }?.requirement ?? "the same requirement"
                    changes.append(.init(
                        id: "replace-\(item.id.uuidString)-\(item.key)-\(destination.season.rawValue)-\(destination.year)",
                        kind: .replace(courseID: item.id, removed: removed, added: added, to: bare(destination)),
                        reason: "\(item.key.description) also counts toward \(requirement) and can be taken in the \(seasonWord(destination.season)), so it replaces \(removed.description)"
                    ))
                } else if let home, home.season != destination.season || home.year != destination.year {
                    changes.append(.init(
                        id: "move-\(item.id.uuidString)-\(destination.season.rawValue)-\(destination.year)",
                        kind: .move(courseID: item.id, course: item.key, from: bare(home), to: bare(destination)),
                        reason: moveReason(item, from: home, to: destination, found: found)
                    ))
                }
            }
            guard !changes.isEmpty else { return nil }
            let newName = finishName(built)
            let oldName = finishName(plan)
            var delay: DegreePlanReorganization.Delay?
            if delayed, let newName, let oldName, (finishSort(built) ?? 0) > (previousFinish ?? .min) {
                let because = delayReason(found: found, newName: newName, previous: previousFinish)
                delay = .init(fromName: oldName, toName: newName, because: because)
            }
            let title: String
            if let delay {
                title = "Finishes after \(delay.toName) instead of \(delay.fromName)."
            } else if let newName {
                title = "Finishes after \(newName), the same as now."
            } else {
                title = "Keeps the same finish."
            }
            return DegreePlanReorganization.Proposal(
                changes: changes, proposed: built, outcomeTitle: title, outcomeDetail: delay?.because, delay: delay
            )
        }

        func bare(_ term: DegreePlanTerm) -> DegreePlanTerm {
            DegreePlanTerm(id: term.id, season: term.season, year: term.year)
        }

        func moveReason(_ item: Item, from home: DegreePlanTerm, to dest: DegreePlanTerm, found: Found) -> String {
            let name = item.key.description
            if !isOffered(item.key, slot: Slot(term: home, isNew: false)) {
                var sentence = "\(name) \(offeredPhrase(item.key, absentFrom: home)), so it moved to \(dest.shortName)"
                if let blocked = earliestOffered(item, before: dest, slots: found.slots), DegreePlanLoad.isCoopTerm(blocked) {
                    sentence = "\(name) \(offeredPhrase(item.key, absentFrom: home)), and \(blocked.shortName) is a co-op term, so it moved to \(dest.shortName)"
                }
                return sentence
            }
            if let other = clashPartner(item.key, in: home) {
                return "\(name) overlaps \(other.description) in \(home.shortName), so it moved to \(dest.shortName)"
            }
            if let needed = unmetPrerequisite(item, in: home, found: found) {
                return "\(needed) moved, so \(name) moved to \(dest.shortName) to come after it"
            }
            if DegreePlanLoad.isCoopTerm(home) {
                return "\(home.shortName) is a co-op term, so \(name) moved to \(dest.shortName)"
            }
            if home.credits + item.credits > DegreePlanLoad.maxCreditsPerTerm {
                return "\(home.shortName) would be over \(DegreePlanText.credits(DegreePlanLoad.maxCreditsPerTerm)), so \(name) moved to \(dest.shortName)"
            }
            return "\(name) moved to \(dest.shortName) so the other courses still fit"
        }

        func offeredPhrase(_ key: CourseKey, absentFrom home: DegreePlanTerm) -> String {
            let families = offeringFamilies(key)
            let seasonIsTypical = families.contains { Self.family($0, matches: home.season) }
            if !families.isEmpty, !seasonIsTypical {
                if families.count == 1, let only = families.first {
                    return "has only been offered in \(only)"
                }
                return "has been offered in \(Self.list(families)), not in the \(seasonWord(home.season))"
            }
            let catalogID = DegreePlanReorganization.Context.catalogKey(season: home.season, year: home.year)
            if context.catalogs[catalogID] != nil {
                return "isn’t offered in \(home.name)"
            }
            let summary = context.history.summary(of: key, in: home.season)
            return summary.prefix(1).lowercased() + summary.dropFirst()
        }

        func offeringFamilies(_ key: CourseKey) -> [String] {
            let seasons = context.history.seasons(of: key)
            var families: [String] = []
            for (family, match) in [("spring", PlanSeason.spring), ("summer", PlanSeason.summerFull), ("fall", PlanSeason.fall), ("winter", PlanSeason.winter)] {
                if seasons.contains(where: { match == .summerFull ? Self.isSummer($0) : $0 == match }) { families.append(family) }
            }
            return families
        }

        func earliestOffered(_ item: Item, before dest: DegreePlanTerm, slots: [Slot]) -> DegreePlanTerm? {
            slots.map(\.term)
                .filter { $0.sortKey < dest.sortKey && isOffered(item.key, slot: Slot(term: $0, isNew: false)) }
                .min { $0.sortKey < $1.sortKey }
        }

        func clashPartner(_ key: CourseKey, in term: DegreePlanTerm) -> CourseKey? {
            guard let catalog = context.catalogs[DegreePlanReorganization.Context.catalogKey(season: term.season, year: term.year)] else { return nil }
            let others = term.courses.compactMap(\.key).filter { $0 != key }
            for other in others {
                let mine = catalog[key] ?? []
                let theirs = catalog[other] ?? []
                guard !mine.isEmpty, !theirs.isEmpty else { continue }
                let clashes = mine.allSatisfy { section in theirs.allSatisfy { section.conflicts(with: $0) } }
                if clashes { return other }
            }
            return others.first
        }

        /// A planned prerequisite that, in the new arrangement, is no longer taken before `home`.
        func unmetPrerequisite(_ item: Item, in home: DegreePlanTerm, found: Found) -> CourseKey? {
            guard case .needs(let requisite) = context.prerequisites[item.key] ?? .unknown else { return nil }
            let before = taken(before: Slot(term: home, isNew: false), slots: found.slots, assignment: found.assignment, items: found.items)
            guard !requisiteMet(.needs(requisite), taken: before) else { return nil }
            return requisite.referencedCourses.first { key in
                found.items.contains { $0.key == key }
            }
        }

        func delayReason(found: Found, newName: String, previous: Int?) -> String {
            let late = found.items.filter { item in
                guard let index = found.assignment[item.id] else { return false }
                return found.slots[index].sortKey > (previous ?? .max)
            }
            guard let item = late.min(by: { ($0.homeSort, $0.index) < ($1.homeSort, $1.index) }) else {
                return "Nothing earlier can hold the remaining courses, so the earliest finish is \(newName)."
            }
            let name = item.key.description
            if case .needs(let requisite) = context.prerequisites[item.key] ?? .unknown,
               let needed = requisite.referencedCourses.first(where: { key in plan.terms.contains { $0.courses.contains { $0.key == key } } }) {
                let families = offeringFamilies(needed)
                if families.count == 1, let only = families.first {
                    return "\(name) needs \(needed.description), and \(needed.description) has only been offered in \(only), so the earliest finish is \(newName)."
                }
                return "\(name) needs \(needed.description), which can’t be taken earlier, so the earliest finish is \(newName)."
            }
            let families = offeringFamilies(item.key)
            if families.count == 1, let only = families.first {
                return "\(name) has only been offered in \(only), so the earliest finish is \(newName)."
            }
            return "\(name) can’t be taken until \(newName), so that is the earliest finish."
        }

        func seasonWord(_ season: PlanSeason) -> String {
            switch season {
            case .fall: "fall"
            case .spring: "spring"
            case .winter: "winter"
            case .summerA: "Summer A"
            case .summerB: "Summer B"
            case .summerFull: "summer"
            }
        }

        static func family(_ name: String, matches season: PlanSeason) -> Bool {
            switch name {
            case "spring": season == .spring
            case "fall": season == .fall
            case "winter": season == .winter
            case "summer": isSummer(season)
            default: false
            }
        }

        static func isSummer(_ season: PlanSeason) -> Bool {
            switch season {
            case .summerA, .summerB, .summerFull: true
            default: false
            }
        }

        static func list(_ items: [String]) -> String {
            switch items.count {
            case 0, 1: items.first ?? ""
            case 2: "\(items[0]) and \(items[1])"
            default: items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
            }
        }
    }
}
