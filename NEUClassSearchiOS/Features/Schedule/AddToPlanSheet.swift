//
//  AddToPlanSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// "Add to Schedule": pick the plans (one or several) that should get a course,
/// optionally with a specific section, or start a new plan on the spot.
struct AddToPlanSheet: View {
    var request: AddToPlanRequest

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var loadedIndex: CatalogIndex?
    @State private var selectedIDs: Set<UUID> = []
    @State private var didSeedSelection = false
    @State private var isCreating = false
    @State private var newName = ""
    @State private var addedPlans: [SchedulePlan]?
    @State private var haptic = PlanHaptic()
    @FocusState private var nameFocused: Bool

    private var index: CatalogIndex? {
        catalog.planIndex(for: request.termCode, fallback: loadedIndex)
    }

    private var course: Course? { index?.course(request.key) }

    private var requestedSection: CourseSection? {
        request.crn.flatMap { index?.section(crn: $0) }
    }

    private var plans: [SchedulePlan] { userData.plans(in: request.termCode) }

    private var courseCRNs: Set<String> {
        var crns = Set(index?.sections(for: request.key).map(\.crn) ?? [])
        if let crn = request.crn { crns.insert(crn) }
        return crns
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                if let addedPlans {
                    successView(addedPlans)
                } else {
                    chooser
                }
            }
            .navigationTitle(addedPlans == nil ? "Add to Schedule" : "Added")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if addedPlans == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .loadPlanIndex(termCode: request.termCode, into: $loadedIndex)
        .planHaptic(haptic)
        .onAppear(perform: seedSelection)
        .task(id: addedPlans?.map(\.id)) {
            // Dismiss on its own after a moment, unless VoiceOver is reading it or
            // there is a choice to make (several schedules to view).
            guard let added = addedPlans, added.count == 1, !voiceOverEnabled else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        List {
            Section {
                courseHeader
            }

            Section {
                ForEach(plans) { plan in
                    planRow(plan)
                }
                newScheduleRow
            } header: {
                Text("Add to")
            } footer: {
                if plans.count > 1 {
                    Text("You can add a course to several schedules. Each keeps its own sections.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            Button(action: add) {
                Text(addButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(targetCount == 0)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
        }
    }

    private var courseHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(request.key.description)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tint)
                    .monospacedDigit()
                if let course {
                    Text(course.creditsLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let term = index?.term {
                    Text(term.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(course?.title ?? requestedSection?.title ?? request.key.description)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let section = requestedSection {
                VStack(alignment: .leading, spacing: 3) {
                    Label(ScheduleFormat.sectionTitleWithCRN(section), systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.medium))
                    Text(section.scheduleSummary + (ScheduleFormat.location(of: section).map { " · \($0)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SeatsBadge(section: section)
                        if let instructors = ScheduleFormat.instructors(of: section) {
                            Text(instructors)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
            } else if request.crn == nil {
                Text("You can choose a section after adding it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Plan rows

    private enum RowState {
        case available
        case alreadyAdded
        case canSwitchSection(current: CourseSection?)
    }

    private func rowState(for plan: SchedulePlan) -> RowState {
        guard plan.contains(request.key) else { return .available }
        guard let crn = request.crn else { return .alreadyAdded }
        let current = plan.selectedCRNs.first { courseCRNs.contains($0) }
        if current == crn { return .alreadyAdded }
        return .canSwitchSection(current: current.flatMap { index?.section(crn: $0) })
    }

    private func planRow(_ plan: SchedulePlan) -> some View {
        let state = rowState(for: plan)
        let isSelected = selectedIDs.contains(plan.id)
        let isSelectable: Bool = {
            if case .alreadyAdded = state { return false }
            return true
        }()

        return Button {
            guard isSelectable else { return }
            withAnimation(.snappy) {
                if isSelected { selectedIDs.remove(plan.id) } else { selectedIDs.insert(plan.id) }
            }
            haptic.fire(.selection)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelectable ? (isSelected ? "checkmark.circle.fill" : "circle") : "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(isSelectable ? (isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)) : AnyShapeStyle(.green))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plan.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if plan.isPrimary {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .accessibilityLabel("My Schedule")
                        }
                    }
                    Text(subtitle(for: plan, state: state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isSelectable ? 1 : 0.75)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func subtitle(for plan: SchedulePlan, state: RowState) -> String {
        switch state {
        case .available:
            let count = plan.courses.count
            return count == 0 ? "Empty" : (count == 1 ? "1 course" : "\(count) courses")
        case .alreadyAdded:
            return request.crn == nil ? "Already in this schedule" : "Already has this section"
        case .canSwitchSection(let current):
            if let current { return "Already added · switch from \(ScheduleFormat.sectionTitle(current))" }
            return "Already added · choose this section"
        }
    }

    @ViewBuilder
    private var newScheduleRow: some View {
        if isCreating {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                TextField("Schedule name", text: $newName)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.words)
                    .onSubmit { nameFocused = false }
                if !plans.isEmpty {
                    Button {
                        withAnimation(.snappy) { isCreating = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel new schedule")
                }
            }
        } else {
            Button {
                startCreating()
            } label: {
                Label("New Schedule…", systemImage: "plus.circle")
                    .font(.body.weight(.medium))
            }
        }
    }

    // MARK: Success

    private func successView(_ added: [SchedulePlan]) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : added.count)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(successTitle(added))
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(successDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .combine)

            VStack(spacing: 10) {
                if added.count == 1, let plan = added.first {
                    Button {
                        view(plan)
                    } label: {
                        Label("View Schedule", systemImage: "calendar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                } else {
                    Menu {
                        ForEach(added) { plan in
                            Button(plan.name) { view(plan) }
                        }
                    } label: {
                        Label("View Schedule", systemImage: "calendar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .padding(.horizontal, Theme.Spacing.l)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successTitle(_ added: [SchedulePlan]) -> String {
        if added.count == 1, let plan = added.first { return "Added to \(plan.name)" }
        return "Added to \(added.count) schedules"
    }

    private var successDetail: String {
        let label = requestedSection.map { ScheduleFormat.sectionTitle($0) }
        if let label { return "\(request.key.description) · \(label) is on your calendar." }
        return "\(request.key.description) is in your schedule. Choose a section to see it on your calendar."
    }

    private func view(_ plan: SchedulePlan) {
        let route = AppRoute.plan(id: plan.id)
        if router.schedulePath.last == route {
            // Already showing this schedule: just switch tabs.
            router.selectedTab = .schedule
        } else {
            router.show(route, in: .schedule)
        }
        dismiss()
    }

    // MARK: Logic

    private var targetCount: Int {
        selectedIDs.count + (isCreating && !newName.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : 0)
    }

    private var addButtonTitle: String {
        let count = targetCount
        if count == 0 { return "Choose a schedule" }
        if count == 1 {
            if isCreating, selectedIDs.isEmpty {
                return "Create “\(newName.trimmingCharacters(in: .whitespaces))” and Add"
            }
            if let id = selectedIDs.first, let name = userData.plan(id: id)?.name { return "Add to \(name)" }
            return "Add"
        }
        return "Add to \(count) Schedules"
    }

    private func seedSelection() {
        guard !didSeedSelection else { return }
        didSeedSelection = true
        let candidates = plans.filter { plan in
            if case .alreadyAdded = rowState(for: plan) { return false }
            return true
        }
        if plans.isEmpty {
            startCreating()
        } else if let primary = candidates.first(where: \.isPrimary) {
            selectedIDs = [primary.id]
        } else if candidates.count == 1, let only = candidates.first {
            selectedIDs = [only.id]
        }
    }

    private func startCreating() {
        newName = PlanEditing.nextPlanName(existing: plans.map(\.name))
        withAnimation(.snappy) { isCreating = true }
        if !plans.isEmpty { nameFocused = true }
    }

    private func add() {
        var ids = Array(selectedIDs)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCreating, !trimmed.isEmpty {
            ids.append(userData.createPlan(name: trimmed, termCode: request.termCode).id)
        }
        guard !ids.isEmpty else { return }

        let crns = courseCRNs
        for id in ids {
            userData.addCourse(request.key, toPlan: id)
            if let crn = request.crn {
                userData.updatePlan(id: id) { PlanEditing.setSection(crn, courseCRNs: crns, in: &$0) }
            }
        }
        haptic.fire(.success)
        let order = Dictionary(userData.plans(in: request.termCode).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        addedPlans = ids.compactMap { userData.plan(id: $0) }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }
}
