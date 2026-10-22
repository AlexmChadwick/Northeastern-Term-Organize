//
//  SearchTabView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Root of the search tab. The search field lives in the tab bar and is bound
/// to `SearchModel.text` by the app shell; this view renders the pinned filter
/// chips and either suggestions or results for the current query.
struct SearchTabView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(SearchModel.self) private var searchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Results together with the query and term they were computed for.
    private struct Completed {
        var termCode: String
        var query: SearchQuery
        var response: SearchResponse
        /// Changes whenever results are replaced.
        var revision: Int
    }

    /// Everything that should trigger a new search when it changes.
    private struct TaskKey: Hashable {
        var query: SearchQuery
        var termCode: String?
        var updatedAt: Date?
        var liveRefreshes: [CourseKey: Date]
        var indexVersion: Int
    }

    @State private var completed: Completed?
    /// Changes whenever a different query's results arrive, so the list starts at the top.
    @State private var listGeneration = 0
    @State private var revision = 0
    @State private var isFiltersPresented = false
    @State private var filtersRequest = SearchFiltersRequest()
    @State private var popularSubjects: [Subject] = []
    /// The text of the latest search that was started. A different text means
    /// the user is typing (debounced); the same text means a filter or sort change.
    @State private var lastRequestedText: String?

    // MARK: Derived state

    private var trimmedText: String {
        searchModel.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The campus from the user's preferences, when this term has it.
    private var preferredCampus: String? {
        guard let campus = userData.preferences.preferredCampus,
              let index = catalog.readyIndex,
              index.campusNames.contains(campus) else { return nil }
        return campus
    }

    /// The landing screen: nothing typed, the default sort, and no filters
    /// beyond the preferred campus that is applied for the user. It shows
    /// suggestions rather than a list of every course.
    private var isLanding: Bool {
        var baseline = SearchFilters()
        if let preferredCampus { baseline.campuses = [preferredCampus] }
        let filters = searchModel.filters
        return trimmedText.isEmpty
            && searchModel.sort == .relevance
            && (filters.isEmpty || filters == baseline)
    }

    private var taskKey: TaskKey {
        TaskKey(
            query: searchModel.query,
            termCode: catalog.readyIndex?.term.code,
            updatedAt: catalog.sectionsUpdatedAt,
            liveRefreshes: catalog.liveRefreshedAt,
            indexVersion: catalog.indexVersion
        )
    }

    // MARK: Body

    var body: some View {
        let key = taskKey
        let landing = isLanding
        content(isLanding: landing)
            .navigationTitle("Search")
            .navigationSubtitle(catalog.selectedTerm?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .top) {
                if catalog.readyIndex != nil {
                    SearchFilterBar(model: searchModel, isLanding: landing, popularSubjects: popularSubjects) { target in
                        filtersRequest = SearchFiltersRequest(target: target, token: filtersRequest.token + 1)
                        isFiltersPresented = true
                    }
                }
            }
            .sheet(isPresented: $isFiltersPresented) {
                SearchFiltersSheet(
                    resultCount: landing ? nil : completed?.response.results.count,
                    request: filtersRequest
                )
            }
            .task(id: key) {
                await runSearch(key)
            }
            .task(id: catalog.readyIndex?.term.code) {
                prepare()
            }
            .onChange(of: router.searchPath) { oldPath, newPath in
                // Opening a result counts as a deliberate search. (Submitting the
                // search field is recorded by the app shell, which owns the field.)
                if newPath.count > oldPath.count { recordSearch() }
            }
    }

    @ViewBuilder
    private func content(isLanding: Bool) -> some View {
        if let index = catalog.readyIndex {
            if !isLanding, let completed, completed.termCode == index.term.code {
                SearchResultsList(
                    index: index,
                    response: completed.response,
                    query: completed.query,
                    revision: completed.revision,
                    onClearFilters: clearFilters
                )
                .equatable()
                .id(listGeneration)
            } else {
                // The landing screen, and also what stays up while the first
                // results of a new search are computed: no spinner or empty
                // state flashes by in between.
                SearchSuggestionsList(index: index, popularSubjects: popularSubjects)
            }
        } else if let termCode = catalog.selectedTermCode {
            BrowseIndexUnavailable(termCode: termCode)
        } else {
            ContentUnavailableView {
                Label("Choose a term", systemImage: "calendar")
            } description: {
                Text("Pick a term on the Catalog tab to search its courses.")
            } actions: {
                Button("Open catalog") {
                    router.selectedTab = .catalog
                }
                .buttonStyle(.glass)
            }
        }
    }

    // MARK: Searching

    /// Runs the search for `key`. A new key cancels the previous task, which
    /// is what debounces typing; the previous results stay on screen until
    /// the new ones arrive.
    private func runSearch(_ key: TaskKey) async {
        guard let index = catalog.readyIndex, !isLanding else {
            completed = nil
            lastRequestedText = nil
            return
        }
        let query = key.query
        let isTyping = lastRequestedText != query.text
        lastRequestedText = query.text
        // Wait out fast typing, even before any results exist. Filter and sort
        // changes, clearing the field, and the re-run when this tab reappears
        // search right away.
        if isTyping, !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        let response = await catalog.search(query)
        if Task.isCancelled { return }
        if completed?.query != query { listGeneration += 1 }
        revision += 1
        completed = Completed(termCode: index.term.code, query: query, response: response, revision: revision)
    }

    private func clearFilters() {
        withAnimation(.browseSnappy(reduceMotion: reduceMotion)) {
            searchModel.filters = SearchFilters()
        }
    }

    private func recordSearch() {
        userData.recordSearch(searchModel.text)
    }

    // MARK: Per-term setup

    /// Precomputes the popular subjects and applies the preferred campus once per launch.
    private func prepare() {
        guard let index = catalog.readyIndex else {
            popularSubjects = []
            return
        }
        popularSubjects = index.popularSubjects()
        applyPreferredCampus()
    }

    /// Starts the search with the user's preferred campus selected, once per
    /// launch, and only for a user who has not brought a search or filters of
    /// their own (typed text, filters or a sort from the home screen's quick
    /// searches, a link...). The "applied" flag is only set when the campus
    /// really was applied, so a preference or term that is not usable yet can
    /// still take effect later.
    private func applyPreferredCampus() {
        guard !SearchLaunchState.didApplyPreferredCampus, !SearchLaunchState.userBroughtOwnSearch else { return }
        if !searchModel.filters.isEmpty || searchModel.sort != .relevance || !trimmedText.isEmpty {
            SearchLaunchState.userBroughtOwnSearch = true
            return
        }
        guard let campus = preferredCampus else { return }
        searchModel.filters.campuses = [campus]
        SearchLaunchState.didApplyPreferredCampus = true
    }
}

/// Launch-wide search state that must survive the tab being rebuilt.
@MainActor
private enum SearchLaunchState {
    /// The preferred campus has been applied as the starting filter.
    static var didApplyPreferredCampus = false
    /// The search tab was first used with a search or filters the user chose,
    /// so the preferred campus must never be added behind their back later.
    static var userBroughtOwnSearch = false
}
