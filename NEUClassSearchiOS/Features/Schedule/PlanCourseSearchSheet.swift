//
//  PlanCourseSearchSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// "Add Course": searches the plan's term and adds courses to the plan. When a
/// course has corequisites (a lab, say) it offers to add them too.
struct PlanCourseSearchSheet: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var suggestions: [CorequisiteSuggestion] = []
    @State private var haptic = PlanHaptic()
    @State private var toast: PlanToast?

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

    var body: some View {
        NavigationStack {
            list
                .planToast($toast)
                .navigationTitle("Add Course")
                .navigationBarTitleDisplayMode(.inline)
                .navigationSubtitle(plan.map { "\($0.name) · \($0.courses.count) \($0.courses.count == 1 ? "course" : "courses")" } ?? "")
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Course code or title")
                .autocorrectionDisabled()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .task(id: text) { await runSearch() }
        .planHaptic(haptic)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if let plan {
            List {
                let visibleSuggestions = suggestions.filter { !plan.contains($0.coreq) }
                if !visibleSuggestions.isEmpty {
                    Section {
                        ForEach(visibleSuggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }

                if index == nil {
                    if indexLoadFinished, catalog.loadState != .loading {
                        ContentUnavailableView {
                            Label("Course data unavailable", systemImage: "icloud.slash")
                        } description: {
                            Text("The catalog for this term isn’t on this device yet.")
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                } else if trimmedText.isEmpty {
                    suggestedCourses(plan: plan)
                } else if results.isEmpty {
                    if isSearching {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ContentUnavailableView.search(text: trimmedText)
                            .listRowBackground(Color.clear)
                    }
                } else {
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
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        } else {
            ContentUnavailableView("Schedule not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    /// Saved and recently viewed courses while the search field is empty.
    @ViewBuilder
    private func suggestedCourses(plan: SchedulePlan) -> some View {
        let saved = userData.savedCourses(in: plan.termCode).compactMap { index?.course($0.key) }
        let savedKeys = Set(saved.map(\.key))
        let recent = userData.recents(in: plan.termCode).compactMap { index?.course($0.key) }.filter { !savedKeys.contains($0.key) }
        if saved.isEmpty && recent.isEmpty {
            ContentUnavailableView {
                Label("Find a course", systemImage: "magnifyingglass")
            } description: {
                Text("Search by code, like CS 3000, or by title. Saved and recently viewed courses show up here.")
            }
            .listRowBackground(Color.clear)
        } else {
            if !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved.prefix(20)) { course in
                        courseRow(course, stats: index?.stats(for: course.key), note: nil, plan: plan)
                    }
                }
            }
            if !recent.isEmpty {
                Section("Recently viewed") {
                    ForEach(recent.prefix(12)) { course in
                        courseRow(course, stats: index?.stats(for: course.key), note: nil, plan: plan)
                    }
                }
            }
        }
    }

    private func courseRow(_ course: Course, stats: CourseStats?, note: String?, plan: SchedulePlan) -> some View {
        let added = plan.contains(course.key)
        return Button {
            add(course, to: plan)
        } label: {
            HStack(spacing: 10) {
                CourseRow(course: course, stats: stats, note: note)
                VStack(spacing: 2) {
                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(added ? Color.green : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                    if added {
                        Text("Added")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                .frame(minWidth: 44)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(added ? "Added" : "")
        .accessibilityHint(added ? "Already in this schedule" : "Adds to \(plan.name)")
    }

    private func suggestionRow(_ suggestion: CorequisiteSuggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title.isEmpty ? "Also add \(suggestion.coreq.description)?" : "Also add \(suggestion.coreq.description) (\(suggestion.title))?")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Corequisite of \(suggestion.parent.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Add") {
                addCorequisite(suggestion)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                withAnimation { suggestions.removeAll { $0 == suggestion } }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss suggestion")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    private func add(_ course: Course, to plan: SchedulePlan) {
        guard !plan.contains(course.key) else { return }
        userData.addCourse(course.key, toPlan: planID)
        haptic.fire(.success)
        Task { await offerCorequisites(for: course.key) }
    }

    private func addCorequisite(_ suggestion: CorequisiteSuggestion) {
        userData.addCourse(suggestion.coreq, toPlan: planID)
        haptic.fire(.success)
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
                // Say so here: the app-wide banner sits behind this sheet.
                catalog.lastRefreshError = nil
                haptic.fire(.warning)
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
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        guard let plan else { return }

        if catalog.selectedTermCode == plan.termCode, catalog.readyIndex != nil {
            let response = await catalog.search(SearchQuery(text: query))
            guard !Task.isCancelled else { return }
            results = response.results
        } else if let index {
            results = Self.localSearch(query, in: index)
        } else {
            results = []
        }
        isSearching = false
    }

    /// A simple code/title search for terms other than the selected one.
    private static func localSearch(_ query: String, in index: CatalogIndex) -> [SearchResult] {
        let normalized = SearchText.normalize(query)
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        var found: [SearchResult] = []
        for course in index.courses {
            let code = "\(course.subject)\(course.number)".lowercased()
            let title = SearchText.normalize(course.title)
            let score: Double
            if code == compact {
                score = 1000
            } else if code.hasPrefix(compact) {
                score = 500 - Double(code.count - compact.count)
            } else if tokens.allSatisfy({ title.contains($0) || code.contains($0) }) {
                score = 100
            } else {
                continue
            }
            found.append(SearchResult(course: course, stats: index.stats(for: course.key), score: score))
        }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.course.key < $1.course.key }
        return found
    }
}
