//
//  OfferingHistoryRepository.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Works out `OfferingHistory`: in which of the last two years' terms (summers included) a set of
/// courses had sections.
///
/// For each term of the window it uses, in order, a loaded catalog the caller passes in (a full
/// schedule needs no request), the disk cache, and Banner's class search. Banner is asked per
/// term, in batches of a few courses (a search session, then a small search per course), and
/// only about courses it hasn't been asked about: every answer is cached, so a later question
/// about the same courses costs nothing. Past terms never change and are cached forever; the
/// newest term is read again after a week.
actor OfferingHistoryRepository {
    static let shared = OfferingHistoryRepository()

    private struct Entry: Codable {
        var fetchedAt: Date
        /// Whether the course had at least one section in the term.
        var offered: Bool
    }

    private struct Stored: Codable {
        var version: Int
        /// Term code, then course (`CS 3386`).
        var terms: [String: [String: Entry]]
    }

    private static let storedVersion = 2

    /// Courses asked about in one go (one search session).
    private static let batchSize = 10

    private let fetcher: OfferingFetching
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let windowMonths: Int
    private let currentTermLifetime: TimeInterval
    private let concurrency: Int

    private var cache: [String: [String: Entry]] = [:]
    private var didLoad = false
    private var isDirty = false

    init(
        fetcher: OfferingFetching = BannerCourseDataFetcher(),
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        windowMonths: Int = 24,
        currentTermLifetime: TimeInterval = 7 * 24 * 3600,
        concurrency: Int = 2
    ) {
        self.fetcher = fetcher
        self.fileURL = (directory ?? AppPaths.courseInfoDirectory).appendingPathComponent("offering-history.json")
        self.now = now
        self.windowMonths = windowMonths
        self.currentTermLifetime = currentTermLifetime
        self.concurrency = max(1, concurrency)
    }

    /// The Northeastern terms within `months` of the newest one, newest first.
    static func window(of terms: [Term], months: Int) -> [Term] {
        let sorted = terms.sorted(by: >)
        guard let newest = sorted.first else { return [] }
        let oldest = OfferingHistory.monthIndex(ofTerm: newest.code) - months
        return sorted.filter { OfferingHistory.monthIndex(ofTerm: $0.code) >= oldest }
    }

    /// The offering history of `keys`. A term whose answer couldn't be had (the network failed)
    /// is left out of `checkedTerms` rather than reported as "not offered".
    ///
    /// - Parameter indexes: loaded catalogs; a term that has one is answered from it.
    func history(for keys: [CourseKey], indexes: [CatalogIndex] = []) async -> OfferingHistory {
        loadIfNeeded()
        var seen = Set<CourseKey>()
        let keys = keys.filter { seen.insert($0).inserted }
        guard !keys.isEmpty else { return .empty }

        var terms = ((try? await fetcher.terms()) ?? []).filter { $0.college == .neu }
        for index in indexes where index.term.college == .neu && !terms.contains(where: { $0.code == index.term.code }) {
            terms.append(index.term)
        }
        let window = Self.window(of: terms, months: windowMonths)
        guard let newest = window.first?.code else {
            return OfferingHistory(checkedTerms: [], offered: [:], checkedKeys: Set(keys))
        }
        let indexByTerm = Dictionary(indexes.map { ($0.term.code, $0) }, uniquingKeysWith: { first, _ in first })

        var answers: [String: Set<CourseKey>] = [:]
        let limit = min(concurrency, window.count)
        await withTaskGroup(of: (String, Set<CourseKey>?).self) { group in
            var iterator = window.makeIterator()
            func addNext() {
                guard let term = iterator.next() else { return }
                let index = indexByTerm[term.code]
                group.addTask {
                    (term.code, await self.offered(keys, in: term.code, isNewest: term.code == newest, index: index))
                }
            }
            for _ in 0..<limit { addNext() }
            while let (code, offered) = await group.next() {
                if let offered { answers[code] = offered }
                addNext()
            }
        }
        saveIfNeeded()

        let checked = window.map(\.code).filter { answers[$0] != nil }
        var offered: [CourseKey: Set<String>] = [:]
        for code in checked {
            for key in answers[code] ?? [] { offered[key, default: []].insert(code) }
        }
        return OfferingHistory(checkedTerms: checked, offered: offered, checkedKeys: Set(keys))
    }

    /// Forgets the cache, in memory and on disk.
    func clear() {
        cache = [:]
        didLoad = true
        isDirty = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - One term

    /// The courses among `keys` that had sections in the term; nil when that can't be told.
    private func offered(_ keys: [CourseKey], in term: String, isNewest: Bool, index: CatalogIndex?) async -> Set<CourseKey>? {
        // A loaded catalog has every section of its term.
        if let index {
            return Set(keys.filter { !index.sections(for: $0).isEmpty })
        }
        let missing = keys.filter { !isFresh(term: term, key: $0, isNewest: isNewest) }
        var start = 0
        while start < missing.count {
            if Task.isCancelled { return nil }
            let batch = Array(missing[start..<min(start + Self.batchSize, missing.count)])
            start += Self.batchSize
            do {
                let found = try await fetcher.offeredCourses(term: term, courses: batch)
                let stamp = now()
                for key in batch {
                    cache[term, default: [:]][key.description] = Entry(fetchedAt: stamp, offered: found.contains(key))
                }
                isDirty = true
            } catch {
                // What earlier batches found is kept for next time.
                return nil
            }
        }
        return Set(keys.filter { cache[term]?[$0.description]?.offered == true })
    }

    /// The newest term is read again after a week. An older term is settled for good once it was
    /// read after its classes began; one read before then (while the schedule was still being
    /// built) is read again.
    private func isFresh(term: String, key: CourseKey, isNewest: Bool) -> Bool {
        guard let entry = cache[term]?[key.description] else { return false }
        if isNewest { return now().timeIntervalSince(entry.fetchedAt) < currentTermLifetime }
        guard let window = TermCalendar.approximateWindow(for: term) else { return true }
        return entry.fetchedAt >= window.lowerBound
    }

    // MARK: - Disk

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode(Stored.self, from: data), stored.version == Self.storedVersion else { return }
        cache = stored.terms
    }

    private func saveIfNeeded() {
        guard isDirty else { return }
        isDirty = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Stored(version: Self.storedVersion, terms: cache)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
