//
//  MacSearchView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Course search for the selected term. The toolbar's search field is bound to
/// `MacNavigator.searchText`; this view runs `SearchEngine` for it and the filters in
/// `MacCatalogState`, and shows either the landing page (nothing asked yet) or the results in a
/// sortable table.
struct MacSearchView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    @State private var state = MacCatalogState.shared
    @State private var completed: Completed?
    @State private var revision = 0
    @State private var selection: Set<CourseKey> = []
    @State private var newSchedule: MacCatalogNewScheduleRequest?
    private let preview = MacCatalogPreviewMode()
    @FocusState private var isSearchFocused: Bool
    /// The text of the latest search that was started. A different text means the user is typing
    /// (debounced); the same text means a filter change.
    @State private var lastRequestedText: String?

    /// Results together with the query and term they were computed for.
    private struct Completed {
        var termCode: String
        var query: SearchQuery
        var response: SearchResponse
        var rows: [MacCatalogCourseRow]
        /// Changes whenever results are replaced.
        var revision: Int
    }

    /// Everything that should trigger a new search when it changes.
    private struct TaskKey: Hashable {
        var query: SearchQuery
        var termCode: String?
        var updatedAt: Date?
        var liveRefreshes: [CourseKey: Date]
    }

    // MARK: Derived state

    private var trimmedText: String {
        navigator.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The campus from the user's preferences, when this term has it.
    private var preferredCampus: String? {
        guard let campus = userData.preferences.preferredCampus,
              let index = catalog.readyIndex,
              index.campusNames.contains(campus) else { return nil }
        return campus
    }

    /// The landing page: nothing typed and no filters beyond the preferred campus that is applied for
    /// the user. It shows suggestions rather than a table of every course.
    private var isLanding: Bool {
        var baseline = SearchFilters()
        if let preferredCampus { baseline.campuses = [preferredCampus] }
        let filters = state.filters
        return trimmedText.isEmpty && (filters.isEmpty || filters == baseline)
    }

    private var query: SearchQuery {
        SearchQuery(text: navigator.searchText, filters: state.filters, sort: .relevance)
    }

    private var taskKey: TaskKey {
        TaskKey(
            query: query,
            termCode: catalog.readyIndex?.term.code,
            updatedAt: catalog.sectionsUpdatedAt,
            liveRefreshes: catalog.liveRefreshedAt
        )
    }

    /// Results that belong to the term on screen, once there are any.
    private var visibleResults: Completed? {
        guard !isLanding, let completed, completed.termCode == catalog.readyIndex?.term.code else { return nil }
        return completed
    }

    /// Whether there is a table of courses (the preview and its toolbar button need one).
    private var hasResults: Bool { visibleResults?.rows.isEmpty == false }

    private var termCode: String { catalog.readyIndex?.term.code ?? catalog.selectedTermCode ?? "" }

    private var subtitle: String {
        guard let index = catalog.readyIndex else { return catalog.selectedTerm?.name ?? "" }
        if let visibleResults, !visibleResults.rows.isEmpty {
            return "\(index.term.name) · \(browseSummaryText(shown: visibleResults.rows.count, total: visibleResults.rows.count, open: 0))"
        }
        return index.term.name
    }

    // MARK: Body

    var body: some View {
        #if DEBUG
        // Snapshots of a course or professor window inside the main window, where the toolbar is real.
        if let window = MacCatalogSnapshotArguments.windowInMainWindow(termCode: catalog.selectedTermCode) {
            window
        } else {
            searchBody
        }
        #else
        searchBody
        #endif
    }

    private var searchBody: some View {
        @Bindable var navigator = navigator
        return MacCatalogGate { index in
            // The selected course's page beside the results, when the window has room (or when asked).
            MacSplitPane(
                storageKey: "mac.split.catalog.search",
                paneEdge: .trailing,
                defaultShare: 0.4,
                paneMinWidth: 340,
                primaryMinWidth: 420,
                maxShare: 0.7,
                isPaneShown: preview.binding(available: hasResults)
            ) {
                VStack(spacing: 0) {
                    MacSearchFilterBar(state: state, index: index, isLanding: isLanding)
                    Divider()
                    if let results = visibleResults {
                        resultsPane(results, index: index)
                    } else {
                        // The landing page, and also what stays up while the first results of a new
                        // search are computed: no empty state flashes by in between.
                        MacSearchLanding(index: index)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } pane: {
                MacCatalogCoursePreview(selection: selection, termCode: index.term.code)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { preview.measure($0) }
        }
        .navigationTitle("Search")
        .navigationSubtitle(subtitle)
        .searchable(text: $navigator.searchText, placement: .toolbar, prompt: "Courses, professors, CRNs")
        .searchFocused($isSearchFocused)
        .searchSuggestions { suggestions }
        .onSubmit(of: .search) { userData.recordSearch(navigator.searchText) }
        .toolbar { toolbarContent }
        .task(id: taskKey) { await runSearch(taskKey) }
        .task(id: catalog.readyIndex?.term.code) { prepare() }
        .task(id: state.searchFocusRequest) {
            // Find was chosen (here or from another area): put the cursor in the field.
            guard state.searchFocusRequest != state.handledSearchFocusRequest else { return }
            state.handledSearchFocusRequest = state.searchFocusRequest
            isSearchFocused = true
        }
        .focusedSceneValue(\.macReload, canReload ? MacMenuAction(title: "Update Seat Counts") { catalog.syncSelectedTerm() } : nil)
        .focusedSceneValue(\.macSidePane, preview.sidePane(available: hasResults))
        .catalogNewScheduleAlert($newSchedule)
        .catalogToastHost()
        #if DEBUG
        .task { MacCatalogSnapshotArguments.applyToSearch(navigator: navigator, state: state, selectFirst: { selectFirstRow() }) }
        #endif
    }

    #if DEBUG
    /// For snapshots: selects the first row of the results (`-MacSnapshotSelectFirst YES`).
    private func selectFirstRow() {
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if let first = visibleResults?.rows.first {
                    selection = [first.key]
                    return
                }
            }
        }
    }
    #endif

    // MARK: Results

    @ViewBuilder
    private func resultsPane(_ results: Completed, index: CatalogIndex) -> some View {
        let response = results.response
        let hasHits = response.crnMatch != nil || !response.subjects.isEmpty || !response.instructors.isEmpty
        VStack(spacing: 0) {
            if hasHits {
                MacSearchTopHits(
                    response: response,
                    index: index,
                    openCourse: { open([$0]) },
                    showSubject: { MacCatalogNavigation.showSubject($0, navigator: navigator, openWindow: openWindow) },
                    openProfessor: { name in
                        openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: index.term.code, name: name))
                    }
                )
                Divider()
            }
            if results.rows.isEmpty {
                Group {
                    if hasHits {
                        ContentUnavailableView {
                            Label("No Courses Match", systemImage: "magnifyingglass")
                        } description: {
                            Text("Only the top hits above match “\(results.query.text.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        }
                    } else {
                        emptyState(for: results.query)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacCatalogCourseTable(
                    rows: results.rows,
                    termCode: index.term.code,
                    revision: results.revision,
                    keepsSelection: preview.isShown,
                    storageKey: "mac.catalog.searchColumns",
                    selection: $selection,
                    sortOrder: $state.searchSort,
                    onOpen: open
                )
                .equatable()
            }
            MacCatalogStatusBar(summary: statusText(results))
        }
    }

    private func statusText(_ results: Completed) -> String {
        let rows = results.rows
        if rows.isEmpty { return "No matching courses" }
        var text = browseSummaryText(
            shown: rows.count,
            total: rows.count,
            open: rows.filter { $0.openSections > 0 }.count,
            openOnly: results.query.filters.openSeatsOnly
        )
        if !selection.isEmpty {
            text += " · \(selection.count.formatted()) selected"
        }
        return text
    }

    @ViewBuilder
    private func emptyState(for query: SearchQuery) -> some View {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFilters = !query.filters.isEmpty
        if text.isEmpty {
            ContentUnavailableView {
                Label("No Matching Courses", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No courses match these filters. Try removing some of them.")
            } actions: {
                if hasFilters {
                    Button("Clear Filters") { state.filters = SearchFilters() }
                }
            }
        } else if hasFilters {
            ContentUnavailableView {
                Label("No Results for “\(text)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling, try a new search, or remove some filters.")
            } actions: {
                Button("Clear Filters") { state.filters = SearchFilters() }
            }
        } else {
            ContentUnavailableView.search(text: text)
        }
    }

    // MARK: Suggestions

    /// What the search field offers while it is focused: recent searches before anything is typed,
    /// then courses, professors and subjects that match what is typed.
    @ViewBuilder
    private var suggestions: some View {
        if trimmedText.isEmpty {
            ForEach(userData.searchHistory, id: \.self) { term in
                Label(term, systemImage: "clock.arrow.circlepath")
                    .searchCompletion(term)
            }
        } else if let response = completed?.response, completed?.query.text == navigator.searchText {
            ForEach(response.results.prefix(5)) { result in
                Label("\(result.course.code)  \(result.course.title)", systemImage: "book.closed")
                    .searchCompletion(result.course.code)
            }
            ForEach(response.instructors.prefix(3)) { instructor in
                Label(instructor.displayName, systemImage: "person.crop.circle")
                    .searchCompletion(instructor.displayName)
            }
            ForEach(response.subjects.prefix(2)) { subject in
                Label("\(subject.code) · \(subject.name)", systemImage: "square.grid.2x2")
                    .searchCompletion(subject.code)
            }
        }
    }

    // MARK: Toolbar

    private var canReload: Bool { catalog.readyIndex != nil && !catalog.isSyncing }

    private var stores: MacCatalogStores {
        MacCatalogStores(catalog: catalog, userData: userData, navigator: navigator)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if hasResults {
            MacCatalogSelectionToolbar(
                stores: stores,
                termCode: termCode,
                selection: selection,
                newSchedule: $newSchedule,
                onOpen: open
            )
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { sortMenu }
            ToolbarItem(placement: .primaryAction) { MacCatalogPreviewToggle(isShown: preview.binding()) }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Update Seats", systemImage: "arrow.clockwise") { catalog.syncSelectedTerm() }
                .disabled(!canReload)
                .help("Download the latest seat counts for \(catalog.selectedTerm?.name ?? "this term")")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: sortChoice) {
                ForEach(SearchSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.symbol).tag(Optional(sort))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort the results (or click a column heading)")
    }

    /// The sort the table is in, when it is one of the menu's: "Best Match" is no sort at all, the
    /// order the search itself ranks them in.
    private var sortChoice: Binding<SearchSort?> {
        Binding(
            get: {
                let order = state.searchSort
                guard let first = order.first else { return .relevance }
                guard order.count == 1 else { return nil }
                if first.keyPath == \MacCatalogCourseRow.key, first.order == .forward { return .courseNumber }
                if first.keyPath == \MacCatalogCourseRow.title, first.order == .forward { return .title }
                if first.keyPath == \MacCatalogCourseRow.openSeats, first.order == .reverse { return .openSeats }
                return nil
            },
            set: { sort in
                switch sort {
                case .relevance, nil: state.searchSort = []
                case .courseNumber: state.searchSort = [KeyPathComparator(\.key)]
                case .title: state.searchSort = [KeyPathComparator(\.title, comparator: .localizedStandard)]
                case .openSeats: state.searchSort = [KeyPathComparator(\.openSeats, order: .reverse)]
                }
            }
        )
    }

    // MARK: Actions

    private func open(_ keys: [CourseKey]) {
        guard let index = catalog.readyIndex else { return }
        // Opening a result counts as a deliberate search.
        userData.recordSearch(navigator.searchText)
        for key in keys {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: index.term.code, key: key))
        }
    }

    // MARK: Searching

    /// Runs the search for `key`. A new key cancels the previous task, which is what debounces
    /// typing; the previous results stay on screen until the new ones arrive.
    private func runSearch(_ key: TaskKey) async {
        guard let index = catalog.readyIndex, !isLanding else {
            completed = nil
            lastRequestedText = nil
            return
        }
        let query = key.query
        let isTyping = lastRequestedText != query.text
        lastRequestedText = query.text
        // Wait out fast typing. Filter changes and clearing the field search right away.
        if isTyping, !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        let response = await catalog.search(query)
        if Task.isCancelled { return }
        let rows = response.results.map { MacCatalogCourseRow(course: $0.course, stats: $0.stats, note: $0.matchNote) }
        revision += 1
        completed = Completed(termCode: index.term.code, query: query, response: response, rows: rows, revision: revision)
        let present = Set(rows.map(\.key))
        if !selection.isSubset(of: present) { selection = selection.intersection(present) }
    }

    /// Starts the search with the user's preferred campus selected, once per launch, and only for a
    /// user who has not brought a search or filters of their own (typed text, quick searches, a link…).
    private func prepare() {
        guard catalog.readyIndex != nil else { return }
        guard !state.didApplyPreferredCampus, !state.userBroughtOwnSearch else { return }
        if !state.filters.isEmpty || !trimmedText.isEmpty {
            state.userBroughtOwnSearch = true
            return
        }
        guard let campus = preferredCampus else { return }
        state.filters.campuses = [campus]
        state.didApplyPreferredCampus = true
    }
}

// MARK: - Top hits

/// The strip above the results for what the query matches besides courses: a CRN, subjects and
/// professors.
struct MacSearchTopHits: View {
    var response: SearchResponse
    var index: CatalogIndex
    var openCourse: (CourseKey) -> Void
    var showSubject: (String) -> Void
    var openProfessor: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Hits")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if let section = response.crnMatch {
                crnRow(section)
            }
            if !response.subjects.isEmpty || !response.instructors.isEmpty {
                CourseFlowLayout(spacing: 8, lineSpacing: 6) {
                    ForEach(response.subjects) { subject in
                        Button {
                            showSubject(subject.code)
                        } label: {
                            let count = index.courseCountBySubject[subject.code] ?? 0
                            Label("\(subject.code) · \(subject.name) · \(CourseFormat.count(count, "course"))", systemImage: "square.grid.2x2")
                        }
                        .help("Show the courses in \(subject.name)")
                    }
                    ForEach(response.instructors) { instructor in
                        Button {
                            openProfessor(instructor.name)
                        } label: {
                            let courses = CourseFormat.count(instructor.courseKeys.count, "course")
                            let sections = CourseFormat.count(instructor.crns.count, "section")
                            Label("\(instructor.displayName) · \(courses) · \(sections)", systemImage: "person.crop.circle")
                        }
                        .help("Open \(instructor.displayName)'s window")
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07))
    }

    private func crnRow(_ section: CourseSection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "number")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("CRN \(section.crn) · \(section.courseKey.description) Section \(section.sectionNumber)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("\(section.title) · \(section.classType) · \(section.scheduleSummary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            SeatsBadge(section: section)
            Button("Open Course") { openCourse(section.courseKey) }
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }
}
