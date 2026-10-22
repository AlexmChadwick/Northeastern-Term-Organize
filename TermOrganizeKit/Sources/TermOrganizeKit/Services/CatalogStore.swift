//
//  CatalogStore.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation

/// UI-facing state for course data: the selected term, its index, and the
/// status of network refreshes.
@MainActor
@Observable
final class CatalogStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// No catalog exists on device for the term yet (needs a sync).
        case missing
        case failed(String)
    }

    enum SyncState: Equatable {
        case idle
        case syncing(SyncProgress)
        case failed(String)
    }

    /// Terms to offer in pickers (Banner's list merged with local catalogs), newest first.
    private(set) var terms: [Term] = []
    private(set) var selectedTermCode: String?
    /// Index for the selected term.
    private(set) var index: CatalogIndex?
    private(set) var loadState: LoadState = .idle
    private(set) var syncState: SyncState = .idle
    /// Courses whose live seats are being fetched.
    private(set) var refreshingCourses: Set<CourseKey> = []
    /// Courses whose details (description, instructors) are being fetched.
    private(set) var loadingDetails: Set<CourseKey> = []
    /// Last error from a course-level refresh, for transient banners.
    var lastRefreshError: String?
    /// Courses refreshed live during this session, with the time of refresh.
    private(set) var liveRefreshedAt: [CourseKey: Date] = [:]

    /// Bumped whenever any index changes (term load, sync, live course refresh).
    /// Views that derive data from an index can key work on this.
    private(set) var indexVersion = 0

    @ObservationIgnored private let repository: CatalogRepository
    /// Indexes for every loaded term (observed, so `cachedIndex(for:)` readers update).
    private var otherIndexes: [String: CatalogIndex] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(repository: CatalogRepository = .shared) {
        self.repository = repository
    }

    /// The selected term — even while its catalog is still loading (in which case
    /// `index` may still hold the previous term).
    var selectedTerm: Term? {
        if let index, index.term.code == selectedTermCode { return index.term }
        return terms.first { $0.code == selectedTermCode } ?? index?.term
    }

    /// The index, but only once it matches the selected term.
    var readyIndex: CatalogIndex? {
        guard let index, index.term.code == selectedTermCode else { return nil }
        return index
    }

    var isSyncing: Bool {
        if case .syncing = syncState { return true }
        return false
    }

    /// When seat data for the selected term was last refreshed.
    var sectionsUpdatedAt: Date? { index?.catalog.sectionsUpdatedAt }

    // MARK: - Startup

    /// Loads local terms immediately, then the preferred term, then refreshes
    /// the list of terms from Banner in the background.
    func bootstrap(preferredTermCode: String?) async {
        // Show a loading state (not "no term") while we look at what's on disk.
        if loadState == .idle { loadState = .loading }
        let localCodes = await repository.localTermCodes()
        let cached = await repository.cachedRemoteTerms() ?? []
        mergeTerms(remote: cached, localCodes: localCodes)

        let initial = preferredTermCode.flatMap { code in localCodes.contains(code) ? code : nil } ?? localCodes.first ?? terms.first?.code
        if let initial {
            await select(termCode: initial)
        } else {
            loadState = .idle
        }

        Task {
            if let remote = try? await repository.remoteTerms() {
                let localCodes = await repository.localTermCodes()
                mergeTerms(remote: remote, localCodes: localCodes)
            }
        }
    }

    private func mergeTerms(remote: [Term], localCodes: [String]) {
        var byCode: [String: Term] = [:]
        for t in remote { byCode[t.code] = t }
        for code in localCodes where byCode[code] == nil {
            if let existing = terms.first(where: { $0.code == code }) {
                byCode[code] = existing
            } else if let indexTerm = index?.term, indexTerm.code == code {
                byCode[code] = indexTerm
            } else {
                byCode[code] = Term(code: code, bannerDescription: "Term \(code)")
            }
        }
        terms = byCode.values.sorted(by: >)
    }

    /// Whether a catalog for the term is stored on device.
    func hasLocalCatalog(_ termCode: String) async -> Bool {
        await repository.localTermCodes().contains(termCode)
    }

    // MARK: - Selecting terms

    func select(termCode: String) async {
        guard termCode != selectedTermCode || index == nil else { return }
        selectedTermCode = termCode
        loadState = .loading
        loadTask?.cancel()
        let repository = self.repository
        do {
            if let catalog = try await repository.catalog(for: termCode) {
                let built = await Task.detached(priority: .userInitiated) { CatalogIndex.build(catalog) }.value
                guard selectedTermCode == termCode else { return }
                index = built
                otherIndexes[termCode] = built
                indexVersion += 1
                loadState = .loaded
                if let i = terms.firstIndex(where: { $0.code == termCode }), terms[i].bannerDescription.hasPrefix("Term ") {
                    terms[i] = built.term
                }
            } else {
                index = nil
                loadState = .missing
            }
        } catch {
            index = nil
            loadState = .failed(error.localizedDescription)
        }
    }

    /// An already-loaded index for any term, without loading. Pair with
    /// `index(for:)` in a `.task` to load it.
    func cachedIndex(for termCode: String) -> CatalogIndex? {
        if let index, index.term.code == termCode { return index }
        return otherIndexes[termCode]
    }

    /// The index for any term (cached), loading it from disk if needed.
    func index(for termCode: String) async -> CatalogIndex? {
        if let index, index.term.code == termCode { return index }
        if let cached = otherIndexes[termCode] { return cached }
        guard let catalog = try? await repository.catalog(for: termCode) else { return nil }
        let built = await Task.detached(priority: .userInitiated) { CatalogIndex.build(catalog) }.value
        otherIndexes[termCode] = built
        indexVersion += 1
        return built
    }

    private func install(_ catalog: TermCatalog) async {
        let built = await Task.detached(priority: .userInitiated) { CatalogIndex.build(catalog) }.value
        otherIndexes[catalog.term.code] = built
        if selectedTermCode == catalog.term.code {
            index = built
            loadState = .loaded
        }
        indexVersion += 1
    }

    /// Applies refreshed courses to the existing index without a full rebuild.
    private func patch(_ catalog: TermCatalog, courses keys: [CourseKey]) async {
        let code = catalog.term.code
        guard let current = (index?.term.code == code ? index : nil) ?? otherIndexes[code] else {
            await install(catalog)
            return
        }
        let patched = await Task.detached(priority: .userInitiated) { () -> CatalogIndex in
            var result = current
            for key in keys {
                result = result.replacingCourse(
                    key,
                    course: catalog.courses.first { $0.key == key },
                    sections: catalog.sections.filter { $0.courseKey == key }
                )
            }
            return result
        }.value
        otherIndexes[code] = patched
        if selectedTermCode == code {
            index = patched
        }
        indexVersion += 1
    }

    // MARK: - Syncing

    /// Downloads the latest sections for the selected term from Banner.
    func syncSelectedTerm() {
        guard let term = selectedTerm ?? selectedTermCode.map({ Term(code: $0, bannerDescription: "Term \($0)") }) else { return }
        sync(term: term)
    }

    func sync(term: Term) {
        guard !isSyncing else { return }
        syncState = .syncing(SyncProgress(phase: .connecting))
        let repository = self.repository
        syncTask = Task {
            do {
                let catalog = try await repository.syncTerm(term) { progress in
                    Task { @MainActor in
                        guard case .syncing = self.syncState else { return }
                        self.syncState = .syncing(progress)
                    }
                }
                await install(catalog)
                let localCodes = await repository.localTermCodes()
                mergeTerms(remote: terms, localCodes: localCodes)
                syncState = .idle
            } catch is CancellationError {
                syncState = .idle
            } catch {
                syncState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSync() {
        syncTask?.cancel()
        syncState = .idle
    }

    func dismissSyncError() {
        if case .failed = syncState { syncState = .idle }
    }

    // MARK: - Course level refresh

    /// Fetches live seats (and any missing instructors) for a course.
    func refresh(course key: CourseKey, termCode: String? = nil) async {
        guard let termCode = termCode ?? selectedTermCode, !refreshingCourses.contains(key) else { return }
        refreshingCourses.insert(key)
        defer { refreshingCourses.remove(key) }
        do {
            let catalog = try await repository.refreshCourse(key, termCode: termCode)
            liveRefreshedAt[key] = .now
            await patch(catalog, courses: [key])
        } catch is CancellationError {
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    /// Loads description, requisites and instructors when the course only has stub data.
    func ensureDetails(for key: CourseKey, termCode: String? = nil) async {
        guard let termCode = termCode ?? selectedTermCode,
              let index = await index(for: termCode),
              let course = index.course(key) else { return }
        let needsInstructors = index.sections(for: key).contains { $0.instructors == nil }
        let needsTopics = course.specialTopics && index.sections(for: key).contains { $0.description == nil }
        let needsRestrictions = index.sections(for: key).contains { $0.restrictions == nil }
        guard !course.detailsLoaded || needsInstructors || needsTopics || needsRestrictions, !loadingDetails.contains(key) else { return }
        loadingDetails.insert(key)
        defer { loadingDetails.remove(key) }
        do {
            let catalog = try await repository.loadDetails(for: key, termCode: termCode)
            await install(catalog)
        } catch is CancellationError {
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    /// Live sections for several courses (watchlist). Also updates stored data.
    func liveSections(for keys: [CourseKey], termCode: String) async throws -> [CourseKey: [CourseSection]] {
        let result = try await repository.refreshCourses(keys, termCode: termCode)
        if let catalog = try? await repository.catalog(for: termCode) {
            await patch(catalog, courses: keys)
        }
        for key in keys { liveRefreshedAt[key] = .now }
        return result
    }

    // MARK: - Search

    /// Runs a search off the main actor.
    func search(_ query: SearchQuery) async -> SearchResponse {
        guard let index = readyIndex else { return SearchResponse() }
        return await Task.detached(priority: .userInitiated) {
            SearchEngine.search(query, in: index)
        }.value
    }

    // MARK: - Maintenance

    func clearDownloadedData() async {
        try? await repository.clearDownloads()
        otherIndexes.removeAll()
        let code = selectedTermCode
        selectedTermCode = nil
        index = nil
        indexVersion += 1
        let localCodes = await repository.localTermCodes()
        mergeTerms(remote: terms, localCodes: localCodes)
        if let code { await select(termCode: code) }
    }
}
