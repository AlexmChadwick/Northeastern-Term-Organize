//
//  WeekCalendarView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One block on a week calendar.
struct CalendarEvent: Identifiable, Hashable {
    var id: String
    /// e.g. `CS 3000`.
    var title: String
    /// e.g. `WVH 210`.
    var subtitle: String?
    /// e.g. `Lecture`.
    var detail: String?
    /// 0 = Sunday … 6 = Saturday.
    var day: Int
    /// Minutes after midnight.
    var start: Int
    var end: Int
    var color: CourseColor
    var isConflict = false
    /// A tentative block (e.g. previewing a section), drawn translucent and dashed.
    var isGhost = false
    /// Arbitrary identifier for tap handling (e.g. a CRN).
    var payload: String?
    /// ISO (yyyy-MM-dd) dates bounding the meeting, used so half-term
    /// classes at the same time aren't flagged as conflicts.
    var startDate: String? = nil
    var endDate: String? = nil

    /// Expands a section's weekly meetings into calendar events.
    static func events(for section: CourseSection, color: CourseColor, isGhost: Bool = false, title: String? = nil) -> [CalendarEvent] {
        // Some sections list several single-date meetings at the same weekday and time;
        // fold those so each weekly block appears once (and ids stay unique).
        var seen = Set<String>()
        return section.weeklyMeetings.enumerated().flatMap { offset, meeting -> [CalendarEvent] in
            guard let start = meeting.start, let end = meeting.end else { return [] }
            return meeting.days.indices.compactMap { day in
                guard seen.insert("\(day)-\(start)-\(end)-\(meeting.locationLabel)").inserted else { return nil }
                return CalendarEvent(
                    id: "\(section.crn)-\(offset)-\(day)-\(start)",
                    title: title ?? section.courseKey.description,
                    subtitle: meeting.isOnline ? "Online" : meeting.locationLabel,
                    detail: section.classType,
                    day: day,
                    start: start,
                    end: end,
                    color: color,
                    isGhost: isGhost,
                    payload: section.crn,
                    startDate: meeting.startDate,
                    endDate: meeting.endDate
                )
            }
        }
    }

    /// Marks events that overlap another event on the same day as conflicts.
    static func markingConflicts(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var result = events
        for i in result.indices {
            for j in result.indices where i != j && !result[i].isGhost && !result[j].isGhost {
                let a = result[i], b = result[j]
                if a.day == b.day, a.start < b.end, b.start < a.end, a.payload != b.payload,
                   Meeting.dateWindowsOverlap(a.startDate, a.endDate, b.startDate, b.endDate) {
                    result[i].isConflict = true
                }
            }
        }
        return result
    }
}

/// A Monday–Friday (optionally weekend) time grid with positioned events.
struct WeekCalendarView: View {
    var events: [CalendarEvent]
    /// Day indices to show, 0 = Sunday. Defaults to weekdays plus any weekend days with events.
    var days: [Int]?
    var showWeekends = false
    /// Visible hour range; computed from events when nil.
    var startHour: Int?
    var endHour: Int?
    var hourHeight: CGFloat = 54
    /// Tiny rendering for thumbnails: no labels or header text.
    var compact = false
    var showsHeader = true
    var showsNowIndicator = true
    var onSelect: ((CalendarEvent) -> Void)?

    private let axisWidth: CGFloat = 34

    private var visibleDays: [Int] {
        if let days { return days }
        var d = [1, 2, 3, 4, 5]
        let eventDays = Set(events.map(\.day))
        if showWeekends || eventDays.contains(6) { d.append(6) }
        if showWeekends || eventDays.contains(0) { d.insert(0, at: 0) }
        return d
    }

    private var hourRange: ClosedRange<Int> {
        let defaultStart = startHour ?? 8
        let defaultEnd = endHour ?? 18
        guard !events.isEmpty else { return defaultStart...max(defaultStart + 1, defaultEnd) }
        let minStart = events.map(\.start).min()! / 60
        let maxEnd = Int((Double(events.map(\.end).max()!) / 60).rounded(.up))
        let lower = min(startHour ?? minStart, minStart)
        let upper = max(endHour ?? maxEnd, maxEnd, lower + (compact ? 1 : 4))
        return max(0, lower)...min(24, upper)
    }

    var body: some View {
        let range = hourRange
        let days = visibleDays
        VStack(spacing: 0) {
            if showsHeader && !compact {
                header(days: days)
            }
            GeometryReader { proxy in
                let axis = compact ? 0 : axisWidth
                let columnWidth = (proxy.size.width - axis) / CGFloat(max(1, days.count))
                ZStack(alignment: .topLeading) {
                    grid(range: range, days: days, axis: axis, columnWidth: columnWidth, width: proxy.size.width)
                    ForEach(Array(days.enumerated()), id: \.element) { column, day in
                        dayColumn(day: day, range: range, width: columnWidth)
                            .frame(width: columnWidth, height: height(for: range), alignment: .topLeading)
                            .offset(x: axis + CGFloat(column) * columnWidth)
                    }
                    if showsNowIndicator && !compact {
                        nowIndicator(range: range, days: days, axis: axis, columnWidth: columnWidth)
                    }
                }
            }
            .frame(height: height(for: range))
        }
    }

    private func height(for range: ClosedRange<Int>) -> CGFloat {
        CGFloat(range.upperBound - range.lowerBound) * hourHeight
    }

    private func y(_ minutes: Int, range: ClosedRange<Int>) -> CGFloat {
        CGFloat(minutes - range.lowerBound * 60) / 60 * hourHeight
    }

    // MARK: Header

    private func header(days: [Int]) -> some View {
        let today = Calendar.current.component(.weekday, from: .now) - 1
        return HStack(spacing: 0) {
            Color.clear.frame(width: axisWidth, height: 1)
            ForEach(days, id: \.self) { day in
                Text(DaySet.shortNames[day])
                    .font(.caption.weight(day == today ? .bold : .medium))
                    .foregroundStyle(day == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 6)
        .accessibilityHidden(true)
    }

    // MARK: Grid

    private func grid(range: ClosedRange<Int>, days: [Int], axis: CGFloat, columnWidth: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for hour in range {
                    let yPos = y(hour * 60, range: range)
                    path.move(to: CGPoint(x: axis, y: yPos))
                    path.addLine(to: CGPoint(x: width, y: yPos))
                }
                for column in 0...days.count {
                    let x = axis + CGFloat(column) * columnWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height(for: range)))
                }
            }
            .stroke(.separator.opacity(compact ? 0.5 : 0.7), lineWidth: compact ? 0.5 : 0.5)

            if !compact {
                ForEach(Array(range.dropLast()), id: \.self) { hour in
                    Text(TimeOfDay.hourAxisLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .offset(y: y(hour * 60, range: range) - 6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Events

    private func dayColumn(day: Int, range: ClosedRange<Int>, width: CGFloat) -> some View {
        let dayEvents = events.filter { $0.day == day }.sorted { $0.start < $1.start }
        let lanes = CalendarLayout.lanes(for: dayEvents)
        return ZStack(alignment: .topLeading) {
            ForEach(dayEvents) { event in
                let lane = lanes[event.id] ?? (0, 1)
                let laneWidth = (width - 3) / CGFloat(lane.count)
                CalendarEventBlock(event: event, compact: compact)
                    .frame(width: max(2, laneWidth - 2), height: max(compact ? 2 : 18, y(event.end, range: range) - y(event.start, range: range) - 2))
                    .offset(x: 1.5 + CGFloat(lane.index) * laneWidth, y: y(event.start, range: range) + 1)
                    .onTapGesture { onSelect?(event) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(event.title), \(DaySet.fullNames[event.day]) \(TimeOfDay.rangeLabel(start: event.start, end: event.end))\(event.subtitle.map { ", \($0)" } ?? "")\(event.isConflict ? ", conflicts with another class" : "")")
                    .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
            }
        }
    }

    private func nowIndicator(range: ClosedRange<Int>, days: [Int], axis: CGFloat, columnWidth: CGFloat) -> some View {
        // `.everyMinute`, not `.periodic(from: .now, …)`: a schedule that changes on every
        // evaluation restarts the timeline each time the calendar is rebuilt.
        TimelineView(.everyMinute) { context in
            let calendar = Calendar.current
            let today = calendar.component(.weekday, from: context.date) - 1
            let minutes = calendar.component(.hour, from: context.date) * 60 + calendar.component(.minute, from: context.date)
            if let column = days.firstIndex(of: today), minutes >= range.lowerBound * 60, minutes <= range.upperBound * 60 {
                let yPos = y(minutes, range: range)
                ZStack(alignment: .leading) {
                    Rectangle().fill(.red).frame(width: columnWidth, height: 1.5)
                    Circle().fill(.red).frame(width: 7, height: 7).offset(x: -3.5)
                }
                .offset(x: axis + CGFloat(column) * columnWidth, y: yPos - 0.75)
                .allowsHitTesting(false)
            }
        }
    }
}

/// The rounded block drawn for an event.
struct CalendarEventBlock: View {
    var event: CalendarEvent
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 2 : Theme.Radius.block, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(event.isConflict ? Color.red.opacity(0.18) : event.color.fill)
            if !compact {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(event.isConflict ? Color.red : event.color.stroke)
                        .frame(width: 3)
                    // Same font in every block: when a block is short, drop the
                    // lower-priority lines instead of shrinking the text.
                    ViewThatFits(in: .vertical) {
                        labels(subtitle: true, detail: true)
                        labels(subtitle: true, detail: false)
                        labels(subtitle: false, detail: false)
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 3)
                    Spacer(minLength: 0)
                }
                .clipShape(shape)
            }
        }
        .overlay {
            if event.isGhost {
                shape.strokeBorder(event.color.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            } else if event.isConflict {
                shape.strokeBorder(Color.red.opacity(0.8), lineWidth: 1)
            }
        }
        .opacity(event.isGhost ? 0.75 : 1)
        .contentShape(shape)
    }

    private func labels(subtitle showSubtitle: Bool, detail showDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // One line, scaled down slightly in narrow day columns ("CHEM 1211").
            Text(event.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(event.isConflict ? Color.red : event.color.text)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if showSubtitle, let subtitle = event.subtitle {
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if showDetail, let detail = event.detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

enum CalendarLayout {
    /// Assigns overlapping events to side-by-side lanes. Returns, for each
    /// event id, its lane index and the number of lanes in its overlap group.
    static func lanes(for events: [CalendarEvent]) -> [String: (index: Int, count: Int)] {
        var result: [String: (Int, Int)] = [:]
        var group: [(event: CalendarEvent, lane: Int)] = []
        var laneEnds: [Int] = []
        var groupEnd = Int.min

        func flush() {
            let count = max(1, laneEnds.count)
            for item in group { result[item.event.id] = (item.lane, count) }
            group.removeAll()
            laneEnds.removeAll()
        }

        for event in events.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if event.start >= groupEnd { flush() }
            if let lane = laneEnds.firstIndex(where: { $0 <= event.start }) {
                laneEnds[lane] = event.end
                group.append((event, lane))
            } else {
                laneEnds.append(event.end)
                group.append((event, laneEnds.count - 1))
            }
            groupEnd = max(groupEnd, event.end)
        }
        flush()
        return result
    }
}
