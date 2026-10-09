//
//  MacAddCourseView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The popover of "Add Course": searches the schedule's term and adds courses to it. When a course
/// has corequisites (a lab, say) it offers to add them too. The popover stays open, so several
/// courses can be added one after another.
struct MacAddCourseView: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.openWindow) private var openWindow

    @State private var text = ""
    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var suggestions: [CorequisiteSuggestion] = []
    @State private var highlighted: CourseKey?
    @State private var toast: PlanToast?
    @FocusState private var isSearchFocused: Bool

    private struct CorequisiteSuggestion: Identifiable, Hashable {
        var parent: CourseKey
        var coreq: CourseKey
        var title: String
        var id: String { "\(parent)>\(coreq)" }
    }

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The courses on screen, in order (for the arrow keys and Return).
    private func visibleKeys(plan: SchedulePlan) -> [CourseKey] {
        if trimmedText.isEmpty { return suggestedCourses(plan: plan).map(\.key) }
        return results.prefix(100).map(\.course.key)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .frame(width: 440, height: 500)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .task(id: text) { await runSearch() }
        .planToast($toast)
        .onAppear { isSearchFocused = true }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Course code or title", text: $text)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .autocorrectionDisabled()
                .onSubmit(addHighlighted)
                .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let plan {
            let visibleSuggestions = suggestions.filter { !plan.contains($0.coreq) }
            if index == nil {
                if indexLoadFinished, catalog.loadState != .loading {
                    ContentUnavailableView {
                        Label("Course data unavailable", systemImage: "icloud.slash")
                    } description: {
                        Text("The catalog for this term isn’t on this device yet.")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $highlighted) {
                        if !visibleSuggestions.isEmpty {
                            Section {
                                ForEach(visibleSuggestions) { suggestion in
                                    suggestionRow(suggestion)
                                }
                            }
                        }
                        courseSections(plan: plan)
                    }
                    .listStyle(.inset)
                    .onChange(of: highlighted) { _, key in
                        if let key { proxy.scrollTo(key) }
                    }
                }
                .overlay { emptyOverlay(plan: plan) }
            }
        } else {
            ContentUnavailableView("Schedule not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    @ViewBuilder
    private func courseSections(plan: SchedulePlan) -> some View {
        if trimmedText.isEmpty {
            let saved = savedCourses(plan: plan)
            let recent = recentCourses(plan: plan, excluding: Set(saved.map(\.key)))
            if !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved) { course in
                        courseRow(course, stats: index?.stats(for: course.key), note: nil, plan: plan)
                    }
                }
            }
            if !recent.isEmpty {
                Section("Recently Viewed") {
                    ForEach(recent) { course in
                        courseRow(course, stats: index?.stats(for: course.key), note: nil, plan: plan)
                    }
                }
            }
        } else if !results.isEmpty {
            Section {
                ForEach(results.prefix(100)) { result in
                    courseRow(result.course, stats: result.stats, note: result.matchNote, plan: plan)
                }
            } footer: {
                if results.count > 100 {
                    Text("Showing the first 100 of \(results.count) results. Keep typing to narrow them down.")
                }
            }
        }
    }

    @ViewBuilder
    private func emptyOverlay(plan: SchedulePlan) -> some View {
        if trimmedText.isEmpty {
            if suggestedCourses(plan: plan).isEmpty {
                ContentUnavailableView {
                    Label("Find a course", systemImage: "magnifyingglass")
                } description: {
                    Text("Search by code, like CS 3000, or by title. Saved and recently viewed courses show up here.")
                }
            }
        } else if results.isEmpty {
            if isSearching {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: trimmedText)
            }
        }
    }

    // MARK: Rows

    private func savedCourses(plan: SchedulePlan) -> [Course] {
        userData.savedCourses(in: plan.termCode).compactMap { index?.course($0.key) }.prefix(20).map { $0 }
    }

    private func recentCourses(plan: SchedulePlan, excluding saved: Set<CourseKey>) -> [Course] {
        userData.recents(in: plan.termCode).compactMap { index?.course($0.key) }.filter { !saved.contains($0.key) }.prefix(12).map { $0 }
    }

    private func suggestedCourses(plan: SchedulePlan) -> [Course] {
        let saved = savedCourses(plan: plan)
        return saved + recentCourses(plan: plan, excluding: Set(saved.map(\.key)))
    }

    private func courseRow(_ course: Course, stats: CourseStats?, note: String?, plan: SchedulePlan) -> some View {
        let added = plan.contains(course.key)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(course.code)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.tint)
                        .monospacedDigit()
                    Text(course.creditsLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let stats, stats.sectionCount > 0 {
                        Text(stats.openSectionCount == 0 ? "Full" : "\(stats.openSectionCount)/\(stats.sectionCount) open")
                            .font(.caption)
                            .foregroundStyle(stats.openSectionCount == 0 ? Color.red : Color.secondary)
                            .monospacedDigit()
                    }
                }
                Text(course.title)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let first = stats?.instructorNames.first {
                    Text((stats?.instructorNames.count ?? 0) > 1 ? "\(first) +\((stats?.instructorNames.count ?? 1) - 1)" : first)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button {
                add(course, to: plan)
            } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(added ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(added)
            .help(added ? "\(course.code) is already in \(plan.name)" : "Add \(course.code) to \(plan.name)")
            .accessibilityLabel(added ? "\(course.code), added" : "Add \(course.code)")
        }
        .padding(.vertical, 2)
        .tag(course.key)
        .contentShape(.rect)
        .onTapGesture(count: 2) { add(course, to: plan) }
        .contextMenu {
            Button("Add to \(plan.name)", systemImage: "plus.circle") { add(course, to: plan) }
                .disabled(added)
            Button("Open in New Window", systemImage: "macwindow") {
                openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: plan.termCode, key: course.key))
            }
        }
    }

    private func suggestionRow(_ suggestion: CorequisiteSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title.isEmpty ? "Also add \(suggestion.coreq.description)?" : "Also add \(suggestion.coreq.description) (\(suggestion.title))?")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Corequisite of \(suggestion.parent.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Add") { addCorequisite(suggestion) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                withAnimation { suggestions.removeAll { $0 == suggestion } }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss suggestion")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    private func moveHighlight(_ delta: Int) {
        guard let plan else { return }
        let keys = visibleKeys(plan: plan)
        guard !keys.isEmpty else { return }
        let current = highlighted.flatMap { keys.firstIndex(of: $0) } ?? (delta > 0 ? -1 : keys.count)
        highlighted = keys[min(max(current + delta, 0), keys.count - 1)]
    }

    /// Return adds the highlighted course, or the first result when none is highlighted.
    private func addHighlighted() {
        guard let plan else { return }
        let keys = visibleKeys(plan: plan)
        guard let key = highlighted ?? keys.first, let course = index?.course(key) else { return }
        add(course, to: plan)
    }

    private func add(_ course: Course, to plan: SchedulePlan) {
        guard !plan.contains(course.key) else { return }
        userData.addCourse(course.key, toPlan: planID)
        Task { await offerCorequisites(for: course.key) }
    }

    private func addCorequisite(_ suggestion: CorequisiteSuggestion) {
        userData.addCourse(suggestion.coreq, toPlan: planID)
        withAnimation { suggestions.removeAll { $0 == suggestion } }
        Task { await offerCorequisites(for: suggestion.coreq) }
    }

    /// Looks up the course's corequisites (fetching details if needed) and queues suggestions.
    private func offerCorequisites(for key: CourseKey) async {
        guard let termCode = plan?.termCode else { return }
        var index = self.index
        if let course = index?.course(key), !course.detailsLoaded {
            catalog.lastRefreshError = nil
            await catalog.ensureDetails(for: key, termCode: termCode)
            index = await catalog.index(for: termCode)
            loadedIndex = index
            if let message = catalog.lastRefreshError {
                // Say so here: the app-wide banner sits behind this popover.
                catalog.lastRefreshError = nil
                toast = PlanToast(text: "Couldn’t check \(key.description) for a lab or corequisite: \(message)", systemImage: "wifi.exclamationmark")
            }
        }
        guard let index, let coreqs = index.course(key)?.coreqs?.referencedCourses else { return }
        let inPlan = Set(userData.plan(id: planID)?.courses.map(\.key) ?? [])
        for coreq in coreqs where !inPlan.contains(coreq) && coreq != key {
            guard let course = index.course(coreq) else { continue }
            let suggestion = CorequisiteSuggestion(parent: key, coreq: coreq, title: course.title)
            if !suggestions.contains(suggestion) {
                withAnimation { suggestions.append(suggestion) }
            }
        }
    }

    // MARK: Search

    private func runSearch() async {
        let query = trimmedText
        highlighted = nil
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, let index else { return }
        let found = await Task.detached(priority: .userInitiated) {
            SearchEngine.search(SearchQuery(text: query), in: index)
        }.value
        guard !Task.isCancelled else { return }
        results = found.results
        highlighted = results.first?.course.key
        isSearching = false
    }
}
