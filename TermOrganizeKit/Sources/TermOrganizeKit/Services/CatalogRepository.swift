//
//  CatalogRepository.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Progress of a full-term sync.
struct SyncProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case connecting
        case sections(fetched: Int, total: Int)
        case finishing
    }
    var phase: Phase

    var fraction: Double? {
        if case .sections(let fetched, let total) = phase, total > 0 { return Double(fetched) / Double(total) }
        return nil
    }

    var label: String {
        switch phase {
        case .connecting: "Connecting to Banner…"
        case .sections(let fetched, let total): "Downloading sections \(fetched.formatted()) of \(total.formatted())"
        case .finishing: "Saving catalog…"
        }
    }
}

/// Owns every catalog on device: snapshots bundled with the app and catalogs
/// downloaded or refreshed from Banner. All mutation happens on this actor.
actor CatalogRepository {
    static let shared = CatalogRepository()

    private let client: BannerClient
    private var loaded: [String: TermCatalog] = [:]
    private var loadOrder: [String] = []
    private let maxLoaded = 3

    init(client: BannerClient = .shared) {
        self.client = client
    }

    // MARK: - Terms

    /// Terms that have a catalog on device (bundled or downloaded), newest first.
    func localTermCodes() -> [String] {
        let downloaded = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.catalogsDirectory.path)) ?? []
        let bundled = AppPaths.bundledCatalogURLs.map(\.lastPathComponent)
        let codes = Set((downloaded + bundled).compactMap(CatalogArchive.termCode(fromFileName:)))
        return codes.sorted(by: >)
    }

    private static let cachedTermsKey = "CatalogRepository.remoteTerms"

    /// Terms Banner currently lists, newest first. Falls back to the last
    /// successful response when offline.
    func remoteTerms() async throws -> [Term] {
        do {
            let terms = try await client.fetchTerms(max: 40)
            if let data = try? JSONEncoder().encode(terms) {
                UserDefaults.standard.set(data, forKey: Self.cachedTermsKey)
            }
            return terms
        } catch {
            if let cached = cachedRemoteTerms() { return cached }
            throw error
        }
    }

    func cachedRemoteTerms() -> [Term]? {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedTermsKey) else { return nil }
        return try? JSONDecoder().decode([Term].self, from: data)
    }

    // MARK: - Loading & saving

    /// Loads the freshest catalog for a term: the downloaded copy when it is newer
    /// than the bundled snapshot.
    func catalog(for termCode: String) throws -> TermCatalog? {
        if let cached = loaded[termCode] {
            touch(termCode)
            return cached
        }
        let fileName = CatalogArchive.fileName(forTerm: termCode)
        var candidates: [TermCatalog] = []
        let downloadedURL = AppPaths.catalogsDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: downloadedURL.path) {
            do {
                candidates.append(try CatalogArchive.read(from: downloadedURL))
            } catch {
                // A corrupt download should not hide the bundled snapshot.
                try? FileManager.default.removeItem(at: downloadedURL)
            }
        }
        if let bundledURL = AppPaths.bundledCatalogURLs.first(where: { $0.lastPathComponent == fileName }) {
            candidates.append(try CatalogArchive.read(from: bundledURL))
        }
        guard let best = candidates.max(by: { freshness($0) < freshness($1) }) else { return nil }
        remember(best)
        return best
    }

    private func freshness(_ c: TermCatalog) -> (Date, Int) {
        (c.sectionsUpdatedAt, c.courses.filter(\.detailsLoaded).count)
    }

    func save(_ catalog: TermCatalog) throws {
        let url = AppPaths.catalogsDirectory.appendingPathComponent(CatalogArchive.fileName(forTerm: catalog.term.code))
        try CatalogArchive.write(catalog, to: url)
        remember(catalog)
    }

    /// Removes downloaded catalogs (bundled snapshots remain).
    func clearDownloads() throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: AppPaths.catalogsDirectory.path) {
            try fm.removeItem(at: AppPaths.catalogsDirectory.appendingPathComponent(name))
        }
        loaded.removeAll()
        loadOrder.removeAll()
    }

    private func remember(_ catalog: TermCatalog) {
        loaded[catalog.term.code] = catalog
        touch(catalog.term.code)
        while loadOrder.count > maxLoaded {
            let evicted = loadOrder.removeFirst()
            loaded[evicted] = nil
        }
    }

    private func touch(_ code: String) {
        loadOrder.removeAll { $0 == code }
        loadOrder.append(code)
    }

    /// Course details known from other terms' catalogs, used to fill in stubs.
    private func knowledge(excluding termCode: String) -> [CourseKey: Course] {
        var result: [CourseKey: Course] = [:]
        for code in localTermCodes() where code != termCode {
            guard let other = try? catalog(for: code) else { continue }
            for course in other.courses where course.detailsLoaded && result[course.key] == nil {
                result[course.key] = course
            }
        }
        return result
    }

    // MARK: - Network operations

    /// Downloads every section of a term (about 20 requests) and merges it
    /// with what is already known.
    func syncTerm(_ term: Term, progress: @escaping @Sendable (SyncProgress) -> Void) async throws -> TermCatalog {
        progress(SyncProgress(phase: .connecting))
        async let subjectsTask = client.fetchSubjects(term: term.code)
        async let campusesTask = client.fetchCampuses(term: term.code)
        async let attributesTask = client.fetchAttributes(term: term.code)
        let sections = try await client.fetchAllSections(term: term.code, parallelism: 4) { fetched, total in
            progress(SyncProgress(phase: .sections(fetched: fetched, total: total)))
        }
        let subjects = try? await subjectsTask
        let campuses = try? await campusesTask
        let attributes = try? await attributesTask
        try Task.checkCancellation()

        progress(SyncProgress(phase: .finishing))
        let existing = try? catalog(for: term.code)
        let merged = CatalogBuilder.merge(
            existing: existing,
            fresh: sections,
            term: term,
            subjects: subjects,
            campuses: campuses,
            attributes: attributes,
            knowledge: knowledge(excluding: term.code)
        )
        try save(merged)
        return merged
    }

    /// Fetches live sections for one course and stores them. Instructors for
    /// sections we have not seen before are fetched too.
    func refreshCourse(_ key: CourseKey, termCode: String) async throws -> TermCatalog {
        guard var catalog = try catalog(for: termCode) else { throw BannerError.invalidResponse }
        let live = try await client.fetchSections(term: termCode, courses: [key])
        // An empty answer for a course we know has sections is far more likely a
        // Banner hiccup than a cancellation; keep what we have.
        guard let fresh = live[key], !fresh.isEmpty || !catalog.sections.contains(where: { $0.courseKey == key }) else {
            return catalog
        }
        let hadDetails = catalog.courses.first { $0.key == key }?.detailsLoaded == true
        CatalogBuilder.applyCourseRefresh(&catalog, course: key, banner: fresh)
        try await fillInstructors(&catalog, crns: catalog.sections.filter { $0.courseKey == key && $0.instructors == nil }.map(\.crn))
        if hadDetails {
            try await fillRestrictions(&catalog, crns: catalog.sections.filter { $0.courseKey == key }.map(\.crn))
        }
        catalog.recomputePostreqs()
        try save(catalog)
        return catalog
    }

    /// Live sections for several courses (used by the watchlist). Updates the
    /// stored catalog when one exists.
    func refreshCourses(_ keys: [CourseKey], termCode: String) async throws -> [CourseKey: [CourseSection]] {
        let live = try await client.fetchSections(term: termCode, courses: keys)
        var result: [CourseKey: [CourseSection]] = [:]
        if var catalog = try? catalog(for: termCode) {
            for key in keys {
                if let fresh = live[key], !fresh.isEmpty || !catalog.sections.contains(where: { $0.courseKey == key }) {
                    CatalogBuilder.applyCourseRefresh(&catalog, course: key, banner: fresh)
                }
                result[key] = catalog.sections.filter { $0.courseKey == key }
            }
            try? save(catalog)
        } else {
            for key in keys {
                result[key] = CatalogBuilder.makeSections(from: live[key] ?? [])
            }
        }
        return result
    }

    /// Fetches description, requisites, catalog title and instructors for a
    /// course that only has stub data.
    func loadDetails(for key: CourseKey, termCode: String) async throws -> TermCatalog {
        guard var catalog = try catalog(for: termCode),
              let courseIndex = catalog.courses.firstIndex(where: { $0.key == key }) else {
            throw BannerError.invalidResponse
        }
        let sections = catalog.sections.filter { $0.courseKey == key }
        guard let firstCRN = sections.first?.crn else { return catalog }

        let lookup = BannerParsers.SubjectLookup(catalog.subjects)
        let course = catalog.courses[courseIndex]
        if !course.detailsLoaded {
            catalog.courses[courseIndex] = try await client.fetchCourseDetails(term: termCode, crn: firstCRN, course: course, subjects: lookup)
        }
        if course.specialTopics {
            for section in sections where section.description == nil {
                let html = try await client.fetchDescriptionHTML(term: termCode, crn: section.crn)
                if let i = catalog.sections.firstIndex(where: { $0.crn == section.crn }) {
                    catalog.sections[i].description = BannerParsers.description(fromHTML: html).nilIfBlank ?? ""
                }
            }
        }
        try await fillInstructors(&catalog, crns: sections.filter { $0.instructors == nil }.map(\.crn))
        let missingRestrictions = catalog.sections.filter { $0.courseKey == key && $0.restrictions == nil }.map(\.crn)
        try await fillRestrictions(&catalog, crns: missingRestrictions)
        catalog.recomputePostreqs()
        try save(catalog)
        return catalog
    }

    private func fillInstructors(_ catalog: inout TermCatalog, crns: [String]) async throws {
        guard !crns.isEmpty else { return }
        let termCode = catalog.term.code
        let client = self.client
        let results = await withTaskGroup(of: (String, [Instructor]?).self) { group in
            var out: [String: [Instructor]] = [:]
            var iterator = crns.makeIterator()
            for _ in 0..<4 {
                guard let crn = iterator.next() else { break }
                group.addTask { (crn, try? await client.fetchInstructors(term: termCode, crn: crn)) }
            }
            while let (crn, instructors) = await group.next() {
                if let instructors { out[crn] = instructors }
                if let next = iterator.next() {
                    group.addTask { (next, try? await client.fetchInstructors(term: termCode, crn: next)) }
                }
            }
            return out
        }
        for i in catalog.sections.indices {
            if let instructors = results[catalog.sections[i].crn] { catalog.sections[i].instructors = instructors }
        }
    }

    /// Reads restriction lists a few at a time. A failed section keeps whatever
    /// was already cached (nil when it was never loaded).
    private func fillRestrictions(_ catalog: inout TermCatalog, crns: [String]) async throws {
        guard !crns.isEmpty else { return }
        let termCode = catalog.term.code
        let client = self.client
        let results = await withTaskGroup(of: (String, [SectionRestriction]?).self) { group in
            var out: [String: [SectionRestriction]] = [:]
            var iterator = crns.makeIterator()
            func enqueue(_ crn: String) {
                group.addTask {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    return (crn, try? await client.fetchRestrictions(term: termCode, crn: crn))
                }
            }
            for _ in 0..<2 {
                guard let crn = iterator.next() else { break }
                enqueue(crn)
            }
            while let (crn, restrictions) = await group.next() {
                if let restrictions { out[crn] = restrictions }
                if let next = iterator.next() { enqueue(next) }
            }
            return out
        }
        for index in catalog.sections.indices {
            if let restrictions = results[catalog.sections[index].crn] {
                catalog.sections[index].restrictions = restrictions
            }
        }
    }
}
