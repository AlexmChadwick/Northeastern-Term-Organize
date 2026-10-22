//
//  MacDegreePlanView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI

/// Where the plan page remembers what it shows.
enum MacDegreePlanPane {
    /// `@AppStorage` key: whether the requirements are shown beside the plan.
    static let showsRequirementsKey = "mac.degreePlan.showsRequirements"
}

/// A degree plan: its totals and checks, one section per planned semester with prerequisite
/// checks, and the completed courses, with the degree requirements beside them in a pane (shown
/// until hidden with the toolbar's Requirements button or View › Hide Requirements). Courses are
/// rows of one list: drag them between semesters, press Delete to remove them, double-click to
/// open the course in its own window, and right-click for the rest (move to a semester, mark
/// completed…). Edits can be undone with ⌘Z.
///
/// The two sides follow each other: selecting a course marks where it counts in the
/// requirements, clicking a course in the requirements selects it here, and a course the
/// requirements still need can be dragged onto a semester to plan it.
struct MacDegreePlanView: View {
    var planID: UUID
    /// Whether the completed courses start expanded; nil leaves it to their number (a long list
    /// starts collapsed).
    var showsCompleted: Bool?
    /// A course to select once the plan is shown, so the requirements mark where it counts. For
    /// snapshots.
    var initiallySelected: CourseKey?
    /// A requirement of the pane to select, and with `opensRequirementDetails` to open, once the
    /// requirements have loaded. For snapshots.
    var initialRequirement: String?
    var opensRequirementDetails = false

    init(planID: UUID, showsCompleted: Bool? = nil, initiallySelected: CourseKey? = nil,
         initialRequirement: String? = nil, opensRequirementDetails: Bool = false) {
        self.planID = planID
        self.showsCompleted = showsCompleted
        self.initiallySelected = initiallySelected
        self.initialRequirement = initialRequirement
        self.opensRequirementDetails = opensRequirementDetails
    }

    var body: some View {
        // Another plan is another page: the selection, sheets and expansion start over.
        MacDegreePlanContent(
            planID: planID, showsCompleted: showsCompleted, initiallySelected: initiallySelected,
            initialRequirement: initialRequirement, opensRequirementDetails: opensRequirementDetails
        )
        .id(planID)
    }
}

/// The plan page itself (see `MacDegreePlanView`).
struct MacDegreePlanContent: View {
    var planID: UUID
    var initiallySelected: CourseKey?
    var initialRequirement: String?
    var opensRequirementDetails: Bool

    init(planID: UUID, showsCompleted: Bool? = nil, initiallySelected: CourseKey? = nil,
         initialRequirement: String? = nil, opensRequirementDetails: Bool = false) {
        self.planID = planID
        self.initiallySelected = initiallySelected
        self.initialRequirement = initialRequirement
        self.opensRequirementDetails = opensRequirementDetails
        _completedExpansion = State(initialValue: showsCompleted)
    }

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    /// The selected courses, planned or completed (by `DegreePlanCourse.id`).
    @State private var selection: Set<UUID> = []
    @State private var sheet: ActiveSheet?
    @State private var confirmsDelete = false
    @State private var confirmsStudentRemoval = false
    @State private var termToRemove: DegreePlanTerm?
    /// nil until the user opens or closes the completed list; then their choice wins.
    @State private var completedExpansion: Bool?
    @State private var isBuildingSchedule = false
    @State private var toast: MacDegreeToast?
    /// A course the list is asked to scroll to (one that was clicked in the requirements).
    @State private var scrollRequest: UUID?
    /// Columns for where each course counts and its prerequisites, when the list is wide.
    @State private var rowLayout = MacDegreePlanRowLayout.compact
    /// Whether the requirements are shown beside the plan; remembered, and shown to start with.
    @AppStorage(MacDegreePlanPane.showsRequirementsKey) private var showsRequirements = true
    /// Remembers the requirements audit and finish milestone between updates.
    @State private var requirementsCache = DegreeRequirementsCache()
    /// Offering history used to tell when a planned semester can't be taken.
    @State private var feasibility = DegreePlanFeasibilityModel()
    @State private var suggestionCache = DegreeEquivalenceSuggestionCache()
    @AppStorage(DegreeEquivalenceDismissals.storageKey) private var dismissedSuggestions = ""

    /// Banner's course catalog for courses the loaded terms don't list (prerequisites,
    /// retired courses, equivalences). Reading it in `body` keeps the screen up to date.
    private var info: CourseInfoStore { .shared }

    private enum ActiveSheet: Identifiable {
        case details
        case export
        case requirementsSetup
        case equivalence(DegreeEquivalenceRequest)
        case reorganize

        var id: String {
            switch self {
            case .details: "details"
            case .export: "export"
            case .requirementsSetup: "requirements-setup"
            case .equivalence(let request): "equivalence-\(request.id)"
            case .reorganize: "reorganize"
            }
        }
    }

    /// Completed lists longer than this start collapsed.
    private static let collapsedThreshold = 8
    /// The list gets its columns at this width.
    private static let columnsMinWidth: CGFloat = 800

    private struct LoadKey: Hashable {
        var selectedTermCode: String?
        var termCount: Int
        var planTermCount: Int
        var isLoading: Bool
    }

    private var loadKey: LoadKey {
        LoadKey(
            selectedTermCode: catalog.selectedTermCode,
            termCount: catalog.terms.count,
            planTermCount: userData.degreePlan(id: planID)?.terms.count ?? 0,
            isLoading: catalog.loadState == .loading
        )
    }

    private struct CourseInfoKey: Hashable {
        var updatedAt: Date?
        var termCodes: [String]
    }

    private var courseInfoKey: CourseInfoKey {
        CourseInfoKey(
            updatedAt: userData.degreePlan(id: planID)?.updatedAt,
            termCodes: catalog.degreePlanSnapshot().indexes.map(\.term.code)
        )
    }

    private var requirementsKey: String {
        let plan = userData.degreePlan(id: planID)
        return "\(plan?.catalogYear ?? 0)|\(plan?.catalogProgramPath ?? "")"
    }

    private var feasibilityKey: String {
        let plan = userData.degreePlan(id: planID)
        let codes = plan?.degreePlanPlannedKeys.map(\.description).sorted().joined(separator: "|") ?? ""
        let terms = catalog.degreePlanSnapshot().indexes.map(\.term.code).sorted().joined(separator: ",")
        return codes + "#" + terms
    }

    private var editor: MacDegreePlanEditor {
        MacDegreePlanEditor(userData: userData, planID: planID, undoManager: undoManager)
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
        .task(id: loadKey) {
            await catalog.degreePlanLoadLocalCatalogs(for: userData.degreePlan(id: planID))
        }
        .task(id: courseInfoKey) {
            // Prerequisites of planned courses the loaded terms don't list, and whether
            // completed courses have been renumbered since.
            await loadCourseInfo()
        }
        .task(id: requirementsKey) {
            // Degree requirements, when set up: the saved copy right away, the catalog when needed.
            if let plan = userData.degreePlan(id: planID), plan.catalogProgramPath != nil {
                await programCatalog.loadRequirements(for: plan)
            }
        }
        .task(id: feasibilityKey) {
            guard let plan = userData.degreePlan(id: planID) else { return }
            await feasibility.loadIfNeeded(plan: plan, indexes: catalog.degreePlanSnapshot().indexes)
        }
    }

    // MARK: Content

    private func content(_ plan: DegreePlan) -> some View {
        let snapshot = catalog.degreePlanSnapshot()
        let review = info.degreePlanReview(for: plan, catalog: snapshot)
        let equivalences = info.equivalences(for: plan)
        let requirements = programCatalog.degreeRequirementsContext(
            for: plan, cache: requirementsCache, equivalences: equivalences, includesMilestone: true
        )
        // With requirements set up, their titles and courses help: a retired course the catalog
        // names can be matched to one of the plan's by title.
        let prompts = suggestionCache.prompts(
            for: plan, dismissed: DegreeEquivalenceDismissals.decode(dismissedSuggestions), info: info, newest: snapshot.reference,
            catalogTitles: requirements.requirements?.courseTitles ?? [:],
            alsoComparing: requirements.requirements?.degreeListedCourses(concentrationID: plan.concentrationID) ?? []
        )

        // The requirements sit beside the plan in a `MacSplitPane`: the share the pane takes is
        // remembered and grows with the window, and in a narrow window the pane floats over the
        // plan instead of making the window wider.
        return MacSplitPane(
            storageKey: "mac.split.degreePlan",
            defaultShare: 0.44,
            paneMinWidth: 340,
            primaryMinWidth: 440,
            maxShare: 0.7,
            isPaneShown: $showsRequirements
        ) {
            planList(plan, snapshot: snapshot, review: review, equivalences: equivalences, requirements: requirements, prompts: prompts)
        } pane: {
            MacDegreeRequirementsContent(
                planID: planID,
                presentation: .pane,
                initialRule: initialRequirement,
                opensInitialRuleDetails: opensRequirementDetails,
                linkedCourses: linkedCourses(in: plan),
                onShowCourseInPlan: { key, semester in showInPlan(key, semester: semester) },
                onOpenPage: { navigator.selection = .degreeRequirements(planID) },
                onClose: { withAnimation(.snappy) { showsRequirements = false } }
            )
        }
        .navigationTitle(plan.name)
        .navigationSubtitle(plan.program ?? "")
        .toolbar { toolbar(plan) }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog(
            "Delete “\(plan.name)”?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Plan", role: .destructive) { deletePlan() }
        } message: {
            Text("The plan and its semesters will be deleted, and with iCloud sync on, from your other devices too. This can’t be undone.")
        }
        .confirmationDialog(
            "Remove student info?",
            isPresented: $confirmsStudentRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Student Info", role: .destructive) { removeStudentInfo() }
        } message: {
            Text("Exported PDFs will no longer include your name and ID.")
        }
        .confirmationDialog(
            termToRemove.map { "Remove \($0.name)?" } ?? "Remove semester?",
            isPresented: Binding(get: { termToRemove != nil }, set: { if !$0 { termToRemove = nil } }),
            titleVisibility: .visible,
            presenting: termToRemove
        ) { term in
            Button("Remove \(term.name)", role: .destructive) { removeTerm(term) }
        } message: { term in
            Text("Its \(DegreePlanText.courses(term.courses.count)) will be removed from this plan.")
        }
        .macDegreeToast($toast)
        .focusedSceneValue(\.macDegreePlan, menuActions(for: plan))
        .focusedSceneValue(\.macSidePane, MacPaneToggle(title: "Requirements", isShown: showsRequirements) {
            withAnimation(.snappy) { showsRequirements.toggle() }
        })
        .focusedSceneValue(\.macExport, MacMenuAction(title: "Export Degree Plan as PDF…") { sheet = .export })
        .focusedSceneValue(\.macPrint, MacMenuAction(title: "Print Degree Plan…") { MacDegreePlanPrinting.print(plan) })
        .focusedSceneValue(\.macDelete, removableCount(in: plan) == 0 ? nil : MacMenuAction(
            title: removableCount(in: plan) == 1 ? "Remove Course" : "Remove \(removableCount(in: plan)) Courses"
        ) { removeCourses(selection) })
        .task {
            // For snapshots: a course selected from the start, to show where it counts.
            guard let initiallySelected, selection.isEmpty else { return }
            showInPlan(initiallySelected, semester: nil)
        }
    }

    /// The plan: its header and checks, a section per semester, the completed courses and the
    /// equivalences.
    private func planList(_ plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot, review: DegreePlanReview,
                          equivalences: CourseEquivalences, requirements: DegreeRequirementsContext,
                          prompts: DegreeEquivalencePrompts) -> some View {
        let report = feasibility.report(for: plan, snapshot: snapshot)
        let termWarning = report.warningLine(milestone: requirements.milestone, plan: plan)
        let lastTermWithCourses = plan.terms.lastIndex { !$0.courses.isEmpty }
        let editor = editor

        return ScrollViewReader { proxy in
            List(selection: $selection) {
                Section {
                    MacDegreePlanHeader(
                        plan: plan,
                        review: review,
                        requirements: requirements,
                        requirementsAreBeside: showsRequirements,
                        notes: headerNotes(plan, snapshot: snapshot, review: review),
                        isLoadingCourseData: !snapshot.hasData && catalog.loadState == .loading,
                        onUsePlan: { setPrimary(plan) },
                        onRetryChecks: { retryCourseInfo() },
                        onSetUpRequirements: { setUpRequirements() },
                        onOpenRequirements: { withAnimation(.snappy) { showsRequirements = true } },
                        onRetryRequirements: { Task { await programCatalog.loadRequirements(for: plan, forceRefresh: true) } },
                        termWarning: termWarning,
                        onReorganize: { sheet = .reorganize }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
                }

                if requirements.milestone == .completed {
                    Section {
                        MacDegreeMilestoneRow(milestone: .completed, hasLaterSemesters: lastTermWithCourses != nil)
                            .selectionDisabled()
                    }
                    .listRowBackground(Color.green.opacity(0.12))
                }

                if plan.degreePlanHasStudentInfo {
                    MacDegreePlanStudentSection(plan: plan) { confirmsStudentRemoval = true }
                }

                ForEach(Array(plan.terms.enumerated()), id: \.element.id) { index, term in
                    MacDegreePlanSemesterSection(
                        plan: plan,
                        term: term,
                        review: review,
                        catalog: snapshot,
                        editor: editor,
                        requirementNote: { requirements.requirementNote(for: $0, semester: term) },
                        onBuildSchedule: { buildSchedule(termID: term.id) },
                        onRemove: { requestRemoval(ofTerm: term.id) },
                        feasibility: report.report(for: term.id),
                        onReorganize: { sheet = .reorganize },
                        onDrop: { items, position in drop(items, onto: term, at: position) }
                    )
                    if let milestone = requirements.milestone, milestone.termID == term.id {
                        // A calm marker between semesters: everything is met after this one.
                        Section {
                            MacDegreeMilestoneRow(milestone: milestone, hasLaterSemesters: (lastTermWithCourses ?? -1) > index)
                                .selectionDisabled()
                        }
                        .listRowBackground(Color.green.opacity(0.12))
                    }
                }

                Section {
                    addSemesterMenu(plan)
                        .selectionDisabled()
                } footer: {
                    if plan.terms.isEmpty {
                        Text("Add the semesters you want to plan, then fill them with courses.")
                    }
                }

                MacDegreePlanCompletedSection(
                    plan: plan,
                    review: review,
                    catalog: snapshot,
                    editor: editor,
                    isExpanded: completedBinding(plan),
                    requirementNote: { requirements.requirementNote(for: $0, semester: nil) },
                    onDrop: { items in dropOnCompleted(items) }
                )

                MacDegreePlanEquivalencesSection(
                    plan: plan,
                    prompts: prompts.forPlanCourses,
                    onConfirm: { confirm($0) },
                    onDismiss: { dismissSuggestion($0) },
                    onEdit: { sheet = .equivalence(DegreeEquivalenceRequest(planID: planID, existing: $0)) },
                    onDelete: { deleteEquivalence($0) },
                    onAdd: { sheet = .equivalence(DegreeEquivalenceRequest(planID: planID)) }
                )
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                courseMenu(for: ids, plan: plan, snapshot: snapshot, review: review, equivalences: equivalences)
            } primaryAction: { ids in
                openCourses(ids, in: plan)
            }
            .onDeleteCommand { removeCourses(selection) }
            // ⌘C copies the selected courses as lines of text: code, title and credits.
            .copyable(copyableCourses(in: plan, snapshot: snapshot))
            .onKeyPress(.return) {
                // Return opens the selected courses, like a double-click.
                guard !selection.isEmpty else { return .ignored }
                openCourses(selection, in: plan)
                return .handled
            }
            // A course clicked in the requirements: bring it into view.
            .task(id: scrollRequest) {
                guard let id = scrollRequest else { return }
                // (The completed list may have just opened.)
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                // A long list sizes the rows it hasn't shown yet as it scrolls, so once they have
                // settled the course may not be quite in the middle: scroll once more.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                scrollRequest = nil
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            let layout: MacDegreePlanRowLayout = width >= Self.columnsMinWidth ? .columns : .compact
            if layout != rowLayout { rowLayout = layout }
        }
        .environment(\.macPlanRowLayout, rowLayout)
    }

    // MARK: Requirements beside the plan

    /// The keys of the selected courses: the requirements mark where they count.
    private func linkedCourses(in plan: DegreePlan) -> Set<CourseKey> {
        guard !selection.isEmpty else { return [] }
        let chosen = plan.terms.flatMap(\.courses) + plan.completed
        return Set(chosen.filter { selection.contains($0.id) }.compactMap(\.key))
    }

    /// Selects a course a requirement shows, and scrolls to it: the one planned in `semester`
    /// when it's taken more than once, else the planned one, else the completed one.
    private func showInPlan(_ key: CourseKey, semester: String?) {
        guard let plan = userData.degreePlan(id: planID) else { return }
        let planned = plan.terms.flatMap { term in term.courses.filter { $0.key == key }.map { (term: term, course: $0) } }
        let completed = plan.completed.first { $0.key == key }
        let target: DegreePlanCourse?
        if semester == nil, let completed {
            target = completed
        } else {
            target = planned.first { $0.term.name == semester }?.course ?? planned.first?.course ?? completed
        }
        guard let target else { return }
        if plan.completed.contains(where: { $0.id == target.id }) { completedExpansion = true }
        selection = [target.id]
        scrollRequest = target.id
    }

    private func setUpRequirements() {
        sheet = .requirementsSetup
    }

    /// What the Degree Plan menu does for this plan.
    private func menuActions(for plan: DegreePlan) -> MacDegreePlanMenuActions {
        MacDegreePlanMenuActions(
            planName: plan.name,
            isPrimary: plan.isPrimary,
            nextSemesters: DegreePlanAutofill.nextSemesters(after: plan),
            semesters: plan.terms,
            hasPlannedSelection: plan.terms.contains { term in term.courses.contains { selection.contains($0.id) } },
            addSemester: { addSemester($0) },
            moveSelection: { moveCourses(selection, toTerm: $0) },
            markSelectionCompleted: { markCompleted(selection) },
            showRequirements: { navigator.selection = .degreeRequirements(planID) },
            setPrimary: { setPrimary(plan) },
            editDetails: { sheet = .details },
            addEquivalence: { sheet = .equivalence(DegreeEquivalenceRequest(planID: planID)) },
            duplicate: { duplicate(plan) }
        )
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .details:
            MacDegreePlanDetailsSheet(planID: planID)
        case .export:
            MacDegreePlanExportSheet(planID: planID)
        case .requirementsSetup:
            MacDegreeRequirementsSetupSheet(planID: planID)
        case .equivalence(let request):
            MacDegreeEquivalenceSheet(request: request)
        case .reorganize:
            reorganizeSheet
        }
    }

    @ViewBuilder
    private var reorganizeSheet: some View {
        if let plan = userData.degreePlan(id: planID) {
            let snapshot = catalog.degreePlanSnapshot()
            let report = feasibility.report(for: plan, snapshot: snapshot)
            DegreePlanReorganizeSheet(
                plan: plan,
                hasKnownProblem: !report.infeasibleTerms.isEmpty,
                load: { await proposeReorganization(of: plan) },
                onAccept: { applyReorganization($0) }
            )
        }
    }

    private func proposeReorganization(of plan: DegreePlan) async -> DegreePlanReorganization.Proposal? {
        await DegreePlanReorganization.propose(
            plan: plan,
            info: info,
            requirements: programCatalog.requirements(for: plan),
            snapshot: catalog.degreePlanSnapshot()
        )
    }

    private func applyReorganization(_ changes: [DegreePlanReorganization.Change]) {
        let count = changes.count
        editor.perform(count == 1 ? "Reorganize 1 Course" : "Reorganize \(count) Courses") { plan in
            plan.terms = DegreePlanReorganization.applying(changes, to: plan).terms
        }
    }

    // MARK: Header notes

    /// Notes under the header: why prerequisite checks may be missing, and which semesters can't
    /// have a schedule built yet.
    private func headerNotes(_ plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot, review: DegreePlanReview) -> [String] {
        var notes: [String] = []
        let isLoading = !snapshot.hasData && catalog.loadState == .loading
        // Without a catalog on this Mac, courses are looked up in Banner; say what helps only
        // when that didn't work.
        if !snapshot.hasData, !isLoading, review.failedCount > 0 {
            notes.append("Prerequisite checks need course data: connect to the internet, or download a term’s catalog.")
        }
        if let unposted = unpostedNote(plan, snapshot: snapshot) { notes.append(unposted) }
        return notes
    }

    private func unpostedNote(_ plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot) -> String? {
        guard !snapshot.terms.isEmpty else { return nil }
        let unposted = plan.terms.filter { !$0.courses.isEmpty && !$0.degreePlanHasEnded() && snapshot.bannerTerm(for: $0) == nil }
        guard let first = unposted.first else { return nil }
        if unposted.count == 1 {
            return "\(first.name) isn’t on Banner yet. Northeastern usually posts a semester a few weeks before registration, and you can build its schedule then."
        }
        let others = unposted.count - 1
        return "\(first.name) and \(others) other \(others == 1 ? "semester aren’t" : "semesters aren’t") on Banner yet. Northeastern usually posts a semester a few weeks before registration, and you can build their schedules then."
    }

    // MARK: Add semester

    private func addSemesterMenu(_ plan: DegreePlan) -> some View {
        Menu {
            addSemesterItems(plan)
        } label: {
            Label("Add Semester", systemImage: "plus.circle.fill")
                .font(.body.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func addSemesterItems(_ plan: DegreePlan) -> some View {
        ForEach(DegreePlanAutofill.nextSemesters(after: plan), id: \.name) { semester in
            Button(semester.name) { addSemester(semester) }
        }
    }

    private func completedBinding(_ plan: DegreePlan) -> Binding<Bool> {
        let defaultValue = plan.completed.count <= Self.collapsedThreshold
        return Binding(
            get: { completedExpansion ?? defaultValue },
            set: { completedExpansion = $0 }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ plan: DegreePlan) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                addSemesterItems(plan)
            } label: {
                Label("Add Semester", systemImage: "calendar.badge.plus")
            }
            .help("Add a semester to the plan")
            Button {
                sheet = .export
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the plan as a PDF (⌘E)")
            Menu {
                Section {
                    Button {
                        sheet = .export
                    } label: {
                        Label("Export as PDF…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        copyAsText(plan)
                    } label: {
                        Label("Copy as Text", systemImage: "doc.on.doc")
                    }
                }
                Section {
                    Button {
                        sheet = .details
                    } label: {
                        Label("Rename or Edit Program…", systemImage: "pencil")
                    }
                    Button {
                        sheet = .equivalence(DegreeEquivalenceRequest(planID: planID))
                    } label: {
                        Label("Add Course Equivalence…", systemImage: "equal.circle")
                    }
                    Button {
                        sheet = .requirementsSetup
                    } label: {
                        Label(plan.catalogProgramPath == nil ? "Set Up Degree Requirements…" : "Change Degree Requirements…", systemImage: "checklist")
                    }
                    Button {
                        duplicate(plan)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button {
                        setPrimary(plan)
                    } label: {
                        Label(
                            plan.isPrimary ? "Used for Prerequisite Checks" : "Use for Prerequisite Checks",
                            systemImage: plan.isPrimary ? "star.fill" : "star"
                        )
                    }
                    .disabled(plan.isPrimary)
                }
                Section {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Delete Plan…", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions for this plan")
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showsRequirements.animation(.snappy)) {
                Label("Requirements", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the requirements beside the plan (⌥⌘0)")
        }
    }

    // MARK: Context menu

    /// What a course's context menu offers: a single course gets everything; several selected
    /// courses can be moved, completed or removed together.
    @ViewBuilder
    private func courseMenu(for ids: Set<UUID>, plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot,
                            review: DegreePlanReview, equivalences: CourseEquivalences) -> some View {
        let planned = plan.terms.flatMap { term in term.courses.filter { ids.contains($0.id) }.map { (term: term, course: $0) } }
        let completed = plan.completed.filter { ids.contains($0.id) }
        if let equivalence = plan.courseEquivalences.first(where: { ids.contains($0.id) }) {
            // A declared equivalence's row (its own list rows aren't selectable, but have a menu).
            Button("Edit…") { sheet = .equivalence(DegreeEquivalenceRequest(planID: planID, existing: equivalence)) }
            Divider()
            Button("Delete", role: .destructive) { deleteEquivalence(equivalence) }
        } else if planned.count + completed.count == 1, let entry = planned.first {
            let course = entry.course
            let term = entry.term
            if let key = course.key, snapshot.routeTermCode(for: key, in: term) != nil {
                Button("Open Course in New Window", systemImage: "book") { openCourse(course, in: term) }
                Divider()
            }
            moveMenu(for: [course.id], plan: plan, excluding: [term.id])
            Button("Mark as Completed", systemImage: "checkmark.circle") { markCompleted([course.id]) }
            if let replacement = replacement(for: course, in: term, review: review, equivalences: equivalences) {
                Button("Replace with \(replacement.description)", systemImage: "arrow.triangle.2.circlepath") {
                    replace(course, with: replacement)
                }
            }
            if let key = course.key {
                Button("Counts as Another Course…", systemImage: "equal.circle") {
                    sheet = .equivalence(DegreeEquivalenceRequest(planID: planID, course: key))
                }
            }
            if plan.catalogProgramPath != nil, !showsRequirements {
                Button("Show Where It Counts", systemImage: "checklist") {
                    withAnimation(.snappy) { showsRequirements = true }
                }
            }
            if review.uncheckedReason(for: course) == .failed {
                Button("Check Prerequisites Again", systemImage: "arrow.clockwise") { retryCourseInfo() }
            }
            Divider()
            Button("Remove from \(term.name)", systemImage: "trash", role: .destructive) { removeCourses([course.id]) }
        } else if planned.isEmpty, completed.count == 1, let course = completed.first {
            if let key = course.key, snapshot.routeTermCode(for: key) != nil {
                Button("Open Course in New Window", systemImage: "book") { openCourse(course, in: nil) }
                Divider()
            }
            if let key = course.key {
                Button("Counts as Another Course…", systemImage: "equal.circle") {
                    sheet = .equivalence(DegreeEquivalenceRequest(planID: planID, course: key))
                }
                Divider()
            }
            Button("Remove from Completed", systemImage: "trash", role: .destructive) { removeCourses([course.id]) }
        } else if !planned.isEmpty || !completed.isEmpty {
            if !planned.isEmpty {
                moveMenu(for: Set(planned.map(\.course.id)), plan: plan, excluding: [])
                Button("Mark as Completed", systemImage: "checkmark.circle") { markCompleted(Set(planned.map(\.course.id))) }
                Divider()
            }
            Button("Remove \(planned.count + completed.count) Courses", systemImage: "trash", role: .destructive) { removeCourses(ids) }
        }
    }

    @ViewBuilder
    private func moveMenu(for ids: Set<UUID>, plan: DegreePlan, excluding excluded: Set<UUID>) -> some View {
        let others = plan.terms.filter { !excluded.contains($0.id) }
        if !others.isEmpty {
            Menu {
                ForEach(others) { other in
                    Button(other.name) { moveCourses(ids, toTerm: other.id) }
                }
            } label: {
                Label("Move to", systemImage: "arrow.right.circle")
            }
        }
    }

    // MARK: Course actions

    private func courseName(_ course: DegreePlanCourse) -> String {
        course.key?.description ?? course.label
    }

    /// The selected courses as text, one line each (`CS 3500⇥Object-Oriented Design⇥4`), planned
    /// ones in plan order, then completed ones.
    private func copyableCourses(in plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot) -> [String] {
        let chosen = plan.terms.flatMap(\.courses) + plan.completed
        return chosen.filter { selection.contains($0.id) }.map { course in
            [course.key?.description ?? course.label, snapshot.title(for: course), DegreePlanText.number(course.credits)].joined(separator: "\t")
        }
    }

    /// How many selected courses exist in the plan, to enable Edit › Delete.
    private func removableCount(in plan: DegreePlan) -> Int {
        let planned = plan.terms.reduce(0) { $0 + $1.courses.filter { selection.contains($0.id) }.count }
        return planned + plan.completed.filter { selection.contains($0.id) }.count
    }

    private func openCourse(_ course: DegreePlanCourse, in term: DegreePlanTerm?) {
        guard let key = course.key,
              let termCode = catalog.degreePlanSnapshot().routeTermCode(for: key, in: term) else { return }
        openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
    }

    /// Double-click or Return: opens the selected courses, each in its own window.
    private func openCourses(_ ids: Set<UUID>, in plan: DegreePlan) {
        for term in plan.terms {
            for course in term.courses where ids.contains(course.id) { openCourse(course, in: term) }
        }
        for course in plan.completed where ids.contains(course.id) { openCourse(course, in: nil) }
    }

    private func removeCourses(_ ids: Set<UUID>) {
        guard let plan = userData.degreePlan(id: planID) else { return }
        let planned = plan.terms.flatMap(\.courses).filter { ids.contains($0.id) }
        let completed = plan.completed.filter { ids.contains($0.id) }
        let count = planned.count + completed.count
        guard count > 0 else { return }
        let name = count == 1 ? "Remove \(courseName((planned + completed)[0]))" : "Remove \(count) Courses"
        editor.perform(name) { plan in
            for course in planned { DegreePlanEditing.removePlannedCourse(course.id, from: &plan) }
            for course in completed { DegreePlanEditing.removeCompletedCourse(course.id, from: &plan) }
        }
        selection.subtract(ids)
    }

    private func moveCourses(_ ids: Set<UUID>, toTerm termID: UUID) {
        guard let plan = userData.degreePlan(id: planID), let destination = plan.terms.first(where: { $0.id == termID }) else { return }
        let moving = plan.terms.flatMap(\.courses).filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let name = moving.count == 1 ? "Move \(courseName(moving[0])) to \(destination.name)" : "Move \(moving.count) Courses to \(destination.name)"
        editor.perform(name) { plan in
            for course in moving { DegreePlanEditing.move(course.id, toTerm: termID, in: &plan) }
        }
    }

    private func markCompleted(_ ids: Set<UUID>) {
        guard let plan = userData.degreePlan(id: planID) else { return }
        let moving = plan.terms.flatMap(\.courses).filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let name = moving.count == 1 ? "Mark \(courseName(moving[0])) Completed" : "Mark \(moving.count) Courses Completed"
        editor.perform(name) { plan in
            for course in moving { DegreePlanEditing.markCompleted(course.id, in: &plan) }
        }
        selection.subtract(ids)
    }

    /// A drop on a semester, at a position between its courses or at its end: planned courses
    /// moving there from another semester, or courses the requirements need being added to it.
    private func drop(_ items: [MacDegreeCourseDrag], onto term: DegreePlanTerm, at position: Int?) -> Bool {
        guard let plan = userData.degreePlan(id: planID) else { return false }
        let mine = items.filter { $0.planID == planID }
        let moves = mine.compactMap(\.courseID)
        let additions = mine.compactMap(\.addition)
        guard !moves.isEmpty || !additions.isEmpty else { return false }

        let name: String
        let toastText: String?
        if moves.isEmpty {
            name = additions.count == 1 ? "Add \(additions[0].key) to \(term.name)" : "Add \(additions.count) Courses to \(term.name)"
            toastText = additions.count == 1 ? "Added \(additions[0].key) to \(term.shortName)" : "Added \(additions.count) courses to \(term.shortName)"
        } else if additions.isEmpty {
            let first = mine.first { $0.courseID != nil }?.summary.components(separatedBy: " ").prefix(2).joined(separator: " ") ?? "Course"
            name = moves.count == 1 ? "Move \(first) to \(term.name)" : "Move \(moves.count) Courses to \(term.name)"
            toastText = nil
        } else {
            name = "Move \(moves.count + additions.count) Courses to \(term.name)"
            toastText = nil
        }

        var addedIDs: [UUID] = []
        editor.perform(name) { plan in
            var index = position ?? plan.terms.first { $0.id == term.id }?.courses.count ?? 0
            for item in mine {
                if let courseID = item.courseID {
                    DegreePlanEditing.move(courseID, toTerm: term.id, at: index, in: &plan)
                    index += 1
                } else if let addition = item.addition {
                    let course = DegreePlanCourse(key: addition.key, title: addition.title, credits: addition.credits)
                    DegreePlanEditing.add(course, toTerm: term.id, in: &plan)
                    DegreePlanEditing.move(course.id, toTerm: term.id, at: index, in: &plan)
                    addedIDs.append(course.id)
                    index += 1
                }
            }
        }
        if let toastText {
            toast = MacDegreeToast(text: toastText, systemImage: "calendar.badge.plus")
            // The new course is selected, so the requirements show where it counts now.
            selection = Set(addedIDs)
        }
        return true
    }

    /// A drop of planned courses on the completed courses marks them completed.
    private func dropOnCompleted(_ items: [MacDegreeCourseDrag]) -> Bool {
        let ids = Set(items.filter { $0.planID == planID }.compactMap(\.courseID))
        guard !ids.isEmpty else { return false }
        markCompleted(ids)
        return true
    }

    /// For a planned course that is no longer offered: a course it counts as that is still
    /// offered (and isn't in that semester already).
    private func replacement(for course: DegreePlanCourse, in term: DegreePlanTerm, review: DegreePlanReview,
                             equivalences: CourseEquivalences) -> CourseKey? {
        guard let key = course.key, review.offeringNote(for: course) != nil else { return nil }
        let present = Set(term.courses.compactMap(\.key))
        return equivalences.equivalents(of: key).sorted().first { !present.contains($0) && !info.state(for: $0).degreeIsRetired }
    }

    /// Plans the replacement in the course's place.
    private func replace(_ course: DegreePlanCourse, with key: CourseKey) {
        let snapshot = catalog.degreePlanSnapshot()
        let title = snapshot.course(key)?.title.nilIfBlank ?? info.info(for: key)?.title.nilIfBlank ?? key.description
        let credits = snapshot.course(key)?.defaultChoiceCredits ?? info.info(for: key).flatMap { info in
            guard let low = info.minCredits ?? info.maxCredits else { return nil as Double? }
            return CreditSpan(low: low, high: info.maxCredits ?? low, bannerDefault: nil).defaultChoice()
        } ?? course.credits
        let replacement = DegreePlanCourse(key: key, title: DegreePlanFormat.exportTitle(title), credits: credits)
        editor.perform("Replace \(courseName(course)) with \(key)") {
            DegreePlanEditing.replacePlannedCourse(course.id, with: replacement, in: &$0)
        }
    }

    // MARK: Semesters

    private func requestRemoval(ofTerm termID: UUID) {
        guard let term = userData.degreePlan(id: planID)?.terms.first(where: { $0.id == termID }) else { return }
        if term.courses.isEmpty {
            removeTerm(term)
        } else {
            termToRemove = term
        }
    }

    private func removeTerm(_ term: DegreePlanTerm) {
        editor.perform("Remove \(term.name)") { DegreePlanEditing.removeTerm(term.id, from: &$0) }
    }

    private func addSemester(_ semester: DegreePlanTerm) {
        editor.perform("Add \(semester.name)") { DegreePlanEditing.addTerm(semester, to: &$0) }
    }

    // MARK: Course information and equivalences

    private func loadCourseInfo() async {
        guard let plan = userData.degreePlan(id: planID) else { return }
        await info.degreePlanLoad(plan, indexes: catalog.degreePlanSnapshot().indexes)
    }

    /// Looks up again what couldn't be looked up. Banner isn't asked again about a course for a
    /// minute after it failed, so say so when that's why nothing changed.
    private func retryCourseInfo() {
        Task {
            await loadCourseInfo()
            guard let plan = userData.degreePlan(id: planID) else { return }
            if plan.degreePlanPlannedKeys.contains(where: { info.state(for: $0) == .failed }) {
                toast = MacDegreeToast(text: "Couldn’t reach Banner. Try again in a minute.", systemImage: "wifi.exclamationmark")
            }
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

    private func deleteEquivalence(_ equivalence: CourseEquivalence) {
        editor.perform("Delete Equivalence", touching: .equivalences) { $0.removeEquivalence(id: equivalence.id) }
    }

    // MARK: Build schedule

    /// Creates a schedule for the semester's Banner term from the semester's courses, then
    /// opens it in the Schedules area.
    private func buildSchedule(termID: UUID) {
        guard !isBuildingSchedule,
              let plan = userData.degreePlan(id: planID),
              let semester = plan.terms.first(where: { $0.id == termID }),
              let bannerTerm = catalog.degreePlanSnapshot().bannerTerm(for: semester) else { return }

        // Reuse a schedule in that term that already holds exactly these courses.
        guard let result = userData.scheduleForDegreePlan(semester, termCode: bannerTerm.code) else { return }
        let schedule = result.plan
        isBuildingSchedule = true
        if result.isNew {
            toast = MacDegreeToast(text: "Created “\(schedule.name)” with \(DegreePlanText.courses(result.courseCount))", systemImage: "calendar.badge.plus")
        } else {
            toast = MacDegreeToast(text: "Opening “\(schedule.name)”", systemImage: "calendar")
        }

        Task {
            // Make the schedule's term the one being browsed, when its catalog is on this Mac.
            if await catalog.hasLocalCatalog(bannerTerm.code) {
                await catalog.select(termCode: bannerTerm.code)
                userData.preferences.selectedTermCode = bannerTerm.code
            }
            isBuildingSchedule = false
            navigator.selection = .schedule(schedule.id)
        }
    }

    // MARK: Plan actions

    private func setPrimary(_ plan: DegreePlan) {
        guard !plan.isPrimary else { return }
        userData.setPrimaryDegreePlan(id: plan.id)
        toast = MacDegreeToast(text: "Using “\(plan.name)” for prerequisite checks", systemImage: "star.fill")
    }

    private func duplicate(_ plan: DegreePlan) {
        let copy = DegreePlanEditing.duplicate(plan, existingNames: userData.degreePlans.map(\.name))
        let stored = userData.addDegreePlan(copy)
        navigator.selection = .degreePlan(stored.id)
    }

    private func deletePlan() {
        userData.deleteDegreePlan(id: planID)
        navigator.selection = .degreePlans
    }

    private func removeStudentInfo() {
        editor.perform("Remove Student Info", touching: .student) { DegreePlanEditing.removeStudentInfo(from: &$0) }
    }

    private func copyAsText(_ plan: DegreePlan) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DegreePlanFormat.text(for: plan, includeStudent: false), forType: .string)
        toast = MacDegreeToast(text: "Copied plan as text", systemImage: "doc.on.doc.fill")
    }
}
