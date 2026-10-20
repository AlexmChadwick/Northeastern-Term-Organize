//
//  CourseInfoRepository.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

// MARK: - Fetching

/// Where `CourseInfoRepository` reads Banner's course catalog from. A protocol so tests can
/// answer without the network.
protocol CourseInfoFetching: Sendable {
    /// Banner's terms, newest first.
    func terms() async throws -> [Term]
    /// The course's catalog entry as of `term`; nil when that term's catalog doesn't list it.
    func catalogEntry(for key: CourseKey, term: String) async throws -> CourseInfo?
}

/// Where `OfferingHistoryRepository` reads which courses had sections from.
protocol OfferingFetching: Sendable {
    /// Banner's terms, newest first.
    func terms() async throws -> [Term]
    /// Which of `courses` have at least one section in `term`.
    func offeredCourses(term: String, courses: [CourseKey]) async throws -> Set<CourseKey>
}

/// Banner (Northeastern's public class search) as the source of all three.
struct BannerCourseDataFetcher: CourseInfoFetching, OfferingFetching, AttributeFetching {
    private let client: BannerClient
    private let directory = SubjectDirectory()

    init(client: BannerClient = .shared) {
        self.client = client
    }

    /// Banner's terms: the list the catalog already holds from its last launch, else a request.
    func terms() async throws -> [Term] {
        if let cached = await CatalogRepository.shared.cachedRemoteTerms(), !cached.isEmpty { return cached }
        return try await CatalogRepository.shared.remoteTerms()
    }

    func catalogEntry(for key: CourseKey, term: String) async throws -> CourseInfo? {
        let client = self.client, directory = self.directory
        return try await client.fetchCourseInfo(key, term: term) {
            try await directory.lookup(for: term, client: client)
        }
    }

    func offeredCourses(term: String, courses: [CourseKey]) async throws -> Set<CourseKey> {
        try await client.fetchOfferedCourses(term: term, courses: courses)
    }

    func sectionAttributes(term: String, courses: [CourseKey]) async throws -> [CourseKey: Set<String>] {
        let sections = try await client.fetchSections(term: term, courses: courses)
        return sections.filter { !$0.value.isEmpty }.mapValues { sections in
            Set(sections.flatMap { ($0.sectionAttributes ?? []).map(\.code) }.filter { $0 != honorsAttributeCode })
        }
    }
}

/// The subject names Banner's requisite tables use ("Computer Science") mapped to codes
/// ("CS"), per term: each is fetched once. Subjects of other terms are kept too, since a
/// retired course's requisites can name subjects that no longer exist.
private final class SubjectDirectory: Sendable {
    private let state = Isolated()

    private actor Isolated {
        var byTerm: [String: [Subject]] = [:]
        /// Reads in progress, so two courses found in one term share one request.
        var pending: [String: Task<[Subject], Error>] = [:]

        func lookup(for term: String, client: BannerClient) async throws -> BannerParsers.SubjectLookup {
            if byTerm[term] == nil {
                let task = pending[term] ?? Task { try await client.fetchSubjects(term: term) }
                pending[term] = task
                do {
                    byTerm[term] = try await task.value
                } catch {
                    pending[term] = nil
                    throw error
                }
                pending[term] = nil
            }
            // The requested term's subjects go last so they win when names repeat.
            let others = byTerm.filter { $0.key != term }.sorted { $0.key < $1.key }.flatMap(\.value)
            return BannerParsers.SubjectLookup(others + (byTerm[term] ?? []))
        }
    }

    func lookup(for term: String, client: BannerClient) async throws -> BannerParsers.SubjectLookup {
        try await state.lookup(for: term, client: client)
    }
}

// MARK: - Repository

/// Finds catalog information (prerequisites, corequisites, equivalents) for a course by its key,
/// including courses that aren't taught in the loaded term. For each course, in order:
///
/// 1. the loaded catalogs the caller passes in (the schedule of a term the app has);
/// 2. the disk cache in Application Support/CourseInfo, filled by earlier lookups;
/// 3. Banner's course catalog: the newest term, then earlier fall and spring terms, newest
///    first, up to `maxTermsBack` before it ("previous years").
///
/// Courses found are cached long-term (`foundLifetime`), courses no catalog lists for a week
/// (`notFoundLifetime`), so a course that doesn't exist isn't searched for again and again.
/// Failures are not cached. Banner lookups run a few at a time (`concurrency`).
actor CourseInfoRepository {
    static let shared = CourseInfoRepository()

    enum Lookup: Sendable, Equatable {
        case found(CourseInfo)
        /// None of the catalogs searched lists the course (not "no prerequisites").
        case notFound
        /// The network failed; nothing was cached and a later call tries again.
        case failed
    }

    private struct Missing: Codable {
        var key: CourseKey
        var checkedAt: Date
    }

    private struct Stored: Codable {
        var version: Int
        var found: [CourseInfo]
        var missing: [Missing]
    }

    private static let storedVersion = 1

    private let fetcher: CourseInfoFetching
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let maxTermsBack: Int
    private let notFoundLifetime: TimeInterval
    private let foundLifetime: TimeInterval
    private let concurrency: Int

    private var found: [CourseKey: CourseInfo] = [:]
    private var missing: [CourseKey: Date] = [:]
    private var didLoad = false
    private var isDirty = false
    private var termCache: (codes: [String], at: Date)?

    init(
        fetcher: CourseInfoFetching = BannerCourseDataFetcher(),
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        maxTermsBack: Int = 8,
        notFoundLifetime: TimeInterval = 7 * 24 * 3600,
        foundLifetime: TimeInterval = 180 * 24 * 3600,
        concurrency: Int = 2
    ) {
        self.fetcher = fetcher
        self.fileURL = (directory ?? AppPaths.courseInfoDirectory).appendingPathComponent("course-info.json")
        self.now = now
        self.maxTermsBack = maxTermsBack
        self.notFoundLifetime = notFoundLifetime
        self.foundLifetime = foundLifetime
        self.concurrency = max(1, concurrency)
    }

    // MARK: Lookups

    /// What's known without the network: the cache (memory and disk). Nil when the course
    /// hasn't been looked up, or the answer has expired.
    func cachedLookup(_ key: CourseKey) -> Lookup? {
        loadIfNeeded()
        if let info = found[key], isFresh(info) { return .found(info) }
        if let checkedAt = missing[key], now().timeIntervalSince(checkedAt) < notFoundLifetime { return .notFound }
        return nil
    }

    func lookup(_ key: CourseKey, indexes: [CatalogIndex] = []) async -> Lookup {
        await lookup([key], indexes: indexes)[key] ?? .failed
    }

    /// Looks up several courses. `indexes` are the loaded catalogs, newest first.
    ///
    /// - Parameter onResult: called as each course is answered (the ones the loaded catalogs and
    ///   the cache know first, then the others as Banner replies), so a screen can fill in as the
    ///   lookups finish rather than when the last one does.
    func lookup(
        _ keys: [CourseKey],
        indexes: [CatalogIndex] = [],
        onResult: (@Sendable (CourseKey, Lookup) async -> Void)? = nil
    ) async -> [CourseKey: Lookup] {
        loadIfNeeded()
        var results: [CourseKey: Lookup] = [:]
        var pending: [CourseKey] = []
        for key in Self.unique(keys) {
            let known = CourseInfo.fromLoaded(key, in: indexes).map(Lookup.found) ?? cachedLookup(key)
            if let known {
                results[key] = known
                await onResult?(key, known)
            } else {
                pending.append(key)
            }
        }
        guard !pending.isEmpty else { return results }

        let terms: [String]
        do {
            terms = try await catalogTerms()
        } catch {
            for key in pending {
                results[key] = staleOrFailed(key)
                await onResult?(key, results[key] ?? .failed)
            }
            return results
        }

        let limit = min(concurrency, pending.count)
        await withTaskGroup(of: (CourseKey, Lookup).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard let key = iterator.next() else { return }
                group.addTask { (key, await self.resolve(key, terms: terms)) }
            }
            for _ in 0..<limit { addNext() }
            while let (key, result) = await group.next() {
                let answer = result == .failed ? staleOrFailed(key) : result
                results[key] = answer
                await onResult?(key, answer)
                addNext()
            }
        }
        saveIfNeeded()
        return results
    }

    /// Forgets everything cached, in memory and on disk.
    func clear() {
        found = [:]
        missing = [:]
        termCache = nil
        didLoad = true
        isDirty = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Terms

    /// The terms whose catalogs are searched, newest first: the newest Northeastern term, then
    /// the fall and spring terms before it, at most `maxBack` of them. Summers are skipped
    /// since the catalog rarely changes between a spring and the summer after it, and
    /// walking every term would be many more requests for the same answers.
    static func catalogTerms(from terms: [Term], maxBack: Int) -> [String] {
        let neu = terms.filter { $0.college == .neu }.sorted(by: >)
        guard let newest = neu.first else { return [] }
        var codes = [newest.code]
        for term in neu.dropFirst() where term.season == .fall || term.season == .spring {
            guard codes.count <= maxBack else { break }
            codes.append(term.code)
        }
        return codes
    }

    private func catalogTerms() async throws -> [String] {
        if let cached = termCache, now().timeIntervalSince(cached.at) < 3600 { return cached.codes }
        let codes = Self.catalogTerms(from: try await fetcher.terms(), maxBack: maxTermsBack)
        guard !codes.isEmpty else { throw BannerError.invalidResponse }
        termCache = (codes, now())
        return codes
    }

    // MARK: Resolving

    private func resolve(_ key: CourseKey, terms: [String]) async -> Lookup {
        let result = await search(key, terms: terms)
        switch result {
        case .found(let info):
            found[key] = info
            missing[key] = nil
            isDirty = true
        case .notFound:
            missing[key] = now()
            isDirty = true
        case .failed:
            break
        }
        return result
    }

    /// Asks each term's catalog, newest first, until one lists the course. A course only an older
    /// catalog lists has been retired.
    private func search(_ key: CourseKey, terms: [String]) async -> Lookup {
        for (position, term) in terms.enumerated() {
            do {
                if var info = try await fetcher.catalogEntry(for: key, term: term) {
                    info.isRetired = position > 0
                    return .found(info)
                }
            } catch {
                return .failed
            }
        }
        return .notFound
    }

    /// An expired cache entry beats nothing when the network fails.
    private func staleOrFailed(_ key: CourseKey) -> Lookup {
        found[key].map(Lookup.found) ?? .failed
    }

    private func isFresh(_ info: CourseInfo) -> Bool {
        now().timeIntervalSince(info.fetchedAt) < foundLifetime
    }

    private static func unique(_ keys: [CourseKey]) -> [CourseKey] {
        var seen = Set<CourseKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    // MARK: Disk

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode(Stored.self, from: data), stored.version == Self.storedVersion else { return }
        for info in stored.found { found[info.key] = info }
        for entry in stored.missing { missing[entry.key] = entry.checkedAt }
    }

    private func saveIfNeeded() {
        guard isDirty else { return }
        isDirty = false
        // Entries that have expired aren't worth keeping.
        let current = now()
        let stored = Stored(
            version: Self.storedVersion,
            found: found.values.filter(isFresh).sorted { $0.key < $1.key },
            missing: missing.filter { current.timeIntervalSince($0.value) < notFoundLifetime }
                .map { Missing(key: $0.key, checkedAt: $0.value) }
                .sorted { $0.key < $1.key }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
