//
//  MacRoomInspector.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The inspector of the Free Rooms screen: whether the selected room is free at the time on
/// screen and what happens next, a timeline of its classes for a day (or its whole week), and
/// those classes as a list. Clicking a class opens its course in a window of its own.
///
/// Don't wrap this in a `TimelineView`: the calendar draws its "now" line with one of its own, and
/// nested timelines send SwiftUI into an endless render loop. The clock comes in as `now`.
struct MacRoomInspector: View {
    var index: CatalogIndex
    var room: RoomSchedule
    /// The time the table shows: now, or the day and time the user chose.
    var moment: RoomAvailability.Moment
    var isNow: Bool
    var now: Date
    var classDates: RoomAvailability.ClassDates?
    /// Back to the overview the pane shows while no room is selected.
    var onShowOverview: (() -> Void)?

    @Environment(UserDataStore.self) private var userData
    @Environment(\.openWindow) private var openWindow

    private enum Mode: Hashable {
        case day, week
    }

    @State private var mode = Mode.day
    /// The weekday chosen in the inspector; nil follows the time on screen.
    @State private var dayOverride: Int?

    private var weekday: Int { dayOverride ?? moment.weekday }

    var body: some View {
        let status = RoomAvailability.status(of: room, at: moment)
        let today = RoomAvailability.bookings(of: room, on: moment.weekday, date: moment.date)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let onShowOverview {
                    Button(action: onShowOverview) {
                        Label("Overview", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Back to the overview of the rooms in the list")
                }
                statusHeader(status: status, today: today)
                notices

                VStack(alignment: .leading, spacing: 10) {
                    controls
                    switch mode {
                    case .day: dayTimeline
                    case .week: weekCalendar
                    }
                }

                classList
                Text(RoomsText.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .onChange(of: room.id) { dayOverride = nil }
        .onChange(of: moment.weekday) { dayOverride = nil }
        .onAppear {
            // Debug snapshots can open on the week (`-MacSnapshotRoomMode week`).
            #if DEBUG
            if MacShellRun.isSnapshot, UserDefaults.standard.string(forKey: "MacSnapshotRoomMode") == "week" { mode = .week }
            #endif
        }
    }

    // MARK: Status

    private func statusHeader(status: RoomAvailability.Status, today: [RoomSchedule.Booking]) -> some View {
        let tint = status.roomsTint(at: moment)
        let note = RoomsText.followUpNote(status: status, today: today)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.label)
                    .font(.title2.weight(.bold))
                Text(room.buildingName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: status.roomsSymbol)
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.detailedSummary)
                        .font(.headline)
                        .foregroundStyle(tint)
                    if let note {
                        Text(note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(room.buildingName) \(room.room). \(status.detailedSummary). \(note ?? "")")
        }
    }

    @ViewBuilder
    private var notices: some View {
        if isNow, let classDates, !classDates.contains(now) {
            MacRoomsNotice(
                systemImage: "calendar.badge.exclamationmark",
                text: RoomsText.classDatesMessage(termName: index.term.shortName, dates: classDates)
            )
        }
        if !moment.isWithinClassHours {
            MacRoomsNotice(systemImage: "moon.zzz.fill", text: RoomsText.outsideHours, tint: .indigo)
        }
    }

    // MARK: Timeline

    private var controls: some View {
        HStack {
            Picker("View", selection: $mode) {
                Text("Day").tag(Mode.day)
                Text("Week").tag(Mode.week)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 130)
            Spacer()
            if mode == .day {
                Picker("Day", selection: Binding(get: { weekday }, set: { dayOverride = $0 })) {
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                        Text(DaySet.fullNames[day]).tag(day)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// One day of the room's classes, hour by hour.
    private var dayTimeline: some View {
        WeekCalendarView(
            events: calendarEvents.filter { $0.day == weekday },
            days: [weekday],
            startHour: 8,
            endHour: 18,
            hourHeight: 38,
            showsHeader: false,
            onSelect: openCourse
        )
    }

    private var weekCalendar: some View {
        WeekCalendarView(
            events: calendarEvents,
            showWeekends: userData.preferences.showWeekends,
            startHour: 8,
            endHour: 18,
            hourHeight: 34,
            onSelect: openCourse
        )
    }

    private var calendarEvents: [CalendarEvent] {
        room.calendarEvents(in: index)
    }

    // MARK: Classes

    private var dayBookings: [RoomSchedule.Booking] {
        RoomAvailability.bookings(of: room, on: weekday, date: weekday == moment.weekday ? moment.date : nil)
    }

    @ViewBuilder
    private var classList: some View {
        let bookings = dayBookings
        VStack(alignment: .leading, spacing: 6) {
            Text(weekday == moment.weekday && isNow ? "Today · \(DaySet.fullNames[weekday])" : DaySet.fullNames[weekday])
                .font(.headline)
            if bookings.isEmpty {
                Label("No classes. This room is free all day.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(bookings.enumerated()), id: \.offset) { _, booking in
                    bookingRow(booking)
                }
            }
        }
    }

    private func bookingRow(_ booking: RoomSchedule.Booking) -> some View {
        let isCurrent = weekday == moment.weekday && booking.start <= moment.minutes && moment.minutes < booking.end
        let isPast = weekday == moment.weekday && booking.end <= moment.minutes
        let section = index.section(crn: booking.crn)
        let title = section?.title.nilIfBlank ?? index.course(booking.course)?.title ?? ""

        return Button {
            open(booking.course)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(booking.course.description)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        if let type = section?.classType {
                            Text(type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(isPast ? .secondary : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(TimeOfDay.rangeLabel(start: booking.start, end: booking.end))
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if isCurrent {
                        TagLabel(text: isNow ? "In progress" : "At this time", tint: .red)
                    }
                }
                .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(booking.course.description)\(title.isEmpty ? "" : ", \(title)"), \(TimeOfDay.rangeLabel(start: booking.start, end: booking.end))\(isCurrent ? ", in progress" : isPast ? ", finished" : "")")
        .accessibilityHint("Opens the course in a window")
    }

    // MARK: Actions

    private func openCourse(_ event: CalendarEvent) {
        guard let crn = event.payload,
              let booking = room.bookings.first(where: { $0.crn == crn }) else { return }
        open(booking.course)
    }

    private func open(_ key: CourseKey) {
        openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: index.term.code, key: key))
    }
}

/// A calm inline notice used for the "typical week" and "outside class hours" messages.
struct MacRoomsNotice: View {
    var systemImage: String
    var text: String
    var tint: Color = .blue
    /// A bound on the lines, for a notice above the table: unbounded text that wraps at the
    /// window's smallest width would make the window's minimum height grow with it.
    var lineLimit: Int?

    var body: some View {
        Label {
            if let lineLimit {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
            } else {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}
