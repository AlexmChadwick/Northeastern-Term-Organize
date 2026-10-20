//
//  MacDegreeRequirementsView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A degree plan read against its program's requirements, laid out like the academic catalog's
/// requirements page: each section and area in catalog order, every course it lists, and where
/// each one stands in the plan (completed, in progress, planned, or not in plan). Selecting a
/// requirement shows it in detail in a pane beside the list, where substitutions and petitions
/// are recorded. Reload with ⌘R.
///
/// This is the full-page version. The degree plan shows the same requirements beside its
/// semesters (`MacDegreeRequirementsContent` with the pane presentation), which is where most
/// people read them.
struct MacDegreeRequirementsView: View {
    var planID: UUID
    /// A requirement to select, and show in the details pane, once the requirements have
    /// loaded: the first whose name contains this text. For snapshots.
    var initialRule: String?
    /// Open the parts of every checked sentence (NUpath…). For snapshots.
    var expandsChecks = false

    var body: some View {
        // Another plan is another page: the selection, filter and sheets start over.
        MacDegreeRequirementsContent(planID: planID, initialRule: initialRule, expandsChecks: expandsChecks)
            .id(planID)
    }
}

/// The requirements themselves (see `MacDegreeRequirementsView`), shown as a page or as a pane
/// beside the degree plan.
struct MacDegreeRequirementsContent: View {
    /// Where the requirements are shown.
    enum Presentation {
        /// The whole page: the selected requirement's details are a pane beside the list.
        case page
        /// Beside the degree plan: opening a requirement's details replaces the list within the
        /// pane (a back button returns), so the details never cover the plan.
        case pane
    }

    var planID: UUID
    var presentation: Presentation = .page
    /// A requirement to select once the requirements have loaded: the first whose name contains
    /// this text. For snapshots.
    var initialRule: String?
    /// With the pane: open the initial requirement's details too. For snapshots.
    var opensInitialRuleDetails = false
    /// Open the parts of every checked sentence once the requirements have loaded. For snapshots.
    var expandsChecks = false
    /// The courses selected in the plan beside the pane: where they count is marked and shown.
    var linkedCourses: Set<CourseKey> = []
    /// Selects a course of the plan and shows it there (the semester it's planned in, when it
    /// is in more than one).
    var onShowCourseInPlan: ((CourseKey, String?) -> Void)?
    /// Opens the requirements as a full page (the pane's menu).
    var onOpenPage: (() -> Void)?
    /// Hides the pane.
    var onClose: (() -> Void)?

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(CatalogStore.self) private var catalog
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    @State private var filter = DegreeRequirementsFilter.all
    @State private var selectedRuleID: String?
    /// The pane: the requirement whose details replace the list.
    @State private var detailRuleID: String?
    /// The page: whether the details pane is shown.
    @State private var showsInspector = false
    @State private var isEditingSetup = false
    @State private var substitutionRequest: DegreeSubstitutionRequest?
    @State private var substitutionToDelete: RequirementSubstitution?
    @State private var cache = DegreeRequirementsCache()
    @State private var feasibility = DegreePlanFeasibilityModel()
    @State private var suggestionCache = DegreeEquivalenceSuggestionCache()
    @State private var questionCache = DegreePetitionQuestionCache()
    @State private var equivalenceRequest: DegreeEquivalenceRequest?
    /// Requirements whose long lists of options are expanded.
    @State private var expandedRules: Set<String> = []
    /// Checked sentences whose parts are shown.
    @State private var expandedChecks: Set<String> = []
    /// Catalog sections the student folded away.
    @State private var collapsedSections: Set<String> = []
    @State private var toast: MacDegreeToast?
    @State private var didSelectInitialRule = false
    @State private var rowLayout = MacDegreeRowLayout.table
    /// Until the person opens or closes the details pane (or selects a requirement), the page
    /// shows it when the window is wide enough to have room beside the list.
    @State private var inspectorFollowsWidth = true
    /// The courses a click in this list selected in the plan: they don't need revealing here.
    @State private var courseSelectedHere: Set<CourseKey>?
    /// The linked courses the list last scrolled to (or didn't need to), so closing a
    /// requirement's details doesn't scroll again.
    @State private var revealedCourses: Set<CourseKey> = []
    /// What the list showed above the requirements then, and when it last scrolled.
    @State private var revealedLayout: [Int] = []
    @State private var lastRevealAt: Date?
    @AppStorage(DegreeEquivalenceDismissals.storageKey) private var dismissedSuggestions = ""

    /// Banner's course catalog: equivalences, and courses that are no longer offered.
    private var info: CourseInfoStore { .shared }

    /// The list needs this much width for its columns; narrower, each course takes two lines.
    private static let tableMinWidth: CGFloat = 600
    /// The full page shows its details pane from this width, until the person says otherwise.
    private static let wideWindowWidth: CGFloat = 1100

    private var feasibilityKey: String {
        let plan = userData.degreePlan(id: planID)
        let codes = plan?.degreePlanPlannedKeys.map(\.description).sorted().joined(separator: "|") ?? ""
        let terms = catalog.degreePlanSnapshot().indexes.map(\.term.code).sorted().joined(separator: ",")
        return codes + "#" + terms
    }

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

    private var editor: MacDegreePlanEditor {
        MacDegreePlanEditor(userData: userData, planID: planID, undoManager: undoManager)
    }

    /// Whether the details pane is shown; setting it (the toolbar, the divider, the View menu) is
    /// the person's choice, which the window's width no longer overrides.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showsInspector },
            set: { newValue in
                inspectorFollowsWidth = false
                showsInspector = newValue
            }
        )
    }

    var body: some View {
        chrome(
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
        )
        .task(id: loadKey) { await load(forceRefresh: false) }
        .task(id: courseInfoKey) { await loadCourseInfo() }
        .task(id: feasibilityKey) {
            guard let plan = userData.degreePlan(id: planID) else { return }
            await feasibility.loadIfNeeded(plan: plan, indexes: catalog.degreePlanSnapshot().indexes)
        }
        .sheet(isPresented: $isEditingSetup) {
            MacDegreeRequirementsSetupSheet(planID: planID)
        }
        .sheet(item: $substitutionRequest) { request in
            MacRequirementSubstitutionSheet(request: request) { substitution in
                convertToEquivalence(substitution)
            }
        }
        .sheet(item: $equivalenceRequest) { request in
            MacDegreeEquivalenceSheet(request: request)
        }
        .confirmationDialog(
            "Delete this substitution?",
            isPresented: Binding(get: { substitutionToDelete != nil }, set: { if !$0 { substitutionToDelete = nil } }),
            titleVisibility: .visible,
            presenting: substitutionToDelete
        ) { substitution in
            Button("Delete Substitution", role: .destructive) { delete(substitution) }
        } message: { _ in
            Text("The requirement goes back to the catalog’s rule.")
        }
        .macDegreeToast($toast)
        .focusedSceneValue(\.macReload, MacMenuAction(title: "Reload Requirements") {
            Task { await load(forceRefresh: true) }
        })
    }

    /// The title, toolbar and menu of the full page. The pane beside the plan has none of its
    /// own: the plan's window toolbar and menu serve both.
    @ViewBuilder
    private func chrome<Content: View>(_ content: Content) -> some View {
        switch presentation {
        case .page:
            content
                .navigationTitle("Degree Requirements")
                .navigationSubtitle(userData.degreePlan(id: planID)?.name ?? "")
                .toolbar { pageToolbar }
                .focusedSceneValue(\.macDegreePlan, MacDegreePlanMenuActions(
                    planName: userData.degreePlan(id: planID)?.name ?? "",
                    showPlan: { navigator.selection = .degreePlan(planID) },
                    toggleDetails: { inspectorBinding.wrappedValue.toggle() },
                    detailsAreShown: showsInspector
                ))
                .focusedSceneValue(\.macSidePane, MacPaneToggle(title: "Requirement Details", isShown: showsInspector) {
                    withAnimation(.snappy) { inspectorBinding.wrappedValue.toggle() }
                })
                .onChange(of: selectedRuleID) { _, id in
                    // Selecting a requirement shows its details (when they weren't shown already,
                    // which is the person's choice to see them).
                    if id != nil, !showsInspector { inspectorBinding.wrappedValue = true }
                }
        case .pane:
            content
        }
    }

    @ToolbarContentBuilder
    private var pageToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                navigator.selection = .degreePlan(planID)
            } label: {
                Label("Plan", systemImage: "chevron.backward")
            }
            .help("Back to the degree plan")
        }
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter.animation(.snappy)) {
                ForEach(DegreeRequirementsFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .help("Show all requirements, the ones still open, or the ones that are done")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isEditingSetup = true
            } label: {
                Label("Catalog Year and Program", systemImage: "slider.horizontal.3")
            }
            .disabled(userData.degreePlan(id: planID) == nil)
            .help("Change the catalog year, program or concentration")
            Button {
                Task { await load(forceRefresh: true) }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Read the requirements from the catalog again (⌘R)")
            Button {
                withAnimation(.snappy) { inspectorBinding.wrappedValue.toggle() }
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the details of the selected requirement (⌥⌘0)")
        }
    }

    // MARK: States

    @ViewBuilder
    private func content(_ plan: DegreePlan) -> some View {
        let context = programCatalog.degreeRequirementsContext(
            for: plan, cache: cache, equivalences: info.equivalences(for: plan), includesMilestone: true
        )
        let page: MacDegreeRequirementsPage? = {
            guard let requirements = context.requirements, let audit = context.audit else { return nil }
            let lookup = DegreeCourseLookup.make(plan: plan, requirements: requirements, audit: audit, userData: userData, catalog: catalog)
            return makePage(plan: plan, context: context, requirements: requirements, audit: audit, lookup: lookup)
        }()
        switch presentation {
        case .page:
            if let page {
                pageLayout(page: page)
            } else {
                stateView(plan: plan, context: context)
            }
        case .pane:
            VStack(spacing: 0) {
                MacDegreeRequirementsPaneHeader(
                    isShowingDetails: detailRuleID != nil,
                    showsFilter: page != nil,
                    filter: $filter,
                    canChangeSetup: true,
                    onBack: { withAnimation(.snappy) { detailRuleID = nil } },
                    onChangeSetup: { isEditingSetup = true },
                    onReload: { Task { await load(forceRefresh: true) } },
                    onOpenPage: onOpenPage,
                    onClose: onClose
                )
                Divider()
                if let page {
                    paneLayout(page: page)
                } else {
                    stateView(plan: plan, context: context)
                }
            }
        }
    }

    /// Requirements that aren't there yet: not set up, failed, or still loading.
    @ViewBuilder
    private func stateView(plan: DegreePlan, context: DegreeRequirementsContext) -> some View {
        if !context.isSetUp {
            ContentUnavailableView {
                Label("Set up degree requirements", systemImage: "checklist")
            } description: {
                Text("Choose the catalog year you started in and your program to check this plan against Northeastern’s requirements.")
            } actions: {
                Button("Set Up…") {
                    isEditingSetup = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else if let failure = context.failure {
            ContentUnavailableView {
                Label("Couldn’t load the requirements", systemImage: "wifi.exclamationmark")
            } description: {
                Text(failure)
            } actions: {
                HStack {
                    Button("Try Again") {
                        Task { await load(forceRefresh: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Change Program or Year…") { isEditingSetup = true }
                }
                .controlSize(.large)
            }
        } else {
            ProgressView("Loading requirements…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Page

    private func makePage(plan: DegreePlan, context: DegreeRequirementsContext, requirements: ProgramRequirements,
                          audit: DegreeAudit, lookup: DegreeCourseLookup) -> MacDegreeRequirementsPage {
        let newest = catalog.degreePlanSnapshot().reference
        return MacDegreeRequirementsPage(
            plan: plan,
            context: context,
            requirements: requirements,
            audit: audit,
            lookup: lookup,
            equivalences: info.equivalences(for: plan),
            addTargets: DegreeCourseLookup.addTargets(for: plan),
            prompts: suggestionCache.prompts(
                for: plan,
                listed: audit.degreeOpenListedCourses(notIn: plan),
                dismissed: DegreeEquivalenceDismissals.decode(dismissedSuggestions),
                info: info,
                newest: newest,
                catalogTitles: requirements.courseTitles,
                alsoComparing: requirements.degreeListedCourses(concentrationID: plan.concentrationID)
            ),
            expandedRules: expandedRules,
            expandedChecks: expandedChecks,
            subjectName: { newest?.subjectName($0) },
            linkedCourses: linkedCourses,
            actions: actions(plan: plan, requirements: requirements, audit: audit, lookup: lookup)
        )
    }

    /// The full page: the list, and beside it (a `MacSplitPane`, so nothing has a fixed width and
    /// a narrow window floats it over the list) the selected requirement's details.
    private func pageLayout(page: MacDegreeRequirementsPage) -> some View {
        // In a wide window the details pane starts open, so the width goes to something useful;
        // in a narrow one it would cover the list, and opens when a requirement is selected.
        let pane = MacSplitPane(
            storageKey: "mac.split.degreeRequirements",
            defaultShare: 0.38,
            paneMinWidth: 320,
            primaryMinWidth: 440,
            maxShare: 0.6,
            isPaneShown: inspectorBinding
        ) {
            requirementsList(page: page)
        } pane: {
            MacDegreeRequirementInspector(page: page, ruleID: selectedRuleID)
        }
        return pane
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                guard inspectorFollowsWidth, width > 0 else { return }
                let isWide = width >= Self.wideWindowWidth
                guard showsInspector != isWide else { return }
                showsInspector = isWide
                // The pane opens on the first requirement that still needs something, so it
                // shows something useful rather than an empty prompt.
                if isWide, selectedRuleID == nil {
                    selectedRuleID = page.audit.ruleResults.first { $0.status <= .partial }?.rule.id
                }
            }
    }

    /// The pane beside the degree plan: the list, and over it (within the pane) one
    /// requirement's details when opened. The list stays where it was scrolled to underneath.
    private func paneLayout(page: MacDegreeRequirementsPage) -> some View {
        ZStack {
            requirementsList(page: page)
                .allowsHitTesting(detailRuleID == nil)
                .accessibilityHidden(detailRuleID != nil)
            if let detailRuleID {
                MacDegreeRequirementInspector(page: page, ruleID: detailRuleID)
                    .background(.background)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .clipped()
        // Escape goes back to the list, whichever part of the pane has the keyboard.
        .onExitCommand(perform: detailRuleID == nil ? nil : { withAnimation(.snappy) { detailRuleID = nil } })
        .animation(.snappy(duration: 0.25), value: detailRuleID)
    }

    // MARK: List

    private func requirementsList(page: MacDegreeRequirementsPage) -> some View {
        let plan = page.plan, context = page.context, requirements = page.requirements, audit = page.audit
        let hasVisibleRules = audit.ruleResults.contains { filter.includes($0.status) }
        let equivalences = page.equivalences
        let questions = questionCache.questions(plan: plan, requirements: requirements, equivalences: equivalences, audit: audit)
        let dismissed = DegreeEquivalenceDismissals.decode(dismissedSuggestions)
        let renumberings = DegreeSubstitutionEditing
            .likelyRenumberings(in: plan, requirements: requirements, isRetired: { info.info(for: $0)?.isRetired })
            .filter { !dismissed.contains(DegreeEquivalenceDismissals.pairID($0.course, $0.countsAs)) }
        // What the list shows above the requirements; when it grows (a question appears, NUpath
        // data arrives) after the list scrolled, the row it scrolled to has moved down.
        let layout = [questions.count, renumberings.count, audit.noteChecks.count,
                      audit.noteChecks.reduce(0) { $0 + $1.items.count }, audit.noteChecks.filter(\.counts).count]
        return ScrollViewReader { proxy in
            List(selection: $selectedRuleID) {
                Section {
                    DegreeRequirementsSummary(
                        context: context, audit: audit,
                        blockedFinish: feasibility.report(for: plan, snapshot: catalog.degreePlanSnapshot())
                            .warningLine(milestone: context.milestone, plan: plan)
                    )
                        .selectionDisabled()
                } footer: {
                    attribution(context: context, requirements: requirements, hintsAtDragging: presentation == .pane && audit.satisfiedCount < audit.totalCount)
                }

                if !questions.isEmpty || !renumberings.isEmpty {
                    questionsSection(questions, renumberings: renumberings, page: page)
                }

                if context.milestone == .completed {
                    Section {
                        MacDegreeMilestoneRow(milestone: .completed, hasLaterSemesters: plan.terms.contains { !$0.courses.isEmpty })
                            .selectionDisabled()
                    }
                    .listRowBackground(Color.green.opacity(0.12))
                }

                if audit.needsConcentration, filter != .done {
                    concentrationSection(requirements)
                }

                ForEach(audit.sections) { section in
                    if section.rules.isEmpty {
                        notesSection(section, page: page)
                    } else {
                        MacDegreeRequirementsSection(
                            section: section,
                            filter: filter,
                            page: page,
                            opensDetails: presentation == .pane,
                            isCollapsed: collapsedSections.contains(section.id)
                        ) {
                            withAnimation(.snappy) {
                                if collapsedSections.contains(section.id) { collapsedSections.remove(section.id) } else { collapsedSections.insert(section.id) }
                            }
                        }
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
                        .selectionDisabled()
                    }
                }

                if filter == .all {
                    extraCoursesSection(page: page)
                    substitutionsSection(page: page)
                }
            }
            .listStyle(.inset)
            .onKeyPress(.return) {
                guard presentation == .pane, let selectedRuleID else { return .ignored }
                withAnimation(.snappy) { detailRuleID = selectedRuleID }
                return .handled
            }
            .onAppear {
                if expandsChecks { expandedChecks = Set(audit.noteChecks.map(\.id)) }
                guard let initialRule, !didSelectInitialRule else { return }
                didSelectInitialRule = true
                selectedRuleID = audit.ruleResults.first {
                    (requirements.degreeShortName(ofRule: $0.rule.id) ?? $0.rule.displayLabel).localizedCaseInsensitiveContains(initialRule)
                }?.rule.id
                if opensInitialRuleDetails { detailRuleID = selectedRuleID }
            }
            // Courses selected in the plan: scroll to the requirement that counts them.
            .task(id: RevealKey(courses: linkedCourses, isListShown: detailRuleID == nil, layout: layout)) {
                await reveal(page: page, proxy: proxy, layout: layout)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            let layout: MacDegreeRowLayout = width < Self.tableMinWidth ? .compact : .table
            if layout != rowLayout { rowLayout = layout }
        }
        .environment(\.macDegreeRowLayout, rowLayout)
    }

    // MARK: Revealing a course

    private struct RevealKey: Hashable {
        var courses: Set<CourseKey>
        var isListShown: Bool
        var layout: [Int]
    }

    /// The first row that counts one of the linked courses: its id, and the section it is in
    /// (nil for the extra courses).
    private func revealTarget(page: MacDegreeRequirementsPage) -> (rowID: String, sectionID: String?)? {
        for section in page.audit.sections {
            for result in section.rules where filter.includes(result.status) {
                for row in MacDegreeRuleRows.rows(for: result, page: page) {
                    if let key = row.countedCourse, linkedCourses.contains(key) { return (row.id, section.id) }
                }
            }
        }
        if filter == .all, let use = page.audit.unused.first(where: { $0.credits > 0 && linkedCourses.contains($0.key) }) {
            return (use.id, nil)
        }
        return nil
    }

    /// Scrolls to where the course selected in the plan counts, opening its section when folded.
    /// Selecting several courses only marks them; a course selected from this list is already
    /// in view; and while a requirement's details cover the list it waits until they close. The
    /// list scrolls once more when what's above the row changes soon after.
    private func reveal(page: MacDegreeRequirementsPage, proxy: ScrollViewProxy, layout: [Int]) async {
        guard detailRuleID == nil else { return }
        if linkedCourses == revealedCourses {
            // The same course: only the list above it growing soon after the last scroll counts.
            let moved = layout != revealedLayout && lastRevealAt.map { Date.now.timeIntervalSince($0) < 12 } == true
            revealedLayout = layout
            guard moved else { return }
        }
        revealedCourses = linkedCourses
        revealedLayout = layout
        guard linkedCourses.count == 1, courseSelectedHere != linkedCourses else {
            courseSelectedHere = nil
            return
        }
        guard let target = revealTarget(page: page) else { return }
        if let sectionID = target.sectionID, collapsedSections.contains(sectionID) {
            withAnimation(.snappy) { _ = collapsedSections.remove(sectionID) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        lastRevealAt = .now
        withAnimation(.snappy) { proxy.scrollTo(target.rowID, anchor: .center) }
        // A long list sizes the rows it hasn't shown yet as it scrolls, so once they have settled
        // the row may not be quite centered: scroll once more.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) { proxy.scrollTo(target.rowID, anchor: .center) }
    }

    // MARK: Questions

    /// Questions about substitutions: whether a petition keeps its requirement's minimum course
    /// number, and whether a substituted course is the required one under a new number. Shown
    /// whatever the filter, since an answer can change any status.
    private func questionsSection(_ questions: [DegreePetitionQuestion], renumberings: [DegreeSubstitutionEditing.LikelyRenumbering],
                                  page: MacDegreeRequirementsPage) -> some View {
        Section {
            ForEach(renumberings, id: \.rowID) { prompt in
                MacDegreeRenumberingPromptRow(prompt: prompt) {
                    convertToEquivalence(prompt.substitution)
                } onKeep: {
                    page.actions.keepAsSubstitution(prompt)
                }
                .selectionDisabled()
            }
            // Identified by text: the petition's own id is also its row's in the substitutions
            // list below, and rows of one list that share an id show each other's content.
            ForEach(questions, id: \.substitution.id.uuidString) { question in
                MacDegreePetitionQuestionRow(question: question) { limit in
                    answer(question, with: limit)
                } onOther: {
                    page.actions.editSubstitution(question.substitution)
                }
                .selectionDisabled()
            }
        } header: {
            Text(Self.questionsTitle(petitions: questions.count, renumberings: renumberings.count))
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .macListHeaderBackground()
        }
        .listRowBackground(Color.orange.opacity(0.10))
    }

    private static func questionsTitle(petitions: Int, renumberings: Int) -> String {
        switch (petitions, renumberings) {
        case (_, 0): petitions == 1 ? "A Question About Your Petition" : "Questions About Your Petitions"
        case (0, _): renumberings == 1 ? "Same Course, New Number?" : "Same Courses, New Numbers?"
        default: "Questions About Your Substitutions"
        }
    }

    /// Saves which course numbers a petition accepts. Edit › Undo takes it back, and so does the
    /// toast's Undo.
    private func answer(_ question: DegreePetitionQuestion, with limit: CourseNumberLimit) {
        let id = question.substitution.id
        let actionName = "Answer Petition Question"
        editor.perform(actionName, touching: .substitutions) { $0.setCourseNumbers(limit, forSubstitution: id) }
        let text = limit == .anyNumber
            ? "\(question.ruleTitle) petition: any course number"
            : "\(question.ruleTitle) petition: \(question.likeTitle)’s minimum"
        showUndoToast(text, systemImage: "checkmark.circle.fill", actionName: actionName) {
            $0.setCourseNumbers(nil, forSubstitution: id)
        }
    }

    /// A toast with Undo: Edit › Undo's action when it is still the last one, else putting the
    /// plan back by hand.
    private func showUndoToast(_ text: String, systemImage: String, actionName: String, restore: @escaping (inout DegreePlan) -> Void) {
        let undoManager = undoManager
        let planID = planID
        toast = MacDegreeToast(text: text, systemImage: systemImage, actionTitle: "Undo") {
            if let undoManager, undoManager.canUndo, undoManager.undoActionName == actionName {
                undoManager.undo()
            } else {
                userData.updateDegreePlan(id: planID, restore)
            }
        }
    }

    /// Where the requirements come from, when they were read, and that this isn't official. Beside
    /// the plan, it also says how to plan a course the requirements still need.
    private func attribution(context: DegreeRequirementsContext, requirements: ProgramRequirements, hintsAtDragging: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if hintsAtDragging {
                Text("Drag a course you still need onto a semester to plan it.")
            }
            if let url = context.catalogURL, let year = context.year {
                Link("From Northeastern’s \(year.description) academic catalog", destination: url)
            }
            if context.isCurrentEdition, requirements.fetchedAt > .distantPast {
                Text("Updated \(requirements.fetchedAt.formatted(.relative(presentation: .named)))")
            }
            Text("Unofficial planning aid. Confirm with your degree audit and academic advisor.")
        }
    }

    // MARK: Sentences

    /// The sentences of a section that has none of its own requirements (`NUpath Requirements`,
    /// `Khoury College GPA Requirement`), each with how the plan stands against it when the audit
    /// can say; the filter picks them by that status, and the ones that can't be checked show
    /// with All. The total-hours line the summary already shows stays out unless it is checked.
    @ViewBuilder
    private func notesSection(_ section: DegreeAudit.SectionResult, page: MacDegreeRequirementsPage) -> some View {
        let notes = Self.notes(of: section).compactMap { note -> NoteEntry? in
            if let check = page.audit.noteCheck(sectionID: section.id, note: note) {
                return filter.includes(check.status) ? NoteEntry(note: note, check: check) : nil
            }
            guard filter == .all else { return nil }
            let restatesTotal = page.requirements.totalHours != nil && note.localizedCaseInsensitiveContains("total semester hours")
            return restatesTotal ? nil : NoteEntry(note: note, check: nil)
        }
        if !notes.isEmpty {
            Section {
                ForEach(notes) { entry in
                    MacDegreeNoteRow(
                        note: entry.note,
                        check: entry.check,
                        isExpanded: entry.check.map { page.expandedChecks.contains($0.id) } ?? false,
                        onToggle: {
                            if let check = entry.check { page.actions.toggleCheck(check.id) }
                        },
                        onFindCourses: page.actions.findCourses
                    )
                    .selectionDisabled()
                }
            } header: {
                Text(section.section.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .macListHeaderBackground()
            }
        }
    }

    private struct NoteEntry: Identifiable {
        var note: String
        var check: DegreeAudit.NoteCheck?
        var id: String { note }
    }

    /// The sentences the audit checks in a section: its own and those of groups without rules.
    static func notes(of section: DegreeAudit.SectionResult) -> [String] {
        section.section.notes + section.groups.filter(\.rules.isEmpty).flatMap { $0.group.notes }
    }

    private func concentrationSection(_ requirements: ProgramRequirements) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Choose your concentration", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                Text("Your program has concentrations. Pick yours to check its courses too.")
                    .foregroundStyle(.secondary)
                Menu("Choose Concentration") {
                    ForEach(requirements.concentrations) { concentration in
                        Button(concentration.concentrationName) { choose(concentration) }
                    }
                }
                .fixedSize()
            }
            .padding(.vertical, 4)
            .selectionDisabled()
        }
    }

    // MARK: Extra courses

    @ViewBuilder
    private func extraCoursesSection(page: MacDegreeRequirementsPage) -> some View {
        let extra = page.audit.unused.filter { $0.credits > 0 }
        if !extra.isEmpty {
            Section {
                ForEach(extra) { use in
                    MacDegreeCatalogCourseRow(
                        key: use.key,
                        title: page.lookup.title(of: use.key),
                        credits: use.credits,
                        connector: nil,
                        status: page.lookup.status(of: use.key),
                        isCountedHere: false,
                        caption: page.lookup.offeringNote(for: use.key),
                        onViewCourse: { viewCourse(use.key) },
                        equivalence: ("Counts as Another Course…", { equivalenceRequest = DegreeEquivalenceRequest(planID: planID, course: use.key) }),
                        showInPlan: page.actions.showCourseInPlan.map { show in { show(use.key, use.semester) } }
                    )
                    .selectionDisabled()
                    .listRowBackground(linkedCourses.contains(use.key) ? Color.accentColor.opacity(0.18) : nil)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { viewCourse(use.key) })
                    // A renumbered course often lands here: the catalog lists its new number.
                    if let prompt = page.prompts.forPlanCourse(use.key) {
                        MacDegreeEquivalencePromptRow(prompt: prompt, onConfirm: { confirm(prompt) }, onDismiss: { dismissSuggestion(prompt) })
                            .selectionDisabled()
                    }
                }
            } header: {
                Text("Extra Courses")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .macListHeaderBackground()
            } footer: {
                Text("These don’t count toward a requirement, but they still count toward your total credits.")
            }
        }
    }

    // MARK: Substitutions

    private func substitutionsSection(page: MacDegreeRequirementsPage) -> some View {
        let plan = page.plan
        let unmatched = Set(page.audit.unmatchedSubstitutions.map(\.id))
        return Section {
            if plan.substitutions.isEmpty {
                Text("When an advisor approves a course substitution or petition, select the requirement it changes and record it.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(plan.substitutions) { substitution in
                // The requirement the audit applied it to: one saved under another catalog year
                // follows its requirement's name when the id changed.
                let ruleID = page.audit.placements[substitution.id] ?? substitution.ruleID
                let renumbering = DegreeSubstitutionEditing.renumbering(for: substitution, requirements: page.requirements)
                MacDegreeSubstitutionRow(
                    substitution: substitution,
                    ruleName: page.requirements.degreeShortName(ofRule: ruleID) ?? substitution.ruleTitle,
                    status: page.audit.result(for: ruleID)?.status,
                    doesNotApply: unmatched.contains(substitution.id),
                    renumbering: renumbering,
                    onConvert: { page.actions.convertToEquivalence(substitution) }
                )
                .selectionDisabled()
                .onTapGesture(count: 2) { page.actions.editSubstitution(substitution) }
                .contextMenu {
                    Button("Edit…") { page.actions.editSubstitution(substitution) }
                    if page.audit.result(for: ruleID) != nil {
                        Button("Show Requirement") {
                            if presentation == .pane { page.actions.openDetails(ruleID) } else { page.actions.selectRule(ruleID) }
                        }
                    }
                    if let renumbering {
                        Button("Same Course, New Number (\(renumbering.course.description) = \(renumbering.countsAs.description))") {
                            page.actions.convertToEquivalence(substitution)
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { page.actions.deleteSubstitution(substitution) }
                }
            }
        } header: {
            Text("Substitutions & Petitions")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .macListHeaderBackground()
        } footer: {
            if !plan.substitutions.isEmpty {
                Text("To add another, select the requirement it changes. Double-click one to edit it.")
            }
        }
    }

    // MARK: Actions

    private func actions(plan: DegreePlan, requirements: ProgramRequirements, audit: DegreeAudit,
                         lookup: DegreeCourseLookup) -> MacDegreeRequirementActions {
        MacDegreeRequirementActions(
            selectRule: { selectedRuleID = $0 },
            openDetails: { ruleID in
                switch presentation {
                case .page:
                    selectedRuleID = ruleID
                    inspectorBinding.wrappedValue = true
                case .pane:
                    selectedRuleID = ruleID
                    withAnimation(.snappy) { detailRuleID = ruleID }
                }
            },
            addCourse: { key, semester in add(key, to: semester, lookup: lookup) },
            startSubstitution: { ruleID, kind in
                substitutionRequest = DegreeSubstitutionRequest(
                    planID: planID, ruleID: ruleID,
                    ruleTitle: requirements.degreeShortName(ofRule: ruleID) ?? "Requirement",
                    kind: kind
                )
            },
            countSpecificCourse: { ruleID, key in
                substitutionRequest = DegreeSubstitutionRequest(
                    planID: planID, ruleID: ruleID,
                    ruleTitle: requirements.degreeShortName(ofRule: ruleID) ?? "Requirement",
                    kind: .countCourse, course: key
                )
            },
            answerPetition: { question, limit in answer(question, with: limit) },
            editSubstitution: { substitution in
                // Opened for the requirement the audit applied it to (saving points it there).
                let ruleID = audit.placements[substitution.id] ?? substitution.ruleID
                substitutionRequest = DegreeSubstitutionRequest(
                    planID: planID,
                    ruleID: ruleID,
                    ruleTitle: requirements.degreeShortName(ofRule: ruleID) ?? substitution.ruleTitle,
                    existing: substitution
                )
            },
            deleteSubstitution: { substitutionToDelete = $0 },
            convertToEquivalence: { convertToEquivalence($0) },
            keepAsSubstitution: { prompt in
                withAnimation {
                    DegreeEquivalenceDismissals.dismiss(prompt.course, prompt.countsAs, in: &dismissedSuggestions)
                }
            },
            viewCourse: { viewCourse($0) },
            showCourseInPlan: onShowCourseInPlan.map { show in
                { key, semester in
                    courseSelectedHere = [key]
                    show(key, semester)
                }
            },
            confirmEquivalence: { confirm($0) },
            dismissEquivalence: { dismissSuggestion($0) },
            addEquivalence: { key in equivalenceRequest = DegreeEquivalenceRequest(planID: planID, countsAs: key) },
            toggleExpanded: { ruleID in
                withAnimation(.snappy) {
                    if expandedRules.contains(ruleID) { expandedRules.remove(ruleID) } else { expandedRules.insert(ruleID) }
                }
            },
            toggleCheck: { checkID in
                withAnimation(.snappy) {
                    if expandedChecks.contains(checkID) { expandedChecks.remove(checkID) } else { expandedChecks.insert(checkID) }
                }
            },
            findCourses: { nupath in
                var filters = SearchFilters()
                filters.nupaths = [nupath]
                MacCatalogNavigation.search(filters: filters, navigator: navigator, openWindow: openWindow)
            }
        )
    }

    private func load(forceRefresh: Bool) async {
        guard let plan = userData.degreePlan(id: planID) else { return }
        await programCatalog.loadRequirements(for: plan, forceRefresh: forceRefresh)
    }

    /// Looks up the plan's courses in Banner's course catalog, then the courses that open
    /// requirements list and the newest term doesn't teach (one that is no longer offered may
    /// have a suggested replacement, and shouldn't be offered for the plan), and the required
    /// courses that substitutions stand in for (a retired one suggests a renumbering).
    private func loadCourseInfo() async {
        guard let plan = userData.degreePlan(id: planID) else { return }
        let snapshot = catalog.degreePlanSnapshot()
        await info.degreePlanLoad(plan, indexes: snapshot.indexes)
        guard let audit = programCatalog.degreeRequirementsContext(for: plan, cache: cache, equivalences: info.equivalences(for: plan)).audit else { return }
        let replaced = plan.substitutions.compactMap {
            DegreeSubstitutionEditing.renumbering(for: $0, requirements: audit.requirements)?.countsAs
        }
        let listed = (audit.degreeOpenListedCourses(notIn: plan) + replaced).filter { snapshot.reference?.course($0) == nil }
        if !listed.isEmpty {
            await info.load(listed, indexes: snapshot.indexes)
        }
    }

    /// Declares a suggested equivalence.
    private func confirm(_ prompt: DegreeEquivalencePrompt) {
        guard let plan = userData.degreePlan(id: planID),
              !plan.declaredEquivalences.areEquivalent(prompt.course, prompt.countsAs) else { return }
        editor.perform("Count \(prompt.course) as \(prompt.countsAs)", touching: .equivalences) {
            $0.declareEquivalence(course: prompt.course, countsAs: prompt.countsAs)
        }
        toast = MacDegreeToast(text: "\(prompt.course) now counts as \(prompt.countsAs)", systemImage: "equal.circle.fill")
    }

    private func dismissSuggestion(_ prompt: DegreeEquivalencePrompt) {
        withAnimation { dismissedSuggestions = DegreeEquivalenceDismissals.adding(prompt.id, to: dismissedSuggestions) }
    }

    /// Turns a substitution into the equivalence it amounts to (CS 3484 for the retired IS 4800
    /// becomes "CS 3484 counts as IS 4800"). Edit › Undo and the toast's Undo take it back.
    private func convertToEquivalence(_ substitution: RequirementSubstitution) {
        guard let plan = userData.degreePlan(id: planID),
              let requirements = programCatalog.requirements(for: plan),
              let equivalence = DegreeSubstitutionEditing.renumbering(for: substitution, requirements: requirements) else { return }
        let actionName = "Count \(equivalence.course) as \(equivalence.countsAs)"
        let substitutions = plan.substitutions
        let equivalences = plan.courseEquivalences
        editor.perform(actionName, touching: [.substitutions, .equivalences]) {
            DegreeSubstitutionEditing.convertToEquivalence(substitution, requirements: requirements, in: &$0)
        }
        showUndoToast("\(equivalence.course) now counts as \(equivalence.countsAs)", systemImage: "equal.circle.fill", actionName: actionName) {
            $0.substitutions = substitutions
            $0.courseEquivalences = equivalences
        }
    }

    /// Opens a course in its own window, for the term whose catalog lists it.
    private func viewCourse(_ key: CourseKey) {
        guard let termCode = catalog.degreePlanSnapshot().routeTermCode(for: key) else { return }
        openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
    }

    private func choose(_ concentration: RequirementSection) {
        userData.updateDegreePlan(id: planID) { $0.concentrationID = concentration.id }
    }

    private func add(_ key: CourseKey, to semester: DegreePlanTerm, lookup: DegreeCourseLookup) {
        let course = DegreePlanCourse(
            key: key,
            title: DegreePlanFormat.exportTitle(lookup.title(of: key) ?? key.description),
            credits: lookup.credits(of: key) ?? 4
        )
        editor.perform("Add \(key) to \(semester.shortName)") { DegreePlanEditing.addCourse(course, to: semester, in: &$0) }
        toast = MacDegreeToast(text: "Added \(key) to \(semester.shortName)", systemImage: "calendar.badge.plus")
        // Beside the plan, show where the course landed.
        if let show = onShowCourseInPlan {
            courseSelectedHere = [key]
            show(key, semester.name)
        }
    }

    private func delete(_ substitution: RequirementSubstitution) {
        editor.perform("Delete Substitution", touching: .substitutions) { plan in
            plan.substitutions.removeAll { $0.id == substitution.id }
        }
    }
}

// MARK: - Section

/// One section of the catalog's requirements (`Computer Science Requirements`), laid out like
/// the catalog page: area headers, then every course in catalog order, each annotated with its
/// status in the plan. A course that counts for a requirement by substitution sits inside that
/// requirement's block, indented under its courses with an arrow and a tag.
struct MacDegreeRequirementsSection: View {
    var section: DegreeAudit.SectionResult
    var filter: DegreeRequirementsFilter
    var page: MacDegreeRequirementsPage
    /// A requirement's first row opens its details (the requirements beside the plan).
    var opensDetails = false
    /// The section is folded away, leaving its header.
    var isCollapsed = false
    var onToggle: () -> Void = {}

    private struct VisibleGroup {
        var group: DegreeAudit.GroupResult
        var rules: [DegreeAudit.RuleResult]
    }

    var body: some View {
        let groups = section.groups.compactMap { group -> VisibleGroup? in
            let rules = group.rules.filter { filter.includes($0.status) }
            return rules.isEmpty ? nil : VisibleGroup(group: group, rules: rules)
        }
        // The section's sentences: the ones the plan is checked against are rows of their own, the
        // rest a footnote.
        let notes = section.section.notes
        let checks = notes.compactMap { note in page.audit.noteCheck(sectionID: section.id, note: note) }
            .filter { filter.includes($0.status) }
        let plainNotes = notes.filter { page.audit.noteCheck(sectionID: section.id, note: $0) == nil }
        if !groups.isEmpty {
            Section {
                if !isCollapsed {
                    ForEach(groups, id: \.group.id) { entry in
                        groupRows(entry.group, rules: entry.rules)
                    }
                    ForEach(checks) { check in
                        MacDegreeNoteRow(
                            note: check.note,
                            check: check,
                            isExpanded: page.expandedChecks.contains(check.id),
                            onToggle: { page.actions.toggleCheck(check.id) },
                            onFindCourses: page.actions.findCourses
                        )
                        .selectionDisabled()
                    }
                }
            } header: {
                header
            } footer: {
                if !isCollapsed, !plainNotes.isEmpty {
                    Text(plainNotes.joined(separator: "\n"))
                }
            }
        }
    }

    private var header: some View {
        let rules = section.rules
        let covered = rules.filter(\.status.isSatisfied).count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(section.section.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text("\(covered) of \(rules.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .textCase(nil)
        .macListHeaderBackground()
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .help(isCollapsed ? "Show this section" : "Hide this section")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.section.title), \(covered) of \(rules.count) requirements covered")
        .accessibilityHint(isCollapsed ? "Expands the section" : "Collapses the section")
        .accessibilityAddTraits([.isHeader, .isButton])
    }

    @ViewBuilder
    private func groupRows(_ group: DegreeAudit.GroupResult, rules: [DegreeAudit.RuleResult]) -> some View {
        // Every titled group gets its band, as in the catalog, however many rules it has, so a
        // group never reads as nested in the one above it. (Groups the filter empties aren't
        // shown at all, so there are no empty bands.)
        if let title = group.group.title {
            MacDegreeAreaBand(title: title)
                .listRowBackground(Color.secondary.opacity(0.08))
                .selectionDisabled()
        }
        ForEach(rules) { result in
            ForEach(MacDegreeRuleRows.rows(for: result, page: page)) { row in
                rowView(row)
            }
        }
    }

    /// The head row of a requirement is the one that is selected (and shows the requirement in
    /// the details pane); clicking any other row of it selects the requirement too.
    @ViewBuilder
    private func rowView(_ row: MacDegreeRuleRow) -> some View {
        let ruleID = row.result.rule.id
        if row.isHead {
            MacDegreeRuleRowView(row: row, page: page, opensDetails: opensDetails)
                .tag(ruleID)
                .modifier(MacDegreeCourseDoubleClick(row: row, page: page))
                .modifier(MacDegreeCourseClick(row: row, page: page))
                .listRowBackground(RowBackground(row: row, page: page))
        } else {
            MacDegreeRuleRowView(row: row, page: page, opensDetails: opensDetails)
                .selectionDisabled()
                .modifier(MacDegreeCourseDoubleClick(row: row, page: page))
                .modifier(MacDegreeCourseClick(row: row, page: page))
                .onTapGesture { page.actions.selectRule(ruleID) }
                .listRowBackground(RowBackground(row: row, page: page))
        }
    }

    /// Substitutes are tinted, so they read as one thing with the requirement they belong to; a
    /// course selected in the plan marks where it counts.
    private struct RowBackground: View {
        var row: MacDegreeRuleRow
        var page: MacDegreeRequirementsPage

        var body: some View {
            ZStack {
                if row.isSubstitute { Color.indigo.opacity(0.07) }
                if let key = row.countedCourse, page.linkedCourses.contains(key) { Color.accentColor.opacity(0.18) }
            }
        }
    }
}
