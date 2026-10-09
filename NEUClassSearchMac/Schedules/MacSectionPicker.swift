//
//  MacSectionPicker.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Chooses the section of one course of a schedule: a table of every section with its times, room,
/// instructor and seats, and a week calendar that shows the highlighted one (dashed) over the rest of
/// the schedule. "Use Section" commits the choice.
struct MacSectionPickerSheet: View {
    var planID: UUID
    var courseKey: CourseKey
    /// The window's undo manager, so a change of section can be undone with ⌘Z.
    var undoManager: UndoManager?

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var highlightedCRN: String?
    @State private var onlyFitting = false
    @State private var onlyOpen = false
    @State private var sortOrder: [KeyPathComparator<Row>] = []
    @State private var isRefreshing = false
    /// Why the last seat refresh failed, shown under the table until one succeeds.
    @State private var refreshError: String?
    /// Why instructor names couldn't be loaded.
    @State private var detailsError: String?
    @State private var toast: PlanToast?
    /// The width of the sheet: a wide one shows the preview beside the table, a narrow one below it.
    @State private var sheetWidth: CGFloat = 900

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    /// One section as a table row.
    struct Row: Identifiable {
        var section: CourseSection
        var isCurrent: Bool
        var isExcluded: Bool
        /// The other courses whose chosen sections overlap this one.
        var overlapping: [CourseKey]

        var id: String { section.crn }
        var typeAndNumber: String { "\(section.classType) \(section.sectionNumber)" }
        var firstStart: Int { section.weeklyMeetings.compactMap(\.start).min() ?? Int.max }
        var seats: Int { section.seatsRemaining }
        var instructor: String { ScheduleFormat.instructors(of: section) ?? "" }
    }

    var body: some View {
        Group {
            if let plan {
                let resolved = ResolvedPlan(plan: plan, index: index)
                if !resolved.hasCatalog {
                    if indexLoadFinished, catalog.loadState != .loading {
                        ContentUnavailableView {
                            Label("Course data unavailable", systemImage: "icloud.slash")
                        } description: {
                            Text("The catalog for this term isn’t on this device, so sections can’t be shown.")
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let entry = resolved.entry(for: courseKey) {
                    picker(plan: plan, resolved: resolved, entry: entry)
                } else {
                    ContentUnavailableView("Course not in this schedule", systemImage: "questionmark.folder")
                }
            } else {
                ContentUnavailableView("Schedule not found", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .frame(minWidth: 620, idealWidth: 880, minHeight: 500, idealHeight: 600)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sheetWidth = $0 }
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .task(id: plan?.termCode) { await loadDetails() }
        .planToast($toast)
    }

    // MARK: Picker

    private func picker(plan: SchedulePlan, resolved: ResolvedPlan, entry: ResolvedPlan.Entry) -> some View {
        let current = entry.chosen
        let highlighted = highlightedCRN.flatMap { crn in entry.allSections.first { $0.crn == crn } }
        let others = resolved.entries.filter { $0.key != courseKey }.flatMap(\.selected)
        let rows = visibleRows(entry: entry, others: others)
        let multiCampus = Set(entry.allSections.map(\.campus)).count > 1

        return VStack(spacing: 0) {
            header(entry: entry, shown: rows.count)
            Divider()
            if sheetWidth >= 820 {
                HStack(spacing: 0) {
                    sections(rows: rows, entry: entry, current: current, multiCampus: multiCampus)
                    Divider()
                    previewColumn(resolved: resolved, entry: entry, others: others, highlighted: highlighted)
                        .frame(width: 290)
                }
            } else {
                VStack(spacing: 0) {
                    sections(rows: rows, entry: entry, current: current, multiCampus: multiCampus)
                    Divider()
                    previewColumn(resolved: resolved, entry: entry, others: others, highlighted: highlighted)
                        .frame(height: 210)
                }
            }
            Divider()
            bottomBar(entry: entry, current: current, highlighted: highlighted)
        }
        .onAppear { if highlightedCRN == nil { highlightedCRN = current?.crn } }
    }

    /// The table (or why there is none) with the notes about seats under it.
    private func sections(rows: [Row], entry: ResolvedPlan.Entry, current: CourseSection?, multiCampus: Bool) -> some View {
        VStack(spacing: 0) {
            if entry.allSections.isEmpty {
                ContentUnavailableView {
                    Label("No sections this term", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("\(courseKey.description) isn’t offered in \(index?.term.name ?? "this term").")
                }
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No matching sections", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Turn off a filter to see more of the \(entry.allSections.count) sections.")
                }
            } else {
                table(rows: rows, entry: entry, current: current, showsCampus: multiCampus)
            }
            footerNotes
        }
    }

    // MARK: Header

    private func header(entry: ResolvedPlan.Entry, shown: Int) -> some View {
        HStack(spacing: 12) {
            PlanColorDot(colorIndex: entry.planCourse.colorIndex, size: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(courseKey.description)
                        .font(.headline)
                        .foregroundStyle(entry.color.text)
                    if let course = entry.course {
                        Text(course.creditsLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(index?.course(courseKey)?.title ?? "Choose a section")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $onlyFitting) {
                Label("No Conflicts", systemImage: "checkmark.circle")
            }
            .toggleStyle(.button)
            .help("Only sections that don’t overlap the rest of your schedule")
            Toggle(isOn: $onlyOpen) {
                Label("Open Seats", systemImage: "chair.lounge")
            }
            .toggleStyle(.button)
            .help("Only sections with open seats")
            Text(shown == entry.allSections.count ? "\(shown) sections" : "\(shown) of \(entry.allSections.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Table

    private func table(rows: [Row], entry: ResolvedPlan.Entry, current: CourseSection?, showsCampus: Bool) -> some View {
        // A table adds about 17 points of spacing to every column. These add up to a width that fits the
        // narrowest sheet (620), so the table does not need to scroll sideways there.
        Table(rows.sorted(using: sortOrder), selection: $highlightedCRN, sortOrder: $sortOrder) {
            TableColumn("Section", value: \.typeAndNumber) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.isCurrent ? AnyShapeStyle(entry.color.stroke) : AnyShapeStyle(.quaternary))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ScheduleFormat.sectionTitle(row.section)).fontWeight(.medium)
                        Text("CRN \(row.section.crn)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .opacity(row.isExcluded ? 0.6 : 1)
            }
            .width(min: 96, ideal: 104)
            TableColumn("Days & Time", value: \.firstStart) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.section.scheduleSummary)
                        .lineLimit(2)
                    if let location = ScheduleFormat.location(of: row.section) {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .opacity(row.isExcluded ? 0.6 : 1)
            }
            .width(min: 130, ideal: 156)
            TableColumn("Instructor", value: \.instructor) { row in
                Text(row.instructor)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .width(min: 72, ideal: 90)
            TableColumn("Seats", value: \.seats) { row in
                SeatsBadge(section: row.section)
            }
            .width(min: 72, ideal: 76)
            TableColumn("Notes") { row in
                notes(for: row, showsCampus: showsCampus)
            }
            .width(min: 66, ideal: 84)
        }
        .contextMenu(forSelectionType: String.self) { crns in
            if let crn = crns.first, let row = rows.first(where: { $0.id == crn }) {
                Button("Use This Section", systemImage: "checkmark.circle") { choose(crn, entry: entry) }
                Button(row.isExcluded ? "Use When Generating" : "Don’t Use When Generating", systemImage: row.isExcluded ? "eye" : "eye.slash") {
                    setExcluded(!row.isExcluded, crn: crn)
                }
                Divider()
                Button("Copy CRN", systemImage: "doc.on.doc") { MacPasteboard.copy(crn) }
            }
        } primaryAction: { crns in
            if let crn = crns.first { choose(crn, entry: entry) }
        }
    }

    @ViewBuilder
    private func notes(for row: Row, showsCampus: Bool) -> some View {
        CourseFlowLayout(spacing: 4, lineSpacing: 3) {
            if row.isCurrent {
                TagLabel(text: "In schedule", systemImage: "checkmark", tint: .green)
            }
            if !row.overlapping.isEmpty {
                ScheduleConflictTag(text: row.overlapping.count == 1 ? "Overlaps \(row.overlapping[0])" : "Overlaps \(row.overlapping.count) courses")
            }
            if row.isExcluded {
                TagLabel(text: "Skipped", systemImage: "eye.slash")
            }
            if row.section.honors {
                TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
            }
            if showsCampus, !row.section.campus.isEmpty {
                TagLabel(text: row.section.campus, systemImage: row.section.isOnline ? "wifi" : "building.2")
            }
        }
    }

    // MARK: Preview

    private func previewColumn(resolved: ResolvedPlan, entry: ResolvedPlan.Entry, others: [CourseSection], highlighted: CourseSection?) -> some View {
        let colors = Dictionary(resolved.entries.map { ($0.key, $0.color) }, uniquingKeysWith: { first, _ in first })
        let solid = others.flatMap { section in
            CalendarEvent.events(for: section, color: colors[section.courseKey] ?? CourseColor.forCourse(section.courseKey))
        }
        let ghost = highlighted.map { CalendarEvent.events(for: $0, color: entry.color, isGhost: true) } ?? []
        let events = Self.previewEvents(solid: solid, ghost: ghost)
        let hours = MacCalendarRange.hours(for: events, preferences: userData.preferences, padding: 1)
        let days = MacCalendarRange.days(for: events, showWeekends: userData.preferences.showWeekends)
        return VStack(alignment: .leading, spacing: 8) {
            Text(highlighted.map { "Preview: \(ScheduleFormat.sectionTitle($0))" } ?? "Your week")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            MacWeekCalendar(
                events: events, days: days, hours: hours,
                minHourHeight: 18, maxHourHeight: 34, showsNowIndicator: false, compact: true
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(highlighted.map { "Preview of \(ScheduleFormat.fullLabel($0)) on your week" } ?? "Your week")
        }
    }

    /// Solid events plus ghost previews; anything that overlaps a ghost is marked as a conflict.
    private static func previewEvents(solid: [CalendarEvent], ghost: [CalendarEvent]) -> [CalendarEvent] {
        var base = CalendarEvent.markingConflicts(solid)
        var ghosts = ghost
        for g in ghosts.indices {
            for s in base.indices where base[s].day == ghosts[g].day && base[s].start < ghosts[g].end && ghosts[g].start < base[s].end
                && Meeting.dateWindowsOverlap(base[s].startDate, base[s].endDate, ghosts[g].startDate, ghosts[g].endDate) {
                base[s].isConflict = true
                ghosts[g].isConflict = true
            }
        }
        return base + ghosts
    }

    // MARK: Footer

    /// Live "Seats as of …" plus anything that went wrong refreshing.
    private var footerNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let refreshError {
                Label("Couldn’t refresh seats: \(refreshError) Showing the last known counts.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if let detailsError {
                Label("Instructor names couldn’t be loaded: \(detailsError)", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                PlanSeatsFreshness(date: catalog.liveRefreshedAt[courseKey] ?? index?.catalog.sectionsUpdatedAt, refreshHint: "")
                Button {
                    Task { await refreshSeats() }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh Seats", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bottom bar

    private func bottomBar(entry: ResolvedPlan.Entry, current: CourseSection?, highlighted: CourseSection?) -> some View {
        HStack(spacing: 10) {
            if let highlighted {
                let excluded = entry.planCourse.excludedCRNs.contains(highlighted.crn)
                Toggle(isOn: Binding(get: { excluded }, set: { setExcluded($0, crn: highlighted.crn) })) {
                    Text("Skip this section when generating")
                }
                .toggleStyle(.checkbox)
                .help("Generated schedules skip sections you don’t use")
            }
            Spacer()
            if current != nil {
                Button("Remove Section", role: .destructive) { clear(entry: entry) }
                    .help("Take this course’s section out of the schedule")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(buttonTitle(highlighted: highlighted, current: current)) {
                if let highlighted { choose(highlighted.crn, entry: entry) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(highlighted == nil || highlighted?.crn == current?.crn)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func buttonTitle(highlighted: CourseSection?, current: CourseSection?) -> String {
        guard let highlighted else { return "Use Section" }
        if highlighted.crn == current?.crn { return "Section Selected" }
        return "Use \(ScheduleFormat.sectionTitle(highlighted))"
    }

    // MARK: Data

    private func visibleRows(entry: ResolvedPlan.Entry, others: [CourseSection]) -> [Row] {
        entry.allSections.compactMap { section in
            if onlyOpen, section.isFull { return nil }
            let overlappingSections = ScheduleConflicts.sections(overlapping: section, in: others)
            if onlyFitting, !overlappingSections.isEmpty { return nil }
            return Row(
                section: section,
                isCurrent: entry.chosen?.crn == section.crn,
                isExcluded: entry.planCourse.excludedCRNs.contains(section.crn),
                overlapping: Array(Set(overlappingSections.map(\.courseKey))).sorted()
            )
        }
    }

    private var editor: MacSchedulePlanEditor {
        MacSchedulePlanEditor(userData: userData, planID: planID, undoManager: undoManager)
    }

    private func choose(_ crn: String, entry: ResolvedPlan.Entry) {
        editor.perform("Change Section") { plan in
            PlanEditing.setSection(crn, courseCRNs: entry.courseCRNs, in: &plan)
        }
        dismiss()
    }

    private func clear(entry: ResolvedPlan.Entry) {
        editor.perform("Remove Section") { plan in
            PlanEditing.setSection(nil, courseCRNs: entry.courseCRNs, in: &plan)
        }
        dismiss()
    }

    private func setExcluded(_ excluded: Bool, crn: String) {
        userData.updatePlan(id: planID) { plan in
            PlanEditing.setExcluded(excluded, crn: crn, for: courseKey, in: &plan)
        }
    }

    /// Instructors are fetched lazily; this makes them appear in the table (and says so when it can't).
    private func loadDetails() async {
        guard let termCode = plan?.termCode else { return }
        catalog.lastRefreshError = nil
        await catalog.ensureDetails(for: courseKey, termCode: termCode)
        loadedIndex = await catalog.index(for: termCode)
        if let message = catalog.lastRefreshError {
            catalog.lastRefreshError = nil
            detailsError = message
        } else {
            detailsError = nil
        }
    }

    private func refreshSeats() async {
        guard let termCode = plan?.termCode, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let before = catalog.liveRefreshedAt[courseKey]
        catalog.lastRefreshError = nil
        await catalog.refresh(course: courseKey, termCode: termCode)
        loadedIndex = await catalog.index(for: termCode)
        if let message = catalog.lastRefreshError {
            catalog.lastRefreshError = nil
            refreshError = message
            toast = PlanToast(text: "Couldn’t refresh seats", systemImage: "wifi.exclamationmark")
        } else if catalog.liveRefreshedAt[courseKey] != before {
            refreshError = nil
            toast = PlanToast(text: "Seats updated", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}
