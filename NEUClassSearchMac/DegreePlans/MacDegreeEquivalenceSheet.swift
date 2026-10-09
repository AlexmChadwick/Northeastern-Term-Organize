//
//  MacDegreeEquivalenceSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Declares (or edits) that a course of the plan counts as another one, such as the old number
/// of a renumbered course counting as the new one. Prerequisite checks and degree requirements
/// then treat the two as the same course.
struct MacDegreeEquivalenceSheet: View {
    var request: DegreeEquivalenceRequest

    @Environment(UserDataStore.self) private var userData

    var body: some View {
        if let plan = userData.degreePlan(id: request.planID) {
            MacDegreeEquivalenceForm(plan: plan, request: request)
        } else {
            ContentUnavailableView("Plan not found", systemImage: "list.bullet.clipboard")
                .frame(width: 520, height: 260)
        }
    }
}

private struct MacDegreeEquivalenceForm: View {
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
    @State private var isChoosingCourse = false

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
        VStack(spacing: 0) {
            Form {
                courseSection
                countsAsSection
                Section("Note") {
                    TextField("Note", text: $note, prompt: Text("Renumbered in 2025"), axis: .vertical)
                        .lineLimit(1...4)
                        .labelsHidden()
                }
                if request.existing != nil {
                    Section {
                        Button("Delete Equivalence…", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Save", isConfirmDisabled: !canSave, onConfirm: save, onCancel: { dismiss() })
        }
        .frame(width: 520, height: 600)
        .task(id: trimmedText) { await search() }
        .task(id: "\(course?.description ?? "")|\(countsAs?.description ?? "")") {
            // Titles and suggestions for courses the loaded catalogs don't list.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let keys = [course, countsAs].compactMap { $0 }
            if !keys.isEmpty { await info.load(keys, indexes: catalog.degreePlanSnapshot().indexes) }
        }
        .confirmationDialog("Delete this equivalence?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Equivalence", role: .destructive) { delete() }
        } message: {
            Text("The two courses will count separately again.")
        }
    }

    // MARK: Course

    private var courseSection: some View {
        Section {
            LabeledContent("Course") {
                Button(course?.description ?? "Choose…") {
                    isChoosingCourse = true
                }
                .popover(isPresented: $isChoosingCourse, arrowEdge: .bottom) {
                    MacDegreeCoursePicker(choices: plan.degreeCourseChoices, selection: $course)
                }
            }
            if let course, let title = title(of: course) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Course you have")
        } footer: {
            Text("A completed or planned course in this plan.")
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
            TextField("Course code", text: $countsAsText, prompt: Text("Course code, like CS 2100"))
                .autocorrectionDisabled()
            if let countsAs, let title = title(of: countsAs) {
                Text(title)
                    .font(.callout)
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.description)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    if let title = title(of: key), title != detail {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
        try? await Task.sleep(for: .milliseconds(200))
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
        dismiss()
    }

    private func delete() {
        guard let existing = request.existing else { return }
        userData.updateDegreePlan(id: plan.id) { $0.removeEquivalence(id: existing.id) }
        dismiss()
    }
}
