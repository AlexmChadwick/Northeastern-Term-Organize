//
//  MacUpNextMenu.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI

/// The menu bar extra: the class in progress or the next one from "My Schedule", and the rest of
/// today's classes. "My Schedule" is the primary schedule of the term in session (or the next
/// to start), whichever term the main window shows, the same one the iPhone's widgets use.
struct MacUpNextMenu: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Settings › General › "Show Up Next in the menu bar".
    @AppStorage("mac.showsMenuBarExtra") private var showsMenuBarExtra = true

    /// Where the schedule comes from: the user's own in the app, a fixed one in snapshots.
    enum Source {
        case primarySchedule
        case fixed(SchedulePlan?)
    }

    /// The current time. A ticker in state, like everywhere in the shell.
    @State private var now: Date
    /// The term whose course data couldn't be loaded, so the menu says so instead of loading forever.
    @State private var unavailableTermCode: String?
    private let isPinned: Bool
    private let source: Source

    /// - Parameters:
    ///   - now: a fixed time instead of the clock (snapshots only).
    ///   - source: a fixed schedule instead of the primary one (snapshots only).
    init(now: Date? = nil, source: Source = .primarySchedule) {
        _now = State(initialValue: now ?? MacShellClock.now)
        isPinned = now != nil
        self.source = source
    }

    private static let width: CGFloat = 340

    var body: some View {
        let plan = currentPlan
        // Any loaded term works (it is observable); a plan for a term that isn't loaded yet is
        // loaded in the background and the menu fills in when it arrives.
        let index = plan.flatMap { catalog.cachedIndex(for: $0.termCode) }

        VStack(alignment: .leading, spacing: 0) {
            header(plan: plan, index: index)
            Divider()
            content(plan: plan, index: index)
            Divider()
            footer(plan: plan)
        }
        .frame(width: Self.width)
        .task(id: plan?.termCode) {
            guard let code = plan?.termCode else { return }
            unavailableTermCode = await catalog.index(for: code) == nil ? code : nil
        }
        .task {
            guard !isPinned else { return }
            await MacShellClock.everyMinute { now = $0 }
        }
        // The menu may have been closed for hours: show the current time as it opens.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if !isPinned { now = MacShellClock.now }
        }
    }

    private var currentPlan: SchedulePlan? {
        switch source {
        case .primarySchedule: userData.activePrimaryPlan(now: now)
        case .fixed(let plan): plan
        }
    }

    // MARK: Header

    private func header(plan: SchedulePlan?, index: CatalogIndex?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Up Next", systemImage: "calendar.badge.clock")
                .font(.headline)
            Spacer()
            if let plan {
                Text([index?.term.shortName, plan.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private func content(plan: SchedulePlan?, index: CatalogIndex?) -> some View {
        switch UpNextClass.find(plan: plan, index: index, now: now) {
        case .class(let item):
            VStack(alignment: .leading, spacing: 12) {
                MacUpNextCard(item: item)
                if let plan, let index {
                    MacUpNextToday(
                        occurrences: ScheduleWidgetBuilder.make(plan: plan, index: index, now: now).classes(on: now),
                        now: now
                    )
                }
            }
            .padding(14)
        case .termEnded:
            message(
                "Term Complete",
                systemImage: "checkmark.seal",
                detail: "The last class day of \(index?.term.shortName ?? "this term") has passed."
            )
        case .noClasses:
            message(
                "No Classes",
                systemImage: "calendar",
                detail: "\(plan?.name ?? "This schedule") has no classes with fixed times."
            )
        case .unavailable:
            if plan == nil {
                message(
                    "No Schedule Yet",
                    systemImage: "calendar.badge.plus",
                    detail: "Mark a schedule as My Schedule to see its classes here."
                )
            } else if let plan, unavailableTermCode == plan.termCode {
                message(
                    "Course Data Unavailable",
                    systemImage: "exclamationmark.triangle",
                    detail: "The course data for this schedule's term isn't on this Mac. Open Term Organize to download it."
                )
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading your schedule…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }

    private func message(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private func footer(plan: SchedulePlan?) -> some View {
        HStack(spacing: 8) {
            Button(plan == nil ? "Open Schedules" : "Open Schedule") {
                navigator.selection = plan.map { .schedule($0.id) } ?? .schedules
                MacShellWindows.showMain(openWindow: openWindow)
            }
            Button("Open Term Organize") {
                MacShellWindows.showMain(openWindow: openWindow)
            }
            Spacer()
            Menu {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Divider()
                Button("Hide Up Next in the Menu Bar") {
                    showsMenuBarExtra = false
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Pieces

/// The class in progress or the next to start: its colour, when it starts or ends, and where.
private struct MacUpNextCard: View {
    var item: UpNextClass.Item

    private var tint: Color { CourseColor.at(item.meeting.colorIndex).stroke }

    private var overline: String {
        if item.isInProgress { return "In class" }
        return Calendar.current.isDate(item.start, inSameDayAs: item.now) ? "Up next" : "Next class"
    }

    /// `in 25 min`, `35 min left`, `Tomorrow`, `Mon`.
    private var trailing: String {
        if item.isInProgress {
            let minutes = max(1, Int((item.end.timeIntervalSince(item.now) / 60).rounded(.up)))
            return minutes < 60 ? "\(minutes) min left" : "ends \(TimeOfDay.label(item.meeting.end))"
        }
        return item.relativeText
    }

    private var timeText: String {
        let range = TimeOfDay.rangeLabel(start: item.meeting.start, end: item.meeting.end)
        let calendar = Calendar.current
        if calendar.isDate(item.start, inSameDayAs: item.now) { return range }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: item.now)
        let day = tomorrow.map { calendar.isDate(item.start, inSameDayAs: $0) } == true
            ? "Tomorrow"
            : item.start.formatted(.dateTime.weekday(.wide))
        return "\(day), \(range)"
    }

    private var locationText: String? {
        let location = item.meeting.location
        return location.isEmpty ? nil : location
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(overline.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.isInProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Spacer()
                    Text(trailing)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(item.isInProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .monospacedDigit()
                }
                Text(item.meeting.courseCode)
                    .font(.title3.weight(.bold))
                Text(item.meeting.title)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label(timeText, systemImage: "clock")
                    if let locationText {
                        Label(locationText, systemImage: "mappin.and.ellipse")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.top, 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }
}

/// Today's classes in order: finished ones dimmed, the one in progress marked.
private struct MacUpNextToday: View {
    var occurrences: [WidgetScheduleData.Occurrence]
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today")
                .font(.subheadline.weight(.semibold))
            if occurrences.isEmpty {
                Label("No classes today", systemImage: "moon.zzz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(occurrences) { occurrence in
                        row(occurrence)
                    }
                }
            }
        }
    }

    private func row(_ occurrence: WidgetScheduleData.Occurrence) -> some View {
        let meeting = occurrence.meeting
        let isCurrent = occurrence.start <= now && now < occurrence.end
        let isPast = occurrence.end <= now
        return HStack(spacing: 8) {
            Circle()
                .fill(isPast ? AnyShapeStyle(.quaternary) : AnyShapeStyle(CourseColor.at(meeting.colorIndex).stroke))
                .frame(width: 8, height: 8)
            Text(TimeOfDay.label(meeting.start))
                .monospacedDigit()
                .frame(width: 66, alignment: .leading)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(meeting.courseCode)
                .fontWeight(isCurrent ? .bold : .semibold)
            Text(meeting.classType)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(meeting.location)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .opacity(isPast ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meeting.courseCode) \(meeting.classType), \(TimeOfDay.rangeLabel(start: meeting.start, end: meeting.end)), \(meeting.location)\(isCurrent ? ", in progress" : isPast ? ", finished" : "")")
    }
}
