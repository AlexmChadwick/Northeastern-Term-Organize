//
//  MacNewDegreePlanSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// File › New Degree Plan (⇧⌘N): starts a plan, autofilled from the closest previous plan and
/// the My Schedule plans, with a live preview of what it will start with. The new plan is
/// selected in the sidebar.
struct MacNewDegreePlanSheet: View {
    @Environment(UserDataStore.self) private var userData

    var body: some View {
        MacNewDegreePlanForm(
            defaultName: DegreePlanEditing.defaultNewPlanName(existing: userData.degreePlans.map(\.name)),
            latestPlan: userData.primaryDegreePlan
        )
    }
}

/// The form itself. It's a separate view so its fields can start from values that depend on
/// the stored plans (the default name, the latest plan's program).
private struct MacNewDegreePlanForm: View {
    var defaultName: String

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
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
        return VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Plan name", text: $name)
                    TextField("Program (optional)", text: programBinding, prompt: Text("CS-B-CSCI-BSCS"))
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
                                Text(position == 0 ? "Copy “\(plan.name)” (your latest plan)" : "Copy “\(plan.name)”")
                                    .tag(Source.plan(plan.id))
                            }
                            Divider()
                            Text("Empty plan").tag(Source.empty)
                        }
                        if let sourcePlan {
                            Text("\(DegreePlanText.credits(sourcePlan.completedCredits)) completed · \(DegreePlanText.semesters(sourcePlan.terms.count)) planned")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
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
                            .foregroundStyle(.secondary)
                    } else {
                        MacDegreePlanPreviewRows(plan: preview)
                    }
                } header: {
                    Text("Preview")
                }
            }
            .formStyle(.grouped)
            .onChange(of: source) { _, newValue in
                // Follow the chosen plan's program until the program has been typed by hand.
                guard !programWasEdited, case .plan(let id) = newValue, let program = userData.degreePlan(id: id)?.program else { return }
                self.program = program
            }
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Create", onConfirm: create, onCancel: { dismiss() })
        }
        .frame(width: 540, height: 640)
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
        dismiss()
        navigator.selection = .degreePlan(stored.id)
    }
}
