//
//  DegreePlanAddCourseSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// "Add course": searches the catalog and adds courses to one semester of a plan. The
/// sheet stays open so several courses can be added in a row.
struct DegreePlanAddCourseSheet: View {
    var planID: UUID
    var termID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var haptic = DegreePlanHaptic()

    private var plan: DegreePlan? { userData.degreePlan(id: planID) }
    private var term: DegreePlanTerm? { plan?.terms.first { $0.id == termID } }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The semester's own catalog, when it is on the device.
    private var termIndex: CatalogIndex? { term.flatMap { catalog.degreePlanSnapshot().index(for: $0) } }

    /// The catalog behind saved and recent courses: the semester's, else the newest on the device.
    private var searchIndex: CatalogIndex? { termIndex ?? catalog.degreePlanSnapshot().reference }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add course")
                .navigationBarTitleDisplayMode(.inline)
                .navigationSubtitle(term.map { "\($0.name) · \($0.degreePlanSummaryLine)" } ?? "")
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Course code or title")
                .onSubmit(of: .search, addByCodeIfUnlisted)
                .autocorrectionDisabled()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: text) { await runSearch() }
        .degreePlanHaptic(haptic)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let plan, let term {
            List {
                if let index = searchIndex {
                    if termIndex == nil {
                        Section {
                            Label("\(term.name) isn’t posted yet, so this searches every catalog on this device. Its courses may differ once it is.", systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        }
                    }
                    if trimmedText.isEmpty {
                        suggestions(index: index, plan: plan, term: term)
                    } else if results.isEmpty {
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                        } else if let key = AddCourseSearch.codeKey(from: trimmedText) {
                            ContentUnavailableView {
                                Label("\(key.description) isn’t in the catalogs on this device", systemImage: "magnifyingglass")
                            } description: {
                                Text("You can still add it to \(term.name) by its code.")
                            } actions: {
                                Button("Add \(key.description)") { addByCode(key) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .listRowBackground(Color.clear)
                        } else {
                            ContentUnavailableView.search(text: trimmedText)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            ForEach(results.prefix(100)) { result in
                                courseRow(result.course, plan: plan, term: term)
                            }
                        } footer: {
                            if results.count > 100 {
                                Text("Showing the first 100 of \(results.count) results. Keep typing to narrow them down.")
                            }
                        }
                    }
                } else if catalog.loadState == .loading {
                    HStack {
                        Spacer()
                        ProgressView("Loading courses…")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView {
                        Label("No course data on this device", systemImage: "icloud.slash")
                    } description: {
                        Text("Download a term’s catalog from the Catalog tab or Settings, then add courses here.")
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        } else {
            ContentUnavailableView("Semester not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    /// Saved and recently viewed courses while the search field is empty.
    @ViewBuilder
    private func suggestions(index: CatalogIndex, plan: DegreePlan, term: DegreePlanTerm) -> some View {
        let code = index.term.code
        let saved = userData.savedCourses(in: code).compactMap { index.course($0.key) }
        let savedKeys = Set(saved.map(\.key))
        let recent = userData.recents(in: code).compactMap { index.course($0.key) }.filter { !savedKeys.contains($0.key) }
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
                        courseRow(course, plan: plan, term: term)
                    }
                }
            }
            if !recent.isEmpty {
                Section("Recently viewed") {
                    ForEach(recent.prefix(12)) { course in
                        courseRow(course, plan: plan, term: term)
                    }
                }
            }
        }
    }

    private func courseRow(_ course: Course, plan: DegreePlan, term: DegreePlanTerm) -> some View {
        let entry = DegreePlanCourse(key: course.key, title: course.title, credits: course.defaultChoiceCredits)
        return Button {
            add(course)
        } label: {
            HStack(spacing: 10) {
                DegreePlanCourseRow(
                    course: entry,
                    title: course.title,
                    status: missingPrerequisite(of: course, in: plan, term: term),
                    note: planNote(for: course, in: plan, term: term)
                )
                addState()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(accessibilityHint(for: course, in: term))
    }

    /// "Add" stays available after the course is already in the semester, so a second copy can be added.
    private func addState() -> some View {
        Label("Add", systemImage: "plus")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.14), in: .capsule)
            .accessibilityHidden(true)
    }

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

    private func add(_ course: Course) {
        guard term != nil else { return }
        let entry = DegreePlanCourse(
            key: course.key,
            title: DegreePlanFormat.exportTitle(course.title),
            credits: course.defaultChoiceCredits
        )
        userData.updateDegreePlan(id: planID) { DegreePlanEditing.add(entry, toTerm: termID, in: &$0) }
        haptic.fire(.success)
    }

    /// Return in the search field adds the typed code when nothing in the catalogs matched it.
    private func addByCodeIfUnlisted() {
        guard !isSearching, results.isEmpty, let key = AddCourseSearch.codeKey(from: trimmedText) else { return }
        addByCode(key)
    }

    /// Adds a course by its code when no catalog on this device lists it.
    private func addByCode(_ key: CourseKey) {
        guard term != nil else { return }
        let entry = DegreePlanCourse(key: key, title: key.description, credits: AddCourseSearch.byCodeCredits)
        userData.updateDegreePlan(id: planID) { DegreePlanEditing.add(entry, toTerm: termID, in: &$0) }
        haptic.fire(.success)
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

        guard let term else { return }
        let found = await catalog.degreePlanSnapshot().searchForAdding(SearchQuery(text: query), semester: term)
        guard !Task.isCancelled else { return }
        results = found.results
        isSearching = false
    }
}
