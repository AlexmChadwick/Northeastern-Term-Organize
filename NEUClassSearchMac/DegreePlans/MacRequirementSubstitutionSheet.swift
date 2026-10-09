//
//  MacRequirementSubstitutionSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Records an approved exception to a requirement: a course that counts toward it, a petition
/// that replaces it with other courses, or a waiver, each with a note and approval date. When the
/// course counted is the required course under a new number, the sheet says so and offers to
/// count it as that course instead.
struct MacRequirementSubstitutionSheet: View {
    var request: DegreeSubstitutionRequest
    /// Turns a "count a course" substitution (saved or not) into the equivalence it amounts to.
    /// The screen does it, so Edit › Undo can take it back.
    var onConvert: ((RequirementSubstitution) -> Void)?

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog

    var body: some View {
        let plan = userData.degreePlan(id: request.planID)
        let requirements = plan.flatMap { programCatalog.requirements(for: $0) }
        if let plan {
            MacRequirementSubstitutionForm(
                request: request,
                plan: plan,
                requirements: requirements,
                initialAmount: DegreeSubstitutionRequest.initialAmount(rule: requirements?.rule(id: request.ruleID)),
                onConvert: onConvert
            )
        } else {
            ContentUnavailableView("Plan not found", systemImage: "list.bullet.clipboard")
                .frame(width: 540, height: 260)
        }
    }
}

private struct MacRequirementSubstitutionForm: View {
    var request: DegreeSubstitutionRequest
    var plan: DegreePlan
    var requirements: ProgramRequirements?
    var onConvert: ((RequirementSubstitution) -> Void)?
    /// The requirements audit of the plan, to say where each course counts now.
    private let audit: DegreeAudit?

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
    @State private var isChoosingSpecificCourses = false

    init(request: DegreeSubstitutionRequest, plan: DegreePlan, requirements: ProgramRequirements?,
         initialAmount: (count: Int, hours: Double, inHours: Bool), onConvert: ((RequirementSubstitution) -> Void)?) {
        self.request = request
        self.plan = plan
        self.requirements = requirements
        self.onConvert = onConvert
        audit = requirements.map {
            DegreeAudit.run(plan: plan, requirements: $0, equivalences: CourseInfoStore.shared.equivalences(for: plan),
                            attributes: CourseInfoStore.shared.degreeAttributes(for: plan))
        }
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
        // The requirement it takes courses like, by id or (saved under another catalog year,
        // where the id differs) by its name.
        let likeRuleID = replacement.flatMap { requirements?.degreeRule(id: $0.likeRuleID, named: $0.likeRuleTitle)?.id } ?? replacement?.likeRuleID
        _likeRuleID = State(initialValue: likeRuleID)
        _specificCourses = State(initialValue: Set(replacement?.courses ?? []))
        _numberChoice = State(initialValue: CourseNumberChoice(replacement?.courseNumbers))
        _minimumNumber = State(initialValue: CourseNumberChoice.suggestedMinimum(
            for: DegreeSubstitutionEditing.likeRanges(likeRuleID: likeRuleID, requirements: requirements),
            saved: replacement?.courseNumbers
        ))
        _note = State(initialValue: existing?.note ?? "")
        _hasApprovalDate = State(initialValue: existing?.approvedOn != nil)
        _approvalDate = State(initialValue: existing?.approvedOn ?? .now)
    }

    private var rule: RequirementRule? { requirements?.rule(id: request.ruleID) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.ruleTitle)
                            .font(.headline)
                        if let rule, rule.displayLabel != request.ruleTitle {
                            Text(rule.displayLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text(request.existing == nil ? "Add Substitution" : "Edit Substitution")
                }

                Section {
                    Picker("Change", selection: $kind.animation(.snappy)) {
                        Text("Count a course").tag(DegreeSubstitutionRequest.Kind.countCourse)
                        Text("Replace it (petition)").tag(DegreeSubstitutionRequest.Kind.replace)
                        Text("Waive it").tag(DegreeSubstitutionRequest.Kind.waive)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    Text(kindDetail)
                }

                switch kind {
                case .countCourse:
                    renumberingSection
                    courseSections
                case .replace:
                    replacementSections
                case .waive:
                    Section {
                        EmptyView()
                    } footer: {
                        Text("The requirement won’t be checked. Add who approved it below.")
                    }
                }

                Section("Note") {
                    TextField("Note", text: $note, prompt: Text("Petition approved by Khoury advising…"), axis: .vertical)
                        .lineLimit(2...6)
                        .labelsHidden()
                }

                Section {
                    Toggle("Approval date", isOn: $hasApprovalDate.animation(.snappy))
                    if hasApprovalDate {
                        DatePicker("Approved on", selection: $approvalDate, displayedComponents: .date)
                    }
                }

                if request.existing != nil {
                    Section {
                        Button("Delete Substitution…", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Save", isConfirmDisabled: !canSave, onConfirm: save, onCancel: { dismiss() })
        }
        .frame(width: 560, height: 700)
        .confirmationDialog("Delete this substitution?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Substitution", role: .destructive) { deleteSubstitution() }
        } message: {
            Text("The requirement goes back to the catalog’s rule.")
        }
    }

    /// What the chosen kind of change means.
    private var kindDetail: String {
        switch kind {
        case .countCourse: "A course in your plan counts toward this requirement."
        case .replace: "Other courses satisfy it, like two Khoury electives."
        case .waive: "The requirement no longer applies to you."
        }
    }

    // MARK: Renumbering

    /// The substitution as it stands in the form, when it counts a course.
    private var draftSubstitution: RequirementSubstitution? {
        guard kind == .countCourse, let course else { return nil }
        var draft = request.existing ?? RequirementSubstitution(ruleID: request.ruleID, ruleTitle: request.ruleTitle, change: .countCourse(course))
        draft.ruleID = request.ruleID
        draft.change = .countCourse(course)
        return draft
    }

    /// Offered whenever the course counted is the one course the requirement names under a new
    /// number (CS 3484 for IS 4800): it then counts as that course everywhere, like a renumbered
    /// course, instead of as a substitution.
    @ViewBuilder
    private var renumberingSection: some View {
        if let onConvert, let draft = draftSubstitution,
           let equivalence = DegreeSubstitutionEditing.renumbering(for: draft, requirements: requirements) {
            Section {
                MacDegreeRenumberingNote(
                    equivalence: equivalence,
                    isRetired: CourseInfoStore.shared.info(for: equivalence.countsAs)?.isRetired == true
                ) {
                    dismiss()
                    onConvert(draft)
                }
            }
        }
    }

    // MARK: Count a course

    private var choices: [DegreePlanCourseChoice] {
        DegreeSubstitutionEditing.matching(plan.degreeCourseChoices, query: searchText)
    }

    /// Courses that don't count toward another requirement (free ones and general electives)
    /// come first; ones that count elsewhere move here when chosen.
    @ViewBuilder
    private var courseSections: some View {
        let counting: (CourseKey) -> String? = { key in audit?.ruleCounting(key)?.rule.id }
        let isFree: (DegreePlanCourseChoice) -> Bool = { choice in
            DegreeSubstitutionEditing.isFree(countingRuleID: counting(choice.key), ruleID: request.ruleID, requirements: requirements)
        }
        let free = choices.filter(isFree)
        let elsewhere = choices.filter { !isFree($0) }
        Section {
            TextField("Find a course in your plan", text: $searchText)
            if choices.isEmpty {
                Text(searchText.isEmpty ? "Your plan has no courses yet." : "No course in your plan matches “\(searchText)”.")
                    .foregroundStyle(.secondary)
            }
        }
        if !free.isEmpty {
            Section {
                ForEach(free) { choice in
                    courseChoiceRow(choice, caption: caption(for: choice, countingRuleID: counting(choice.key)))
                }
            } header: {
                Text("Not Counted Elsewhere")
            }
        }
        if !elsewhere.isEmpty {
            Section {
                ForEach(elsewhere) { choice in
                    courseChoiceRow(choice, caption: caption(for: choice, countingRuleID: counting(choice.key)))
                }
            } header: {
                Text("Counted Elsewhere")
            } footer: {
                Text("Choosing one of these moves it to this requirement.")
            }
        }
    }

    private func caption(for choice: DegreePlanCourseChoice, countingRuleID: String?) -> String? {
        DegreeSubstitutionEditing.caption(for: choice, countingRuleID: countingRuleID, ruleID: request.ruleID, requirements: requirements)
    }

    private func courseChoiceRow(_ choice: DegreePlanCourseChoice, caption: String?) -> some View {
        let isSelected = course == choice.key
        return Button {
            course = choice.key
        } label: {
            MacDegreeChoiceRow(choice: choice, caption: caption, trailing: isSelected ? "checkmark" : nil)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Replace

    @ViewBuilder
    private var replacementSections: some View {
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
                Divider()
                ForEach(sources) { source in
                    Text(sourceName(source)).tag(Optional(source.id))
                }
            }
            if let likeRuleID, let section = requirements?.degreeLocation(ofRule: likeRuleID)?.section.title {
                Text(section)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Replace With")
        } footer: {
            Text("For example, 2 courses like Khoury Elective Courses. Courses count here only when they aren’t needed elsewhere.")
        }

        if let likeRuleID, needsCourseNumbers {
            courseNumbersSection(likeRuleID: likeRuleID)
        }

        Section {
            LabeledContent("Specific courses") {
                Button(specificCourses.isEmpty ? "None" : specificCourses.sorted().map(\.description).joined(separator: ", ")) {
                    isChoosingSpecificCourses = true
                }
                .lineLimit(1)
                .popover(isPresented: $isChoosingSpecificCourses, arrowEdge: .bottom) {
                    MacDegreeCourseMultiPicker(choices: plan.degreeCourseChoices, selection: $specificCourses)
                }
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
            ForEach(CourseNumberChoice.allCases) { choice in
                let isSelected = numberChoice == choice
                Button {
                    withAnimation(.snappy) { numberChoice = choice }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title(likeTitle: likeTitle))
                            Text(choice.detail(ranges: ranges, minimum: minimumNumber))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            if numberChoice == .atLeast {
                LabeledContent("Lowest course number") {
                    TextField("Lowest course number", value: $minimumNumber, format: .number.grouping(.never), prompt: Text("2000"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 90)
                }
            }
        } header: {
            Text("Course Numbers")
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
        guard let change = DegreeSubstitutionEditing.change(
            kind: kind, course: course, amountInHours: amountInHours, count: count, hours: hours,
            likeRuleID: likeRuleID, specificCourses: specificCourses, courseNumbers: courseNumbers,
            requirements: requirements, ruleTitle: request.ruleTitle
        ) else { return }
        let substitution = DegreeSubstitutionEditing.substitution(
            for: request, change: change, note: note, approvedOn: hasApprovalDate ? approvalDate : nil
        )
        userData.updateDegreePlan(id: request.planID) { DegreeSubstitutionEditing.store(substitution, in: &$0) }
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
