//
//  CourseAttributeRepository.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Where `CourseAttributeRepository` reads sections' attributes from. A protocol so tests can
/// answer without the network.
protocol AttributeFetching: Sendable {
    /// Banner's terms, newest first.
    func terms() async throws -> [Term]
    /// The attribute codes of each course's sections in `term`, all sections together, for the
    /// courses among `courses` that have sections then.
    func sectionAttributes(term: String, courses: [CourseKey]) async throws -> [CourseKey: Set<String>]
}

/// Finds the attributes (NUpath and others) of courses by their key.
///
/// Banner keeps attributes on sections, not on course catalog entries: its course catalog's
/// attribute endpoint (`courseSearchResults/getCourseAttributes`) answered "No Attribute
/// information available." for ENGW 1111, ENGW 3302, CS 4500 and MATH 1341 in Fall 2026 when
/// tried in October 2026, although their sections carry NUpath attributes. So for each course,
/// in order:
///
/// 1. the loaded catalogs the caller passes in, newest first (a term's full schedule);
/// 2. the disk cache in Application Support/CourseInfo, filled by earlier lookups;
/// 3. Banner's class search in the terms of the last three years, summers included, newest
///    first, stopping at the first term with sections (a search session per term, then a search
///    per course, a few courses at a time).
///
/// Attributes found are kept for a month (they rarely change), courses without sections in the
/// window for a week. Failures aren't cached.
actor CourseAttributeRepository {
    static let shared = CourseAttributeRepository()

    enum Lookup: Sendable, Equatable {
        /// The attribute codes of the course's sections in `term`.
        case found(Set<String>, term: String)
        /// No term searched had sections of the course.
        case notFound
        /// The network failed; nothing was cached and a later call tries again.
        case failed
    }

    private struct Entry: Codable {
        /// Nil when no term searched had sections.
        var codes: [String]?
        var term: String?
        var checkedAt: Date
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private static let storedVersion = 1
    /// Courses asked about in one search session.
    private static let batchSize = 10

    private let fetcher: AttributeFetching
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let windowMonths: Int
    private let foundLifetime: TimeInterval
    private let notFoundLifetime: TimeInterval

    private var entries: [String: Entry] = [:]
    private var didLoad = false
    private var isDirty = false

    init(
        fetcher: AttributeFetching = BannerCourseDataFetcher(),
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        windowMonths: Int = 36,
        foundLifetime: TimeInterval = 30 * 24 * 3600,
        notFoundLifetime: TimeInterval = 7 * 24 * 3600
    ) {
        self.fetcher = fetcher
        self.fileURL = (directory ?? AppPaths.courseInfoDirectory).appendingPathComponent("course-attributes.json")
        self.now = now
        self.windowMonths = windowMonths
        self.foundLifetime = foundLifetime
        self.notFoundLifetime = notFoundLifetime
    }

    /// The attributes of `keys`.
    ///
    /// - Parameter indexes: loaded catalogs, newest first; a course they have sections of is
    ///   answered from them.
    func lookup(_ keys: [CourseKey], indexes: [CatalogIndex] = []) async -> [CourseKey: Lookup] {
        loadIfNeeded()
        var seen = Set<CourseKey>()
        var remaining = keys.filter { seen.insert($0).inserted }
        var results: [CourseKey: Lookup] = [:]

        // Loaded catalogs and the cache need no waiting.
        remaining = remaining.filter { key in
            if let found = Self.fromLoaded(key, in: indexes) {
                results[key] = found
                return false
            }
            if let cached = cached(key) {
                results[key] = cached
                return false
            }
            return true
        }
        guard !remaining.isEmpty else { return results }

        var terms = ((try? await fetcher.terms()) ?? []).filter { $0.college == .neu }
        for index in indexes where index.term.college == .neu && !terms.contains(where: { $0.code == index.term.code }) {
            terms.append(index.term)
        }
        let window = OfferingHistoryRepository.window(of: terms, months: windowMonths)
        guard !window.isEmpty else {
            for key in remaining { results[key] = .failed }
            return results
        }
        let loaded = Set(indexes.map(\.term.code))
        searching: for term in window where !loaded.contains(term.code) {
            var start = 0
            while start < remaining.count {
                if Task.isCancelled { break searching }
                let batch = Array(remaining[start..<min(start + Self.batchSize, remaining.count)])
                start += Self.batchSize
                do {
                    let found = try await fetcher.sectionAttributes(term: term.code, courses: batch)
                    for (key, codes) in found {
                        results[key] = .found(codes, term: term.code)
                        store(key, Entry(codes: codes.sorted(), term: term.code, checkedAt: now()))
                    }
                } catch {
                    // What was found is kept; the rest is tried again later.
                    for key in remaining where results[key] == nil { results[key] = .failed }
                    saveIfNeeded()
                    return results
                }
            }
            remaining.removeAll { results[$0] != nil }
            if remaining.isEmpty { break }
        }
        if Task.isCancelled {
            for key in remaining where results[key] == nil { results[key] = .failed }
        } else {
            for key in remaining where results[key] == nil {
                results[key] = .notFound
                store(key, Entry(codes: nil, term: nil, checkedAt: now()))
            }
        }
        saveIfNeeded()
        return results
    }

    /// Forgets the cache, in memory and on disk.
    func clear() {
        entries = [:]
        didLoad = true
        isDirty = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The course's attributes in the newest loaded term with sections of it.
    static func fromLoaded(_ key: CourseKey, in indexes: [CatalogIndex]) -> Lookup? {
        for index in indexes where !index.sections(for: key).isEmpty {
            return .found(Set(index.course(key)?.attributes ?? []), term: index.term.code)
        }
        return nil
    }

    // MARK: - Cache

    private func cached(_ key: CourseKey) -> Lookup? {
        guard let entry = entries[key.description] else { return nil }
        let age = now().timeIntervalSince(entry.checkedAt)
        if let codes = entry.codes, let term = entry.term {
            return age < foundLifetime ? .found(Set(codes), term: term) : nil
        }
        return age < notFoundLifetime ? .notFound : nil
    }

    private func store(_ key: CourseKey, _ entry: Entry) {
        entries[key.description] = entry
        isDirty = true
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode(Stored.self, from: data), stored.version == Self.storedVersion else { return }
        entries = stored.entries
    }

    private func saveIfNeeded() {
        guard isDirty else { return }
        isDirty = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Stored(version: Self.storedVersion, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
