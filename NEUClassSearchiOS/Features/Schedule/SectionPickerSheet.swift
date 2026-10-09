//
//  SectionPickerSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Chooses the section of one plan course. Tapping a section highlights it and
/// previews it on a mini calendar (dashed, over the rest of the schedule);
/// "Use Section" commits the choice.
struct SectionPickerSheet: View {
    var planID: UUID
    var courseKey: CourseKey

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var highlightedCRN: String?
    @State private var onlyFitting = false
    @State private var onlyOpen = false
    @State private var haptic = PlanHaptic()
    @State private var toast: PlanToast?
    /// Why the last seat refresh failed, shown under the list until one succeeds.
    @State private var refreshError: String?
    /// Why instructor names couldn't be loaded.
    @State private var detailsError: String?

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    var body: some View {
        NavigationStack {
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
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .planToast($toast)
            .navigationTitle(courseKey.description)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(index?.course(courseKey)?.title ?? "Choose a section")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .task(id: plan?.termCode) { await loadDetails() }
        .planHaptic(haptic)
    }

    // MARK: Content

    @ViewBuilder
    private func picker(plan: SchedulePlan, resolved: ResolvedPlan, entry: ResolvedPlan.Entry) -> some View {
        let current = entry.chosen
        let highlighted = highlightedCRN.flatMap { crn in entry.allSections.first { $0.crn == crn } }
        let others = resolved.entries.filter { $0.key != courseKey }.flatMap(\.selected)
        let visible = visibleSections(entry: entry, others: others)
        // Campus tags only help when the course is taught on more than one campus.
        let multiCampus = Set(entry.allSections.map(\.campus)).count > 1

        List {
            if entry.allSections.isEmpty {
                ContentUnavailableView {
                    Label("No sections this term", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("\(courseKey.description) isn’t offered in \(index?.term.name ?? "this term").")
                }
                .listRowBackground(Color.clear)
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label("No matching sections", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Turn off a filter to see more of the \(entry.allSections.count) sections.")
                }
                .listRowBackground(Color.clear)
            } else {
                let grouped = groups(of: visible)
                ForEach(grouped, id: \.type) { group in
                    Section {
                        ForEach(group.sections) { section in
                            row(section, entry: entry, current: current, highlighted: highlighted, others: others, showsCampus: multiCampus)
                        }
                    } header: {
                        if grouped.count > 1 {
                            Text("\(group.type) · \(group.sections.count)")
                        }
                    } footer: {
                        if group.type == grouped.last?.type {
                            footerNotes
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshSeats() }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 6) {
                previewCalendar(resolved: resolved, entry: entry, others: others, highlighted: highlighted)
                filterChips(total: entry.allSections.count, shown: visible.count)
            }
        }
        .safeAreaBar(edge: .bottom) {
            bottomBar(plan: plan, entry: entry, current: current, highlighted: highlighted)
        }
        .onAppear {
            if highlightedCRN == nil { highlightedCRN = current?.crn }
        }
    }

    // MARK: Rows

    private func row(_ section: CourseSection, entry: ResolvedPlan.Entry, current: CourseSection?, highlighted: CourseSection?, others: [CourseSection], showsCampus: Bool) -> some View {
        let isCurrent = current?.crn == section.crn
        let isHighlighted = highlighted?.crn == section.crn
        let isExcluded = entry.planCourse.excludedCRNs.contains(section.crn)
        let overlapping = ScheduleConflicts.sections(overlapping: section, in: others)
        return Button {
            withAnimation(.snappy) { highlightedCRN = section.crn }
            haptic.fire(.selection)
        } label: {
            SectionPickerRow(
                section: section,
                color: entry.color,
                isCurrent: isCurrent,
                isHighlighted: isHighlighted,
                isExcluded: isExcluded,
                overlapping: overlapping,
                showsCampus: showsCampus
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(
            ZStack {
                Color(.secondarySystemGroupedBackground)
                if isHighlighted { entry.color.fill }
            }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                setExcluded(!isExcluded, crn: section.crn)
            } label: {
                Label(isExcluded ? "Use" : "Skip", systemImage: isExcluded ? "eye" : "eye.slash")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button {
                choose(section.crn, entry: entry)
            } label: {
                Label("Use This Section", systemImage: "checkmark.circle")
            }
            Button {
                setExcluded(!isExcluded, crn: section.crn)
            } label: {
                Label(isExcluded ? "Use When Generating" : "Don’t Use When Generating", systemImage: isExcluded ? "eye" : "eye.slash")
            }
        }
    }

    // MARK: Preview

    private func previewCalendar(resolved: ResolvedPlan, entry: ResolvedPlan.Entry, others: [CourseSection], highlighted: CourseSection?) -> some View {
        let colors = Dictionary(resolved.entries.map { ($0.key, $0.color) }, uniquingKeysWith: { first, _ in first })
        let solid = others.flatMap { section in
            CalendarEvent.events(for: section, color: colors[section.courseKey] ?? CourseColor.forCourse(section.courseKey))
        }
        let ghost = highlighted.map { CalendarEvent.events(for: $0, color: entry.color, isGhost: true) } ?? []
        let events = Self.previewEvents(solid: solid, ghost: ghost)

        // Hours that matter: the events plus an hour of padding, never less than a working day.
        let starts = events.map(\.start), ends = events.map(\.end)
        let lower = max(0, min((starts.min() ?? 9 * 60) / 60 - 1, 9))
        let upper = min(24, max(Int((Double(ends.max() ?? 17 * 60) / 60).rounded(.up)) + 1, 17))
        let range = lower...upper
        let days = PlanCalendarSupport.visibleDays(events: events, showWeekends: userData.preferences.showWeekends)
        let height: CGFloat = 132

        return VStack(spacing: 3) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    Text(DaySet.letters[day])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            WeekCalendarView(
                events: events,
                days: days,
                startHour: lower,
                endHour: upper,
                hourHeight: PlanCalendarSupport.hourHeight(fitting: height, range: range),
                compact: true,
                showsNowIndicator: false
            )
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(highlighted.map { "Preview of \(ScheduleFormat.fullLabel($0)) on your week" } ?? "Your week")
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, 4)
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

    private func filterChips(total: Int, shown: Int) -> some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    GlassChip(title: "No conflicts", systemImage: "checkmark.circle", isOn: onlyFitting) {
                        withAnimation(.snappy) { onlyFitting.toggle() }
                    }
                    GlassChip(title: "Open seats", systemImage: "chair.lounge", isOn: onlyOpen) {
                        withAnimation(.snappy) { onlyOpen.toggle() }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(shown == total ? "\(total) sections" : "\(shown) of \(total)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, 4)
    }

    // MARK: Bottom bar

    private func bottomBar(plan: SchedulePlan, entry: ResolvedPlan.Entry, current: CourseSection?, highlighted: CourseSection?) -> some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if let highlighted {
                    let excluded = entry.planCourse.excludedCRNs.contains(highlighted.crn)
                    Toggle(isOn: Binding(get: { excluded }, set: { setExcluded($0, crn: highlighted.crn) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Don’t use this section when generating")
                                .font(.subheadline.weight(.medium))
                            Text(ScheduleFormat.sectionTitleWithCRN(highlighted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                }
                HStack(spacing: 10) {
                    Button {
                        if let highlighted { choose(highlighted.crn, entry: entry) }
                    } label: {
                        Text(buttonTitle(highlighted: highlighted, current: current))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(highlighted == nil || highlighted?.crn == current?.crn)

                    if current != nil {
                        Button {
                            clear(entry: entry)
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 28)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .accessibilityLabel("Remove section from schedule")
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func buttonTitle(highlighted: CourseSection?, current: CourseSection?) -> String {
        guard let highlighted else { return "Choose a section" }
        if highlighted.crn == current?.crn { return "Section selected" }
        return "Use \(ScheduleFormat.sectionTitle(highlighted))"
    }

    // MARK: Data

    private struct SectionGroup {
        var type: String
        var sections: [CourseSection]
    }

    private func visibleSections(entry: ResolvedPlan.Entry, others: [CourseSection]) -> [CourseSection] {
        entry.allSections.filter { section in
            if onlyOpen, section.isFull { return false }
            if onlyFitting, !ScheduleConflicts.sections(overlapping: section, in: others).isEmpty { return false }
            return true
        }
    }

    private func groups(of sections: [CourseSection]) -> [SectionGroup] {
        var order: [String] = []
        var map: [String: [CourseSection]] = [:]
        for section in sections {
            if map[section.classType] == nil { order.append(section.classType) }
            map[section.classType, default: []].append(section)
        }
        return order.map { SectionGroup(type: $0, sections: map[$0] ?? []) }
    }

    /// Live "Seats as of …" plus anything that went wrong refreshing.
    private var footerNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let refreshError {
                Label("Couldn’t refresh seats: \(refreshError) Showing the last known counts.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if let detailsError {
                Label("Instructor names couldn’t be loaded: \(detailsError)", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            PlanSeatsFreshness(date: catalog.liveRefreshedAt[courseKey] ?? index?.catalog.sectionsUpdatedAt)
        }
    }

    private func choose(_ crn: String, entry: ResolvedPlan.Entry) {
        userData.updatePlan(id: planID) { plan in
            PlanEditing.setSection(crn, courseCRNs: entry.courseCRNs, in: &plan)
        }
        haptic.fire(.success)
        dismiss()
    }

    private func clear(entry: ResolvedPlan.Entry) {
        userData.updatePlan(id: planID) { plan in
            PlanEditing.setSection(nil, courseCRNs: entry.courseCRNs, in: &plan)
        }
        haptic.fire(.impact)
        dismiss()
    }

    private func setExcluded(_ excluded: Bool, crn: String) {
        userData.updatePlan(id: planID) { plan in
            PlanEditing.setExcluded(excluded, crn: crn, for: courseKey, in: &plan)
        }
        haptic.fire(.selection)
    }

    /// Instructors are fetched lazily; this makes them appear in the list (and says so when it can't).
    private func loadDetails() async {
        guard let termCode = plan?.termCode else { return }
        catalog.lastRefreshError = nil
        await catalog.ensureDetails(for: courseKey, termCode: termCode)
        loadedIndex = await catalog.index(for: termCode)
        if let message = catalog.lastRefreshError {
            catalog.lastRefreshError = nil      // reported here, so the app-wide banner stays quiet
            detailsError = message
        } else {
            detailsError = nil
        }
    }

    private func refreshSeats() async {
        guard let termCode = plan?.termCode else { return }
        let before = catalog.liveRefreshedAt[courseKey]
        catalog.lastRefreshError = nil
        await catalog.refresh(course: courseKey, termCode: termCode)
        loadedIndex = await catalog.index(for: termCode)
        if let message = catalog.lastRefreshError {
            catalog.lastRefreshError = nil
            refreshError = message
            haptic.fire(.warning)
            toast = PlanToast(text: "Couldn’t refresh seats", systemImage: "wifi.exclamationmark")
        } else if catalog.liveRefreshedAt[courseKey] != before {
            refreshError = nil
            haptic.fire(.success)
            toast = PlanToast(text: "Seats updated", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}

// MARK: - Row

private struct SectionPickerRow: View {
    var section: CourseSection
    var color: CourseColor
    var isCurrent: Bool
    var isHighlighted: Bool
    var isExcluded: Bool
    var overlapping: [CourseSection]
    var showsCampus: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : (isHighlighted ? "circle.inset.filled" : "circle"))
                .font(.title3)
                .foregroundStyle(isCurrent || isHighlighted ? AnyShapeStyle(color.stroke) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ScheduleFormat.sectionTitle(section))
                        .font(.subheadline.weight(.semibold))
                    Text("CRN \(section.crn)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    SeatsBadge(section: section)
                }
                Text(section.scheduleSummary)
                    .font(.subheadline)
                    .foregroundStyle(isExcluded ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                tags
            }
        }
        .padding(.vertical, 3)
        .opacity(isExcluded ? 0.65 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted || isCurrent ? .isSelected : [])
        .accessibilityHint("Highlights this section on your calendar")
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let location = ScheduleFormat.location(of: section) { parts.append(location) }
        if let instructors = ScheduleFormat.instructors(of: section) { parts.append(instructors) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var tags: some View {
        let hasTags = !overlapping.isEmpty || isExcluded || section.honors || isCurrent || showsCampus
        if hasTags {
            PlanFlowLayout(spacing: 6, lineSpacing: 4) {
                if isCurrent {
                    TagLabel(text: "In your schedule", systemImage: "checkmark", tint: .green)
                }
                if !overlapping.isEmpty {
                    ScheduleConflictTag(text: conflictText)
                }
                if isExcluded {
                    TagLabel(text: "Skipped when generating", systemImage: "eye.slash")
                }
                if section.honors {
                    TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
                }
                if showsCampus, !section.campus.isEmpty {
                    TagLabel(text: section.campus, systemImage: section.isOnline ? "wifi" : "building.2")
                }
            }
        }
    }

    private var conflictText: String {
        let keys = Array(Set(overlapping.map(\.courseKey))).sorted()
        if keys.count == 1 { return "Overlaps \(keys[0])" }
        return "Overlaps \(keys.count) courses"
    }
}
