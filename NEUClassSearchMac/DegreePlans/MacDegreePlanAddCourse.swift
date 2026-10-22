//
//  MacDegreePlanAddCourse.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// "Add Course": a popover that searches the catalog and adds courses to one semester of a
/// plan. It stays open so several courses can be added in a row: the arrow keys move through
/// the results and Return adds the highlighted course.
struct MacDegreePlanAddCourse: View {
    var planID: UUID
    var termID: UUID
    var editor: MacDegreePlanEditor

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData

    @State private var text: String
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var highlighted: CourseKey?
    @FocusState private var searchIsFocused: Bool

    /// - Parameter initialText: what the search field starts with.
    init(planID: UUID, termID: UUID, editor: MacDegreePlanEditor, initialText: String = "") {
        self.planID = planID
        self.termID = termID
        self.editor = editor
        _text = State(initialValue: initialText)
    }

    private var plan: DegreePlan? { userData.degreePlan(id: planID) }
    private var term: DegreePlanTerm? { plan?.terms.first { $0.id == termID } }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The catalog searched: the selected term's, else the newest one on this Mac.
    private var searchIndex: CatalogIndex? { catalog.readyIndex ?? catalog.degreePlanSnapshot().reference }

    /// The courses listed now, in order: search results, or saved and recent courses.
    private var listed: [Course] {
        guard let index = searchIndex, plan != nil, term != nil else { return [] }
        if trimmedText.isEmpty {
            let code = index.term.code
            let saved = userData.savedCourses(in: code).compactMap { index.course($0.key) }
            let savedKeys = Set(saved.map(\.key))
            let recent = userData.recents(in: code).compactMap { index.course($0.key) }.filter { !savedKeys.contains($0.key) }
            return Array(saved.prefix(20)) + Array(recent.prefix(12))
        }
        return results.prefix(100).map(\.course)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 540, height: 500)
        .task(id: text) { await runSearch() }
        .task {
            // Focus once the popover is on screen.
            try? await Task.sleep(for: .milliseconds(150))
            searchIsFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let term {
                HStack(alignment: .firstTextBaseline) {
                    Text("Add Course to \(term.name)")
                        .font(.headline)
                    Spacer()
                    Text(term.degreePlanSummaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            TextField("Course code or title", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($searchIsFocused)
                .onSubmit(addHighlighted)
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .accessibilityLabel("Search courses to add")
        }
        .padding(12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let plan, let term {
            if let index = searchIndex {
                VStack(spacing: 0) {
                    if !term.matches(index.term) {
                        Label("Searching the \(index.term.name) catalog. \(term.name) courses may differ once it’s posted.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    list(index: index, plan: plan, term: term)
                }
            } else if catalog.loadState == .loading {
                ProgressView("Loading courses…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No course data on this Mac", systemImage: "icloud.slash")
                } description: {
                    Text("Download a term’s catalog, then add courses here.")
                }
            }
        } else {
            ContentUnavailableView("Semester not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    @ViewBuilder
    private func list(index: CatalogIndex, plan: DegreePlan, term: DegreePlanTerm) -> some View {
        let courses = listed
        if courses.isEmpty {
            if trimmedText.isEmpty {
                ContentUnavailableView {
                    Label("Find a course", systemImage: "magnifyingglass")
                } description: {
                    Text("Search by code, like CS 3000, or by title. Saved and recently viewed courses show up here.")
                }
            } else if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: trimmedText)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(courses) { course in
                            courseRow(course, plan: plan, term: term)
                                .id(course.key)
                        }
                        if trimmedText.isEmpty == false, results.count > 100 {
                            Text("Showing the first 100 of \(results.count) results. Keep typing to narrow them down.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, key in
                    if let key { proxy.scrollTo(key) }
                }
            }
        }
    }

    private func courseRow(_ course: Course, plan: DegreePlan, term: DegreePlanTerm) -> some View {
        let entry = DegreePlanCourse(key: course.key, title: course.title, credits: course.defaultChoiceCredits)
        let isHighlighted = highlighted == course.key
        return Button {
            add(course)
        } label: {
            HStack(spacing: 8) {
                MacDegreePlanCourseRow(
                    course: entry,
                    title: course.title,
                    status: missingPrerequisite(of: course, in: plan, term: term),
                    note: planNote(for: course, in: plan, term: term)
                )
                addState()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { highlighted = course.key }
        }
        .accessibilityHint(accessibilityHint(for: course, in: term))
    }

    /// "Add" stays available after the course is already in the semester, so a second copy can be added.
    private func addState() -> some View {
        Label("Add", systemImage: "plus")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
            .fixedSize()
            .accessibilityHidden(true)
    }

    // MARK: Checks

    /// Warns when the plan wouldn't have a course's prerequisites done before this semester
    /// (counting courses equivalent to the ones it names).
    private func missingPrerequisite(of course: Course, in plan: DegreePlan, term: DegreePlanTerm) -> DegreePlanAnalysis.PrerequisiteStatus? {
        guard course.detailsLoaded, let position = plan.terms.firstIndex(where: { $0.id == term.id }) else { return nil }
        let status = DegreePlanAnalysis.status(
            of: course.prereqs,
            satisfiedBy: DegreePlanAnalysis.coursesBefore(termIndex: position, in: plan),
            equivalences: CourseInfoStore.shared.equivalences(for: plan)
        )
        return status.isMissing ? status : nil
    }

    /// A non-blocking note when the plan already has this number. Adding still keeps another copy.
    private func planNote(for course: Course, in plan: DegreePlan, term: DegreePlanTerm) -> String? {
        if term.courses.contains(where: { $0.key == course.key }) {
            return "Already in \(term.name). Adding it again keeps both copies."
        }
        if plan.completedKeys.contains(course.key) { return "Already in your completed courses. Each copy still counts." }
        if let other = plan.terms.first(where: { $0.id != term.id && $0.courses.contains { $0.key == course.key } }) {
            return "Already planned in \(other.name). Each copy still counts."
        }
        return nil
    }

    private func accessibilityHint(for course: Course, in term: DegreePlanTerm) -> String {
        term.courses.contains(where: { $0.key == course.key })
            ? "Adds another \(course.key) to \(term.name)"
            : "Adds to \(term.name)"
    }

    // MARK: Actions

    private func moveHighlight(by step: Int) {
        let keys = listed.map(\.key)
        guard !keys.isEmpty else { return }
        guard let current = highlighted.flatMap({ keys.firstIndex(of: $0) }) else {
            highlighted = step > 0 ? keys.first : keys.last
            return
        }
        highlighted = keys[min(max(0, current + step), keys.count - 1)]
    }

    private func addHighlighted() {
        let courses = listed
        guard let course = courses.first(where: { $0.key == highlighted }) ?? courses.first else { return }
        add(course)
    }

    private func add(_ course: Course) {
        guard term != nil else { return }
        let entry = MacDegreePlanEditor.newCourse(from: course)
        editor.perform("Add \(course.key)") { DegreePlanEditing.add(entry, toTerm: termID, in: &$0) }
    }

    // MARK: Search

    private func runSearch() async {
        let query = trimmedText
        guard !query.isEmpty else {
            results = []
            isSearching = false
            highlighted = nil
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }

        if catalog.readyIndex != nil {
            let response = await catalog.search(SearchQuery(text: query))
            guard !Task.isCancelled else { return }
            results = response.results
        } else if let index = catalog.degreePlanSnapshot().reference {
            let response = await Task.detached(priority: .userInitiated) {
                SearchEngine.search(SearchQuery(text: query), in: index)
            }.value
            guard !Task.isCancelled else { return }
            results = response.results
        } else {
            results = []
        }
        highlighted = results.first?.course.key
        isSearching = false
    }
}
