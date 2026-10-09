//
//  RoomView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One classroom: whether it is free now, its week of classes and today's bookings.
struct RoomView: View {
    var termCode: String
    var buildingCode: String
    var room: String

    var body: some View {
        RoomsIndexLoader(termCode: termCode) { index in
            if let schedule = index.buildings
                .first(where: { $0.code == buildingCode })?
                .rooms.first(where: { $0.room == room }) {
                RoomContentView(index: index, room: schedule)
            } else {
                ContentUnavailableView(
                    "Room not found",
                    systemImage: "door.left.hand.closed",
                    description: Text("\(buildingCode) \(room) has no scheduled classes in \(index.term.shortName).")
                )
            }
        }
        .navigationTitle("\(buildingCode) \(room)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RoomContentView: View {
    var index: CatalogIndex
    var room: RoomSchedule

    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @State private var classDates: RoomAvailability.ClassDates?
    /// The current minute. A ticker instead of a `TimelineView` around the list: the week
    /// calendar inside has its own `TimelineView` (the "now" line), and nesting the two
    /// sends SwiftUI into an endless render loop while the screen is being pushed.
    @State private var now = Date.now

    var body: some View {
        roomList(now: now)
            .navigationTitle(room.label)
            .navigationSubtitle(room.buildingName)
            .roomsClassDates($classDates, in: index)
            .task { await tickEveryMinute() }
    }

    /// Updates `now` at the start of every minute while the screen is shown.
    private func tickEveryMinute() async {
        while !Task.isCancelled {
            let nextMinute = Calendar.current.nextDate(after: .now, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
                ?? .now.addingTimeInterval(60)
            try? await Task.sleep(for: .seconds(max(1, nextMinute.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            now = .now
        }
    }

    private var termCode: String { index.term.code }

    private func roomList(now: Date) -> some View {
        let moment = RoomAvailability.Moment(date: now)
        let today = RoomAvailability.bookings(of: room, on: moment.weekday, date: moment.date)
        let status = RoomAvailability.status(of: today, at: moment.minutes)

        return List {
            Section {
                statusHeader(status: status, today: today, moment: moment)
                if let dates = classDates, !dates.contains(now) {
                    RoomsNotice(
                        systemImage: "calendar.badge.exclamationmark",
                        text: RoomsText.classDatesMessage(termName: index.term.shortName, dates: dates)
                    )
                }
                if !moment.isWithinClassHours {
                    RoomsNotice(systemImage: "moon.zzz.fill", text: RoomsText.outsideHours, tint: .indigo)
                }
            } footer: {
                Text(RoomsText.disclaimer)
            }

            Section("This week") {
                WeekCalendarView(
                    events: calendarEvents,
                    showWeekends: userData.preferences.showWeekends,
                    startHour: 8,
                    endHour: 18,
                    hourHeight: 40,
                    onSelect: openCourse
                )
                .padding(.vertical, Theme.Spacing.s)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section("Today · \(DaySet.fullNames[moment.weekday])") {
                if today.isEmpty {
                    Label("No classes today. This room is free all day.", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(today.enumerated()), id: \.offset) { _, booking in
                        bookingRow(booking, moment: moment)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Status

    private func statusHeader(status: RoomAvailability.Status, today: [RoomSchedule.Booking], moment: RoomAvailability.Moment) -> some View {
        let tint = status.roomsTint(at: moment)
        return HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Image(systemName: status.roomsSymbol)
                .font(.system(size: 34))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.detailedSummary)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
                if let note = followUpNote(status: status, today: today, moment: moment) {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(room.buildingName) \(room.room). \(status.detailedSummary). \(followUpNote(status: status, today: today, moment: moment) ?? "")")
    }

    /// What happens next: the following class for a free room, or when a busy room frees up.
    private func followUpNote(status: RoomAvailability.Status, today: [RoomSchedule.Booking], moment: RoomAvailability.Moment) -> String? {
        RoomsText.followUpNote(status: status, today: today)
    }

    // MARK: Calendar

    private var calendarEvents: [CalendarEvent] {
        room.calendarEvents(in: index)
    }

    private func openCourse(_ event: CalendarEvent) {
        guard let crn = event.payload,
              let booking = room.bookings.first(where: { $0.crn == crn }) else { return }
        router.navigate(to: .course(termCode: termCode, key: booking.course))
    }

    // MARK: Today's bookings

    private func bookingRow(_ booking: RoomSchedule.Booking, moment: RoomAvailability.Moment) -> some View {
        let isNow = booking.start <= moment.minutes && moment.minutes < booking.end
        let isPast = booking.end <= moment.minutes
        let section = index.section(crn: booking.crn)
        let title = section?.title.nilIfBlank ?? index.course(booking.course)?.title ?? ""

        return NavigationLink(value: AppRoute.course(termCode: termCode, key: booking.course)) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(booking.course.description)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        if let type = section?.classType {
                            Text(type)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isNow {
                            TagLabel(text: "In progress", tint: .red)
                        }
                    }
                    if !title.isEmpty {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(isPast ? .secondary : .primary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Theme.Spacing.s)
                Text(TimeOfDay.rangeLabel(start: booking.start, end: booking.end))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(booking.course.description)\(title.isEmpty ? "" : ", \(title)"), \(TimeOfDay.rangeLabel(start: booking.start, end: booking.end))\(isNow ? ", in progress" : isPast ? ", finished" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens course details")
    }
}
