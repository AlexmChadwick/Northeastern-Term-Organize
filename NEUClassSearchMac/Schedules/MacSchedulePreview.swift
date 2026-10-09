//
//  MacSchedulePreview.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The side pane of the schedules overview: the selected schedule's name and warnings, its week as a
/// real calendar that fills the pane (and shows more of each class the wider the pane gets), its
/// courses, and a button to open it.
struct MacSchedulePreview: View {
    var plan: SchedulePlan?
    var index: CatalogIndex?

    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator

    var body: some View {
        if let plan {
            let resolved = ResolvedPlan(plan: plan, index: index)
            VStack(alignment: .leading, spacing: 0) {
                header(plan: plan, resolved: resolved)
                Divider()
                calendar(plan: plan, resolved: resolved)
                Divider()
                footer(plan: plan, resolved: resolved)
            }
        } else {
            ContentUnavailableView("No schedule selected", systemImage: "calendar", description: Text("Select a schedule to preview its week."))
        }
    }

    // MARK: Header

    private func header(plan: SchedulePlan, resolved: ResolvedPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(plan.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if plan.isPrimary {
                    TagLabel(text: "My Schedule", systemImage: "star.fill", tint: .orange)
                }
            }
            Text(subtitle(plan: plan, resolved: resolved))
                .font(.callout)
                .foregroundStyle(.secondary)
            MacWarningLabels(warnings: resolved.warnings)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subtitle(plan: SchedulePlan, resolved: ResolvedPlan) -> String {
        let count = plan.courses.count
        var parts = [count == 1 ? "1 course" : "\(count) courses"]
        if resolved.hasCatalog, resolved.credits.max > 0 { parts.append(resolved.creditsLabel) }
        return parts.joined(separator: " · ")
    }

    // MARK: Calendar

    private func calendar(plan: SchedulePlan, resolved: ResolvedPlan) -> some View {
        let preferences = userData.preferences
        return ZStack {
            MacWeekCalendar(
                events: resolved.events,
                days: MacCalendarRange.days(for: resolved.events, showWeekends: preferences.showWeekends),
                hours: MacCalendarRange.hours(for: resolved.events, preferences: preferences),
                minHourHeight: 26,
                showsNowIndicator: false,
                extras: { event in
                    event.payload.flatMap { resolved.entry(forCRN: $0)?.section }.map(MacCalendarBlockExtras.init(section:)) ?? MacCalendarBlockExtras()
                }
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if resolved.events.isEmpty {
                Text(emptyHint(plan: plan, resolved: resolved))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyHint(plan: SchedulePlan, resolved: ResolvedPlan) -> String {
        if plan.courses.isEmpty { return "No courses yet" }
        if !resolved.hasCatalog { return "Open to view" }
        return resolved.hasSelection ? "No fixed meeting times" : "Choose sections"
    }

    // MARK: Footer

    private func footer(plan: SchedulePlan, resolved: ResolvedPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !plan.courses.isEmpty {
                CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(resolved.entries) { entry in
                        PlanCourseChip(
                            key: entry.key,
                            colorIndex: entry.planCourse.colorIndex,
                            isRequired: entry.planCourse.isRequired,
                            hasSection: entry.chosen != nil || !resolved.hasCatalog
                        )
                    }
                }
            }
            HStack {
                Spacer()
                Button("Open Schedule") { navigator.selection = .schedule(plan.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
