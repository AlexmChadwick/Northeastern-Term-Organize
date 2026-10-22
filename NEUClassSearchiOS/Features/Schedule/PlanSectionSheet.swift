//
//  PlanSectionSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// Details of one scheduled section, shown when its block is tapped on the
/// calendar: where and when it meets, who teaches it, seats, plus actions.
struct PlanSectionSheet: View {
    var planID: UUID
    var crn: String
    var onChangeSection: (CourseKey, String) -> Void
    var onViewCourse: (CourseKey) -> Void

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var copied = false
    @State private var haptic = PlanHaptic()
    /// Why instructor names couldn't be loaded (nil when they loaded or nothing was needed).
    @State private var detailsError: String?
    @State private var isLoadingDetails = false

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan, let found = ResolvedPlan(plan: plan, index: index).entry(forCRN: crn) {
                    details(plan: plan, entry: found.entry, section: found.section)
                } else if index == nil, !indexLoadFinished || catalog.loadState == .loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Section not found", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("This section is no longer part of the schedule.")
                    }
                }
            }
            .navigationTitle("Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .task(id: index?.section(crn: crn)?.courseKey) { await loadDetails() }
        .planHaptic(haptic)
    }

    /// Instructors are fetched lazily; this fills them in when they are missing, and
    /// remembers the reason when that fails so the sheet can say so.
    private func loadDetails() async {
        guard let termCode = plan?.termCode, let key = index?.section(crn: crn)?.courseKey else { return }
        isLoadingDetails = true
        defer { isLoadingDetails = false }
        catalog.lastRefreshError = nil
        await catalog.ensureDetails(for: key, termCode: termCode)
        loadedIndex = await catalog.index(for: termCode)
        if let message = catalog.lastRefreshError {
            catalog.lastRefreshError = nil      // reported here, so the app-wide banner stays quiet
            detailsError = message
            haptic.fire(.warning)
        } else {
            detailsError = nil
        }
    }

    // MARK: Content

    private func details(plan: SchedulePlan, entry: ResolvedPlan.Entry, section: CourseSection) -> some View {
        let resolved = ResolvedPlan(plan: plan, index: index)
        let others = resolved.selectedSections.filter { $0.crn != section.crn }
        let overlapping = ScheduleConflicts.sections(overlapping: section, in: others)
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        PlanColorDot(colorIndex: entry.planCourse.colorIndex)
                        Text(entry.key.description)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(entry.color.text)
                        if let course = entry.course {
                            Text(course.creditsLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(section.title.isEmpty ? entry.title : section.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ScheduleFormat.sectionTitleWithCRN(section))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }

            Section {
                scheduleRows(section)
                if let instructors = ScheduleFormat.instructors(of: section) {
                    LabeledContent {
                        Text(instructors).multilineTextAlignment(.trailing)
                    } label: {
                        Label("Instructor", systemImage: "person")
                    }
                }
                LabeledContent {
                    SeatsBadge(section: section, style: .detailed)
                } label: {
                    Label("Seats", systemImage: "chair.lounge")
                }
                if !overlapping.isEmpty {
                    LabeledContent {
                        Text(overlapping.map { "\($0.courseKey)" }.joined(separator: ", "))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Overlaps", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            if let detailsError, ScheduleFormat.instructors(of: section) == nil {
                Section {
                    Button {
                        Task { await loadDetails() }
                    } label: {
                        HStack {
                            Label("Try Again", systemImage: "arrow.clockwise")
                            if isLoadingDetails {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isLoadingDetails)
                } footer: {
                    Label("Instructor names couldn’t be loaded: \(detailsError)", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    onChangeSection(entry.key, entry.id)
                } label: {
                    Label("Change Section", systemImage: "arrow.left.arrow.right")
                }
                Button {
                    onViewCourse(entry.key)
                } label: {
                    Label("View Course", systemImage: "book")
                }
                Button {
                    UIPasteboard.general.string = section.crn
                    haptic.fire(.success)
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied CRN \(section.crn)" : "Copy CRN", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Button(role: .destructive) {
                    userData.updatePlan(id: planID) { plan in
                        PlanEditing.setSection(nil, courseCRNs: entry.courseCRNs.union([section.crn]), entryID: entry.id, in: &plan)
                    }
                    haptic.fire(.impact)
                    dismiss()
                } label: {
                    Label("Remove from Schedule", systemImage: "minus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func scheduleRows(_ section: CourseSection) -> some View {
        let meetings = section.weeklyMeetings
        if meetings.isEmpty {
            LabeledContent {
                Text(section.scheduleSummary).multilineTextAlignment(.trailing)
            } label: {
                Label("When", systemImage: "clock")
            }
        } else {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(Array(meetings.enumerated()), id: \.offset) { _, meeting in
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(meeting.days.shortLabel)")
                            Text(meeting.timeLabel).foregroundStyle(.secondary)
                        }
                    }
                }
                .multilineTextAlignment(.trailing)
            } label: {
                Label("When", systemImage: "clock")
            }
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(locations(of: section).enumerated()), id: \.offset) { _, location in
                        Text(location)
                    }
                }
                .multilineTextAlignment(.trailing)
            } label: {
                Label("Where", systemImage: "mappin.and.ellipse")
            }
            if let range = dateRange(of: section) {
                LabeledContent {
                    Text(range)
                } label: {
                    Label("Dates", systemImage: "calendar")
                }
            }
        }
        if let exam = section.finalExam, let examDate = ScheduleDates.date(fromISO: exam.startDate) {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(examDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    if exam.start != nil { Text(exam.timeLabel).foregroundStyle(.secondary) }
                }
                .multilineTextAlignment(.trailing)
            } label: {
                Label("Final exam", systemImage: "doc.text")
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
