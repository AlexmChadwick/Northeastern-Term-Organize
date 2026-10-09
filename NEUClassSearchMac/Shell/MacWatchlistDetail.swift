//
//  MacWatchlistDetail.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The pane beside the Watchlist: the selected section in full (how many seats it has, when and
/// where it meets, who teaches it, the alerts for it) with the actions for it, so a section can be
/// looked over without opening its course. Below it, the watched sections on a week, which fills
/// the pane and shows which of them meet at the same time.
struct MacWatchlistDetail: View {
    /// The selected sections, in the order of the table.
    var rows: [MacWatchRow]
    /// Every section the table lists, for the week.
    var allRows: [MacWatchRow]
    /// The term the week shows when no section is selected (the one the app is on).
    var preferredTermCode: String?
    var showsWeekends: Bool
    /// The catalog's course for a section, for its credits.
    var course: (MacWatchRow) -> Course?
    var now: Date
    /// Whether every selected section also alerts for waitlist spots.
    @Binding var notifiesOnWaitlist: Bool
    var onOpen: () -> Void
    var onCopy: () -> Void
    var onStop: () -> Void
    /// A section was clicked on the week.
    var onSelect: (MacWatchRow.ID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if rows.isEmpty {
                    MacWatchlistNoSelection()
                } else if rows.count == 1, let row = rows.first {
                    MacWatchlistSectionDetail(
                        row: row,
                        course: course(row),
                        now: now,
                        notifiesOnWaitlist: $notifiesOnWaitlist,
                        onOpen: onOpen,
                        onCopy: onCopy,
                        onStop: onStop
                    )
                } else {
                    MacWatchlistSelectionDetail(rows: rows, notifiesOnWaitlist: $notifiesOnWaitlist, onCopy: onCopy, onStop: onStop)
                }
                MacWatchlistWeek(
                    rows: allRows,
                    selected: Set(rows.map(\.id)),
                    preferredTermCode: preferredTermCode,
                    showsWeekends: showsWeekends,
                    onSelect: onSelect
                )
            }
            .padding(16)
        }
    }
}

/// What the Watchlist shows before anything is watched: what it does and how to start, as three steps
/// that sit side by side in a wide window and stack in a narrow one.
struct MacWatchlistEmptyState: View {
    var findCourse: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 52))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Watch Full Sections")
                            .font(.largeTitle.weight(.semibold))
                        Text("Get a notification on this Mac when a seat or waitlist spot opens up. No account or phone number needed.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) { steps }
                        VStack(spacing: 12) { steps }
                            .frame(maxWidth: 480)
                    }
                    Button(action: findCourse) {
                        Text("Find a Course")
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        MacWatchlistStep(
            number: 1, symbol: "magnifyingglass", title: "Find a full section",
            text: "Search for a course and open it to see its sections and how many seats are left."
        )
        MacWatchlistStep(
            number: 2, symbol: "bell", title: "Click the bell",
            text: "Each section has a bell. Click it to watch the section; it is listed here from then on."
        )
        MacWatchlistStep(
            number: 3, symbol: "bell.badge", title: "Get notified",
            text: "While \(LegalText.appName) is open it checks every \(MacWatchlistMonitor.minutes) minutes and tells you when a seat opens."
        )
    }
}

private struct MacWatchlistStep: View {
    var number: Int
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.12), in: .circle)
                    .accessibilityHidden(true)
                Text("Step \(number)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.title3.weight(.semibold))
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 220, maxWidth: 340, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// What the pane says while no section is selected.
private struct MacWatchlistNoSelection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No Section Selected", systemImage: "bell")
                .font(.title3.weight(.semibold))
            Text("Select a watched section to see its seats, times and alerts, or pick one from the week below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The watched sections of one term on a week, colored by their seats, so which of them meet at the
/// same time (and so can't all be taken) shows at a glance. Selected sections stand out, and a click
/// on one selects it.
private struct MacWatchlistWeek: View {
    var rows: [MacWatchRow]
    var selected: Set<MacWatchRow.ID>
    var preferredTermCode: String?
    var showsWeekends: Bool
    var onSelect: (MacWatchRow.ID) -> Void

    /// The term of what is selected, else the one the app is on, else the first listed.
    private var termCode: String? {
        if let first = rows.first(where: { selected.contains($0.id) }) { return first.item.termCode }
        if let preferredTermCode, rows.contains(where: { $0.item.termCode == preferredTermCode }) { return preferredTermCode }
        return rows.first?.item.termCode
    }

    private var shown: [MacWatchRow] {
        guard let termCode else { return [] }
        return rows.filter { $0.item.termCode == termCode }
    }

    private var events: [CalendarEvent] {
        shown.flatMap { row -> [CalendarEvent] in
            guard let section = row.section else { return [] }
            // With a selection, the others fade back.
            let dimmed = !selected.isEmpty && !selected.contains(row.id)
            let color = CourseColor(base: row.status.color.opacity(dimmed ? 0.4 : 1))
            return CalendarEvent.events(for: section, color: color, title: row.courseKey.description)
        }
    }

    private var statuses: [WatchlistStatus] {
        let present = Set(shown.filter { $0.section != nil }.map(\.status))
        let all: [WatchlistStatus] = [.open, .waitlist, .full, .missing]
        return all.filter { present.contains($0) }
    }

    var body: some View {
        let events = events
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Week at a Glance")
                        .font(.headline)
                    Spacer(minLength: 8)
                    if let name = shown.first?.termName {
                        Text(name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                legend
                WeekCalendarView(
                    events: events,
                    showWeekends: showsWeekends,
                    startHour: 8,
                    endHour: 18,
                    hourHeight: 34,
                    onSelect: { event in
                        if let crn = event.payload, let row = shown.first(where: { $0.crn == crn }) { onSelect(row.id) }
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(statuses, id: \.self) { status in
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(Self.name(of: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static func name(of status: WatchlistStatus) -> String {
        switch status {
        case .open: "Seats open"
        case .waitlist: "Waitlist"
        case .full: "Full"
        case .missing: "No longer listed"
        }
    }
}

/// One selected section.
private struct MacWatchlistSectionDetail: View {
    var row: MacWatchRow
    var course: Course?
    var now: Date
    @Binding var notifiesOnWaitlist: Bool
    var onOpen: () -> Void
    var onCopy: () -> Void
    var onStop: () -> Void

    private var item: WatchItem { row.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            seats
            facts
            alerts
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.courseKey.description)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tint)
                TagLabel(text: row.termName, systemImage: "calendar")
            }
            Text(item.courseTitle)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.sectionLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Seats

    private var seats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(row.status.detail(for: item))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            } icon: {
                Image(systemName: row.status.symbol)
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(row.status.color)
            if row.status != .missing, item.seatCapacity > 0 {
                SeatMeter(remaining: item.lastSeatsRemaining, capacity: item.seatCapacity)
            }
            if row.status == .missing {
                Text("The registrar no longer lists this CRN. The numbers are from the last time it did.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let date = item.lastCheckedAt {
                Text("Checked \(WatchlistFormat.ago(date, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row.status.color.opacity(0.1), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: Facts

    private var facts: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 9) {
            GridRow {
                label("CRN")
                HStack(spacing: 8) {
                    Text(item.crn)
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the CRN")
                    .accessibilityLabel("Copy CRN")
                }
            }
            GridRow {
                label("Instructor")
                Text(instructorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GridRow {
                label("Meets")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(meetingLines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(line.time)
                                .monospacedDigit()
                            if let place = line.place {
                                Text(place)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let section = row.section {
                GridRow {
                    label("Campus")
                    Text([section.campus, section.instructionMethod].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
            if let course {
                GridRow {
                    label("Credits")
                    Text(course.creditsLabel)
                }
            }
            GridRow {
                label("Watching since")
                Text(item.addedAt, format: .dateTime.month(.abbreviated).day().year())
            }
            GridRow {
                label("Last opening")
                if let date = item.lastNotifiedAt {
                    Text(WatchlistFormat.ago(date, now: now))
                } else {
                    Text("Not yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.body)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
            .frame(width: 96, alignment: .leading)
    }

    private var instructorText: String {
        guard let section = row.section, let instructors = section.instructors else { return "Not loaded yet" }
        return instructors.isEmpty ? "To be announced" : section.instructorLabel
    }

    private struct MeetingLine {
        var time: String
        var place: String?
    }

    private var meetingLines: [MeetingLine] {
        guard let section = row.section else { return [MeetingLine(time: "Not loaded yet", place: nil)] }
        let weekly = section.weeklyMeetings
        guard !weekly.isEmpty else {
            return [MeetingLine(time: section.isOnline ? "Asynchronous / online" : "Times to be announced", place: nil)]
        }
        return weekly.map { meeting in
            MeetingLine(
                time: "\(meeting.days.compactLabel) \(meeting.timeLabel)",
                place: meeting.isOnline ? "Online" : meeting.longLocationLabel
            )
        }
    }

    // MARK: Alerts and actions

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Also notify for waitlist spots", isOn: $notifiesOnWaitlist)
            Text("You are always notified when a seat opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
                Label("Open Course Window", systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button(role: .destructive, action: onStop) {
                Label("Stop Watching", systemImage: "bell.slash")
            }
        }
    }
}

/// Several selected sections: which they are, and what can be done to all of them.
private struct MacWatchlistSelectionDetail: View {
    var rows: [MacWatchRow]
    @Binding var notifiesOnWaitlist: Bool
    var onCopy: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rows.count) Sections Selected")
                    .font(.title3.weight(.semibold))
                Text(openSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.status.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(row.status.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(row.courseKey.description) · \(row.sectionName)")
                                .fontWeight(.medium)
                            Text("CRN \(row.crn) · \(row.status.detail(for: row.item))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Toggle("Also notify for waitlist spots", isOn: $notifiesOnWaitlist)
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onCopy) {
                    Label("Copy CRNs", systemImage: "doc.on.doc")
                }
                Button(role: .destructive, action: onStop) {
                    Label("Stop Watching \(rows.count) Sections…", systemImage: "bell.slash")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var openSummary: String {
        let open = rows.filter { $0.status == .open }.count
        return open == 0 ? "None has a seat open" : "\(open) with a seat open"
    }
}
