//
//  DegreeRequirementRuleSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One requirement in detail: the catalog's wording and notes, every option with where it
/// stands in the plan, the courses counted, and the substitutions or petitions that change it.
struct DegreeRequirementRuleSheet: View {
    var planID: UUID
    var ruleID: String

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var path: [AppRoute] = []
    @State private var substitutionRequest: DegreeSubstitutionRequest?
    @State private var substitutionToDelete: RequirementSubstitution?
    @State private var equivalenceRequest: DegreeEquivalenceRequest?
    @State private var suggestionCache = DegreeEquivalenceSuggestionCache()
    @State private var toast: DegreePlanToast?
    @State private var haptic = DegreePlanHaptic()
    @AppStorage(DegreeEquivalenceDismissals.storageKey) private var dismissedSuggestions = ""

    private var info: CourseInfoStore { .shared }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let plan = userData.degreePlan(id: planID),
                   let requirements = programCatalog.requirements(for: plan),
                   let location = requirements.degreeLocation(ofRule: ruleID) {
                    let audit = DegreeAudit.run(plan: plan, requirements: requirements, equivalences: info.equivalences(for: plan),
                                                attributes: info.degreeAttributes(for: plan))
                    let lookup = DegreeCourseLookup.make(plan: plan, requirements: requirements, audit: audit, userData: userData, catalog: catalog)
                    if let result = audit.result(for: ruleID) {
                        let prompts = suggestionCache.prompts(
                            for: plan,
                            listed: result.status.isSatisfied ? [] : result.rule.listedCourses,
                            dismissed: DegreeEquivalenceDismissals.decode(dismissedSuggestions),
                            info: info,
                            newest: catalog.degreePlanSnapshot().reference,
                            catalogTitles: requirements.courseTitles,
                            alsoComparing: requirements.degreeListedCourses(concentrationID: plan.concentrationID)
                        )
                        details(plan: plan, requirements: requirements, location: location, audit: audit, result: result, lookup: lookup, prompts: prompts)
                    } else {
                        ContentUnavailableView {
                            Label("Not part of your requirements", systemImage: "checklist")
                        } description: {
                            Text("This requirement belongs to another concentration.")
                        }
                    }
                } else {
                    ContentUnavailableView("Requirement not found", systemImage: "checklist")
                }
            }
            // Inside the stack, so the toast sits under the navigation bar: over it, its Undo would
            // share a corner with Done, which takes the tap.
            .degreePlanToast($toast)
            .navigationTitle("Requirement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .appDestinations()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $substitutionRequest) { request in
            RequirementSubstitutionSheet(request: request) { showRenumbered($0) }
        }
        .sheet(item: $equivalenceRequest) { request in
            DegreeEquivalenceSheet(request: request)
        }
        .confirmationDialog(
            "Delete this substitution?",
            isPresented: Binding(get: { substitutionToDelete != nil }, set: { if !$0 { substitutionToDelete = nil } }),
            titleVisibility: .visible,
            presenting: substitutionToDelete
        ) { substitution in
            Button("Delete substitution", role: .destructive) { delete(substitution) }
        } message: { _ in
            Text("The requirement goes back to the catalog’s rule.")
        }
        .degreePlanHaptic(haptic)
    }

    // MARK: Details

    private func details(plan: DegreePlan, requirements: ProgramRequirements,
                         location: (section: RequirementSection, group: RequirementGroup, rule: RequirementRule),
                         audit: DegreeAudit, result: DegreeAudit.RuleResult, lookup: DegreeCourseLookup,
                         prompts: DegreeEquivalencePrompts) -> some View {
        let rule = location.rule
        let name = requirements.degreeShortName(ofRule: ruleID) ?? rule.displayLabel
        let notes = location.group.notes + rule.degreeParagraphs
        let categories = rule.degreeCategories
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(result.status.degreeLabel.capitalizedFirst)
                    } icon: {
                        DegreeStatusIcon(status: result.status)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(result.status.degreeColor)
                    Text(requirements.degreeRowTitle(ofRule: rule))
                        .font(.title3.weight(.bold))
                    if requirements.degreeRowTitle(ofRule: rule) != rule.displayLabel {
                        Text(rule.displayLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(([DegreeRequirementText.progress(result)] + [rule.hours.map(DegreeRequirementText.hours)].compactMap { $0 }).joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(location.section.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityElement(children: .combine)
            }

            if !notes.isEmpty || !categories.isEmpty {
                Section("From the catalog") {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.subheadline)
                    }
                    if !categories.isEmpty {
                        LabeledContent("Categories", value: categories.joined(separator: ", "))
                            .font(.subheadline)
                    }
                }
            }

            petitionQuestionsSection(plan: plan, requirements: requirements, audit: audit, result: result, name: name)

            coursesSection(rule: rule, result: result, lookup: lookup, plan: plan, prompts: prompts, requirements: requirements)

            nearMissSection(audit: audit, lookup: lookup, name: name)

            substitutionsSection(plan: plan, name: name, result: result, requirements: requirements)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func coursesSection(rule: RequirementRule, result: DegreeAudit.RuleResult, lookup: DegreeCourseLookup, plan: DegreePlan,
                                prompts: DegreeEquivalencePrompts, requirements: ProgramRequirements) -> some View {
        let (options, ranges) = DegreeRequirementsListing.listing(of: rule)
        let listed = Set(options.flatMap(\.allCourses))
        let split = DegreeSubstituteRows.split(result, listed: listed)
        let addTargets = DegreeCourseLookup.addTargets(for: plan)
        let canAct = !result.status.isSatisfied
        // A substitute sits right under the requirement it replaces: before the options of a list,
        // after the course (or the alternatives) a required requirement names.
        let substitutesFirst = { if case .required = rule.kind { false } else { true } }()
        let renumberable = DegreeRenumbering.renumberable(in: plan, requirements: requirements)
        let likely = DegreeRenumbering.likely(in: plan, requirements: requirements, dismissed: DegreeEquivalenceDismissals.decode(dismissedSuggestions))
        if !options.isEmpty || !ranges.isEmpty || !split.substitutes.isEmpty || !split.others.isEmpty {
            Section {
                if substitutesFirst {
                    substituteRows(split.substitutes, result: result, lookup: lookup, requirements: requirements, renumberable: renumberable, likely: likely)
                }
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    ForEach(Array(option.alternatives.enumerated()), id: \.offset) { alternativeIndex, alternative in
                        ForEach(Array(alternative.enumerated()), id: \.offset) { index, key in
                            row(key, connector: index > 0 ? .and : (alternativeIndex > 0 ? .or : nil), result: result,
                                lookup: lookup, addTargets: canAct ? addTargets : [], prompts: prompts, requirements: requirements,
                                renumberable: renumberable)
                        }
                    }
                }
                ForEach(ranges, id: \.label) { range in
                    DegreeRangeRow(label: range.label)
                }
                if !substitutesFirst {
                    substituteRows(split.substitutes, result: result, lookup: lookup, requirements: requirements, renumberable: renumberable, likely: likely)
                }
                ForEach(split.others) { use in
                    row(use.key, connector: nil, result: result, lookup: lookup, addTargets: [], prompts: prompts,
                        requirements: requirements, counted: use, renumberable: renumberable)
                }
            } header: {
                Text(rule.degreeIsGeneralElectives ? "Counted courses" : "Courses")
            } footer: {
                if result.effectiveKind == nil {
                    Text("Waived: these courses aren’t needed.")
                } else if result.substitutions.contains(where: { if case .replace = $0.change { true } else { false } }) {
                    Text("Replaced by petition: courses that count toward the replacement are listed last.")
                }
            }
        }
    }

    /// The courses counted by substitution that the requirement doesn't list, each with the question
    /// whether it is the required course under a new number, when that looks likely.
    @ViewBuilder
    private func substituteRows(_ uses: [DegreeAudit.CourseUse], result: DegreeAudit.RuleResult, lookup: DegreeCourseLookup,
                                requirements: ProgramRequirements, renumberable: Set<UUID>,
                                likely: [UUID: DegreeSubstitutionEditing.LikelyRenumbering]) -> some View {
        ForEach(uses) { use in
            row(use.key, connector: .substitution, result: result, lookup: lookup, addTargets: [], prompts: DegreeEquivalencePrompts(),
                requirements: requirements, counted: use, renumberable: renumberable)
            if let substitution = DegreeSubstituteRows.substitution(counting: use.key, in: result), let prompt = likely[substitution.id] {
                DegreeRenumberingPromptRow(
                    prompt: prompt,
                    isIndented: true,
                    onConfirm: { renumber(substitution, requirements: requirements) },
                    onDismiss: { dismissSuggestion(pairID: DegreeEquivalencePrompt.pairID(prompt.course, prompt.countsAs)) }
                )
                .listRowSeparator(.hidden, edges: .top)
            }
        }
    }

    @ViewBuilder
    private func row(_ key: CourseKey, connector: DegreeCatalogCourseRow.Connector?, result: DegreeAudit.RuleResult,
                     lookup: DegreeCourseLookup, addTargets: [DegreePlanTerm], prompts: DegreeEquivalencePrompts,
                     requirements: ProgramRequirements, counted: DegreeAudit.CourseUse? = nil,
                     renumberable: Set<UUID> = []) -> some View {
        let info = lookup.rowInfo(for: key, in: result, counted: counted)
        let canAct = !result.status.isSatisfied
        let isMissing = canAct && info.status == .notInPlan
        let targets = info.addKey == nil ? [] : addTargets
        // A course counted by substitution: where it's counted, and what can be done with it.
        let countedKey = (counted ?? result.use(for: key))?.key ?? key
        let substitution = info.bySubstitution ? DegreeSubstituteRows.substitution(counting: countedKey, in: result) : nil
        DegreeCatalogCourseRow(
            key: key,
            title: lookup.title(of: key),
            credits: counted?.credits ?? lookup.credits(of: key),
            connector: connector,
            status: info.status,
            isCountedHere: info.isCountedHere,
            bySubstitution: info.bySubstitution,
            isWaived: result.status == .waived,
            caption: DegreeSubstituteRows.caption(of: info, counting: countedKey, in: result, requirements: requirements,
                                                  isChild: connector == .substitution),
            addKey: info.addKey,
            addTargets: targets,
            onOpen: { openCourse(key) },
            onAdd: targets.isEmpty ? nil : { term in if let addKey = info.addKey { add(addKey, to: term, lookup: lookup) } },
            onCountCourse: canAct ? { startSubstitution(.countCourse, name: nil) } : nil,
            onViewCourse: { openCourse(key) },
            equivalenceAction: isMissing ? DegreeRowAction(title: "Same course, different number…") {
                equivalenceRequest = DegreeEquivalenceRequest(planID: planID, countsAs: key)
            } : nil,
            substitutionActions: substitutionActions(for: substitution, result: result, requirements: requirements, renumberable: renumberable),
            substitutionFor: connector == .substitution ? DegreeSubstituteRows.requirementName(of: result, requirements: requirements) : nil,
            opensRequirement: false
        )
        .listRowSeparator(connector == .substitution ? .hidden : .automatic, edges: .top)
        .listRowInsets(.top, connector == .substitution ? 0 : nil)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let substitution, renumberable.contains(substitution.id) {
                Button {
                    renumber(substitution, requirements: requirements)
                } label: {
                    Label("Same course, new number", systemImage: "equal.circle")
                }
                .tint(.indigo)
            }
        }
        if isMissing, let prompt = prompts.forListed(key) {
            DegreeEquivalencePromptRow(prompt: prompt, onConfirm: { confirm(prompt) }, onDismiss: { dismissSuggestion(prompt) })
        }
    }

    private func substitutionActions(for substitution: RequirementSubstitution?, result: DegreeAudit.RuleResult,
                                     requirements: ProgramRequirements, renumberable: Set<UUID>) -> [DegreeRowAction] {
        guard let substitution else { return [] }
        let name = requirements.degreeShortName(ofRule: ruleID) ?? result.rule.displayLabel
        var items = [DegreeRowAction(title: "Edit substitution…", systemImage: "pencil") {
            substitutionRequest = DegreeSubstitutionRequest(planID: planID, ruleID: ruleID, ruleTitle: name, existing: substitution)
        }]
        if renumberable.contains(substitution.id) {
            items.append(DegreeRowAction(title: "Same course, new number", systemImage: "equal.circle") {
                renumber(substitution, requirements: requirements)
            })
        }
        return items
    }

    // MARK: Petition questions and near misses

    /// This requirement's petitions that haven't said whether the minimum course number of the
    /// requirement they take courses like applies; asked here even when it changes nothing.
    @ViewBuilder
    private func petitionQuestionsSection(plan: DegreePlan, requirements: ProgramRequirements, audit: DegreeAudit,
                                          result: DegreeAudit.RuleResult, name: String) -> some View {
        let questions = result.substitutions.compactMap {
            DegreePetitionQuestions.question(about: $0, plan: plan, requirements: requirements, equivalences: info.equivalences(for: plan), audit: audit)
        }
        if !questions.isEmpty {
            Section {
                ForEach(questions) { question in
                    DegreePetitionQuestionRow(question: question) { limit in
                        answer(question, with: limit)
                    } onOther: {
                        substitutionRequest = DegreeSubstitutionRequest(planID: planID, ruleID: ruleID, ruleTitle: name, existing: question.substitution)
                    }
                }
            } header: {
                Text("Course numbers")
            }
        }
    }

    /// Plan courses this requirement's number limits keep out, while it's short.
    @ViewBuilder
    private func nearMissSection(audit: DegreeAudit, lookup: DegreeCourseLookup, name: String) -> some View {
        let misses = audit.nearMisses(for: ruleID)
        if !misses.isEmpty {
            Section {
                ForEach(misses) { miss in
                    DegreeNearMissRow(miss: miss, title: lookup.title(of: miss.course.key)) {
                        substitutionRequest = DegreeSubstitutionRequest(planID: planID, ruleID: ruleID, ruleTitle: name, kind: .countCourse, course: miss.course.key)
                    }
                }
            } header: {
                Text("In your plan, not counted")
            } footer: {
                Text("Their course numbers fall outside this requirement’s ranges. If an adviser approved one for it, count it here.")
            }
        }
    }

    /// Saves which course numbers a petition accepts, with Undo.
    private func answer(_ question: DegreePetitionQuestion, with limit: CourseNumberLimit) {
        let id = question.substitution.id
        withAnimation {
            userData.updateDegreePlan(id: planID) { $0.setCourseNumbers(limit, forSubstitution: id) }
        }
        haptic.fire(.success)
        toast = DegreePlanToast(text: limit == .anyNumber ? "Any course number counts" : "\(question.likeTitle)’s minimum applies",
                                systemImage: "checkmark.circle.fill", actionTitle: "Undo") {
            withAnimation { userData.updateDegreePlan(id: planID) { $0.setCourseNumbers(nil, forSubstitution: id) } }
        }
    }

    // MARK: Substitutions

    private func substitutionsSection(plan: DegreePlan, name: String, result: DegreeAudit.RuleResult,
                                      requirements: ProgramRequirements) -> some View {
        let renumberable = DegreeRenumbering.renumberable(in: plan, requirements: requirements)
        return Section {
            ForEach(result.substitutions) { substitution in
                let canRenumber = renumberable.contains(substitution.id)
                Button {
                    substitutionRequest = DegreeSubstitutionRequest(planID: planID, ruleID: ruleID, ruleTitle: name, existing: substitution)
                } label: {
                    DegreeSubstitutionRow(substitution: substitution, ruleName: name, status: nil, doesNotApply: false)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        substitutionToDelete = substitution
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if canRenumber {
                        Button {
                            renumber(substitution, requirements: requirements)
                        } label: {
                            Label("Same course, new number", systemImage: "equal.circle")
                        }
                        .tint(.indigo)
                    }
                }
                .contextMenu {
                    Button("Edit substitution…", systemImage: "pencil") {
                        substitutionRequest = DegreeSubstitutionRequest(planID: planID, ruleID: ruleID, ruleTitle: name, existing: substitution)
                    }
                    if canRenumber {
                        Button("Same course, new number", systemImage: "equal.circle") {
                            renumber(substitution, requirements: requirements)
                        }
                    }
                    Divider()
                    Button("Delete substitution", systemImage: "trash", role: .destructive) {
                        substitutionToDelete = substitution
                    }
                }
            }
            Button {
                startSubstitution(.countCourse, name: name)
            } label: {
                Label("Count a course toward this…", systemImage: "arrow.left.arrow.right")
            }
            Button {
                startSubstitution(.replace, name: name)
            } label: {
                Label("Replace this requirement (petition)…", systemImage: "signature")
            }
            Button {
                startSubstitution(.waive, name: name)
            } label: {
                Label("Waive this requirement…", systemImage: "minus.circle")
            }
        } header: {
            Text("Substitutions & petitions")
        } footer: {
            Text("Record exceptions your advisor or college approved. They’re saved with this plan.")
        }
    }

    private func startSubstitution(_ kind: DegreeSubstitutionRequest.Kind, name: String?) {
        let title = name ?? userData.degreePlan(id: planID).flatMap { programCatalog.requirements(for: $0)?.degreeShortName(ofRule: ruleID) } ?? "Requirement"
        substitutionRequest = DegreeSubstitutionRequest(planID: planID, ruleID: ruleID, ruleTitle: title, kind: kind)
    }

    // MARK: Actions

    private func openCourse(_ key: CourseKey) {
        guard let termCode = catalog.degreePlanSnapshot().routeTermCode(for: key) else { return }
        path.append(.course(termCode: termCode, key: key))
    }

    private func add(_ key: CourseKey, to semester: DegreePlanTerm, lookup: DegreeCourseLookup) {
        let course = DegreePlanCourse(
            key: key,
            title: DegreePlanFormat.exportTitle(lookup.title(of: key) ?? key.description),
            credits: lookup.credits(of: key) ?? 4
        )
        withAnimation {
            userData.updateDegreePlan(id: planID) { DegreePlanEditing.addCourse(course, to: semester, in: &$0) }
        }
        haptic.fire(.success)
        toast = DegreePlanToast(text: "Added \(key) to \(semester.shortName)", systemImage: "calendar.badge.plus", actionTitle: "Undo") {
            withAnimation {
                userData.updateDegreePlan(id: planID) { DegreePlanEditing.removePlannedCourse(course.id, from: &$0) }
            }
        }
    }

    /// Declares a suggested equivalence, with Undo.
    private func confirm(_ prompt: DegreeEquivalencePrompt) {
        let added = withAnimation {
            userData.declareDegreeEquivalence(planID: planID, course: prompt.course, countsAs: prompt.countsAs)
        }
        guard let id = added else { return }
        haptic.fire(.success)
        toast = DegreePlanToast(text: "\(prompt.course) now counts as \(prompt.countsAs)", systemImage: "equal.circle.fill", actionTitle: "Undo") {
            withAnimation { userData.updateDegreePlan(id: planID) { $0.removeEquivalence(id: id) } }
        }
    }

    private func dismissSuggestion(_ prompt: DegreeEquivalencePrompt) {
        dismissSuggestion(pairID: prompt.id)
    }

    private func dismissSuggestion(pairID: String) {
        withAnimation { dismissedSuggestions = DegreeEquivalenceDismissals.adding(pairID, to: dismissedSuggestions) }
        haptic.fire(.selection)
    }

    /// Makes a substitution the same course under a new number, with Undo.
    private func renumber(_ substitution: RequirementSubstitution, requirements: ProgramRequirements) {
        let change = withAnimation {
            DegreeRenumbering.convert(substitution, planID: planID, requirements: requirements, userData: userData)
        }
        if let change { showRenumbered(change) }
    }

    /// Confirms a renumbering (made here or in the substitution sheet), with Undo.
    private func showRenumbered(_ change: DegreeRenumbering) {
        haptic.fire(.success)
        toast = DegreePlanToast(text: change.message, systemImage: "equal.circle.fill", actionTitle: change.canUndo ? "Undo" : nil,
                                action: change.canUndo ? { withAnimation { change.undo(planID: planID, userData: userData) } } : nil)
    }

    private func delete(_ substitution: RequirementSubstitution) {
        withAnimation {
            userData.updateDegreePlan(id: planID) { plan in
                plan.substitutions.removeAll { $0.id == substitution.id }
            }
        }
        haptic.fire(.warning)
    }
}

private extension String {
    /// `Not in your plan` from `not in your plan`.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
