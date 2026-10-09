//
//  CourseEquivalencePrompts.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The questions under a course's requirements, shared by the iPhone, iPad and Mac interfaces: the
//  logic here chooses and answers them, each interface draws a question its own way.
//

import SwiftUI

/// Under a requirement: "Did CS 2510 count as CS 2100?" when a course the student completed has
/// since been retired and is likely what the requirement asks for under its current number.
///
/// Only a question. Nothing changes until the student confirms, which declares the equivalence
/// in their primary degree plan; from then on every check that reads the plan counts it (the
/// green marks and the status line here, the plan's own audit). "Dismiss" turns the guess down
/// for good, on every page (`EquivalenceSuggestionDismissals`). Draws nothing without a degree
/// plan, or when there is nothing worth asking.
struct CourseEquivalencePrompts<Row: View>: View {
    var requisite: Requisite
    /// Draws one question: the prompt, what confirming it does and what dismissing it does. Each
    /// interface draws it its own way.
    @ViewBuilder var row: (EquivalencePrompt, _ confirm: @escaping () -> Void, _ dismiss: @escaping () -> Void) -> Row

    @Environment(UserDataStore.self) private var userData
    @AppStorage(EquivalenceSuggestionDismissals.storageKey) private var dismissedRaw = ""
    @State private var prompts: [EquivalencePrompt] = []
    @State private var confirmations = 0

    /// What the questions depend on. When any of it changes they are worked out again.
    private struct Inputs: Hashable {
        var requisite: Requisite
        var planID: UUID?
        var completed: Set<CourseKey>
        var declared: [CourseEquivalence]
        var dismissed: String
        /// Changes as catalog information arrives: which courses are retired, what Banner says.
        var storeVersion: Int
    }

    var body: some View {
        let plan = userData.primaryDegreePlan
        let inputs = Inputs(
            requisite: requisite,
            planID: plan?.id,
            completed: plan?.completedKeys ?? [],
            declared: plan?.courseEquivalences ?? [],
            dismissed: dismissedRaw,
            storeVersion: CourseInfoStore.shared.version
        )
        // A dismissed one goes at once; the next-likeliest takes its place when the task below runs.
        let dismissed = EquivalenceSuggestionDismissals.decode(dismissedRaw)
        let shown = prompts.filter { !dismissed.contains(EquivalenceSuggestionDismissals.pairID($0.taken, $0.required)) }
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let plan {
                ForEach(shown) { prompt in
                    row(prompt, { confirm(prompt, in: plan) }, { dismiss(prompt) })
                }
            }
        }
        .padding(.top, plan != nil && !shown.isEmpty ? Theme.Spacing.s : 0)
        .task(id: inputs) { refresh() }
        .sensoryFeedback(.success, trigger: confirmations)
    }

    /// Works the questions out. Reading the catalogs for every retired course takes a moment,
    /// so this runs when the inputs change rather than on every redraw.
    private func refresh() {
        guard let plan = userData.primaryDegreePlan else {
            prompts = []
            return
        }
        let store = CourseInfoStore.shared
        prompts = EquivalencePrompt.choose(
            for: requisite,
            completed: userData.completedCourses(),
            dismissed: EquivalenceSuggestionDismissals.decode(dismissedRaw)
        ) { retired in
            store.equivalenceSuggestions(for: retired, plan: plan, limit: 12)
        }
    }

    /// The student said no: remember it, and never ask this pair again.
    private func dismiss(_ prompt: EquivalencePrompt) {
        withAnimation(.snappy) {
            EquivalenceSuggestionDismissals.dismiss(prompt, in: &dismissedRaw)
        }
    }

    private func confirm(_ prompt: EquivalencePrompt, in plan: DegreePlan) {
        userData.updateDegreePlan(id: plan.id) { stored in
            stored.declareEquivalence(course: prompt.taken, countsAs: prompt.required, note: "")
        }
        confirmations += 1
    }
}
