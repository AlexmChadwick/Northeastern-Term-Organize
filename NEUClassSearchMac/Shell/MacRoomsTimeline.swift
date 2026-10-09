//
//  MacRoomsTimeline.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The Free Rooms list as a timeline: every room is a bar for the school day with its free
//  stretches in green and its classes in gray, so which rooms are free, and for how long,
//  can be read at a glance. The bars use whatever width the window gives them.
//

import SwiftUI

/// The measurements the rows and the axis above them share, so the hours line up with the bars.
enum MacRoomsTimeline {
    /// The school day the bars show, in minutes after midnight (7 AM to 10 PM).
    static let range = RoomAvailability.firstClassMinute..<RoomAvailability.lastClassMinute
    /// The room's name and status, left of its bar.
    static let labelWidth: CGFloat = 172
    static let spacing: CGFloat = 12
    /// Space between the list's edge and the content of its rows and of the axis.
    static let inset: CGFloat = 14
    static let barHeight: CGFloat = 18
}

/// The hours above the bars, and the room column's title. The hours are placed from where the rows'
/// bars actually are (they report it), so they line up whatever the list's insets and scroll bars.
struct MacRoomsAxis: View {
    /// Where the bars are horizontally, in window coordinates; nil until a row reports it.
    var trackRange: Range<CGFloat>?

    /// Below this width of the bars the labels show every second hour.
    private static let crowdedWidth: CGFloat = 520

    @State private var originX: CGFloat = 0
    @State private var width: CGFloat = 1_000

    /// The bars' start and width relative to this view, or an estimate before a row has reported.
    private var track: (start: CGFloat, width: CGFloat) {
        if let trackRange, trackRange.upperBound > trackRange.lowerBound {
            return (trackRange.lowerBound - originX, trackRange.upperBound - trackRange.lowerBound)
        }
        let start = MacRoomsTimeline.inset + 10 + MacRoomsTimeline.labelWidth + MacRoomsTimeline.spacing
        return (start, max(0, width - start - MacRoomsTimeline.inset - 10))
    }

    var body: some View {
        let track = track
        let range = MacRoomsTimeline.range
        let step = track.width < Self.crowdedWidth ? 2 : 1
        let hours = Array(stride(from: range.lowerBound / 60, through: range.upperBound / 60, by: step))
        ZStack(alignment: .topLeading) {
            Text("Room")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .offset(x: MacRoomsTimeline.inset + 10 + 28, y: 8)
            ForEach(hours, id: \.self) { hour in
                let x = track.start + track.width * CGFloat(hour * 60 - range.lowerBound) / CGFloat(range.count)
                Text(TimeOfDay.hourAxisLabel(hour))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: x, y: 15)
            }
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { originX = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityHidden(true)
    }
}

/// One room in the list: its name and status, and its bar for the day.
struct MacRoomTimelineRow: View {
    var row: MacRoomRow
    var moment: RoomAvailability.Moment
    /// Told where the bar is horizontally (window coordinates), for the axis above the list.
    var onTrackRange: (Range<CGFloat>) -> Void = { _ in }

    var body: some View {
        HStack(spacing: MacRoomsTimeline.spacing) {
            HStack(spacing: 8) {
                Image(systemName: row.entry.status.roomsSymbol)
                    .foregroundStyle(row.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(row.statusText)
                        .font(.caption)
                        .foregroundStyle(row.isFree ? AnyShapeStyle(row.tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .frame(width: MacRoomsTimeline.labelWidth, alignment: .leading)
            MacRoomTrack(
                bookings: RoomAvailability.bookings(of: row.room, on: moment.weekday, date: moment.date),
                marker: moment.minutes
            )
            .frame(height: MacRoomsTimeline.barHeight)
            .onGeometryChange(for: Range<CGFloat>.self) { proxy in
                let frame = proxy.frame(in: .global)
                return frame.minX..<frame.maxX
            } action: { onTrackRange($0) }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.room.buildingName) \(row.room.room), \(row.entry.status.detailedSummary)")
    }
}

/// A room's day as a bar: free stretches in green (brighter from the time on screen onward),
/// classes in gray with their course, a line for the time on screen.
struct MacRoomTrack: View {
    var bookings: [RoomSchedule.Booking]
    /// The time of day the list is for, in minutes after midnight.
    var marker: Int

    private let range = MacRoomsTimeline.range

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.13))
                ForEach(Array(freeSegments.enumerated()), id: \.offset) { _, segment in
                    block(segment.range, width: width, height: height)
                        .foregroundStyle(Color.green.opacity(segment.isPast ? 0.26 : 0.75))
                        .help("Free \(Self.label(of: segment.fullStretch))")
                }
                hourLines(width: width, height: height)
                    .stroke(Color(nsColor: .windowBackgroundColor).opacity(0.6), lineWidth: 0.75)
                ForEach(Array(bookings.enumerated()), id: \.offset) { _, booking in
                    classBlock(booking, width: width, height: height)
                }
                if range.contains(marker) {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: height + 10)
                        .offset(x: x(marker, width: width) - 1, y: -5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .accessibilityHidden(true)
    }

    // MARK: Free time

    private struct FreeSegment {
        var range: Range<Int>
        var isPast: Bool
        /// The whole stretch this segment is part of, for its tooltip.
        var fullStretch: Range<Int>
    }

    /// The free stretches of the day, each split at the marker into what has passed and what is ahead.
    private var freeSegments: [FreeSegment] {
        RoomAvailability.freeStretches(in: bookings, from: range.lowerBound, to: range.upperBound).flatMap { stretch -> [FreeSegment] in
            if marker <= stretch.lowerBound { return [FreeSegment(range: stretch, isPast: false, fullStretch: stretch)] }
            if marker >= stretch.upperBound { return [FreeSegment(range: stretch, isPast: true, fullStretch: stretch)] }
            return [
                FreeSegment(range: stretch.lowerBound..<marker, isPast: true, fullStretch: stretch),
                FreeSegment(range: marker..<stretch.upperBound, isPast: false, fullStretch: stretch),
            ]
        }
    }

    // MARK: Drawing

    private func x(_ minutes: Int, width: CGFloat) -> CGFloat {
        let clamped = min(max(minutes, range.lowerBound), range.upperBound)
        return width * CGFloat(clamped - range.lowerBound) / CGFloat(range.count)
    }

    private func block(_ span: Range<Int>, width: CGFloat, height: CGFloat) -> some View {
        let start = x(span.lowerBound, width: width)
        let end = x(span.upperBound, width: width)
        return Rectangle()
            .frame(width: max(0, end - start), height: height)
            .offset(x: start)
    }

    private func classBlock(_ booking: RoomSchedule.Booking, width: CGFloat, height: CGFloat) -> some View {
        let start = x(booking.start, width: width)
        let end = x(booking.end, width: width)
        let blockWidth = max(0, end - start)
        return Rectangle()
            .fill(Color.secondary.opacity(0.34))
            .frame(width: blockWidth, height: height)
            .overlay {
                if blockWidth >= 46 {
                    Text(booking.course.description)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 3)
                }
            }
            .offset(x: start)
            .help("\(booking.course.description) · \(TimeOfDay.rangeLabel(start: booking.start, end: booking.end))")
    }

    private func hourLines(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            for hour in (range.lowerBound / 60 + 1)..<(range.upperBound / 60) {
                let position = x(hour * 60, width: width)
                path.move(to: CGPoint(x: position, y: 0))
                path.addLine(to: CGPoint(x: position, y: height))
            }
        }
    }

    private static func label(of span: Range<Int>) -> String {
        "\(TimeOfDay.rangeLabel(start: span.lowerBound, end: span.upperBound)) (\(MacRoomRow.duration(minutes: span.count)))"
    }
}
