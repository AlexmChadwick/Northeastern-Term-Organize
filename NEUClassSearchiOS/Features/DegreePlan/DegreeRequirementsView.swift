//
//  DegreeRequirementsView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A degree plan read against its program's requirements, laid out like the academic
/// catalog's requirements page: each section and area in catalog order, every course it lists,
/// and where each one stands in the plan (completed, in progress, planned, or not in plan).
/// Pushed with `AppRoute.degreeRequirements`, or shown beside the plan on a wide iPad
/// (`isEmbedded`), where the plan screen's navigation bar stays the plan's.
struct DegreeRequirementsView: View {
    var planID: UUID
    /// Beside the plan: no navigation title or toolbar of its own; the title and Edit sit above the filter.
    var isEmbedded = false

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var filter = DegreeRequirementsFilter.all
    @State private var isEditingSetup = false
    @State private var openRule: DegreeRuleSelection?
    @State private var substitutionRequest: DegreeSubstitutionRequest?
    @State private var substitutionToDelete: RequirementSubstitution?
    @State private var cache: DegreeRequirementsCache
    @State private var feasibility = DegreePlanFeasibilityModel()
    @State private var suggestionCache = DegreeEquivalenceSuggestionCache()
    @State private var questionCache = DegreePetitionQuestionCache()
    @State private var equivalenceRequest: DegreeEquivalenceRequest?
    /// Requirements whose long lists of options are expanded.
    @State private var expandedRules: Set<String> = []
    /// Checked sentences of the catalog (NUpath, universitywide) whose parts are open.
    @State private var expandedNotes: Set<String> = []
    @State private var toast: DegreePlanToast?
    @State private var haptic = DegreePlanHaptic()
    @AppStorage(DegreeEquivalenceDismissals.storageKey) private var dismissedSuggestions = ""

    /// - Parameter sharedCache: the plan screen's audit cache, so beside the plan one audit serves both.
    init(planID: UUID, isEmbedded: Bool = false, sharedCache: DegreeRequirementsCache? = nil) {
        self.planID = planID
        self.isEmbedded = isEmbedded
        _cache = State(initialValue: sharedCache ?? DegreeRequirementsCache())
    }

    /// Banner's course catalog: equivalences, and courses that are no longer offered.
    private var info: CourseInfoStore { .shared }

    private var loadKey: String {
        let plan = userData.degreePlan(id: planID)
        return "\(plan?.catalogYear ?? 0)|\(plan?.catalogProgramPath ?? "")"
    }

    private struct CourseInfoKey: Hashable {
        var updatedAt: Date?
        var termCodes: [String]
        var requirementsFetchedAt: Date?
    }

    private var courseInfoKey: CourseInfoKey {
        let plan = userData.degreePlan(id: planID)
        return CourseInfoKey(
            updatedAt: plan?.updatedAt,
            termCodes: catalog.degreePlanSnapshot().indexes.map(\.term.code),
            requirementsFetchedAt: plan.flatMap { programCatalog.requirements(for: $0)?.fetchedAt }
        )
    }

    private var feasibilityKey: String {
        let plan = userData.degreePlan(id: planID)
        let codes = plan?.degreePlanPlannedKeys.map(\.description).sorted().joined(separator: "|") ?? ""
        let terms = catalog.degreePlanSnapshot().indexes.map(\.term.code).sorted().joined(separator: ",")
        return codes + "#" + terms
    }

    var body: some View {
        Group {
            if let plan = userData.degreePlan(id: planID) {
                content(plan)
            } else {
                ContentUnavailableView {
                    Label("Plan not found", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("This plan may have been deleted.")
                }
            }
        }
        .modifier(DegreeRequirementsNavigation(
            isEmbedded: isEmbedded,
            isEditDisabled: userData.degreePlan(id: planID) == nil,
            onEdit: { isEditingSetup = true }
        ))
        .task(id: loadKey) { await load(forceRefresh: false) }
        .task(id: courseInfoKey) { await loadCourseInfo() }
        .task(id: feasibilityKey) {
            guard let plan = userData.degreePlan(id: planID) else { return }
            await feasibility.loadIfNeeded(plan: plan, indexes: catalog.degreePlanSnapshot().indexes)
        }
        #if DEBUG
        .task {
            // Launch arguments of the debug build's sample plans: a starting filter, an open requirement.
            if let requested = IOSDegreeSamples.requestedFilter { filter = requested }
            if let rule = IOSDegreeSamples.requestedRule { openRule = DegreeRuleSelection(id: rule) }
        }
        #endif
        .sheet(isPresented: $isEditingSetup) {
            DegreeRequirementsSetupSheet(planID: planID)
        }
        .sheet(item: $openRule) { selection in
            DegreeRequirementRuleSheet(planID: planID, ruleID: selection.id)
        }
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
        // Beside the plan the top of the pane is its header, so the toast comes up from the bottom.
        .degreePlanToast($toast, edge: isEmbedded ? .bottom : .top)
        .degreePlanHaptic(haptic)
    }

    // MARK: States

    @ViewBuilder
    private func content(_ plan: DegreePlan) -> some View {
        let context = programCatalog.degreeRequirementsContext(
            for: plan, cache: cache, equivalences: info.equivalences(for: plan), includesMilestone: true
        )
        if !context.isSetUp {
            ContentUnavailableView {
                Label("Set up degree requirements", systemImage: "checklist")
            } description: {
                Text("Choose the catalog year you started in and your program to check this plan against Northeastern’s requirements.")
            } actions: {
                Button {
                    isEditingSetup = true
                } label: {
                    Text("Set up")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        } else if let requirements = context.requirements, let audit = context.audit {
            let lookup = DegreeCourseLookup.make(plan: plan, requirements: requirements, audit: audit, userData: userData, catalog: catalog)
            page(plan: plan, context: context, requirements: requirements, audit: audit, lookup: lookup)
        } else if let failure = context.failure {
            ContentUnavailableView {
                Label("Couldn’t load the requirements", systemImage: "wifi.exclamationmark")
            } description: {
                Text(failure)
            } actions: {
                Button {
                    Task { await load(forceRefresh: true) }
                } label: {
                    Text("Try again")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Change program or year") { isEditingSetup = true }
            }
        } else {
            ProgressView("Loading requirements…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Page

    private func page(plan: DegreePlan, context: DegreeRequirementsContext, requirements: ProgramRequirements,
                      audit: DegreeAudit, lookup: DegreeCourseLookup) -> some View {
        let actions = DegreeRequirementsActions(
            openRule: { openRule = DegreeRuleSelection(id: $0) },
            addCourse: { key, semester in add(key, to: semester, lookup: lookup) },
            countCourse: { ruleID in
                substitutionRequest = DegreeSubstitutionRequest(
                    planID: planID, ruleID: ruleID,
                    ruleTitle: requirements.degreeShortName(ofRule: ruleID) ?? "Requirement",
                    kind: .countCourse
                )
            },
            countSpecificCourse: { ruleID, key in
                substitutionRequest = DegreeSubstitutionRequest(
                    planID: planID, ruleID: ruleID,
                    ruleTitle: requirements.degreeShortName(ofRule: ruleID) ?? "Requirement",
                    kind: .countCourse, course: key
                )
            },
            viewCourse: { key in viewCourse(key) },
            confirmEquivalence: { confirm($0) },
            dismissEquivalence: { dismissSuggestion($0) },
            addEquivalence: { key in equivalenceRequest = DegreeEquivalenceRequest(planID: planID, countsAs: key) },
            toggleExpanded: { ruleID in
                withAnimation(.snappy) {
                    if expandedRules.contains(ruleID) { expandedRules.remove(ruleID) } else { expandedRules.insert(ruleID) }
                }
            },
            editSubstitution: { substitution, ruleID in edit(substitution, ruleID: ruleID, requirements: requirements) },
            renumber: { renumber($0, requirements: requirements) },
            keepSubstitution: { dismissSuggestion(pairID: DegreeEquivalencePrompt.pairID($0.course, $0.countsAs)) },
            toggleNote: { id in
                withAnimation(.snappy) {
                    if expandedNotes.contains(id) { expandedNotes.remove(id) } else { expandedNotes.insert(id) }
                }
            },
            findCourses: { path in findCourses(path) }
        )
        let addTargets = DegreeCourseLookup.addTargets(for: plan)
        let dismissed = DegreeEquivalenceDismissals.decode(dismissedSuggestions)
        let renumberable = DegreeRenumbering.renumberable(in: plan, requirements: requirements)
        // Substitutions for a required course that has been retired: most likely the same course
        // under a new number.
        let likelyRenumberings = DegreeRenumbering.likely(in: plan, requirements: requirements, dismissed: dismissed)
        let newest = catalog.degreePlanSnapshot().reference
        let hasVisibleRules = audit.ruleResults.contains { filter.includes($0.status) }
            || DegreeRequirementNotes.hasChecks(in: audit, filter: filter)
        let questions = questionCache.questions(plan: plan, requirements: requirements, equivalences: info.equivalences(for: plan), audit: audit)
        let prompts = suggestionCache.prompts(
            for: plan,
            listed: audit.degreeOpenListedCourses(notIn: plan),
            dismissed: dismissed,
            info: info,
            newest: newest,
            catalogTitles: requirements.courseTitles,
            alsoComparing: requirements.degreeListedCourses(concentrationID: plan.concentrationID)
        )

        return List {
            Section {
                DegreeRequirementsSummary(
                    context: context, audit: audit,
                    blockedFinish: feasibility.report(for: plan, snapshot: catalog.degreePlanSnapshot())
                        .warningLine(milestone: context.milestone, plan: plan)
                )
            } footer: {
                attribution(context: context, requirements: requirements)
            }

            if !questions.isEmpty {
                questionsSection(questions, requirements: requirements)
            }

            if audit.needsConcentration, filter != .done {
                concentrationSection(requirements)
            }

            ForEach(audit.sections) { section in
                if section.rules.isEmpty {
                    DegreeRequirementsNotesSection(
                        section: section.section,
                        entries: DegreeRequirementNotes.entries(
                            of: section.section, audit: audit, filter: filter, statesTotalHours: requirements.totalHours != nil
                        ),
                        expandedNotes: expandedNotes,
                        actions: actions
                    )
                } else {
                    DegreeRequirementsCatalogSection(
                        section: section,
                        filter: filter,
                        lookup: lookup,
                        addTargets: addTargets,
                        actions: actions,
                        prompts: prompts,
                        likelyRenumberings: likelyRenumberings,
                        renumberable: renumberable,
                        expandedRules: expandedRules,
                        subjectName: { newest?.subjectName($0) },
                        nearMisses: { audit.nearMisses(for: $0) },
                        checkedNotes: DegreeRequirementNotes.checkedEntries(of: section.section, audit: audit, filter: filter),
                        expandedNotes: expandedNotes
                    )
                }
            }

            // (A missing concentration is still open; its section above says so.)
            if filter != .all, !hasVisibleRules, !(filter == .remaining && audit.needsConcentration) {
                Section {
                    Label(
                        filter == .remaining ? "Nothing left: every requirement is complete" : "No requirement is complete yet",
                        systemImage: filter == .remaining ? "checkmark.seal" : "circle.dashed"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if filter == .all {
                extraCoursesSection(audit: audit, lookup: lookup, prompts: prompts)
                substitutionsSection(plan: plan, requirements: requirements, audit: audit, renumberable: renumberable)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                if isEmbedded {
                    embeddedHeader
                }
                Picker("Show", selection: $filter.animation(.snappy)) {
                    ForEach(DegreeRequirementsFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.s)
            }
        }
        .refreshable { await load(forceRefresh: true) }
    }

    /// The title and Edit button of the requirements shown beside the plan.
    private var embeddedHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Degree requirements")
                .font(.headline)
            Spacer()
            Button("Edit") { isEditingSetup = true }
                .accessibilityHint("Change the catalog year, program or concentration")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.s)
    }

    /// Where the requirements come from, when they were read, and that this isn't official.
    private func attribution(context: DegreeRequirementsContext, requirements: ProgramRequirements) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = context.catalogURL, let year = context.year {
                Link(destination: url) {
                    Text("From Northeastern’s \(year.description) academic catalog")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if context.isCurrentEdition, requirements.fetchedAt > .distantPast {
                Text("Updated \(requirements.fetchedAt.formatted(.relative(presentation: .named)))")
            }
            Text("Unofficial planning aid. Confirm with your degree audit and academic advisor.")
        }
    }

    private func concentrationSection(_ requirements: ProgramRequirements) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Choose your concentration", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Text("Your program has concentrations. Pick yours to check its courses too.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(requirements.concentrations) { concentration in
                        Button(concentration.concentrationName) { choose(concentration) }
                    }
                } label: {
                    Text("Choose concentration")
                }
                .buttonStyle(.glass)
                .padding(.top, 2)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    // MARK: Petition questions

    /// Petitions whose answer changes the result: whether they keep a requirement's minimum
    /// course number. Shown whatever the filter, since the answer can change any status.
    private func questionsSection(_ questions: [DegreePetitionQuestion], requirements: ProgramRequirements) -> some View {
        Section {
            ForEach(questions) { question in
                DegreePetitionQuestionRow(question: question) { limit in
                    answer(question, with: limit)
                } onOther: {
                    edit(question.substitution, ruleID: question.ruleID, requirements: requirements)
                }
            }
        } header: {
            Text(questions.count == 1 ? "A question about your petition" : "Questions about your petitions")
                .textCase(nil)
        }
    }

    /// Saves which course numbers a petition accepts, with Undo.
    private func answer(_ question: DegreePetitionQuestion, with limit: CourseNumberLimit) {
        let id = question.substitution.id
        withAnimation {
            userData.updateDegreePlan(id: planID) { $0.setCourseNumbers(limit, forSubstitution: id) }
        }
        haptic.fire(.success)
        let text = limit == .anyNumber
            ? "\(question.ruleTitle) petition: any course number"
            : "\(question.ruleTitle) petition: \(question.likeTitle)’s minimum"
        toast = DegreePlanToast(text: text, systemImage: "checkmark.circle.fill", actionTitle: "Undo") {
            withAnimation { userData.updateDegreePlan(id: planID) { $0.setCourseNumbers(nil, forSubstitution: id) } }
        }
    }

    // MARK: Extra courses

    @ViewBuilder
    private func extraCoursesSection(audit: DegreeAudit, lookup: DegreeCourseLookup, prompts: DegreeEquivalencePrompts) -> some View {
        let extra = audit.unused.filter { $0.credits > 0 }
        if !extra.isEmpty {
            Section {
                ForEach(extra) { use in
                    DegreeCatalogCourseRow(
                        key: use.key,
                        title: lookup.title(of: use.key),
                        credits: use.credits,
                        status: lookup.status(of: use.key),
                        isCountedHere: false,
                        caption: lookup.offeringNote(for: use.key),
                        onOpen: { viewCourse(use.key) },
                        onViewCourse: { viewCourse(use.key) },
                        equivalenceAction: DegreeRowAction(title: "Counts as another course…") {
                            equivalenceRequest = DegreeEquivalenceRequest(planID: planID, course: use.key)
                        },
                        opensRequirement: false
                    )
                    // A renumbered course often lands here: the catalog lists its new number.
                    if let prompt = prompts.forPlanCourse(use.key) {
                        DegreeEquivalencePromptRow(prompt: prompt, onConfirm: { confirm(prompt) }, onDismiss: { dismissSuggestion(prompt) })
                    }
                }
            } header: {
                Text("Extra courses")
                    .textCase(nil)
            } footer: {
                Text("These don’t count toward a requirement, but they still count toward your total credits.")
            }
        }
    }

    // MARK: Substitutions

    /// Every substitution of the plan, in one list. (The question whether a substitute is really the
    /// required course under a new number is asked under the substitute in its requirement.)
    private func substitutionsSection(plan: DegreePlan, requirements: ProgramRequirements, audit: DegreeAudit,
                                      renumberable: Set<UUID>) -> some View {
        let unmatched = Set(audit.unmatchedSubstitutions.map(\.id))
        return Section {
            if plan.substitutions.isEmpty {
                Text("When an advisor approves a course substitution or petition, open the requirement it changes and record it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.substitutions) { substitution in
                let ruleID = audit.placements[substitution.id] ?? substitution.ruleID
                let canRenumber = renumberable.contains(substitution.id)
                Button {
                    edit(substitution, ruleID: ruleID, requirements: requirements)
                } label: {
                    DegreeSubstitutionRow(
                        substitution: substitution,
                        ruleName: requirements.degreeShortName(ofRule: ruleID) ?? substitution.ruleTitle,
                        status: audit.result(for: ruleID)?.status,
                        doesNotApply: unmatched.contains(substitution.id)
                    )
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
                        edit(substitution, ruleID: ruleID, requirements: requirements)
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
        } header: {
            Text("Substitutions & petitions")
                .textCase(nil)
        } footer: {
            if !plan.substitutions.isEmpty {
                Text("To add another, open the requirement it changes.")
            }
        }
    }

    // MARK: Actions

    private func load(forceRefresh: Bool) async {
        guard let plan = userData.degreePlan(id: planID) else { return }
        await programCatalog.loadRequirements(for: plan, forceRefresh: forceRefresh)
    }

    /// Looks up the plan's courses in Banner's course catalog, then the courses that open
    /// requirements list and the newest term doesn't teach: one that is no longer offered may
    /// have a suggested replacement, and shouldn't be offered for the plan.
    private func loadCourseInfo() async {
        guard let plan = userData.degreePlan(id: planID) else { return }
        let snapshot = catalog.degreePlanSnapshot()
        await info.degreePlanLoad(plan, indexes: snapshot.indexes)
        guard let audit = programCatalog.degreeRequirementsContext(for: plan, cache: cache, equivalences: info.equivalences(for: plan)).audit else { return }
        let listed = audit.degreeOpenListedCourses(notIn: plan).filter { snapshot.reference?.course($0) == nil }
        if !listed.isEmpty {
            await info.load(listed, indexes: snapshot.indexes)
        }
        // A substitution for a requirement that names one course may be that course under a new
        // number: look up whether the required course is still offered.
        let named = DegreeRenumbering.coursesToLookUp(in: plan, requirements: audit.requirements)
        if !named.isEmpty {
            await info.load(named, indexes: snapshot.indexes)
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

    /// Makes a substitution the same course under a new number, with Undo: the course then counts
    /// as the required one everywhere, shown like any renumbered course.
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

    /// Opens the courses that have a NUpath attribute, in the term being browsed.
    private func findCourses(_ path: NUPath) {
        guard let termCode = catalog.readyIndex?.term.code ?? catalog.selectedTermCode else { return }
        router.navigate(to: .nupath(termCode: termCode, nupath: path))
    }

    /// Opens a course's page in this tab, for the term whose catalog lists it.
    private func viewCourse(_ key: CourseKey) {
        guard let termCode = catalog.degreePlanSnapshot().routeTermCode(for: key) else { return }
        router.navigate(to: .course(termCode: termCode, key: key))
    }

    private func choose(_ concentration: RequirementSection) {
        userData.updateDegreePlan(id: planID) { $0.concentrationID = concentration.id }
        haptic.fire(.success)
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

    /// Opens a substitution for the requirement the audit applied it to (`ruleID`).
    private func edit(_ substitution: RequirementSubstitution, ruleID: String? = nil, requirements: ProgramRequirements) {
        let ruleID = ruleID ?? substitution.ruleID
        substitutionRequest = DegreeSubstitutionRequest(
            planID: planID,
            ruleID: ruleID,
            ruleTitle: requirements.degreeShortName(ofRule: ruleID) ?? substitution.ruleTitle,
            existing: substitution
        )
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

/// The requirements page's navigation bar: its title and Edit button, unless the page sits beside
/// the plan, whose navigation bar it shares.
private struct DegreeRequirementsNavigation: ViewModifier {
    var isEmbedded: Bool
    var isEditDisabled: Bool
    var onEdit: () -> Void

    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content
                .navigationTitle("Degree requirements")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit", action: onEdit)
                            .disabled(isEditDisabled)
                            .accessibilityHint("Change the catalog year, program or concentration")
                    }
                }
        }
    }
}

/// A requirement whose details sheet is open.
struct DegreeRuleSelection: Identifiable, Hashable {
    let id: String
}

/// A substitution in the list: what it changes, its note and approval, and whether it still
/// applies to the plan's catalog year and concentration.
struct DegreeSubstitutionRow: View {
    var substitution: RequirementSubstitution
    var ruleName: String
    /// The requirement's status in the audit; nil when it isn't part of these requirements.
    var status: DegreeAudit.Status?
    var doesNotApply: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Group {
                if doesNotApply {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let status {
                    DegreeStatusIcon(status: status)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(Color.secondary)
                }
            }
            .font(.body)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DegreeRequirementText.substitutionTitle(substitution, ruleName: ruleName))
                    .foregroundStyle(Color.primary)
                if let detail = DegreeRequirementText.substitutionDetail(substitution) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                if let caption = DegreeRequirementText.substitutionCaption(substitution) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if doesNotApply {
                    Text("Doesn’t apply to this catalog year or concentration")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits the substitution")
    }
}
