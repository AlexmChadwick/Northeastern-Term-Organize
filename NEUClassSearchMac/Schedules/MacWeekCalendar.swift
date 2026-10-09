//
//  MacWeekCalendar.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The week calendar of the Mac app: the grid fills its pane (and scrolls when the pane is too short
/// for it), blocks react to the pointer, and every block can open a popover and a context menu.
/// Blocks are `CalendarEvent`s, the same as on the iPhone's calendar.
struct MacWeekCalendar: View {
    var events: [CalendarEvent]
    /// The day columns, 0 = Sunday.
    var days: [Int]
    /// The hours shown: `8...18` has rows for 8 AM up to 6 PM.
    var hours: ClosedRange<Int>
    /// The hour rows fill the pane's height, between these two (points per hour): a pane too short
    /// for the tighter one scrolls instead, and a taller one than the looser one leaves some room.
    var minHourHeight: CGFloat = 40
    var maxHourHeight: CGFloat = 104
    var showsNowIndicator = true
    /// A small calendar for previews: blocks show only their course, and the axis is narrower.
    var compact = false
    /// Blocks drawn faded, to emphasize the others (the selected course's blocks, say).
    var isDimmed: (CalendarEvent) -> Bool = { _ in false }
    /// What a block with room for it says beyond its course, room and kind of class: the course's
    /// title and the instructor.
    var extras: ((CalendarEvent) -> MacCalendarBlockExtras)?
    /// Content of the popover a click on a block opens; nil for blocks that do nothing when clicked.
    var popover: ((CalendarEvent) -> AnyView)?
    /// Content of a block's context menu.
    var menu: ((CalendarEvent) -> AnyView)?

    @State private var popoverID: String?
    @State private var hoveredID: String?
    @State private var now = Date()
    /// The width the calendar was given: a narrow one shrinks the axis and the blocks' text.
    @State private var width: CGFloat = 600

    /// Whether the calendar is drawn small: asked for, or too narrow for the full-size text.
    private var isTight: Bool { compact || width < 440 }
    private var axisWidth: CGFloat { isTight ? 40 : 50 }
    private var headerHeight: CGFloat { isTight ? 22 : 26 }
    /// Room above the first hour line for its label.
    private let topInset: CGFloat = 8

    private var rowCount: Int { max(1, hours.upperBound - hours.lowerBound) }

    /// The width of a day column.
    private var columnWidth: CGFloat { max(0, width - axisWidth) / CGFloat(max(1, days.count)) }

    /// Whether the columns are wide enough for full day names.
    private var hasWideColumns: Bool { !isTight && columnWidth >= 120 }

    /// When the first class starts, in minutes after midnight.
    private var firstStart: Int? { events.map(\.start).min() }

    /// The scroll offset that puts the hour of the first class at the top (0 when everything fits).
    private func firstClassOffset(hourHeight: CGFloat) -> CGFloat {
        guard let firstStart else { return 0 }
        return max(0, y(firstStart / 60 * 60, hourHeight: hourHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { proxy in
                let fit = (proxy.size.height - topInset - 6) / CGFloat(rowCount)
                let hourHeight = min(max(minHourHeight, fit), max(minHourHeight, maxHourHeight))
                MacCalendarScroll(firstClassOffset: firstClassOffset(hourHeight: hourHeight), firstStart: firstStart) {
                    grid(hourHeight: hourHeight)
                        .frame(height: hourHeight * CGFloat(rowCount))
                        .padding(.top, topInset)
                        .padding(.bottom, 6)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task {
            // One loop moves the "now" line; no TimelineView, so nothing nests.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        let today = Calendar.current.component(.weekday, from: now) - 1
        return HStack(spacing: 0) {
            Color.clear.frame(width: axisWidth, height: 1)
            ForEach(days, id: \.self) { day in
                Text(hasWideColumns ? DaySet.fullNames[day] : DaySet.shortNames[day])
                    .font((isTight ? Font.caption : Font.callout).weight(day == today && showsNowIndicator ? .bold : .medium))
                    .foregroundStyle(day == today && showsNowIndicator ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: headerHeight)
        .accessibilityHidden(true)
    }

    // MARK: Grid

    private func y(_ minutes: Int, hourHeight: CGFloat) -> CGFloat {
        CGFloat(minutes - hours.lowerBound * 60) / 60 * hourHeight
    }

    private func grid(hourHeight: CGFloat) -> some View {
        GeometryReader { proxy in
            let columns = max(1, days.count)
            let columnWidth = (proxy.size.width - axisWidth) / CGFloat(columns)
            ZStack(alignment: .topLeading) {
                lines(hourHeight: hourHeight, width: proxy.size.width, columnWidth: columnWidth)
                ForEach(Array(days.enumerated()), id: \.element) { column, day in
                    dayColumn(day: day, hourHeight: hourHeight, width: columnWidth)
                        .frame(width: columnWidth, height: hourHeight * CGFloat(rowCount), alignment: .topLeading)
                        .offset(x: axisWidth + CGFloat(column) * columnWidth)
                }
                if showsNowIndicator {
                    nowIndicator(hourHeight: hourHeight, columnWidth: columnWidth)
                }
            }
        }
    }

    private func lines(hourHeight: CGFloat, width: CGFloat, columnWidth: CGFloat) -> some View {
        let total = hourHeight * CGFloat(rowCount)
        return ZStack(alignment: .topLeading) {
            Path { path in
                for hour in hours.lowerBound...hours.upperBound {
                    let yPos = y(hour * 60, hourHeight: hourHeight)
                    path.move(to: CGPoint(x: axisWidth - 4, y: yPos))
                    path.addLine(to: CGPoint(x: width, y: yPos))
                }
            }
            .stroke(.separator.opacity(0.8), lineWidth: 0.5)
            Path { path in
                for column in 0...days.count {
                    let x = axisWidth + CGFloat(column) * columnWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: total))
                }
            }
            .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            ForEach(Array(hours.dropLast()), id: \.self) { hour in
                Text(isTight ? Self.shortHourLabel(hour) : Self.hourLabel(hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: axisWidth - 10, alignment: .trailing)
                    .offset(y: y(hour * 60, hourHeight: hourHeight) - 6)
            }
        }
        .accessibilityHidden(true)
    }

    /// `9a`, `12p`.
    static func shortHourLabel(_ hour: Int) -> String {
        TimeOfDay.hourAxisLabel(hour)
    }

    /// `9 AM`, `12 PM`.
    static func hourLabel(_ hour: Int) -> String {
        let h24 = hour % 24
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12) \(h24 < 12 ? "AM" : "PM")"
    }

    // MARK: Events

    private func dayColumn(day: Int, hourHeight: CGFloat, width: CGFloat) -> some View {
        let dayEvents = events.filter { $0.day == day }.sorted { $0.start < $1.start }
        let lanes = CalendarLayout.lanes(for: dayEvents)
        return ZStack(alignment: .topLeading) {
            ForEach(dayEvents) { event in
                let lane = lanes[event.id] ?? (0, 1)
                let laneWidth = (width - 4) / CGFloat(lane.count)
                block(for: event, size: blockSize(laneWidth: laneWidth, lanes: lane.count, hourHeight: hourHeight))
                    .frame(
                        width: max(4, laneWidth - 2),
                        height: max(isTight ? 14 : 20, y(event.end, hourHeight: hourHeight) - y(event.start, hourHeight: hourHeight) - 2)
                    )
                    .offset(x: 2 + CGFloat(lane.index) * laneWidth, y: y(event.start, hourHeight: hourHeight) + 1)
            }
        }
    }

    /// How much a block says: only its course in a tight calendar or beside an overlapping class, more
    /// once there is room for it.
    private func blockSize(laneWidth: CGFloat, lanes: Int, hourHeight: CGFloat) -> MacCalendarBlock.Size {
        if isTight || (lanes > 1 && laneWidth < 120) { return .compact }
        if laneWidth >= 230 && hourHeight >= 60 { return .spacious }
        return laneWidth >= 120 && hourHeight >= 52 ? .roomy : .standard
    }

    @ViewBuilder
    private func block(for event: CalendarEvent, size: MacCalendarBlock.Size) -> some View {
        let content = MacCalendarBlock(
            event: event, isHovered: hoveredID == event.id, isDimmed: isDimmed(event), size: size,
            extras: size.isRoomy ? extras?(event) : nil
        )
            .onHover { inside in
                if inside { hoveredID = event.id } else if hoveredID == event.id { hoveredID = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(event.title), \(DaySet.fullNames[event.day]) \(TimeOfDay.rangeLabel(start: event.start, end: event.end))\(event.subtitle.map { ", \($0)" } ?? "")\(event.isConflict ? ", conflicts with another class" : "")")
        if let popover {
            content
                .onTapGesture { popoverID = event.id }
                .popover(
                    isPresented: Binding(get: { popoverID == event.id }, set: { if !$0, popoverID == event.id { popoverID = nil } }),
                    arrowEdge: .trailing
                ) { popover(event) }
                .accessibilityAddTraits(.isButton)
                .contextMenu { menu?(event) }
        } else {
            content.contextMenu { menu?(event) }
        }
    }

    // MARK: Now

    private func nowIndicator(hourHeight: CGFloat, columnWidth: CGFloat) -> some View {
        let calendar = Calendar.current
        let today = calendar.component(.weekday, from: now) - 1
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return Group {
            if let column = days.firstIndex(of: today), minutes >= hours.lowerBound * 60, minutes <= hours.upperBound * 60 {
                ZStack(alignment: .leading) {
                    Rectangle().fill(.red).frame(width: columnWidth, height: 1.5)
                    Circle().fill(.red).frame(width: 7, height: 7).offset(x: -3.5)
                }
                .offset(x: axisWidth + CGFloat(column) * columnWidth, y: y(minutes, hourHeight: hourHeight) - 0.75)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Scrolling

/// The calendar's vertical scroll view. It opens on the hour of the first class, so a pane too short
/// for every hour shows the classes instead of the empty morning (a pane tall enough does not scroll).
/// It stays there while the pane settles into its size and until the student scrolls.
private struct MacCalendarScroll<Content: View>: View {
    var firstClassOffset: CGFloat
    /// When the first class starts: a different one moves the view to it again.
    var firstStart: Int?
    var content: Content

    @State private var position: ScrollPosition
    @State private var studentScrolled = false

    init(firstClassOffset: CGFloat, firstStart: Int?, @ViewBuilder content: () -> Content) {
        self.firstClassOffset = firstClassOffset
        self.firstStart = firstStart
        self.content = content()
        _position = State(initialValue: ScrollPosition(y: firstClassOffset))
    }

    var body: some View {
        ScrollView(.vertical) { content }
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($position)
            // The pane may be measured more than once while it appears, and a position set before the
            // last measurement can end up out of range: set it again whenever the sizes change.
            .onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.containerSize.height, height: $0.contentSize.height) } action: { _, _ in
                if !studentScrolled { position.scrollTo(y: firstClassOffset) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { studentScrolled = true }
            }
            .onChange(of: firstStart) { _, _ in
                studentScrolled = false
                position.scrollTo(y: firstClassOffset)
            }
    }
}

// MARK: - Block

/// What a block with room for it says beyond its course, room and kind of class.
struct MacCalendarBlockExtras {
    var courseTitle: String?
    var instructor: String?

    init(courseTitle: String? = nil, instructor: String? = nil) {
        self.courseTitle = courseTitle
        self.instructor = instructor
    }

    init(section: CourseSection) {
        self.init(courseTitle: section.title.isEmpty ? nil : section.title, instructor: ScheduleFormat.instructors(of: section))
    }
}

/// One class on the calendar: its course color, the course, the room and the kind of class.
struct MacCalendarBlock: View {
    /// How much a block says: just the course; the course, room and kind of class; or, with room for
    /// it, the course's title, the time and the instructor too (in a larger font when the block is
    /// very big).
    enum Size {
        case compact, standard, roomy, spacious

        /// Whether there is room for the title, the time and the instructor.
        var isRoomy: Bool { self == .roomy || self == .spacious }
    }

    var event: CalendarEvent
    var isHovered = false
    var isDimmed = false
    var size: Size = .standard
    var extras: MacCalendarBlockExtras?

    private enum Line {
        case code, courseTitle, time, room, kind, roomAndKind, instructor
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.isRoomy ? 8 : 6, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(event.isConflict ? Color.red.opacity(isHovered ? 0.26 : 0.18) : event.color.base.opacity(isHovered ? 0.30 : 0.18))
            HStack(spacing: 0) {
                Rectangle()
                    .fill(event.isConflict ? Color.red : event.color.stroke)
                    .frame(width: size.isRoomy ? 4 : 3)
                // The same fonts in every block: a short block drops its lower lines instead of shrinking.
                ViewThatFits(in: .vertical) {
                    switch size {
                    case .roomy, .spacious:
                        labels([.code, .courseTitle, .time, .roomAndKind, .instructor])
                        labels([.code, .courseTitle, .time, .roomAndKind])
                        labels([.code, .time, .roomAndKind])
                        labels([.code, .room])
                        labels([.code])
                    case .standard:
                        labels([.code, .room, .kind])
                        labels([.code, .room])
                        labels([.code])
                    case .compact:
                        labels([.code])
                    }
                }
                .padding(.horizontal, size == .compact ? 3 : (size == .spacious ? 10 : (size == .roomy ? 8 : 5)))
                .padding(.vertical, size == .compact ? 2 : (size == .spacious ? 7 : (size == .roomy ? 5 : 3)))
                Spacer(minLength: 0)
            }
            .clipShape(shape)
        }
        .overlay {
            if event.isGhost {
                shape.strokeBorder(event.color.stroke, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            } else if event.isConflict {
                shape.strokeBorder(Color.red.opacity(0.8), lineWidth: 1)
            }
        }
        .opacity(isDimmed ? 0.4 : (event.isGhost ? 0.8 : 1))
        .contentShape(shape)
    }

    private func labels(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: size == .spacious ? 3 : (size == .roomy ? 2 : 1)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                text(for: line)
            }
        }
    }

    @ViewBuilder
    private func text(for line: Line) -> some View {
        switch line {
        case .code:
            Text(event.title)
                .font(codeFont.weight(.bold))
                .foregroundStyle(event.isConflict ? Color.red : event.color.text)
                .lineLimit(1)
                .minimumScaleFactor(size == .compact ? 0.6 : 0.75)
        case .courseTitle:
            if let title = extras?.courseTitle {
                Text(title)
                    .font(detailFont.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
            }
        case .time:
            Text(TimeOfDay.rangeLabel(start: event.start, end: event.end))
                .font(detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .room:
            if let room = event.subtitle {
                Text(room)
                    .font(size.isRoomy ? detailFont : .caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        case .kind:
            if let kind = event.detail {
                Text(kind)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        case .roomAndKind:
            let parts = [event.subtitle, event.detail].compactMap { $0 }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        case .instructor:
            if let instructor = extras?.instructor {
                Text(instructor)
                    .font(detailFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var codeFont: Font {
        switch size {
        case .compact: .caption2
        case .standard: .caption
        case .roomy: .callout
        case .spacious: .body
        }
    }

    /// The font of the lines below the course.
    private var detailFont: Font {
        size == .spacious ? .callout : .caption
    }
}

// MARK: - Hours and days

enum MacCalendarRange {
    /// The hours to show for `events`: a working day at least, plus whatever the events need, with the
    /// preferences' calendar hours as the default when there are none.
    static func hours(for events: [CalendarEvent], preferences: AppPreferences, padding: Int = 0) -> ClosedRange<Int> {
        let defaultStart = max(0, preferences.calendarStartHour)
        let defaultEnd = min(24, max(defaultStart + 4, preferences.calendarEndHour))
        guard !events.isEmpty else { return defaultStart...defaultEnd }
        let first = events.map(\.start).min() ?? defaultStart * 60
        let last = events.map(\.end).max() ?? defaultEnd * 60
        let upper = min(24, max(defaultEnd, Int((Double(last) / 60).rounded(.up)) + padding))
        let lower = min(max(0, min(defaultStart, first / 60 - padding)), upper - 1)
        return lower...max(lower + 1, min(24, max(lower + 4, upper)))
    }

    /// The day columns: Monday to Friday, plus the weekend when the student shows it or a class meets then.
    static func days(for events: [CalendarEvent], showWeekends: Bool) -> [Int] {
        PlanCalendarSupport.visibleDays(events: events, showWeekends: showWeekends)
    }
}
