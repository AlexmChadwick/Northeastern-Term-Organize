//
//  RequirementSubstitutionSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Records an approved exception to a requirement: a course that counts toward it, a petition
/// that replaces it with other courses, or a waiver, each with a note and approval date.
struct RequirementSubstitutionSheet: View {
    var request: DegreeSubstitutionRequest
    /// Called when the course turned out to be the required course under a new number (so the
    /// screen below can say so, with Undo).
    var onRenumbered: (DegreeRenumbering) -> Void = { _ in }

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog

    var body: some View {
        let plan = userData.degreePlan(id: request.planID)
        let requirements = plan.flatMap { programCatalog.requirements(for: $0) }
        NavigationStack {
            if let plan {
                RequirementSubstitutionForm(
                    request: request,
                    plan: plan,
                    requirements: requirements,
                    initialAmount: Self.initialAmount(rule: requirements?.rule(id: request.ruleID)),
                    onRenumbered: onRenumbered
                )
            } else {
                ContentUnavailableView("Plan not found", systemImage: "list.bullet.clipboard")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// A petition usually replaces a requirement with as many courses (or hours) as it asks for.
    private static func initialAmount(rule: RequirementRule?) -> (count: Int, hours: Double, inHours: Bool) {
        DegreeSubstitutionRequest.initialAmount(rule: rule)
    }
}

private struct RequirementSubstitutionForm: View {
    var request: DegreeSubstitutionRequest
    var plan: DegreePlan
    var requirements: ProgramRequirements?
    var onRenumbered: (DegreeRenumbering) -> Void

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var kind: DegreeSubstitutionRequest.Kind
    @State private var course: CourseKey?
    @State private var amountInHours: Bool
    @State private var count: Int
    @State private var hours: Double
    @State private var likeRuleID: String?
    @State private var specificCourses: Set<CourseKey>
    /// Which course numbers count, when "Courses like" has a minimum; nil until answered.
    @State private var numberChoice: CourseNumberChoice?
    @State private var minimumNumber: Int
    @State private var note: String
    @State private var hasApprovalDate: Bool
    @State private var approvalDate: Date
    @State private var searchText = ""
    @State private var confirmsDelete = false
    @State private var asksRenumbering = false

    init(request: DegreeSubstitutionRequest, plan: DegreePlan, requirements: ProgramRequirements?,
         initialAmount: (count: Int, hours: Double, inHours: Bool), onRenumbered: @escaping (DegreeRenumbering) -> Void) {
        self.request = request
        self.plan = plan
        self.requirements = requirements
        self.onRenumbered = onRenumbered
        let existing = request.existing
        var course: CourseKey?
        var replacement: RequirementReplacement?
        if case .countCourse(let key)? = existing?.change { course = key }
        if case .replace(let value)? = existing?.change { replacement = value }
        _kind = State(initialValue: request.kind)
        _course = State(initialValue: course ?? request.course)
        _amountInHours = State(initialValue: replacement.map { $0.count == nil && $0.hours != nil } ?? initialAmount.inHours)
        _count = State(initialValue: replacement?.count ?? initialAmount.count)
        _hours = State(initialValue: replacement?.hours ?? initialAmount.hours)
        _likeRuleID = State(initialValue: replacement?.likeRuleID)
        _specificCourses = State(initialValue: Set(replacement?.courses ?? []))
        _numberChoice = State(initialValue: CourseNumberChoice(replacement?.courseNumbers))
        _minimumNumber = State(initialValue: CourseNumberChoice.suggestedMinimum(
            for: DegreeSubstitutionEditing.likeRanges(likeRuleID: replacement?.likeRuleID, requirements: requirements),
            saved: replacement?.courseNumbers
        ))
        _note = State(initialValue: existing?.note ?? "")
        _hasApprovalDate = State(initialValue: existing?.approvedOn != nil)
        _approvalDate = State(initialValue: existing?.approvedOn ?? .now)
    }

    private var audit: DegreeAudit? {
        requirements.map {
            DegreeAudit.run(plan: plan, requirements: $0, equivalences: CourseInfoStore.shared.equivalences(for: plan),
                            attributes: CourseInfoStore.shared.degreeAttributes(for: plan))
        }
    }

    private var rule: RequirementRule? { requirements?.rule(id: request.ruleID) }

    var body: some View {
        let audit = audit
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.ruleTitle)
                        .font(.headline)
                    if let rule, rule.displayLabel != request.ruleTitle {
                        Text(rule.displayLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Requirement")
            }

            if let offer = savedRenumbering {
                renumberingSection(offer)
            }

            Section {
                Picker("Change", selection: $kind.animation(.snappy)) {
                    kindOption("Count a course toward it", "A course in your plan counts toward this requirement.").tag(DegreeSubstitutionRequest.Kind.countCourse)
                    kindOption("Replace it (petition)", "Other courses satisfy it, like two Khoury electives.").tag(DegreeSubstitutionRequest.Kind.replace)
                    kindOption("Waive it", "The requirement no longer applies to you.").tag(DegreeSubstitutionRequest.Kind.waive)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            switch kind {
            case .countCourse:
                courseSections(audit: audit)
            case .replace:
                replacementSections(audit: audit)
            case .waive:
                Section {
                    EmptyView()
                } footer: {
                    Text("The requirement won’t be checked. Add who approved it below.")
                }
            }

            Section {
                TextField("Petition approved by Khoury advising…", text: $note, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("Note")
            }

            Section {
                Toggle("Approval date", isOn: $hasApprovalDate.animation(.snappy))
                if hasApprovalDate {
                    DatePicker("Approved on", selection: $approvalDate, displayedComponents: .date)
                }
            }

            if request.existing != nil {
                Section {
                    Button("Delete substitution", role: .destructive) { confirmsDelete = true }
                }
            }
        }
        .navigationTitle(request.existing == nil ? "Add substitution" : "Edit substitution")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find a course in your plan")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Delete this substitution?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete substitution", role: .destructive) { deleteSubstitution() }
        } message: {
            Text("The requirement goes back to the catalog’s rule.")
        }
        .confirmationDialog(
            renumbering.map { "Is \($0.course.description) the new number of \($0.countsAs.description)?" } ?? "Same course under a new number?",
            isPresented: $asksRenumbering,
            titleVisibility: .visible
        ) {
            Button("Same course, new number") { makeRenumbering() }
            Button("Keep as substitution") { performSave() }
        } message: {
            if let renumbering {
                Text("\(renumbering.countsAs.description) isn’t offered anymore. If it’s the same course under a new number, \(renumbering.course.description) counts as it everywhere, prerequisites included.")
            }
        }
    }

    // MARK: Same course, new number

    /// What counting the chosen course amounts to when the requirement names exactly one course:
    /// the same course under a new number (CS 3484 for IS 4800). Nil for any other substitution.
    private var renumbering: CourseEquivalence? {
        guard kind == .countCourse, let course else { return nil }
        let substitution = RequirementSubstitution(ruleID: request.ruleID, ruleTitle: request.ruleTitle, change: .countCourse(course))
        return DegreeSubstitutionEditing.renumbering(for: substitution, requirements: requirements)
    }

    /// Whether Banner says the required course isn't offered anymore while the chosen one is.
    private func looksRenumbered(_ renumbering: CourseEquivalence) -> Bool {
        let info = CourseInfoStore.shared
        return info.info(for: renumbering.countsAs)?.isRetired == true && info.info(for: renumbering.course)?.isRetired != true
    }

    /// The offer for a saved substitution whose course is still the one chosen here.
    private var savedRenumbering: CourseEquivalence? {
        guard let existing = request.existing, case .countCourse(let saved) = existing.change, saved == course else { return nil }
        return renumbering
    }

    private func renumberingSection(_ offer: CourseEquivalence) -> some View {
        let retired = looksRenumbered(offer)
        return Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label {
                    Text("Is \(offer.course.description) the new number of \(offer.countsAs.description)?")
                        .font(.headline)
                } icon: {
                    Image(systemName: "equal.circle")
                        .foregroundStyle(.tint)
                }
                Text(retired
                     ? "\(offer.countsAs.description) isn’t offered anymore. If \(offer.course.description) is the same course under a new number, it counts as \(offer.countsAs.description) everywhere, prerequisites included, instead of being a substitution."
                     : "If \(offer.course.description) is the same course as \(offer.countsAs.description) under a new number, it counts as \(offer.countsAs.description) everywhere, prerequisites included, instead of being a substitution.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Same course, new number") { makeRenumbering() }
                    .buttonStyle(.glassProminent)
                    .padding(.top, 2)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    /// Counts the course as the required one instead of recording a substitution, and tells the
    /// screen below so it can offer Undo.
    private func makeRenumbering() {
        let change: DegreeRenumbering?
        if let existing = request.existing {
            change = DegreeRenumbering.convert(existing, planID: request.planID, requirements: requirements, userData: userData)
        } else if let renumbering {
            change = DegreeRenumbering.declare(course: renumbering.course, countsAs: renumbering.countsAs, planID: request.planID, userData: userData)
        } else {
            change = nil
        }
        guard let change else { return }
        DegreePlanFeedback.success()
        onRenumbered(change)
        dismiss()
    }

    private func kindOption(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Count a course

    private var choices: [DegreePlanCourseChoice] {
        DegreeSubstitutionEditing.matching(plan.degreeCourseChoices, query: searchText)
    }

    /// Courses that don't count toward another requirement (free ones and general electives)
    /// come first; ones that count elsewhere move here when chosen.
    @ViewBuilder
    private func courseSections(audit: DegreeAudit?) -> some View {
        let counting: (CourseKey) -> String? = { key in audit?.ruleCounting(key)?.rule.id }
        let isFree: (DegreePlanCourseChoice) -> Bool = { choice in
            DegreeSubstitutionEditing.isFree(countingRuleID: counting(choice.key), ruleID: request.ruleID, requirements: requirements)
        }
        let free = choices.filter(isFree)
        let elsewhere = choices.filter { !isFree($0) }
        if choices.isEmpty {
            Section {
                Text(searchText.isEmpty ? "Your plan has no courses yet." : "No course in your plan matches “\(searchText)”.")
                    .foregroundStyle(.secondary)
            }
        }
        if !free.isEmpty {
            Section {
                ForEach(free) { choice in
                    courseChoiceRow(choice, caption: caption(for: choice, countingRuleID: counting(choice.key)), isSelected: course == choice.key) {
                        course = choice.key
                    }
                }
            } header: {
                Text("Not counted elsewhere")
            }
        }
        if !elsewhere.isEmpty {
            Section {
                ForEach(elsewhere) { choice in
                    courseChoiceRow(choice, caption: caption(for: choice, countingRuleID: counting(choice.key)), isSelected: course == choice.key) {
                        course = choice.key
                    }
                }
            } header: {
                Text("Counted elsewhere")
            } footer: {
                Text("Choosing one of these moves it to this requirement.")
            }
        }
    }

    private func caption(for choice: DegreePlanCourseChoice, countingRuleID: String?) -> String? {
        DegreeSubstitutionEditing.caption(for: choice, countingRuleID: countingRuleID, ruleID: request.ruleID, requirements: requirements)
    }

    private func courseChoiceRow(_ choice: DegreePlanCourseChoice, caption: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.key.description)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .monospacedDigit()
                    Text([choice.title.nilIfBlank, choice.whenLine].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
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

    // MARK: Replace

    @ViewBuilder
    private func replacementSections(audit: DegreeAudit?) -> some View {
        let sources = requirements?.degreeReplacementSources(excluding: request.ruleID, concentrationID: plan.concentrationID) ?? []
        Section {
            Picker("Amount", selection: $amountInHours) {
                Text("Courses").tag(false)
                Text("Semester hours").tag(true)
            }
            .pickerStyle(.segmented)
            if amountInHours {
                Stepper(value: $hours, in: 1...64, step: 1) {
                    Text(DegreeRequirementText.hours(hours))
                        .monospacedDigit()
                }
            } else {
                Stepper(value: $count, in: 1...12) {
                    Text(count == 1 ? "1 course" : "\(count) courses")
                        .monospacedDigit()
                }
            }
            Picker("Courses like", selection: $likeRuleID) {
                Text("Only the courses below").tag(String?.none)
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceName(source))
                        if let section = requirements?.degreeLocation(ofRule: source.id)?.section.title {
                            Text(section)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(source.id))
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Replace with")
        } footer: {
            Text("For example, 2 courses like Khoury Elective Courses. Courses count here only when they aren’t needed elsewhere.")
        }

        if let likeRuleID, needsCourseNumbers {
            courseNumbersSection(likeRuleID: likeRuleID)
        }

        Section {
            NavigationLink {
                RequirementCoursePicker(choices: plan.degreeCourseChoices, selection: $specificCourses)
            } label: {
                LabeledContent("Specific courses", value: specificCourses.isEmpty ? "None" : specificCourses.sorted().map(\.description).joined(separator: ", "))
            }
        } footer: {
            Text("Optional: courses your petition or adviser approved, even ones “Courses like” wouldn’t include. They count here first.")
        }
    }

    private func sourceName(_ rule: RequirementRule) -> String {
        DegreeSubstitutionEditing.sourceName(of: rule, requirements: requirements)
    }

    // MARK: Course numbers

    /// Whether "Courses like" starts at a minimum course number, so the petition must say
    /// whether it applies.
    private var needsCourseNumbers: Bool {
        DegreeSubstitutionEditing.needsCourseNumbers(likeRuleID: likeRuleID, requirements: requirements)
    }

    private var courseNumbers: CourseNumberLimit? {
        numberChoice?.limit(minimum: minimumNumber)
    }

    /// Asks which course numbers the petition accepts: the other requirement's (CS 2500 or
    /// higher), any number in its subjects, or another minimum. There's no default: petitions
    /// differ, and a wrong guess hides a requirement that's met.
    private func courseNumbersSection(likeRuleID: String) -> some View {
        let ranges = DegreeSubstitutionEditing.likeRanges(likeRuleID: likeRuleID, requirements: requirements)
        let likeTitle = requirements?.rule(id: likeRuleID).map(sourceName) ?? "that requirement"
        return Section {
            Picker("Course numbers", selection: $numberChoice.animation(.snappy)) {
                ForEach(CourseNumberChoice.allCases) { choice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title(likeTitle: likeTitle))
                        Text(choice.detail(ranges: ranges, minimum: minimumNumber))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(choice))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if numberChoice == .atLeast {
                LabeledContent("Lowest course number") {
                    TextField("2000", value: $minimumNumber, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 120)
                }
            }
        } header: {
            Text("Course numbers")
        } footer: {
            if numberChoice == nil {
                Text("Does your petition keep the minimum course number of \(likeTitle), or accept any course in these subjects? Choose one to save. Ask your adviser if you’re not sure.")
            } else if numberChoice == .atLeast, courseNumbers == nil {
                Text("Enter a course number, like 2000.")
            } else {
                Text("Courses the catalog excludes stay excluded.")
            }
        }
    }

    // MARK: Saving

    private var canSave: Bool {
        DegreeSubstitutionEditing.canSave(kind: kind, course: course, likeRuleID: likeRuleID, specificCourses: specificCourses,
                                          needsCourseNumbers: needsCourseNumbers, courseNumbers: courseNumbers)
    }

    private func save() {
        // A course counted for a requirement that names one retired course is most likely that
        // course under a new number: ask before recording a substitution.
        if request.existing == nil, let renumbering, looksRenumbered(renumbering) {
            asksRenumbering = true
            return
        }
        performSave()
    }

    private func performSave() {
        guard let change = DegreeSubstitutionEditing.change(
            kind: kind, course: course, amountInHours: amountInHours, count: count, hours: hours,
            likeRuleID: likeRuleID, specificCourses: specificCourses, courseNumbers: courseNumbers,
            requirements: requirements, ruleTitle: request.ruleTitle
        ) else { return }
        let substitution = DegreeSubstitutionEditing.substitution(
            for: request, change: change, note: note, approvedOn: hasApprovalDate ? approvalDate : nil
        )
        userData.updateDegreePlan(id: request.planID) { DegreeSubstitutionEditing.store(substitution, in: &$0) }
        DegreePlanFeedback.success()
        dismiss()
    }

    private func deleteSubstitution() {
        guard let existing = request.existing else { return }
        userData.updateDegreePlan(id: request.planID) { plan in
            plan.substitutions.removeAll { $0.id == existing.id }
        }
        dismiss()
    }
}

/// Picks several of the plan's courses (a petition's specific courses).
private struct RequirementCoursePicker: View {
    var choices: [DegreePlanCourseChoice]
    @Binding var selection: Set<CourseKey>

    @State private var searchText = ""

    private var filtered: [DegreePlanCourseChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter { $0.key.description.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text(choices.isEmpty ? "Your plan has no courses yet." : "No course matches “\(searchText)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { choice in
                let isSelected = selection.contains(choice.key)
                Button {
                    if isSelected { selection.remove(choice.key) } else { selection.insert(choice.key) }
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
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .navigationTitle("Specific courses")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Find a course")
    }
}
