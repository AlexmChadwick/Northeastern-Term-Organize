//
//  DegreePlanView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// A degree plan: its totals, the student's info (when kept), one section per planned
/// semester with prerequisite checks, and the completed courses. Pushed in the
/// Schedule tab's stack (`AppRoute.degreePlan`).
struct DegreePlanView: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var sheet: ActiveSheet?
    @State private var isEditingDetails = false
    @State private var draftName = ""
    @State private var draftProgram = ""
    @State private var confirmsDelete = false
    @State private var confirmsStudentRemoval = false
    @State private var termToRemove: DegreePlanTerm?
    /// nil until the user opens or closes the completed list; then their choice wins.
    @State private var completedExpansion: Bool?
    @State private var isBuildingSchedule = false
    @State private var toast: DegreePlanToast?
    @State private var haptic = DegreePlanHaptic()
    /// Remembers the requirements audit and finish milestone between updates.
    @State private var requirementsCache = DegreeRequirementsCache()
    /// Offering history used to tell when a planned semester can't be taken.
    @State private var feasibility = DegreePlanFeasibilityModel()
    @State private var suggestionCache = DegreeEquivalenceSuggestionCache()
    @AppStorage(DegreeEquivalenceDismissals.storageKey) private var dismissedSuggestions = ""
    /// How wide this screen is, to know whether the requirements fit beside the plan.
    @State private var screenWidth: CGFloat = 0
    /// Whether a wide iPad shows the requirements beside the plan (remembered).
    @AppStorage("degreePlan.showsRequirementsPane") private var showsRequirementsPane = true

    /// The requirements sit beside the plan from this width on (an iPad in landscape, say), where
    /// both lists keep a comfortable width. Narrower screens, and every iPhone, push them instead.
    #if DEBUG
    static var splitMinWidth: CGFloat { IOSDegreeSamples.splitWidth ?? 1000 }
    #else
    static let splitMinWidth: CGFloat = 1000
    #endif

    /// Banner's course catalog for courses the loaded terms don't list (prerequisites,
    /// retired courses, equivalences). Reading it in `body` keeps the screen up to date.
    private var info: CourseInfoStore { .shared }

    private enum ActiveSheet: Identifiable {
        case addCourse(termID: UUID)
        case export
        case requirementsSetup
        case equivalence(DegreeEquivalenceRequest)
        case reorganize

        var id: String {
            switch self {
            case .addCourse(let termID): "add-\(termID)"
            case .export: "export"
            case .requirementsSetup: "requirements-setup"
            case .equivalence(let request): "equivalence-\(request.id)"
            case .reorganize: "reorganize"
            }
        }
    }

    /// Completed lists longer than this start collapsed.
    private static let collapsedThreshold = 8

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
                .navigationBarTitleDisplayMode(.inline)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
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

    // MARK: Content

    private func content(_ plan: DegreePlan) -> some View {
        let snapshot = catalog.degreePlanSnapshot()
        let review = info.degreePlanReview(for: plan, catalog: snapshot)
        let actions = makeActions()
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
        let report = feasibility.report(for: plan, snapshot: snapshot)
        let termWarning = report.warningLine(milestone: requirements.milestone, plan: plan)
        let lastTermWithCourses = plan.terms.lastIndex { !$0.courses.isEmpty }
        // A wide iPad can show the requirements beside the plan, once they are set up.
        let canSplit = sizeClass == .regular && screenWidth >= Self.splitMinWidth && requirements.isSetUp
        let showsSplit = canSplit && showsRequirementsPane

        let list = List {
            Section {
                DegreePlanHeaderCard(
                    plan: plan, review: review, onUsePlan: { setPrimary(plan) }, onRetryChecks: { retryCourseInfo() },
                    termWarning: termWarning, onReorganize: { sheet = .reorganize }
                )
            } footer: {
                headerFooter(plan, snapshot: snapshot, review: review)
            }

            // Beside the plan, the requirements pane says all of this.
            if !showsSplit {
                DegreeRequirementsEntrySection(
                    context: requirements,
                    blockedFinish: termWarning,
                    onSetUp: { sheet = .requirementsSetup },
                    onRetry: { Task { await programCatalog.loadRequirements(for: plan, forceRefresh: true) } }
                )
            }

            if requirements.milestone == .completed {
                Section {
                    DegreeMilestoneBanner(milestone: .completed, hasLaterSemesters: lastTermWithCourses != nil)
                }
                .listRowBackground(Color.green.opacity(0.12))
            }

            if plan.degreePlanHasStudentInfo {
                DegreePlanStudentSection(plan: plan) { confirmsStudentRemoval = true }
            }

            ForEach(Array(plan.terms.enumerated()), id: \.element.id) { index, term in
                DegreePlanSemesterSection(
                    plan: plan, term: term, review: review, catalog: snapshot, actions: actions,
                    requirementNote: { requirements.requirementNote(for: $0, semester: term) },
                    replacement: { replacement(for: $0, in: term, review: review, equivalences: equivalences) },
                    feasibility: report.report(for: term.id),
                    onReorganize: { sheet = .reorganize }
                )
                if let milestone = requirements.milestone, milestone.termID == term.id {
                    // A calm marker between semesters: everything is met after this one.
                    Section {
                        DegreeMilestoneBanner(milestone: milestone, hasLaterSemesters: (lastTermWithCourses ?? -1) > index)
                    }
                    .listRowBackground(Color.green.opacity(0.12))
                }
            }

            Section {
                addSemesterMenu(plan)
            } footer: {
                if plan.terms.isEmpty {
                    Text("Add the semesters you want to plan, then fill them with courses.")
                }
            }

            DegreePlanCompletedSection(
                plan: plan,
                review: review,
                catalog: snapshot,
                isExpanded: completedBinding(plan),
                actions: actions,
                requirementNote: { requirements.requirementNote(for: $0, semester: nil) }
            )

            DegreePlanEquivalencesSection(
                plan: plan,
                prompts: prompts.forPlanCourses,
                onConfirm: { confirm($0) },
                onDismiss: { dismissSuggestion($0) },
                onEdit: { sheet = .equivalence(DegreeEquivalenceRequest(planID: planID, existing: $0)) },
                onDelete: { deleteEquivalence($0) },
                onAdd: { sheet = .equivalence(DegreeEquivalenceRequest(planID: planID)) }
            )
        }
        .listStyle(.insetGrouped)
        .degreePlanToast($toast)

        return splitContainer(list, showsSplit: showsSplit)
        .navigationTitle(plan.name)
        .navigationSubtitle(plan.program ?? "")
        .navigationBarTitleDisplayMode(showsSplit ? .inline : .large)
        .toolbar { toolbar(plan, canSplit: canSplit, showsSplit: showsSplit) }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet)
        }
        .modifier(DegreePlanDialogs(
            plan: plan,
            isEditingDetails: $isEditingDetails,
            draftName: $draftName,
            draftProgram: $draftProgram,
            confirmsDelete: $confirmsDelete,
            confirmsStudentRemoval: $confirmsStudentRemoval,
            termToRemove: $termToRemove,
            onSaveDetails: { saveDetails() },
            onDelete: { deletePlan() },
            onRemoveStudentInfo: { removeStudentInfo() },
            onRemoveTerm: { removeTerm($0) }
        ))
        .degreePlanHaptic(haptic)
    }

    /// The plan, with the requirements beside it when they fit: both read the same plan, so a change
    /// in either shows in both.
    @ViewBuilder
    private func splitContainer<Plan: View>(_ plan: Plan, showsSplit: Bool) -> some View {
        if showsSplit {
            HStack(spacing: 0) {
                plan
                    .frame(maxWidth: .infinity)
                Divider()
                DegreeRequirementsView(planID: planID, isEmbedded: true, sharedCache: requirementsCache)
                    .frame(maxWidth: .infinity)
            }
        } else {
            plan
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .addCourse(let termID):
            DegreePlanAddCourseSheet(planID: planID, termID: termID)
        case .export:
            DegreePlanExportSheet(planID: planID)
        case .requirementsSetup:
            DegreeRequirementsSetupSheet(planID: planID)
        case .equivalence(let request):
            DegreeEquivalenceSheet(request: request)
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

    // MARK: Header footer

    /// Notes under the header: why prerequisite checks may be missing, and which
    /// semesters can't have a schedule built yet.
    @ViewBuilder
    private func headerFooter(_ plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot, review: DegreePlanReview) -> some View {
        let isLoading = !snapshot.hasData && catalog.loadState == .loading
        // Without a catalog on the device, courses are looked up in Banner; say what helps
        // only when that didn't work.
        let needsData = !snapshot.hasData && !isLoading && review.failedCount > 0
        let unposted = unpostedNote(plan, snapshot: snapshot)
        if isLoading || needsData || unposted != nil {
            VStack(alignment: .leading, spacing: 6) {
                if isLoading {
                    Label("Loading course data for prerequisite checks…", systemImage: "hourglass")
                }
                if needsData {
                    Text("Prerequisite checks need course data: connect to the internet, or download a term’s catalog.")
                }
                if let unposted {
                    Text(unposted)
                }
            }
        }
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
        let options = DegreePlanAutofill.nextSemesters(after: plan)
        return Menu {
            ForEach(options, id: \.name) { semester in
                Button(semester.name) { addSemester(semester) }
            }
        } label: {
            Label("Add semester", systemImage: "plus.circle.fill")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
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
    private func toolbar(_ plan: DegreePlan, canSplit: Bool, showsSplit: Bool) -> some ToolbarContent {
        if canSplit {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { showsRequirementsPane.toggle() }
                } label: {
                    Label(showsSplit ? "Hide requirements" : "Show requirements", systemImage: "sidebar.trailing")
                }
                .accessibilityHint(showsSplit ? "Closes the requirements beside the plan" : "Shows the requirements beside the plan")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button {
                        sheet = .export
                    } label: {
                        Label("Export PDF…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        copyAsText(plan)
                    } label: {
                        Label("Copy as text", systemImage: "doc.on.doc")
                    }
                }
                Section {
                    Button {
                        startEditing(plan)
                    } label: {
                        Label("Rename or edit program…", systemImage: "pencil")
                    }
                    Button {
                        sheet = .equivalence(DegreeEquivalenceRequest(planID: planID))
                    } label: {
                        Label("Add course equivalence…", systemImage: "equal.circle")
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
                            plan.isPrimary ? "Used for prerequisite checks" : "Use for prerequisite checks",
                            systemImage: plan.isPrimary ? "star.fill" : "star"
                        )
                    }
                    .disabled(plan.isPrimary)
                }
                Section {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Delete plan…", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Actions from rows

    private func makeActions() -> DegreePlanActions {
        DegreePlanActions(
            addCourse: { termID in sheet = .addCourse(termID: termID) },
            buildSchedule: { termID in buildSchedule(termID: termID) },
            removeSemester: { termID in requestRemoval(ofTerm: termID) },
            removePlanned: { course in
                performUndoable("Removed \(courseName(course))") { DegreePlanEditing.removePlannedCourse(course.id, from: &$0) }
            },
            removeCompleted: { course in
                performUndoable("Removed \(courseName(course))") { DegreePlanEditing.removeCompletedCourse(course.id, from: &$0) }
            },
            move: { courseID, termID in move(courseID, toTerm: termID) },
            markCompleted: { course in
                performUndoable("Moved \(courseName(course)) to completed", systemImage: "checkmark.circle.fill") {
                    DegreePlanEditing.markCompleted(course.id, in: &$0)
                }
            },
            retryChecks: { retryCourseInfo() },
            addEquivalence: { key in sheet = .equivalence(DegreeEquivalenceRequest(planID: planID, course: key)) },
            replaceCourse: { course, key in replace(course, with: key) },
            setCredits: { courseID, credits in
                performUndoable("Changed credits", systemImage: "plusminus") {
                    DegreePlanEditing.setCredits(courseID, to: credits, in: &$0)
                }
                userData.syncChosenCredits(fromDegreePlan: planID)
            }
        )
    }

    private func courseName(_ course: DegreePlanCourse) -> String {
        course.key?.description ?? course.label
    }

    /// Applies an edit and offers to undo it for a few seconds. Undo puts back the parts of
    /// the plan an edit can change (semesters, completed courses, student info), so it
    /// never undoes a rename or other change made in the meantime.
    private func performUndoable(_ message: String, systemImage: String = "trash.fill", _ change: (inout DegreePlan) -> Void) {
        guard let before = userData.degreePlan(id: planID) else { return }
        withAnimation { userData.updateDegreePlan(id: planID, change) }
        userData.syncChosenCredits(fromDegreePlan: planID)
        haptic.fire(.impact)
        toast = DegreePlanToast(text: message, systemImage: systemImage, actionTitle: "Undo") {
            withAnimation {
                userData.updateDegreePlan(id: planID) { plan in
                    plan.terms = before.terms
                    plan.completed = before.completed
                    plan.studentName = before.studentName
                    plan.studentID = before.studentID
                }
                userData.syncChosenCredits(fromDegreePlan: planID)
            }
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
        performUndoable(
            count == 1 ? "Reorganized 1 course" : "Reorganized \(count) courses",
            systemImage: "arrow.triangle.2.circlepath"
        ) { plan in
            plan.terms = DegreePlanReorganization.applying(changes, to: plan).terms
        }
    }

    private func move(_ courseID: UUID, toTerm termID: UUID) {
        guard let destination = userData.degreePlan(id: planID)?.terms.first(where: { $0.id == termID }) else { return }
        performUndoable("Moved to \(destination.name)", systemImage: "arrow.right.circle.fill") {
            DegreePlanEditing.move(courseID, toTerm: termID, in: &$0)
        }
    }

    private func requestRemoval(ofTerm termID: UUID) {
        guard let term = userData.degreePlan(id: planID)?.terms.first(where: { $0.id == termID }) else { return }
        if term.courses.isEmpty {
            removeTerm(term)
        } else {
            termToRemove = term
        }
    }

    private func removeTerm(_ term: DegreePlanTerm) {
        performUndoable("Removed \(term.name)") { DegreePlanEditing.removeTerm(term.id, from: &$0) }
    }

    private func addSemester(_ semester: DegreePlanTerm) {
        withAnimation { userData.updateDegreePlan(id: planID) { DegreePlanEditing.addTerm(semester, to: &$0) } }
        haptic.fire(.success)
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
                toast = DegreePlanToast(text: "Couldn’t reach Banner. Try again in a minute.", systemImage: "wifi.exclamationmark")
            }
        }
    }

    /// For a planned course that is no longer offered: a course it counts as that is still
    /// offered (and isn't in that semester already).
    private func replacement(for course: DegreePlanCourse, in term: DegreePlanTerm, review: DegreePlanReview,
                             equivalences: CourseEquivalences) -> CourseKey? {
        guard let key = course.key, review.offeringNote(for: course) != nil else { return nil }
        let present = Set(term.courses.compactMap(\.key))
        return equivalences.equivalents(of: key).sorted().first { !present.contains($0) && !info.state(for: $0).degreeIsRetired }
    }

    /// Plans the replacement in the course's place, with Undo.
    private func replace(_ course: DegreePlanCourse, with key: CourseKey) {
        let snapshot = catalog.degreePlanSnapshot()
        let title = snapshot.course(key)?.title.nilIfBlank ?? info.info(for: key)?.title.nilIfBlank ?? key.description
        let credits = snapshot.course(key)?.defaultChoiceCredits ?? info.info(for: key).flatMap { info in
            guard let low = info.minCredits ?? info.maxCredits else { return nil as Double? }
            return CreditSpan(low: low, high: info.maxCredits ?? low, bannerDefault: nil).defaultChoice()
        } ?? course.credits
        let replacement = DegreePlanCourse(key: key, title: DegreePlanFormat.exportTitle(title), credits: credits)
        performUndoable("Replaced \(courseName(course)) with \(key)", systemImage: "arrow.triangle.2.circlepath") {
            DegreePlanEditing.replacePlannedCourse(course.id, with: replacement, in: &$0)
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
        withAnimation { dismissedSuggestions = DegreeEquivalenceDismissals.adding(prompt.id, to: dismissedSuggestions) }
        haptic.fire(.selection)
    }

    private func deleteEquivalence(_ equivalence: CourseEquivalence) {
        withAnimation { userData.updateDegreePlan(id: planID) { $0.removeEquivalence(id: equivalence.id) } }
        haptic.fire(.impact)
        toast = DegreePlanToast(text: "Deleted \(equivalence.course) → \(equivalence.countsAs)", systemImage: "trash.fill", actionTitle: "Undo") {
            withAnimation {
                userData.updateDegreePlan(id: planID) { plan in
                    if !plan.courseEquivalences.contains(where: { $0.id == equivalence.id }) {
                        plan.courseEquivalences.append(equivalence)
                    }
                }
            }
        }
    }

    // MARK: Build schedule

    /// Creates a schedule for the semester's Banner term from the semester's courses,
    /// then opens it in the Schedule tab.
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
            toast = DegreePlanToast(text: "Created “\(schedule.name)” with \(DegreePlanText.courses(result.courseCount))", systemImage: "calendar.badge.plus")
        } else {
            toast = DegreePlanToast(text: "Opening “\(schedule.name)”", systemImage: "calendar")
        }
        haptic.fire(.success)

        Task {
            // Make the schedule's term the one being browsed, when its catalog is on the device.
            if await catalog.hasLocalCatalog(bannerTerm.code) {
                await catalog.select(termCode: bannerTerm.code)
                userData.preferences.selectedTermCode = bannerTerm.code
            }
            isBuildingSchedule = false
            router.show(.plan(id: schedule.id), in: .schedule)
        }
    }

    // MARK: Plan actions

    private func setPrimary(_ plan: DegreePlan) {
        guard !plan.isPrimary else { return }
        userData.setPrimaryDegreePlan(id: plan.id)
        haptic.fire(.success)
        toast = DegreePlanToast(text: "Using “\(plan.name)” for prerequisite checks", systemImage: "star.fill")
    }

    private func startEditing(_ plan: DegreePlan) {
        draftName = plan.name
        draftProgram = plan.program ?? ""
        isEditingDetails = true
    }

    private func saveDetails() {
        guard let plan = userData.degreePlan(id: planID) else { return }
        let name = draftName.nilIfBlank ?? plan.name
        let program = draftProgram.nilIfBlank
        userData.updateDegreePlan(id: planID) {
            $0.name = name
            $0.program = program
        }
        haptic.fire(.success)
    }

    private func duplicate(_ plan: DegreePlan) {
        let copy = DegreePlanEditing.duplicate(plan, existingNames: userData.degreePlans.map(\.name))
        let stored = userData.addDegreePlan(copy)
        haptic.fire(.success)
        router.navigate(to: .degreePlan(id: stored.id))
    }

    private func deletePlan() {
        userData.deleteDegreePlan(id: planID)
        haptic.fire(.warning)
        dismiss()
    }

    private func removeStudentInfo() {
        performUndoable("Removed student info", systemImage: "person.crop.circle.badge.minus") {
            DegreePlanEditing.removeStudentInfo(from: &$0)
        }
    }

    private func copyAsText(_ plan: DegreePlan) {
        UIPasteboard.general.string = DegreePlanFormat.text(for: plan, includeStudent: false)
        haptic.fire(.success)
        toast = DegreePlanToast(text: "Copied plan as text", systemImage: "doc.on.doc.fill")
    }
}

// MARK: - Dialogs

/// The alert and confirmation dialogs of the plan screen, kept apart so the screen's
/// modifier chain stays readable.
private struct DegreePlanDialogs: ViewModifier {
    var plan: DegreePlan
    @Binding var isEditingDetails: Bool
    @Binding var draftName: String
    @Binding var draftProgram: String
    @Binding var confirmsDelete: Bool
    @Binding var confirmsStudentRemoval: Bool
    @Binding var termToRemove: DegreePlanTerm?
    var onSaveDetails: () -> Void
    var onDelete: () -> Void
    var onRemoveStudentInfo: () -> Void
    var onRemoveTerm: (DegreePlanTerm) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Edit plan", isPresented: $isEditingDetails) {
                TextField("Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                TextField("Program", text: $draftProgram)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Save", action: onSaveDetails)
            } message: {
                Text("The program is the code from your degree audit, like CS-B-CSCI-BSCS.")
            }
            .confirmationDialog(
                "Delete “\(plan.name)”?",
                isPresented: $confirmsDelete,
                titleVisibility: .visible
            ) {
                Button("Delete plan", role: .destructive, action: onDelete)
            } message: {
                Text("The plan and its semesters will be deleted, and with iCloud sync on, from your other devices too. This can’t be undone.")
            }
            .confirmationDialog(
                "Remove student info?",
                isPresented: $confirmsStudentRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove student info", role: .destructive, action: onRemoveStudentInfo)
            } message: {
                Text("Exported PDFs will no longer include your name and ID.")
            }
            .confirmationDialog(
                termToRemove.map { "Remove \($0.name)?" } ?? "Remove semester?",
                isPresented: Binding(get: { termToRemove != nil }, set: { if !$0 { termToRemove = nil } }),
                titleVisibility: .visible,
                presenting: termToRemove
            ) { term in
                Button("Remove \(term.name)", role: .destructive) { onRemoveTerm(term) }
            } message: { term in
                Text("Its \(DegreePlanText.courses(term.courses.count)) will be removed from this plan.")
            }
    }
}
