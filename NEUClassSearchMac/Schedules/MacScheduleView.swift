//
//  MacScheduleView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One schedule: its courses beside a week calendar of the chosen sections, with the generator one
/// click away. The toolbar adds courses, sets the filters and "your ideal week" and exports; sections
/// are chosen in a table, and a click on a class of the calendar shows its details.
struct MacScheduleView: View {
    var planID: UUID
    /// What the schedule starts on (the generator for snapshots).
    var initialMode: Mode = .courses

    /// The two faces of a schedule.
    enum Mode: String, CaseIterable, Identifiable {
        case courses
        case generator

        var id: String { rawValue }

        var title: String {
            switch self {
            case .courses: "Schedule"
            case .generator: "Generator"
            }
        }
    }

    var body: some View {
        // A new schedule in the sidebar starts from a clean slate.
        MacScheduleScreen(planID: planID, initialMode: initialMode)
            .id(planID)
    }
}

private struct MacScheduleScreen: View {
    var planID: UUID
    var initialMode: MacScheduleView.Mode

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var mode: MacScheduleView.Mode
    @State private var selection: Set<CourseKey> = []
    @State private var sheet: Sheet?
    @State private var showsAddCourse = false
    @State private var showsFilters = false
    @State private var manager = MacPlanManager()
    @State private var isRefreshingSeats = false
    /// The autofill suggestion an empty schedule is previewing (nil: the best one).
    @State private var autofillChoice: String?
    /// Autofill nudges the student closed, as `ScheduleAutofillSupport.dismissalKey`s (one per schedule and suggestion).
    @AppStorage("schedule.autofill.dismissed") private var dismissedAutofill = ""
    /// Whether the course list (the pane beside the calendar) is shown.
    @AppStorage("mac.schedule.showsCourseList") private var showsCourseList = true

    init(planID: UUID, initialMode: MacScheduleView.Mode) {
        self.planID = planID
        self.initialMode = initialMode
        var start = initialMode
        #if DEBUG
        // `-MacSnapshotScheduleMode generator` opens snapshot runs on the generator.
        if MacSnapshot.isRequested, UserDefaults.standard.string(forKey: "MacSnapshotScheduleMode") == "generator" { start = .generator }
        #endif
        _mode = State(initialValue: start)
    }

    /// Edits of this schedule that ⌘Z takes back.
    private var editor: MacSchedulePlanEditor {
        MacSchedulePlanEditor(userData: userData, planID: planID, undoManager: undoManager)
    }

    private enum Sheet: Identifiable {
        case sectionPicker(CourseKey)
        case preferences
        case export

        var id: String {
            switch self {
            case .sectionPicker(let key): "picker-\(key)"
            case .preferences: "preferences"
            case .export: "export"
            }
        }
    }

    // MARK: Body

    var body: some View {
        Group {
            if let plan = userData.plan(id: planID) {
                content(plan)
            } else {
                ContentUnavailableView {
                    Label("Schedule not found", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("This schedule may have been deleted.")
                }
            }
        }
        .loadPlanIndex(termCode: userData.plan(id: planID)?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
    }

    private func content(_ plan: SchedulePlan) -> some View {
        let index = catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
        let resolved = ResolvedPlan(plan: plan, index: index)
        let termName = termName(for: plan.termCode, index: index)
        // Re-derived whenever the degree plans, this schedule or the catalog change: all three are read
        // here (`indexVersion` is bumped by every index load, sync and live refresh).
        _ = catalog.indexVersion
        return Group {
            switch mode {
            case .courses:
                planPane(plan: plan, resolved: resolved, index: index, termName: termName)
            case .generator:
                MacScheduleGeneratorView(
                    planID: planID, index: index, indexLoadFinished: indexLoadFinished, undoManager: undoManager,
                    onEditPreferences: { sheet = .preferences },
                    onUse: {
                        mode = .courses
                        manager.toast = PlanToast(text: "Sections chosen for \(plan.name)", systemImage: "checkmark.circle.fill")
                    }
                )
            }
        }
        .navigationTitle(plan.name)
        .navigationSubtitle(subtitle(plan: plan, termName: termName, resolved: resolved))
        .toolbar { toolbar(plan: plan, resolved: resolved, index: index) }
        .toolbarTitleMenu { titleMenu(plan: plan) }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet, plan: plan, index: index)
        }
        .macPlanDialogs(manager, userData: userData) { plan in delete(plan) }
        .focusedSceneValue(\.macExport, resolved.hasSelection ? MacMenuAction(title: "Export Schedule…") { sheet = .export } : nil)
        .focusedSceneValue(\.macDelete, mode == .courses && !selection.isEmpty
            ? MacMenuAction(title: selection.count == 1 ? "Remove Course from Schedule" : "Remove \(selection.count) Courses from Schedule") { removeCourses(Array(selection), plan: plan) }
            : nil)
        .focusedSceneValue(\.macReload, plan.courses.isEmpty ? nil : MacMenuAction(title: "Refresh Seats") { Task { await refreshSeats(plan) } })
        .focusedSceneValue(\.macScheduleActions, scheduleActions(plan: plan, resolved: resolved))
    }

    private func termName(for code: String, index: CatalogIndex?) -> String {
        if let index, index.term.code == code { return index.term.name }
        return catalog.terms.first { $0.code == code }?.name ?? code
    }

    private func subtitle(plan: SchedulePlan, termName: String, resolved: ResolvedPlan) -> String {
        var parts = plan.isPrimary ? ["My Schedule", termName] : [termName]
        if resolved.hasCatalog, resolved.credits.max > 0 { parts.append(resolved.creditsLabel) }
        return parts.joined(separator: " · ")
    }

    // MARK: Plan pane

    private func planPane(plan: SchedulePlan, resolved: ResolvedPlan, index: CatalogIndex?, termName: String) -> some View {
        let autofill = ScheduleAutofillSupport.suggestions(
            for: plan,
            terms: catalog.terms,
            degreePlans: userData.degreePlans,
            schedulePlans: userData.plans,
            index: index
        )
        let dismissals = dismissedAutofill
        let nudge = plan.courses.isEmpty ? nil : ScheduleAutofillSupport.nudge(from: autofill) { suggestion in
            ScheduleAutofillSupport.isDismissed(ScheduleAutofillSupport.dismissalKey(planID: plan.id, suggestion: suggestion), in: dismissals)
        }
        let catalogUnavailable = indexLoadFinished && catalog.loadState != .loading
        // The list is a pane the student drags wider or narrower (or closes) to give the calendar the
        // rest of the window. Both fit side by side in a half-screen window; a narrower one has the list
        // float over the calendar.
        return MacSplitPane(
            storageKey: "mac.split.schedule",
            paneEdge: .leading,
            defaultShare: 0.34,
            paneMinWidth: 276,
            primaryMinWidth: 280,
            maxShare: 0.62,
            isPaneShown: $showsCourseList
        ) {
            calendarPane(plan: plan, resolved: resolved)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } pane: {
            MacScheduleCourseList(
                plan: plan,
                resolved: resolved,
                notices: ScheduleNotices.make(for: resolved, termName: termName, catalogUnavailable: catalogUnavailable),
                termName: termName,
                index: index,
                seatsDate: seatsDate(plan: plan, index: index),
                autofill: autofill,
                autofillChoice: $autofillChoice,
                nudge: nudge,
                selection: $selection,
                actions: listActions(plan: plan, resolved: resolved, index: index)
            )
        }
        .focusedSceneValue(\.macSidePane, MacPaneToggle(title: "Course List", isShown: showsCourseList) { showsCourseList.toggle() })
        // Drag courses (or sections) in from the course tables.
        .dropDestination(for: String.self) { items, _ in
            addDropped(items, to: plan, index: index)
        }
    }

    private func calendarPane(plan: SchedulePlan, resolved: ResolvedPlan) -> some View {
        let preferences = userData.preferences
        let selectedTitles = Set(selection.map(\.description))
        return MacWeekCalendar(
            events: resolved.events,
            days: MacCalendarRange.days(for: resolved.events, showWeekends: preferences.showWeekends),
            hours: MacCalendarRange.hours(for: resolved.events, preferences: preferences),
            isDimmed: { event in !selectedTitles.isEmpty && !selectedTitles.contains(event.title) },
            extras: { event in
                event.payload.flatMap { resolved.entry(forCRN: $0)?.section }.map(MacCalendarBlockExtras.init(section:)) ?? MacCalendarBlockExtras()
            },
            popover: { event in
                AnyView(MacSectionDetailsView(planID: planID, crn: event.payload ?? "", undoManager: undoManager) { key in
                    // Let the popover go before the sheet comes.
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        sheet = .sectionPicker(key)
                    }
                })
            },
            menu: { event in AnyView(blockMenu(event, plan: plan, resolved: resolved)) }
        )
        .overlay {
            if resolved.events.isEmpty { calendarHint(resolved) }
        }
        .background(.background)
    }

    private func calendarHint(_ resolved: ResolvedPlan) -> some View {
        let message: (String, String)
        if resolved.entries.isEmpty {
            message = ("calendar.badge.plus", "Add courses to build your week")
        } else if !resolved.hasCatalog {
            message = ("icloud.slash", "Course data isn’t available for this term")
        } else if resolved.hasSelection {
            message = ("wifi", "Your classes have no fixed meeting times")
        } else {
            message = ("hand.tap", "Choose sections, or generate schedules")
        }
        return Label(message.1, systemImage: message.0)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func blockMenu(_ event: CalendarEvent, plan: SchedulePlan, resolved: ResolvedPlan) -> some View {
        if let crn = event.payload, let found = resolved.entry(forCRN: crn) {
            Button("Change Section…", systemImage: "arrow.left.arrow.right") { sheet = .sectionPicker(found.entry.key) }
            Button("Open Course in New Window", systemImage: "macwindow") { openCourse(found.entry.key, plan: plan) }
            Button("Copy CRN", systemImage: "doc.on.doc") { MacPasteboard.copy(crn) }
            Divider()
            Button("Remove Section", systemImage: "minus.circle", role: .destructive) {
                editor.perform("Remove Section") { PlanEditing.setSection(nil, courseCRNs: found.entry.courseCRNs.union([crn]), in: &$0) }
            }
        }
    }

    /// When the stalest seat counts on screen were last refreshed (the oldest across the plan's courses).
    private func seatsDate(plan: SchedulePlan, index: CatalogIndex?) -> Date? {
        let base = index?.catalog.sectionsUpdatedAt
        let dates = plan.courses.compactMap { catalog.liveRefreshedAt[$0.key] ?? base }
        return dates.min() ?? base
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(plan: SchedulePlan, resolved: ResolvedPlan, index: CatalogIndex?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $mode) {
                ForEach(MacScheduleView.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Switch between your schedule and every combination of sections that fits")
            .accessibilityLabel("Show")
        }
        if mode == .courses {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showsCourseList) {
                    Label("Course List", systemImage: "sidebar.leading")
                }
                .help(showsCourseList ? "Hide the course list" : "Show the course list")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsAddCourse.toggle()
            } label: {
                Label("Add Course", systemImage: "plus")
            }
            .help("Add a course to this schedule")
            .popover(isPresented: $showsAddCourse, arrowEdge: .bottom) {
                MacAddCourseView(planID: planID)
            }
            Button {
                showsFilters.toggle()
            } label: {
                Label(plan.filters.activeCount == 0 ? "Filters" : "Filters · \(plan.filters.activeCount)", systemImage: "line.3.horizontal.decrease")
            }
            .help("Limit which sections the generator uses")
            .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
                MacScheduleFiltersView(planID: planID, campusNames: index?.campusNames ?? [], courseCount: plan.courses.count)
            }
            Button {
                sheet = .preferences
            } label: {
                Label(plan.preferences?.hasWishes == true ? "Ideal Week · \(plan.preferences?.activeCount ?? 0)" : "Ideal Week", systemImage: "calendar.badge.clock")
            }
            .help("Tell the generator what your ideal week looks like")
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                sheet = .export
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Add the schedule to Calendar, or save it as a calendar file or a picture")
            .disabled(!resolved.hasSelection)
        }
    }

    /// The menu of the window title: what to do with the schedule as a whole.
    @ViewBuilder
    private func titleMenu(plan: SchedulePlan) -> some View {
        Button(plan.isPrimary ? "My Schedule" : "Set as My Schedule", systemImage: plan.isPrimary ? "star.fill" : "star") {
            manager.setPrimary(plan, userData: userData)
        }
        .disabled(plan.isPrimary)
        Button("Rename…", systemImage: "pencil") { manager.startRenaming(plan) }
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(plan) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { manager.planToDelete = plan }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet, plan: SchedulePlan, index: CatalogIndex?) -> some View {
        switch sheet {
        case .sectionPicker(let key):
            MacSectionPickerSheet(planID: planID, courseKey: key, undoManager: undoManager)
        case .preferences:
            MacSchedulePreferencesSheet(
                planID: planID,
                initial: plan.preferences ?? SchedulePreferences(),
                context: SchedulePreferencesContext(plan: plan, index: index),
                undoManager: undoManager
            )
        case .export:
            MacScheduleExportSheet(planID: planID)
        }
    }

    // MARK: Course list actions

    private func listActions(plan: SchedulePlan, resolved: ResolvedPlan, index: CatalogIndex?) -> MacCourseListActions {
        MacCourseListActions(
            chooseSection: { key in sheet = .sectionPicker(key) },
            openCourse: { key in openCourse(key, plan: plan) },
            toggleRequired: { key in
                let required = !(plan.course(key)?.isRequired ?? true)
                editor.perform(required ? "Make Required" : "Make Optional") { PlanEditing.setRequired(required, for: key, in: &$0) }
            },
            remove: { keys in removeCourses(keys, plan: plan) },
            addCourse: { showsAddCourse = true },
            fix: { fix in
                switch fix {
                case .removeSections(let crns):
                    editor.perform("Remove Sections") { PlanEditing.removeStaleCRNs(crns, from: &$0) }
                }
            },
            addAutofill: { suggestion in addAutofill(suggestion, to: plan, index: index) },
            dismissNudge: { suggestion in
                withAnimation {
                    dismissedAutofill = ScheduleAutofillSupport.adding(ScheduleAutofillSupport.dismissalKey(planID: plan.id, suggestion: suggestion), to: dismissedAutofill)
                }
            },
            editPreferences: { sheet = .preferences },
            generate: { mode = .generator },
            showFilters: { showsFilters = true },
            paste: { texts in addDropped(texts, to: plan, index: index) }
        )
    }

    private func openCourse(_ key: CourseKey, plan: SchedulePlan) {
        openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: plan.termCode, key: key))
    }

    /// Removes courses (with their chosen sections and favorite combinations). ⌘Z, or "Undo" in the
    /// toast, puts them back at their old positions.
    private func removeCourses(_ keys: [CourseKey], plan: SchedulePlan) {
        let index = catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
        let resolved = ResolvedPlan(plan: userData.plan(id: planID) ?? plan, index: index)
        var removals: [PlanCourseRemoval] = []
        editor.record(keys.count == 1 ? "Remove Course" : "Remove Courses") {
            for key in keys {
                guard let entry = resolved.entry(for: key), let current = userData.plan(id: planID) else { continue }
                removals.append(SchedulePlanActions.removeCourse(entry, from: current, index: index, userData: userData))
            }
        }
        guard !removals.isEmpty else { return }
        selection.subtract(keys)
        manager.toast = .undoable(
            removals.count == 1 ? "Removed \(removals[0].course.key)" : "Removed \(removals.count) courses",
            systemImage: "trash", undoManager: undoManager
        )
        // Without a loaded catalog the courses' CRNs weren't known, so clear what they left behind
        // as soon as the catalog arrives.
        if index == nil {
            for removal in removals {
                Task { await SchedulePlanActions.pruneLeftovers(of: removal, planID: planID, termCode: plan.termCode, catalog: catalog, userData: userData) }
            }
        }
    }

    /// Adds the courses (and the sections) dragged in from a course or section table. ⌘Z, or "Undo" in
    /// the toast, takes them out again.
    @discardableResult
    private func addDropped(_ items: [String], to plan: SchedulePlan, index: CatalogIndex?) -> Bool {
        var added: [CourseKey] = []
        var touched = false
        editor.record("Add Courses") {
            for dropped in ScheduleDroppedCourse.parse(items) {
                // Text that isn't a course of this term (a professor's name, say) is ignored.
                if let index, index.course(dropped.key) == nil { continue }
                if userData.addCourse(dropped.key, toPlan: planID) { added.append(dropped.key) }
                touched = true
                if let crn = dropped.crn, let section = index?.section(crn: crn), section.courseKey == dropped.key {
                    let crns = Set(index?.sections(for: dropped.key).map(\.crn) ?? [])
                    userData.updatePlan(id: planID) { PlanEditing.setSection(crn, courseCRNs: crns, in: &$0) }
                }
            }
        }
        guard touched else { return false }
        if !added.isEmpty {
            manager.toast = .undoable(added.count == 1 ? "Added \(added[0])" : "Added \(added.count) courses", systemImage: "checkmark.circle.fill", undoManager: undoManager)
        }
        return true
    }

    /// Adds every course of an autofill suggestion as a required course. ⌘Z, or "Undo" in the toast,
    /// takes out just the courses this added.
    private func addAutofill(_ suggestion: ScheduleAutofillSuggestion, to plan: SchedulePlan, index: CatalogIndex?) {
        var added: [CourseKey] = []
        editor.record("Add Courses") {
            added = SchedulePlanActions.addAutofill(suggestion, toPlan: planID, userData: userData)
        }
        guard !added.isEmpty else { return }
        manager.toast = .undoable("Added \(ScheduleAutofillSupport.courseCountLabel(added.count))", systemImage: "checkmark.circle.fill", undoManager: undoManager)
    }

    // MARK: Schedule actions

    private func duplicate(_ plan: SchedulePlan) {
        if let copy = manager.duplicate(plan, userData: userData) {
            navigator.selection = .schedule(copy.id)
        }
    }

    /// Moves to the schedules overview first and removes the schedule once this screen is gone, so
    /// it doesn't flash "not found".
    private func delete(_ plan: SchedulePlan) {
        let id = plan.id
        let store = userData
        navigator.selection = .schedules
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            store.deletePlan(id: id)
        }
    }

    /// Live seat counts for every course in the schedule.
    private func refreshSeats(_ plan: SchedulePlan) async {
        let keys = plan.courses.map(\.key)
        guard !keys.isEmpty, !isRefreshingSeats else { return }
        isRefreshingSeats = true
        defer { isRefreshingSeats = false }
        do {
            _ = try await catalog.liveSections(for: keys, termCode: plan.termCode)
            loadedIndex = await catalog.index(for: plan.termCode)
            manager.toast = PlanToast(text: "Seats updated", systemImage: "arrow.triangle.2.circlepath")
        } catch is CancellationError {
            // Nothing to report.
        } catch {
            manager.toast = PlanToast(text: "Couldn’t refresh seats", systemImage: "wifi.exclamationmark")
        }
    }

    /// The schedule's actions for the Schedule menu.
    private func scheduleActions(plan: SchedulePlan, resolved: ResolvedPlan) -> MacScheduleCommandActions {
        MacScheduleCommandActions(
            planName: plan.name,
            isPrimary: plan.isPrimary,
            isShowingGenerator: mode == .generator,
            hasCourses: !plan.courses.isEmpty,
            canGenerate: !plan.courses.isEmpty && resolved.hasCatalog,
            hasSelection: resolved.hasSelection,
            selectedCourse: selection.count == 1 ? selection.first : nil,
            addCourse: { showsAddCourse = true },
            showSchedule: { mode = .courses },
            showGenerator: { mode = .generator },
            showFilters: { showsFilters = true },
            editPreferences: { sheet = .preferences },
            chooseSection: { key in sheet = .sectionPicker(key) },
            copyCRNs: { copyCRNs(resolved) },
            setPrimary: { manager.setPrimary(plan, userData: userData) },
            rename: { manager.startRenaming(plan) },
            duplicate: { duplicate(plan) },
            delete: { manager.planToDelete = plan }
        )
    }

    private func copyCRNs(_ resolved: ResolvedPlan) {
        let crns = resolved.crnsForRegistration
        guard !crns.isEmpty else {
            manager.toast = PlanToast(text: "Choose sections first", systemImage: "exclamationmark.circle")
            return
        }
        MacPasteboard.copy(crns.joined(separator: "\n"))
        manager.toast = PlanToast(text: crns.count == 1 ? "Copied 1 CRN" : "Copied \(crns.count) CRNs", systemImage: "doc.on.doc.fill")
    }
}
