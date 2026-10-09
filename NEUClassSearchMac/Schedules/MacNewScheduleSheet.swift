//
//  MacNewScheduleSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// File › New Schedule (⌘N): names a schedule for a term, optionally starts it with the courses a
/// degree plan (or another schedule) has for that term, and opens it.
struct MacNewScheduleSheet: View {
    /// Starts with the first suggestion chosen (for snapshots).
    var startsWithFirstSuggestion = false

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// Whether the student has typed a name (otherwise it follows the term: "Plan A", "Plan B"…).
    @State private var hasEditedName = false
    /// The next change of `name` is ours (a new suggestion), not the student typing.
    @State private var isSuggestingName = false
    @State private var termCode: String?
    @State private var startChoice: String?
    @State private var loadedIndex: CatalogIndex?
    @State private var isCreating = false
    @FocusState private var isNameFocused: Bool

    /// The terms to choose from: the selected one first, then the others, newest first.
    private var terms: [Term] {
        var list = catalog.terms
        if let selected = catalog.selectedTerm, !list.contains(where: { $0.code == selected.code }) { list.append(selected) }
        return list.sorted(by: >)
    }

    private var selectedTerm: Term? {
        guard let termCode else { return nil }
        return terms.first { $0.code == termCode }
    }

    /// The catalog of the chosen term, once it is loaded.
    private var index: CatalogIndex? {
        guard let termCode else { return nil }
        return catalog.cachedIndex(for: termCode) ?? loadedIndex.flatMap { $0.term.code == termCode ? $0 : nil }
    }

    /// A schedule with nothing in it for the chosen term, to ask which courses it could start with.
    private var draftPlan: SchedulePlan? {
        guard let termCode else { return nil }
        return SchedulePlan(name: name, termCode: termCode)
    }

    private var suggestions: [ScheduleAutofillSuggestion] {
        guard let draftPlan else { return [] }
        return ScheduleAutofillSupport.suggestions(
            for: draftPlan,
            terms: catalog.terms,
            degreePlans: userData.degreePlans,
            schedulePlans: userData.plans,
            index: index
        )
    }

    private var chosenSuggestion: ScheduleAutofillSuggestion? {
        guard let startChoice else { return nil }
        return suggestions.first { $0.id == startChoice }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Plan A"))
                        .focused($isNameFocused)
                        .onChange(of: name) { _, _ in
                            if isSuggestingName {
                                isSuggestingName = false
                            } else {
                                hasEditedName = true
                            }
                        }
                        .onSubmit(create)
                    Picker("Term", selection: $termCode) {
                        ForEach(terms) { term in
                            Text(term.name).tag(String?.some(term.code))
                        }
                    }
                } header: {
                    Text("New Schedule")
                } footer: {
                    Text("Name your schedule, like “Plan A”. You can build several and compare them.")
                }

                startSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(termCode == nil || isCreating)
            }
            .padding(12)
        }
        .frame(width: 480)
        .frame(minHeight: 280)
        .onAppear {
            termCode = catalog.selectedTermCode ?? terms.first?.code
            suggestName()
            isNameFocused = true
        }
        .task {
            // Once the term is set and its suggestions are known.
            guard startsWithFirstSuggestion else { return }
            try? await Task.sleep(for: .milliseconds(400))
            startChoice = suggestions.first?.id
        }
        .onChange(of: termCode) { _, _ in
            startChoice = nil
            if !hasEditedName { suggestName() }
        }
        .task(id: termCode) {
            guard let termCode else { return }
            loadedIndex = await catalog.index(for: termCode)
        }
    }

    /// Puts the next free "Plan A"-style name for the chosen term in the field.
    private func suggestName() {
        let suggestion = suggestedName
        guard suggestion != name else { return }
        isSuggestingName = true
        name = suggestion
    }

    private var suggestedName: String {
        guard let termCode else { return PlanEditing.nextPlanName(existing: []) }
        return PlanEditing.nextPlanName(existing: userData.plans(in: termCode).map(\.name))
    }

    // MARK: Start with

    @ViewBuilder
    private var startSection: some View {
        let options = suggestions
        if !options.isEmpty, let draftPlan {
            Section {
                Picker("Start with", selection: $startChoice) {
                    Text("An empty schedule").tag(String?.none)
                    ForEach(options) { suggestion in
                        let count = suggestion.courses.isEmpty ? "none offered" : ScheduleAutofillSupport.courseCountLabel(suggestion.courses.count)
                        Text("\(suggestion.title) · \(count)").tag(String?.some(suggestion.id))
                    }
                }
                if let suggestion = chosenSuggestion {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        MacAutofillCourses(suggestion: suggestion, plan: draftPlan, index: index)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Courses")
            } footer: {
                Text("Add the courses you planned for this term, or build the schedule yourself.")
            }
        }
    }

    // MARK: Actions

    private func create() {
        guard let termCode, !isCreating else { return }
        isCreating = true
        let finalName = trimmedName.isEmpty ? suggestedName : trimmedName
        let plan = userData.createPlan(name: finalName, termCode: termCode)
        if let suggestion = chosenSuggestion {
            for key in suggestion.courses { userData.addCourse(key, toPlan: plan.id, required: true) }
        }
        let needsTermSwitch = termCode != catalog.selectedTermCode
        Task {
            // A schedule for another term only shows up in the sidebar once that term is selected.
            if needsTermSwitch {
                await catalog.select(termCode: termCode)
                userData.preferences.selectedTermCode = termCode
            }
            navigator.selection = .schedule(plan.id)
            dismiss()
        }
    }
}
