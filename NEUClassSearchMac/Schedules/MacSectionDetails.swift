//
//  MacSectionDetails.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The popover a click on a class of the calendar opens: where and when it meets, who teaches it, the
/// seats, and what can be done with it (another section, the course window, the CRN, removing it).
struct MacSectionDetailsView: View {
    var planID: UUID
    var crn: String
    /// The window's undo manager, so removing the section can be undone with ⌘Z.
    var undoManager: UndoManager?
    var onChangeSection: (CourseKey, String) -> Void

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var copied = false
    /// Why instructor names couldn't be loaded (nil when they loaded or nothing was needed).
    @State private var detailsError: String?
    @State private var isLoadingDetails = false

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    var body: some View {
        Group {
            if let plan, let found = ResolvedPlan(plan: plan, index: index).entry(forCRN: crn) {
                details(plan: plan, entry: found.entry, section: found.section)
            } else if index == nil, !indexLoadFinished || catalog.loadState == .loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ContentUnavailableView {
                    Label("Section not found", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("This section is no longer part of the schedule.")
                }
            }
        }
        .frame(width: 360)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .task(id: index?.section(crn: crn)?.courseKey) { await loadDetails() }
    }

    /// Instructors are fetched lazily; this fills them in when they are missing, and remembers the
    /// reason when that fails so the popover can say so.
    private func loadDetails() async {
        guard let termCode = plan?.termCode, let key = index?.section(crn: crn)?.courseKey else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }
        catalog.lastRefreshError = nil
        await catalog.ensureDetails(for: key, termCode: termCode)
        loadedIndex = await catalog.index(for: termCode)
        if let message = catalog.lastRefreshError {
            // Reported here, so the app-wide banner stays quiet.
            catalog.lastRefreshError = nil
            detailsError = message
        } else {
            detailsError = nil
        }
    }

    // MARK: Content

    private func details(plan: SchedulePlan, entry: ResolvedPlan.Entry, section: CourseSection) -> some View {
        let resolved = ResolvedPlan(plan: plan, index: index)
        let others = resolved.selectedSections.filter { $0.crn != section.crn }
        let overlapping = ScheduleConflicts.sections(overlapping: section, in: others)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    PlanColorDot(colorIndex: entry.planCourse.colorIndex)
                    Text(entry.key.description)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(entry.color.text)
                    if let course = entry.course {
                        Text(course.creditsLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(section.title.isEmpty ? entry.title : section.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(ScheduleFormat.sectionTitleWithCRN(section))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Button {
                        MacPasteboard.copy(section.crn)
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy CRN \(section.crn)")
                    .accessibilityLabel(copied ? "Copied CRN" : "Copy CRN")
                }
            }

            MacSectionFacts(section: section, overlapping: overlapping)

            if let detailsError, ScheduleFormat.instructors(of: section) == nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label("Instructor names couldn’t be loaded: \(detailsError)", systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Try Again") { Task { await loadDetails() } }
                        .controlSize(.small)
                        .disabled(isLoadingDetails)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Change Section…") {
                    dismiss()
                    onChangeSection(entry.key, entry.id)
                }
                Button("View Course") {
                    openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: plan.termCode, key: entry.key))
                }
                Spacer(minLength: 0)
                Button("Remove", role: .destructive) {
                    MacSchedulePlanEditor(userData: userData, planID: planID, undoManager: undoManager).perform("Remove Section") { plan in
                        PlanEditing.setSection(nil, courseCRNs: entry.courseCRNs.union([section.crn]), entryID: entry.id, in: &plan)
                    }
                    dismiss()
                }
                .help("Remove this section from the schedule")
            }
            .controlSize(.small)
        }
        .padding(16)
    }
}

/// The facts of one section as a grid: when and where it meets, who teaches it, the seats, the final
/// exam, and which other courses it overlaps.
struct MacSectionFacts: View {
    var section: CourseSection
    /// Sections of the schedule that meet at the same time as this one.
    var overlapping: [CourseSection] = []

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
            scheduleRows(section)
            if let instructors = ScheduleFormat.instructors(of: section) {
                row("Instructor", systemImage: "person") { Text(instructors) }
            }
            row("Seats", systemImage: "chair.lounge") { SeatsBadge(section: section, style: .detailed) }
            if !overlapping.isEmpty {
                row("Overlaps", systemImage: "exclamationmark.triangle.fill", tint: .red) {
                    Text(Array(Set(overlapping.map(\.courseKey))).sorted().map { "\($0)" }.joined(separator: ", "))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func row<Content: View>(_ title: String, systemImage: String, tint: Color = .secondary, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)
                .gridColumnAlignment(.leading)
            content()
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func scheduleRows(_ section: CourseSection) -> some View {
        let meetings = section.weeklyMeetings
        if meetings.isEmpty {
            row("When", systemImage: "clock") { Text(section.scheduleSummary) }
        } else {
            row("When", systemImage: "clock") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(meetings.enumerated()), id: \.offset) { _, meeting in
                        Text("\(meeting.days.shortLabel), \(meeting.timeLabel)")
                    }
                }
            }
            row("Where", systemImage: "mappin.and.ellipse") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(locations(of: section).enumerated()), id: \.offset) { _, location in
                        Text(location)
                    }
                }
            }
            if let range = dateRange(of: section) {
                row("Dates", systemImage: "calendar") { Text(range) }
            }
        }
        if let exam = section.finalExam, let examDate = ScheduleDates.date(fromISO: exam.startDate) {
            row("Final exam", systemImage: "doc.text") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(examDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    if exam.start != nil { Text(exam.timeLabel).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func locations(of section: CourseSection) -> [String] {
        var seen: [String] = []
        for meeting in section.weeklyMeetings {
            let label = meeting.isOnline ? "Online" : meeting.longLocationLabel
            if !seen.contains(label) { seen.append(label) }
        }
        return seen
    }

    private func dateRange(of section: CourseSection) -> String? {
        let starts = section.weeklyMeetings.compactMap { ScheduleDates.date(fromISO: $0.startDate) }
        let ends = section.weeklyMeetings.compactMap { ScheduleDates.date(fromISO: $0.endDate) }
        guard let start = starts.min(), let end = ends.max() else { return nil }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }
}
