//
//  CourseInfoStore.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation

/// UI-facing course catalog information for courses outside the loaded term: their
/// prerequisites and corequisites, and which courses count as which.
///
/// Call `load` with the courses a screen needs (the planned and completed courses of a degree
/// plan, say); views read what has arrived with `info(for:)`, `state(for:)` or
/// `requisiteLookup()` and refresh as `version` changes. There is a shared instance, so no
/// wiring is needed.
@MainActor
@Observable
final class CourseInfoStore {
    static let shared = CourseInfoStore()

    enum LookupState: Equatable {
        /// Nothing has been asked about the course yet.
        case unknown
        case loading
        case found(CourseInfo)
        /// None of the catalogs searched lists the course.
        case notFound
        /// The last attempt failed (offline, Banner busy); a later `load` retries.
        case failed
    }

    /// Bumped whenever anything changes (info arrived, a course was found missing, equivalences
    /// changed). Views that derive data from the store can key work on it.
    private(set) var version = 0

    private var infos: [CourseKey: CourseInfo] = [:]
    private var notFound: Set<CourseKey> = []
    private var failedAt: [CourseKey: Date] = [:]
    private var loading: Set<CourseKey> = []
    /// Equivalences from Banner and from cross-listed sections, without any plan's own.
    private var derived = CourseEquivalences.none
    /// Attributes (NUpath…) of courses no loaded catalog has sections of, from `loadAttributes`.
    private var attributeLookups: [CourseKey: CourseAttributeRepository.Lookup] = [:]
    private var attributesFailedAt: [CourseKey: Date] = [:]
    private var attributesLoading: Set<CourseKey> = []

    @ObservationIgnored private let repository: CourseInfoRepository
    @ObservationIgnored private let offeringRepository: OfferingHistoryRepository
    @ObservationIgnored private let attributeRepository: CourseAttributeRepository
    /// The loaded catalogs of the last `load` call, newest first.
    @ObservationIgnored private var indexes: [CatalogIndex] = []
    @ObservationIgnored private var indexStamp: [String: Date] = [:]
    @ObservationIgnored private var prerequisiteCache: (term: String, stamp: Date, list: [(course: CourseKey, requisite: Requisite)])?
    @ObservationIgnored private var crossListed: [String: (stamp: Date, equivalences: CourseEquivalences)] = [:]
    /// A failed lookup isn't retried for this long.
    @ObservationIgnored private let retryDelay: TimeInterval = 60

    init(repository: CourseInfoRepository = .shared, offeringRepository: OfferingHistoryRepository = .shared,
         attributeRepository: CourseAttributeRepository = .shared) {
        self.repository = repository
        self.offeringRepository = offeringRepository
        self.attributeRepository = attributeRepository
    }

    // MARK: - Reading

    /// What is known about the course, from memory. Nil until `load` has found it.
    func info(for key: CourseKey) -> CourseInfo? {
        infos[key]
    }

    func state(for key: CourseKey) -> LookupState {
        if let info = infos[key] { return .found(info) }
        if loading.contains(key) { return .loading }
        if notFound.contains(key) { return .notFound }
        if failedAt[key] != nil { return .failed }
        return .unknown
    }

    /// Prerequisites by course, for `DegreePlanAnalysis.prerequisiteStatus(…lookup:)`: nil when
    /// the course isn't known (yet), `.some(nil)` when it is known to have none. A snapshot, so
    /// it can be called from anywhere.
    func requisiteLookup() -> (CourseKey) -> Requisite?? {
        let table = infos.mapValues(\.prerequisites)
        return { table[$0] }
    }

    /// Corequisites by course, in the same shape as `requisiteLookup`: nil when the course
    /// isn't known, `.some(nil)` when it is known to have none.
    func corequisiteLookup() -> (CourseKey) -> Requisite?? {
        let table = infos.mapValues(\.corequisites)
        return { table[$0] }
    }

    /// Everything that counts as something else: what Banner says (mutual exclusions, cross-listed
    /// courses of the loaded terms) merged with the equivalences the plan's student declared.
    func equivalences(for plan: DegreePlan?) -> CourseEquivalences {
        guard let plan else { return derived }
        return derived.merging(plan.declaredEquivalences)
    }

    // MARK: - Attributes

    /// The NUpath attributes of a plan's courses (and of the courses they count as), for
    /// `DegreeAudit.run(…attributes:)`: from the loaded catalogs of the last `load` right away,
    /// else from what `loadAttributes` found. Courses not known yet are listed as loading.
    func degreeAttributes(for plan: DegreePlan) -> DegreeCourseAttributes {
        let equivalences = equivalences(for: plan)
        var keys = plan.degreePlanCourseKeys
        keys += keys.flatMap { equivalences.group(of: $0) }
        var result = DegreeCourseAttributes()
        var seen = Set<CourseKey>()
        for key in keys where seen.insert(key).inserted {
            switch attributeLookups[key] ?? CourseAttributeRepository.fromLoaded(key, in: indexes) {
            case .found(let codes, _)?:
                result.nupaths[key] = Set(NUPath.from(attributeCodes: Array(codes)))
            case .notFound?, .failed?:
                break
            case nil:
                // Not asked about yet: the plan's own courses are about to be.
                if plan.degreePlanCourseKeys.contains(key) { result.loading.insert(key) }
            }
            if attributesLoading.contains(key) { result.loading.insert(key) }
        }
        return result
    }

    /// Looks up the attributes of courses no loaded catalog has sections of, in Banner's recent
    /// terms (see `CourseAttributeRepository`). `degreeAttributes(for:)` has the answers.
    func loadAttributes(_ keys: [CourseKey], indexes: [CatalogIndex]) async {
        let now = Date()
        var seen = Set<CourseKey>()
        let wanted = keys.filter { key in
            guard seen.insert(key).inserted, !attributesLoading.contains(key),
                  CourseAttributeRepository.fromLoaded(key, in: indexes) == nil else { return false }
            switch attributeLookups[key] {
            case nil: return true
            case .failed?: return attributesFailedAt[key].map { now.timeIntervalSince($0) > retryDelay } ?? true
            case .found?, .notFound?: return false
            }
        }
        guard !wanted.isEmpty else { return }
        attributesLoading.formUnion(wanted)
        version += 1
        let results = await attributeRepository.lookup(wanted, indexes: indexes)
        for key in wanted {
            attributesLoading.remove(key)
            let result = results[key] ?? .failed
            if result != .failed {
                attributeLookups[key] = result
                attributesFailedAt[key] = nil
            } else if !Task.isCancelled {
                // A lookup that was cancelled (the screen went away) didn't fail.
                attributeLookups[key] = .failed
                attributesFailedAt[key] = Date()
            }
        }
        version += 1
    }

    // MARK: - Loading

    /// Finds catalog information for courses: first in the loaded catalogs (`indexes`, newest
    /// first, which is instant), then in the disk cache, then in Banner's course catalog for
    /// the current term and earlier years. Courses already known are skipped. The result is
    /// in `info(for:)`; `version` changes as answers arrive.
    func load(_ keys: [CourseKey], indexes: [CatalogIndex]) async {
        self.indexes = indexes
        var seen = Set<CourseKey>()
        let wanted = keys.filter { seen.insert($0).inserted }

        // What the loaded catalogs know needs no waiting.
        var changed = false
        for key in wanted {
            guard var info = CourseInfo.fromLoaded(key, in: indexes) else { continue }
            if let previous = infos[key] {
                // Only a catalog entry from Banner carries mutual exclusions; keep them, and
                // don't replace an entry with an older term's.
                guard info.sourceTerm >= previous.sourceTerm else { continue }
                info.equivalents = previous.equivalents
                if info == previous { continue }
            }
            infos[key] = info
            notFound.remove(key)
            changed = true
        }
        let stamp = Dictionary(indexes.map { ($0.term.code, $0.catalog.sectionsUpdatedAt) }, uniquingKeysWith: { first, _ in first })
        let indexesChanged = stamp != indexStamp
        indexStamp = stamp
        if changed || indexesChanged, rebuildEquivalences() { changed = true }
        // Only a real change bumps the version, so a view that calls `load` whenever the
        // version changes settles.
        if changed { version += 1 }

        let now = Date()
        let pending = wanted.filter { key in
            infos[key] == nil && !notFound.contains(key) && !loading.contains(key)
                && (failedAt[key].map { now.timeIntervalSince($0) > retryDelay } ?? true)
        }
        guard !pending.isEmpty else { return }
        loading.formUnion(pending)
        version += 1

        // Answers are applied as they arrive, so statuses fill in while the rest still load.
        let results = await repository.lookup(pending, indexes: indexes) { [weak self] key, result in
            await self?.receive(result, for: key)
        }
        for key in pending where loading.contains(key) {
            receive(results[key] ?? .failed, for: key)
        }
    }

    private func receive(_ result: CourseInfoRepository.Lookup, for key: CourseKey) {
        loading.remove(key)
        switch result {
        case .found(let info):
            infos[key] = info
            notFound.remove(key)
            failedAt[key] = nil
            rebuildEquivalences()
        case .notFound:
            notFound.insert(key)
            failedAt[key] = nil
        case .failed:
            // A lookup that was cancelled (the screen went away) didn't fail.
            if !Task.isCancelled { failedAt[key] = Date() }
        }
        version += 1
    }

    // MARK: - Suggestions

    /// The courses a retired course may count as, most likely first, for the "counts as" prompt
    /// of a course the catalog no longer lists (CS 2510 after the renumbering, or IS 4300 that a
    /// requirement still names).
    ///
    /// Two kinds of evidence (see `EquivalenceSuggestion`), both a guess for the student to confirm,
    /// never applied on its own:
    /// - the courses the newest loaded term's prerequisites list beside it ("CS 2100 or CS 2510"),
    /// - the student's courses with a similar title: the plan's completed and planned courses, and
    ///   `alsoComparing` (courses a requirement lists), whether or not they are offered now.
    ///
    /// Titles are read from `catalogTitles` first (the degree requirements' `courseTitles`), then
    /// from Banner's catalog entries and the loaded terms, and last from the plan, whose degree
    /// audit titles are cut at 30 characters.
    ///
    /// Empty for a course the newest catalog lists, and for one `load` hasn't found out about yet.
    /// Courses already equivalent (Banner's, or the plan's declared ones) are left out.
    func equivalenceSuggestions(
        for key: CourseKey,
        plan: DegreePlan? = nil,
        limit: Int = 3,
        catalogTitles: [CourseKey: String] = [:],
        alsoComparing extra: [CourseKey] = []
    ) -> [EquivalenceSuggestion] {
        guard let newest = indexes.first, newest.course(key) == nil else { return [] }
        switch state(for: key) {
        case .found(let info) where info.isRetired == false: return []
        case .found, .notFound: break
        case .unknown, .loading, .failed: return []
        }
        let planKeys = plan.map { $0.completed.compactMap(\.key) + $0.terms.flatMap { $0.courses.compactMap(\.key) } } ?? []
        return EquivalenceSuggester.suggestions(
            for: key,
            prerequisites: prerequisiteList(of: newest),
            isCurrent: { newest.course($0) != nil },
            excluding: equivalences(for: plan),
            limit: limit,
            title: { title(of: $0, catalogTitles: catalogTitles, plan: plan) },
            titleCandidates: planKeys + extra
        )
    }

    /// A course's title from the best source: the catalog titles passed in, a Banner catalog
    /// entry, a loaded term, then the plan's own (30 characters at most).
    private func title(of key: CourseKey, catalogTitles: [CourseKey: String], plan: DegreePlan?) -> String? {
        if let title = catalogTitles[key]?.nilIfBlank { return title }
        if let title = infos[key]?.title.nilIfBlank { return title }
        for index in indexes {
            if let title = index.course(key)?.title.nilIfBlank { return title }
        }
        guard let plan else { return nil }
        for course in plan.completed + plan.terms.flatMap(\.courses) where course.key == key {
            if let title = course.title.nilIfBlank { return title }
        }
        return nil
    }

    private func prerequisiteList(of index: CatalogIndex) -> [(course: CourseKey, requisite: Requisite)] {
        let stamp = index.catalog.sectionsUpdatedAt
        if let cached = prerequisiteCache, cached.term == index.term.code, cached.stamp == stamp { return cached.list }
        let list = index.courses.compactMap { course in course.prereqs.map { (course: course.key, requisite: $0) } }
        prerequisiteCache = (index.term.code, stamp, list)
        return list
    }

    // MARK: - Offering history

    /// In which recent terms (about two years, summers included) the courses had sections, to
    /// avoid suggesting a semester a course has never been taught in. Past terms are cached
    /// forever, the newest is refreshed weekly. Terms the loaded catalogs cover cost no
    /// request: pass `indexes`, or leave it nil to use the ones of the last `load`.
    func offeringHistory(for keys: [CourseKey], indexes: [CatalogIndex]? = nil) async -> OfferingHistory {
        await offeringRepository.history(for: keys, indexes: indexes ?? self.indexes)
    }

    // MARK: - Equivalences

    /// Recomputes `derived`; true when it changed.
    @discardableResult
    private func rebuildEquivalences() -> Bool {
        var result = CourseEquivalences(groups: infos.values.filter { !$0.equivalents.isEmpty }.map { [$0.key] + $0.equivalents })
        for index in indexes {
            result = result.merging(crossListEquivalences(of: index))
        }
        guard result != derived else { return false }
        derived = result
        return true
    }

    private func crossListEquivalences(of index: CatalogIndex) -> CourseEquivalences {
        let stamp = index.catalog.sectionsUpdatedAt
        if let cached = crossListed[index.term.code], cached.stamp == stamp { return cached.equivalences }
        let built = CourseEquivalences(crossListedIn: index)
        crossListed[index.term.code] = (stamp, built)
        return built
    }
}
