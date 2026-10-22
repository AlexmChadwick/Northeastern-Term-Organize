//
//  PlanDetailView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// One schedule: a big week calendar of the chosen sections, the plan's
/// courses (each with its section, required/optional switch and swipe to
/// remove), warnings, and the entry points for generating schedules,
/// filtering, and exporting.
struct PlanDetailView: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var sheet: PlanSheet?
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var confirmsDelete = false
    @State private var toast: PlanToast?
    @State private var haptic = PlanHaptic()
    /// The autofill suggestion an empty schedule is previewing (nil: the best one).
    @State private var autofillChoice: String?
    /// Autofill nudges the user closed, as `ScheduleAutofillSupport.dismissalKey`s (one per schedule and suggestion).
    @AppStorage("schedule.autofill.dismissed") private var dismissedAutofill = ""

    private enum PlanSheet: Identifiable, Hashable {
        case section(String)
        case picker(CourseKey, String?)
        case addCourse
        case filters
        case preferences
        case calendar
        case image

        var id: String {
            switch self {
            case .section(let crn): "section-\(crn)"
            case .picker(let key, let entryID): "picker-\(entryID ?? key.description)"
            case .addCourse: "add-course"
            case .filters: "filters"
            case .preferences: "preferences"
            case .calendar: "calendar"
            case .image: "image"
            }
        }
    }

    private struct BannerItem: Identifiable {
        var id: String
        var style: PlanBanner.Style
        var title: String
        var lines: [String] = []
        var actionTitle: String?
        var action: (() -> Void)?
    }

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

    // MARK: Main content

    private func content(_ plan: SchedulePlan) -> some View {
        let index = catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
        let resolved = ResolvedPlan(plan: plan, index: index)
        let termName = termName(for: plan.termCode, index: index)
        // Re-derived whenever the degree plans, this schedule or the catalog change: all three are read
        // here (`indexVersion` is bumped by every index load, sync and live refresh).
        _ = catalog.indexVersion
        let autofill = ScheduleAutofillSupport.suggestions(
            for: plan,
            terms: catalog.terms,
            degreePlans: userData.degreePlans,
            schedulePlans: userData.plans,
            index: index
        )

        return List {
            autofillCardSection(plan: plan, suggestions: autofill, index: index)
            bannerSection(plan: plan, resolved: resolved, termName: termName)
            autofillNudgeSection(plan: plan, suggestions: autofill)
            calendarSection(resolved: resolved)
            untimedSection(resolved: resolved)
            coursesSection(plan: plan, resolved: resolved, termName: termName)
            preferencesSection(plan: plan)
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshSeats(plan) }
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(subtitle(termName: termName, resolved: resolved))
        .toolbar { toolbar(plan: plan, resolved: resolved) }
        .safeAreaBar(edge: .bottom) { bottomBar(plan: plan, resolved: resolved) }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet, plan: plan, index: index)
        }
        .alert("Rename Schedule", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(to: draftName) }
        } message: {
            Text("Choose a name for this schedule.")
        }
        .confirmationDialog("Delete “\(plan.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Schedule", role: .destructive) { deletePlan() }
        } message: {
            Text("The schedule and its saved combinations will be removed. This can’t be undone.")
        }
        .planToast($toast)
        .planHaptic(haptic)
    }

    private func termName(for code: String, index: CatalogIndex?) -> String {
        if let index, index.term.code == code { return index.term.name }
        return catalog.terms.first { $0.code == code }?.name ?? code
    }

    private func subtitle(termName: String, resolved: ResolvedPlan) -> String {
        guard resolved.hasCatalog, resolved.credits.max > 0 else { return termName }
        return "\(termName) · \(resolved.creditsLabel)"
    }

    // MARK: Banners

    private func banners(plan: SchedulePlan, resolved: ResolvedPlan, termName: String) -> [BannerItem] {
        let catalogUnavailable = indexLoadFinished && catalog.loadState != .loading
        return ScheduleNotices.make(for: resolved, termName: termName, catalogUnavailable: catalogUnavailable).map { notice in
            BannerItem(
                id: notice.id,
                style: bannerStyle(for: notice.severity),
                title: notice.title,
                lines: notice.lines,
                actionTitle: notice.fixTitle,
                action: notice.fix.map { fix in { apply(fix) } }
            )
        }
    }

    private func bannerStyle(for severity: ScheduleNotice.Severity) -> PlanBanner.Style {
        switch severity {
        case .error: .error
        case .warning: .warning
        case .info: .info
        }
    }

    private func apply(_ fix: ScheduleNotice.Fix) {
        switch fix {
        case .removeSections(let crns):
            userData.updatePlan(id: planID) { PlanEditing.removeStaleCRNs(crns, from: &$0) }
        }
    }

    @ViewBuilder
    private func bannerSection(plan: SchedulePlan, resolved: ResolvedPlan, termName: String) -> some View {
        let items = banners(plan: plan, resolved: resolved, termName: termName)
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    PlanBanner(style: item.style, title: item.title, lines: item.lines, actionTitle: item.actionTitle, action: item.action)
                        .listRowBackground(item.style.color.opacity(0.12))
                }
            }
        }
    }

    // MARK: Autofill

    /// An empty schedule: the courses it could start with (from a degree plan or another
    /// schedule), front and center above everything else.
    @ViewBuilder
    private func autofillCardSection(plan: SchedulePlan, suggestions: [ScheduleAutofillSuggestion], index: CatalogIndex?) -> some View {
        if plan.courses.isEmpty, !suggestions.isEmpty {
            Section {
                ScheduleAutofillCard(
                    suggestions: suggestions,
                    choice: $autofillChoice,
                    plan: plan,
                    index: index,
                    onAdd: { addAutofill($0, to: plan) }
                )
            }
        }
    }

    /// A schedule that already has courses: a compact, dismissible nudge while the degree
    /// plan's courses for this exact semester aren't all in it yet.
    @ViewBuilder
    private func autofillNudgeSection(plan: SchedulePlan, suggestions: [ScheduleAutofillSuggestion]) -> some View {
        let dismissals = dismissedAutofill
        let nudge = plan.courses.isEmpty ? nil : ScheduleAutofillSupport.nudge(from: suggestions) { suggestion in
            ScheduleAutofillSupport.isDismissed(ScheduleAutofillSupport.dismissalKey(planID: plan.id, suggestion: suggestion), in: dismissals)
        }
        if let nudge {
            Section {
                ScheduleAutofillBanner(
                    suggestion: nudge,
                    onAdd: { addAutofill(nudge, to: plan) },
                    onDismiss: { dismissAutofill(ScheduleAutofillSupport.dismissalKey(planID: plan.id, suggestion: nudge)) }
                )
                .listRowBackground(Color.accentColor.opacity(0.12))
            }
        }
    }

    // MARK: Calendar

    private func calendarSection(resolved: ResolvedPlan) -> some View {
        let preferences = userData.preferences
        return Section {
            WeekCalendarView(
                events: resolved.events,
                showWeekends: preferences.showWeekends,
                startHour: preferences.calendarStartHour,
                endHour: preferences.calendarEndHour,
                hourHeight: 40,
                onSelect: { event in
                    if let crn = event.payload { sheet = .section(crn) }
                }
            )
            .padding(.vertical, 6)
            .overlay {
                if resolved.events.isEmpty {
                    calendarHint(resolved)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
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
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.94), in: .rect(cornerRadius: 14, style: .continuous))
            .padding(24)
            .accessibilityElement(children: .combine)
    }

    // MARK: Online / TBA

    @ViewBuilder
    private func untimedSection(resolved: ResolvedPlan) -> some View {
        if !resolved.untimed.isEmpty {
            Section {
                ForEach(resolved.untimed, id: \.section.crn) { pair in
                    Button {
                        sheet = .section(pair.section.crn)
                    } label: {
                        HStack(spacing: 12) {
                            PlanColorDot(colorIndex: pair.entry.planCourse.colorIndex, size: 12)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(pair.section.courseKey.description) · \(ScheduleFormat.sectionTitle(pair.section))")
                                    .font(.subheadline.weight(.semibold))
                                Text(pair.section.scheduleSummary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: pair.section.isOnline ? "wifi" : "clock.badge.questionmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Online / TBA")
            } footer: {
                Text("These sections don’t meet at a set time, so they don’t appear on the calendar.")
            }
        }
    }

    // MARK: Courses

    private func coursesSection(plan: SchedulePlan, resolved: ResolvedPlan, termName: String) -> some View {
        Section {
            if resolved.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No courses yet")
                        .font(.headline)
                    Text("Add the courses you’re considering, then generate every schedule that fits.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityElement(children: .combine)
            }

            ForEach(resolved.entries) { entry in
                PlanCourseRow(
                    entry: entry,
                    termName: termName,
                    conflictingKeys: conflictingKeys(for: entry, in: resolved),
                    onOpen: { sheet = .picker(entry.key, entry.id) },
                    onToggleRequired: { toggleRequired(entry) },
                    onSetCredits: { credits in
                        userData.setScheduleCourseCredits(planID: plan.id, entryID: entry.id, credits: credits)
                    }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        remove(entry, from: plan)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        toggleRequired(entry)
                    } label: {
                        Label(entry.planCourse.isRequired ? "Optional" : "Required", systemImage: entry.planCourse.isRequired ? "circle.dashed" : "lock.fill")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button {
                        sheet = .picker(entry.key, entry.id)
                    } label: {
                        Label("Choose Section", systemImage: "checklist")
                    }
                    Button {
                        router.navigate(to: .course(termCode: plan.termCode, key: entry.key))
                    } label: {
                        Label("View Course", systemImage: "book")
                    }
                    Button {
                        toggleRequired(entry)
                    } label: {
                        Label(entry.planCourse.isRequired ? "Make Optional" : "Make Required", systemImage: entry.planCourse.isRequired ? "circle.dashed" : "lock")
                    }
                    Divider()
                    Button(role: .destructive) {
                        remove(entry, from: plan)
                    } label: {
                        Label("Remove from Schedule", systemImage: "trash")
                    }
                }
            }

            Button {
                sheet = .addCourse
            } label: {
                Label("Add Course", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
            }
        } header: {
            Text("Courses")
        } footer: {
            if !resolved.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Required courses appear in every generated schedule. Optional courses are added when they fit. Swipe a course to remove it.")
                    PlanSeatsFreshness(date: seatsDate(plan: plan))
                }
            }
        }
    }

    // MARK: Ideal week

    /// "Your ideal week": the wishes schedules are generated and ranked by, one tap from the courses.
    @ViewBuilder
    private func preferencesSection(plan: SchedulePlan) -> some View {
        if !plan.courses.isEmpty {
            Section {
                Button {
                    sheet = .preferences
                } label: {
                    SchedulePreferencesListRow(preferences: plan.preferences ?? SchedulePreferences())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your schedule preferences")
            } footer: {
                Text("Mornings or nights, days off, clubs and work: generated schedules follow what you tell us.")
            }
        }
    }

    private func conflictingKeys(for entry: ResolvedPlan.Entry, in resolved: ResolvedPlan) -> [CourseKey] {
        let crns = Set(entry.selected.map(\.crn))
        var keys: [CourseKey] = []
        for conflict in resolved.conflicts {
            if crns.contains(conflict.first.crn) { keys.append(conflict.second.courseKey) }
            if crns.contains(conflict.second.crn) { keys.append(conflict.first.courseKey) }
        }
        return Array(Set(keys)).sorted()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(plan: SchedulePlan, resolved: ResolvedPlan) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                sheet = .addCourse
            } label: {
                Label("Add Course", systemImage: "plus")
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button {
                        setPrimary(plan)
                    } label: {
                        Label(plan.isPrimary ? "My Schedule" : "Set as My Schedule", systemImage: plan.isPrimary ? "star.fill" : "star")
                    }
                    .disabled(plan.isPrimary)
                }
                Section {
                    Button {
                        copyCRNs(resolved)
                    } label: {
                        Label("Copy CRNs", systemImage: "doc.on.doc")
                    }
                    .disabled(!resolved.hasSelection)
                    Button {
                        sheet = .calendar
                    } label: {
                        Label("Export to Calendar", systemImage: "calendar.badge.plus")
                    }
                    .disabled(!resolved.hasSelection)
                    Button {
                        sheet = .image
                    } label: {
                        Label("Share as Image", systemImage: "photo")
                    }
                    .disabled(!resolved.hasSelection)
                }
                Section {
                    Button {
                        draftName = plan.name
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        duplicate()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Bottom bar

    private func bottomBar(plan: SchedulePlan, resolved: ResolvedPlan) -> some View {
        let activeFilters = plan.filters.activeCount
        return GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                // Pushed through the app's routes, so it lives in the tab's path like every other screen.
                NavigationLink(value: AppRoute.planGenerator(id: planID)) {
                    Label("Generate Schedules", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(plan.courses.isEmpty || !resolved.hasCatalog)

                Button {
                    sheet = .filters
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        if activeFilters > 0 {
                            Text("\(activeFilters)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .frame(minWidth: 26)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .accessibilityLabel("Filters")
                .accessibilityValue(activeFilters == 0 ? "None active" : "\(activeFilters) active")
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: PlanSheet, plan: SchedulePlan, index: CatalogIndex?) -> some View {
        switch sheet {
        case .section(let crn):
            PlanSectionSheet(
                planID: planID,
                crn: crn,
                onChangeSection: { key, entryID in self.sheet = .picker(key, entryID) },
                onViewCourse: { key in
                    self.sheet = nil
                    router.navigate(to: .course(termCode: plan.termCode, key: key))
                }
            )
        case .picker(let key, let entryID):
            SectionPickerSheet(planID: planID, courseKey: key, entryID: entryID)
        case .addCourse:
            PlanCourseSearchSheet(planID: planID)
        case .filters:
            ScheduleFiltersSheet(
                planID: planID,
                campusNames: index?.campusNames ?? [],
                courseCount: plan.courses.count
            )
        case .preferences:
            SchedulePreferencesSheet(
                planID: planID,
                initial: plan.preferences ?? SchedulePreferences(),
                context: SchedulePreferencesContext(plan: plan, index: index)
            )
        case .calendar:
            ScheduleCalendarExportSheet(planID: planID)
        case .image:
            ScheduleImageShareSheet(planID: planID)
        }
    }

    /// When the stalest seat counts on screen were last refreshed (the oldest across the plan's courses).
    private func seatsDate(plan: SchedulePlan) -> Date? {
        let base = catalog.planIndex(for: plan.termCode, fallback: loadedIndex)?.catalog.sectionsUpdatedAt
        let dates = plan.courses.compactMap { catalog.liveRefreshedAt[$0.key] ?? base }
        return dates.min() ?? base
    }

    // MARK: Actions

    /// Pull to refresh: live seat counts for every course in the plan.
    private func refreshSeats(_ plan: SchedulePlan) async {
        let keys = plan.courses.map(\.key)
        guard !keys.isEmpty else { return }
        do {
            _ = try await catalog.liveSections(for: keys, termCode: plan.termCode)
            loadedIndex = await catalog.index(for: plan.termCode)
            haptic.fire(.success)
            toast = PlanToast(text: "Seats updated", systemImage: "arrow.triangle.2.circlepath")
        } catch is CancellationError {
            // The user let go early; nothing to report.
        } catch {
            haptic.fire(.warning)
            toast = PlanToast(text: "Couldn’t refresh seats", systemImage: "wifi.exclamationmark")
        }
    }

    private func toggleRequired(_ entry: ResolvedPlan.Entry) {
        let required = !entry.planCourse.isRequired
        userData.updatePlan(id: planID) { PlanEditing.setRequired(required, entryID: entry.id, in: &$0) }
        haptic.fire(.selection)
    }

    /// Removes a course (and its chosen sections and favorite combinations). "Undo" puts back
    /// just that course, at its old position, via `PlanCourseRemoval`.
    private func remove(_ entry: ResolvedPlan.Entry, from plan: SchedulePlan) {
        let index = catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
        let removal = SchedulePlanActions.removeCourse(entry, from: plan, index: index, userData: userData)
        haptic.fire(.impact)
        toast = PlanToast(
            text: "Removed \(entry.key)",
            systemImage: "trash",
            actionTitle: "Undo",
            action: {
                userData.updatePlan(id: planID) { PlanEditing.restore(removal, in: &$0) }
            }
        )
        // Without a loaded catalog the course's CRNs weren't known, so clear what it
        // left behind as soon as the catalog arrives.
        if index == nil {
            Task { await SchedulePlanActions.pruneLeftovers(of: removal, planID: planID, termCode: plan.termCode, catalog: catalog, userData: userData) }
        }
    }

    /// Adds every course of an autofill suggestion as a required course. "Undo" takes out
    /// just the courses this added.
    private func addAutofill(_ suggestion: ScheduleAutofillSuggestion, to plan: SchedulePlan) {
        let added = SchedulePlanActions.addAutofill(suggestion, toPlan: planID, userData: userData)
        guard !added.isEmpty else {
            haptic.fire(.warning)
            return
        }
        haptic.fire(.success)
        let termCode = plan.termCode
        toast = PlanToast(
            text: "Added \(ScheduleAutofillSupport.courseCountLabel(added.count))",
            systemImage: "checkmark.circle.fill",
            actionTitle: "Undo",
            action: { undoAutofill(added, termCode: termCode) }
        )
    }

    private func undoAutofill(_ keys: [CourseKey], termCode: String) {
        let index = catalog.planIndex(for: termCode, fallback: loadedIndex)
        SchedulePlanActions.undoAutofill(keys, planID: planID, index: index, userData: userData)
        haptic.fire(.selection)
    }

    /// Hides the nudge for this schedule and suggestion for good.
    private func dismissAutofill(_ key: String) {
        withAnimation {
            dismissedAutofill = ScheduleAutofillSupport.adding(key, to: dismissedAutofill)
        }
        haptic.fire(.selection)
    }

    private func setPrimary(_ plan: SchedulePlan) {
        userData.setPrimary(id: planID)
        haptic.fire(.success)
        toast = PlanToast(text: "\(plan.name) is now My Schedule", systemImage: "star.fill")
    }

    private func copyCRNs(_ resolved: ResolvedPlan) {
        let crns = resolved.crnsForRegistration
        guard !crns.isEmpty else {
            haptic.fire(.warning)
            toast = PlanToast(text: "Choose sections first", systemImage: "exclamationmark.circle")
            return
        }
        UIPasteboard.general.string = crns.joined(separator: "\n")
        haptic.fire(.success)
        toast = PlanToast(text: crns.count == 1 ? "Copied 1 CRN" : "Copied \(crns.count) CRNs", systemImage: "doc.on.doc.fill")
    }

    private func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userData.updatePlan(id: planID) { $0.name = trimmed }
        haptic.fire(.success)
    }

    private func duplicate() {
        guard let copy = userData.duplicatePlan(id: planID) else { return }
        haptic.fire(.success)
        router.navigate(to: .plan(id: copy.id))
    }

    private func deletePlan() {
        haptic.fire(.warning)
        // Pop first and remove the plan once the screen is gone, so it doesn't flash "not found".
        let id = planID
        let store = userData
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            store.deletePlan(id: id)
        }
    }
}
