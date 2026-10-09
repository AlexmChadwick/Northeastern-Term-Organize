//
//  NewDegreePlanSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Creates a new degree plan, autofilled from your latest plan and your My Schedule
/// plans, with a live preview of what it will start with.
struct NewDegreePlanSheet: View {
    @Environment(UserDataStore.self) private var userData

    var body: some View {
        NavigationStack {
            NewDegreePlanForm(
                defaultName: DegreePlanEditing.defaultNewPlanName(existing: userData.degreePlans.map(\.name)),
                latestPlan: userData.primaryDegreePlan
            )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// The form itself. It's a separate view so its fields can start from values that
/// depend on the stored plans (the default name, the latest plan's program).
private struct NewDegreePlanForm: View {
    var defaultName: String

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var program: String
    @State private var source: Source
    @State private var includesSchedule = true
    @State private var programWasEdited = false

    private enum Source: Hashable {
        case plan(UUID)
        case empty
    }

    init(defaultName: String, latestPlan: DegreePlan?) {
        self.defaultName = defaultName
        _name = State(initialValue: defaultName)
        _program = State(initialValue: latestPlan?.program ?? "")
        _source = State(initialValue: latestPlan.map { Source.plan($0.id) } ?? Source.empty)
    }

    // MARK: Derived

    private var trimmedName: String { name.nilIfBlank ?? defaultName }

    /// Existing plans to copy from: the latest first.
    private var sourceOptions: [DegreePlan] {
        guard let latest = userData.primaryDegreePlan else { return [] }
        return [latest] + userData.sortedDegreePlans.filter { $0.id != latest.id }
    }

    private var sourcePlan: DegreePlan? {
        guard case .plan(let id) = source else { return nil }
        return userData.degreePlan(id: id)
    }

    /// What "Create" would make. A copy keeps the source plan's degree requirement setup,
    /// substitutions and course equivalences (`newDegreePlanDraft` copies them).
    private var draft: DegreePlan {
        var plan = DegreePlanAutofill.newDegreePlanDraft(
            name: trimmedName,
            basedOn: sourcePlan,
            schedulePlans: includesSchedule ? userData.plans : [],
            catalogIndex: { catalog.cachedIndex(for: $0) }
        )
        plan.program = program.nilIfBlank
        return plan
    }

    private var uniqueName: String {
        DegreePlanEditing.uniqueName(trimmedName, existing: userData.degreePlans.map(\.name))
    }

    // MARK: Body

    var body: some View {
        let preview = draft
        return Form {
            Section {
                TextField("Plan name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Program (optional)", text: programBinding)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } header: {
                Text("Plan")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The program is the code from your degree audit, like CS-B-CSCI-BSCS.")
                    if uniqueName != trimmedName {
                        Text("You already have a plan called “\(trimmedName)”, so this one is saved as “\(uniqueName)”.")
                    }
                }
            }

            if !sourceOptions.isEmpty {
                Section("Start from") {
                    Picker("Start from", selection: $source) {
                        ForEach(Array(sourceOptions.enumerated()), id: \.element.id) { position, plan in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(position == 0 ? "Copy “\(plan.name)” (your latest plan)" : "Copy “\(plan.name)”")
                                Text("\(DegreePlanText.credits(plan.completedCredits)) completed · \(DegreePlanText.semesters(plan.terms.count)) planned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Source.plan(plan.id))
                        }
                        Text("Empty plan").tag(Source.empty)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Section {
                Toggle("Include courses from My Schedule", isOn: $includesSchedule)
            } footer: {
                Text("Adds the courses in your My Schedule plans for terms that haven’t ended, as semesters in this plan.")
            }

            Section {
                if preview.completed.isEmpty && preview.terms.isEmpty {
                    Text("Nothing to start with yet. You can add semesters and courses after creating the plan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    DegreePlanPreviewRows(plan: preview)
                }
            } header: {
                Text("Preview")
            }
        }
        .navigationTitle("New degree plan")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: source) { _, newValue in
            // Follow the chosen plan's program until the program has been typed by hand.
            guard !programWasEdited, case .plan(let id) = newValue, let program = userData.degreePlan(id: id)?.program else { return }
            self.program = program
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }
            }
        }
    }

    private var programBinding: Binding<String> {
        Binding(
            get: { program },
            set: {
                program = $0
                programWasEdited = true
            }
        )
    }

    // MARK: Create

    private func create() {
        var plan = draft
        plan.name = uniqueName
        let stored = userData.addDegreePlan(plan)
        DegreePlanFeedback.success()
        dismiss()
        router.show(.degreePlan(id: stored.id), in: .schedule)
    }
}
