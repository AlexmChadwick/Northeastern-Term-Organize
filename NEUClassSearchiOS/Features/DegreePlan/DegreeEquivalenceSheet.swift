//
//  DegreeEquivalenceSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Declares (or edits) that a course of the plan counts as another one, such as the old number
/// of a renumbered course counting as the new one. Prerequisite checks and degree requirements
/// then treat the two as the same course.
struct DegreeEquivalenceSheet: View {
    var request: DegreeEquivalenceRequest

    @Environment(UserDataStore.self) private var userData

    var body: some View {
        NavigationStack {
            if let plan = userData.degreePlan(id: request.planID) {
                DegreeEquivalenceForm(plan: plan, request: request)
            } else {
                ContentUnavailableView("Plan not found", systemImage: "list.bullet.clipboard")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct DegreeEquivalenceForm: View {
    var plan: DegreePlan
    var request: DegreeEquivalenceRequest

    @Environment(UserDataStore.self) private var userData
    @Environment(CatalogStore.self) private var catalog
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var course: CourseKey?
    @State private var countsAsText: String
    @State private var note: String
    @State private var results: [Course] = []
    @State private var confirmsDelete = false

    private var info: CourseInfoStore { .shared }

    init(plan: DegreePlan, request: DegreeEquivalenceRequest) {
        self.plan = plan
        self.request = request
        _course = State(initialValue: request.existing?.course ?? request.course)
        _countsAsText = State(initialValue: (request.existing?.countsAs ?? request.countsAs)?.description ?? "")
        _note = State(initialValue: request.existing?.note ?? "")
    }

    private var trimmedText: String { countsAsText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var countsAs: CourseKey? { CourseKey(string: trimmedText) }

    /// The plan's other declared equivalences (all of them for a new one).
    private var otherDeclared: CourseEquivalences {
        CourseEquivalences(declared: plan.courseEquivalences.filter { $0.id != request.existing?.id })
    }

    /// Why the equivalence can't be saved yet; nil when it can.
    private var problem: String? {
        guard let course else { return "Choose the course you have." }
        guard !trimmedText.isEmpty else { return nil }
        guard let countsAs else { return "Enter a course code, like CS 2100." }
        if countsAs == course { return "Choose two different courses." }
        if otherDeclared.areEquivalent(course, countsAs) { return "This plan already counts \(course) as \(countsAs)." }
        if info.equivalences(for: nil).areEquivalent(course, countsAs) { return "Banner already lists \(course) and \(countsAs) as the same course." }
        return nil
    }

    private var canSave: Bool { course != nil && countsAs != nil && problem == nil }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    DegreePlanCoursePicker(choices: plan.degreeCourseChoices, selection: $course)
                } label: {
                    LabeledContent("Course") {
                        Text(course?.description ?? "Choose")
                            .foregroundStyle(course == nil ? Color.secondary : Color.primary)
                    }
                }
                if let course, let title = title(of: course) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Course you have")
            } footer: {
                Text("A completed or planned course in this plan.")
            }

            countsAsSection

            Section {
                TextField("Renumbered in 2025", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            } header: {
                Text("Note")
            }

            if request.existing != nil {
                Section {
                    Button("Delete equivalence", role: .destructive) { confirmsDelete = true }
                }
            }
        }
        .navigationTitle(request.existing == nil ? "Course equivalence" : "Edit equivalence")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .task(id: trimmedText) { await search() }
        .task(id: "\(course?.description ?? "")|\(countsAs?.description ?? "")") {
            // Titles and suggestions for courses the loaded catalogs don't list.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let keys = [course, countsAs].compactMap { $0 }
            if !keys.isEmpty { await info.load(keys, indexes: catalog.degreePlanSnapshot().indexes) }
        }
        .confirmationDialog("Delete this equivalence?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete equivalence", role: .destructive) { delete() }
        } message: {
            Text("The two courses will count separately again.")
        }
    }

    // MARK: Counts as

    @ViewBuilder
    private var countsAsSection: some View {
        // The plan's degree requirements, when set up, add their titles and courses.
        let requirements = programCatalog.requirements(for: plan)
        let suggestions = course.map {
            info.equivalenceSuggestions(
                for: $0, plan: plan,
                catalogTitles: requirements?.courseTitles ?? [:],
                alsoComparing: requirements?.degreeListedCourses(concentrationID: plan.concentrationID) ?? []
            )
        } ?? []
        let matches = results.filter { $0.key != countsAs && $0.key != course }.prefix(6)
        Section {
            TextField("Course code, like CS 2100", text: $countsAsText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if let countsAs, let title = title(of: countsAs) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(suggestions.filter { $0.candidate != countsAs }) { suggestion in
                choiceButton(suggestion.candidate, detail: suggestion.evidence, systemImage: "lightbulb")
            }
            ForEach(Array(matches)) { match in
                choiceButton(match.key, detail: match.title, systemImage: "magnifyingglass")
            }
        } header: {
            Text("Counts as")
        } footer: {
            if let problem, course != nil || !trimmedText.isEmpty {
                Text(problem)
            } else {
                Text("Prerequisite checks and degree requirements will treat both as the same course. Use a substitution instead for a petition that only changes one requirement.")
            }
        }
    }

    private func choiceButton(_ key: CourseKey, detail: String?, systemImage: String) -> some View {
        Button {
            countsAsText = key.description
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.description)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    if let title = title(of: key), title != detail {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Uses \(key.description)")
    }

    /// The loaded catalog's title, else Banner's course catalog's, else the plan's.
    private func title(of key: CourseKey) -> String? {
        catalog.degreePlanSnapshot().course(key)?.title.nilIfBlank
            ?? info.info(for: key)?.title.nilIfBlank
            ?? plan.degreeCourseChoices.first { $0.key == key }?.title.nilIfBlank
    }

    // MARK: Search

    private func search() async {
        let query = trimmedText
        guard query.count >= 2, let index = catalog.readyIndex ?? catalog.degreePlanSnapshot().reference else {
            results = []
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let response = await Task.detached(priority: .userInitiated) {
            SearchEngine.search(SearchQuery(text: query), in: index)
        }.value
        guard !Task.isCancelled else { return }
        results = response.results.prefix(12).map(\.course)
    }

    // MARK: Saving

    private func save() {
        guard let course, let countsAs, problem == nil else { return }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = request.existing {
            userData.updateDegreePlan(id: plan.id) { plan in
                guard let index = plan.courseEquivalences.firstIndex(where: { $0.id == existing.id }) else {
                    plan.declareEquivalence(course: course, countsAs: countsAs, note: note)
                    return
                }
                plan.courseEquivalences[index].course = course
                plan.courseEquivalences[index].countsAs = countsAs
                plan.courseEquivalences[index].note = note
            }
        } else {
            userData.updateDegreePlan(id: plan.id) { $0.declareEquivalence(course: course, countsAs: countsAs, note: note) }
        }
        DegreePlanFeedback.success()
        dismiss()
    }

    private func delete() {
        guard let existing = request.existing else { return }
        userData.updateDegreePlan(id: plan.id) { $0.removeEquivalence(id: existing.id) }
        dismiss()
    }
}

/// Picks one of the plan's courses, completed or planned.
struct DegreePlanCoursePicker: View {
    var choices: [DegreePlanCourseChoice]
    @Binding var selection: CourseKey?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [DegreePlanCourseChoice] {
        DegreeSubstitutionEditing.matching(choices, query: searchText)
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text(choices.isEmpty ? "This plan has no courses yet." : "No course matches “\(searchText)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { choice in
                let isSelected = selection == choice.key
                Button {
                    selection = choice.key
                    dismiss()
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.key.description)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text([choice.title.nilIfBlank, choice.whenLine].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer(minLength: Theme.Spacing.s)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .navigationTitle("Course you have")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Find a course in your plan")
    }
}
