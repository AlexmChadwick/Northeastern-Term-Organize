//
//  MacScheduleCards.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A week as a thumbnail: the days as columns, the hours as rows, and a colored block for every class.
/// The cards of the schedules overview and the generator's grid of combinations draw their weeks with
/// it, all to the same scale (`sharedRange`) so that they can be compared at a glance.
struct MacMiniWeek: View {
    var events: [CalendarEvent]
    var days: [Int]
    var hours: ClosedRange<Int>
    /// Shown over an empty week.
    var emptyHint: String?

    private let headerHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    Text(DaySet.shortNames[day])
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: headerHeight)
            Canvas { context, size in
                draw(in: &context, size: size)
            }
        }
        .background(.background)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .overlay {
            if events.isEmpty, let emptyHint {
                Text(emptyHint)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: .capsule)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let rows = max(1, hours.upperBound - hours.lowerBound)
        let columns = max(1, days.count)
        let columnWidth = size.width / CGFloat(columns)
        let hourHeight = size.height / CGFloat(rows)

        var grid = Path()
        for row in 0..<rows {
            let y = CGFloat(row) * hourHeight
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for column in 1..<columns {
            let x = CGFloat(column) * columnWidth
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)

        for (column, day) in days.enumerated() {
            let dayEvents = events.filter { $0.day == day }.sorted { $0.start < $1.start }
            let lanes = CalendarLayout.lanes(for: dayEvents)
            for event in dayEvents {
                let lane = lanes[event.id] ?? (0, 1)
                let laneWidth = (columnWidth - 3) / CGFloat(lane.count)
                let top = CGFloat(event.start - hours.lowerBound * 60) / 60 * hourHeight
                let height = CGFloat(event.end - event.start) / 60 * hourHeight
                let rect = CGRect(
                    x: CGFloat(column) * columnWidth + 1.5 + CGFloat(lane.index) * laneWidth,
                    y: top + 0.5,
                    width: max(2, laneWidth - 1),
                    height: max(2.5, height - 1)
                )
                let color = event.isConflict ? Color.red : event.color.stroke
                context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color.opacity(event.isGhost ? 0.4 : 0.78)))
            }
        }
    }

    /// The hours and days that fit every one of these weeks, so thumbnails side by side are drawn to the
    /// same scale and can be compared.
    static func sharedRange(of weeks: [[CalendarEvent]], showWeekends: Bool, minimum: ClosedRange<Int> = 9...16) -> (hours: ClosedRange<Int>, days: [Int]) {
        let events = weeks.flatMap { $0 }
        guard let first = events.map(\.start).min(), let last = events.map(\.end).max() else {
            return (minimum, PlanCalendarSupport.visibleDays(events: [], showWeekends: showWeekends))
        }
        let lower = max(0, min(minimum.lowerBound, first / 60))
        let upper = min(24, max(minimum.upperBound, Int((Double(last) / 60).rounded(.up))))
        return (lower...max(lower + 1, upper), PlanCalendarSupport.visibleDays(events: events, showWeekends: showWeekends))
    }
}

/// The schedules of a term as cards on a grid: each card shows its week as a thumbnail, its courses
/// and anything that needs attention. A wider window fits more cards across. Click to select (the
/// preview follows), double-click or Return to open, the arrow keys to move, Delete to remove.
struct MacScheduleCards: View {
    var rows: [MacSchedulesOverview.Row]
    @Binding var selection: UUID?
    var showsWeekends: Bool
    var open: (UUID) -> Void
    var delete: (UUID) -> Void
    var menu: (UUID) -> AnyView

    /// The width the grid was given: decides how many cards fit across.
    @State private var width: CGFloat = 800
    @FocusState private var isFocused: Bool

    private let spacing: CGFloat = 16
    private let padding: CGFloat = 20
    private let minimumCardWidth: CGFloat = 250
    private let maximumCardWidth: CGFloat = 400

    private var columnCount: Int {
        max(1, Int((width - 2 * padding + spacing) / (minimumCardWidth + spacing)))
    }

    var body: some View {
        // The grid is an overlay of a plain color, so what is inside the cards (a row of course chips is
        // as wide as all of them side by side) never makes the window ask for more width.
        Color(nsColor: .windowBackgroundColor)
            .overlay { grid }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .delete, .deleteForward]) { press in
                handle(press.key)
            }
    }

    private var grid: some View {
        let shared = MacMiniWeek.sharedRange(of: rows.map(\.resolved.events), showWeekends: showsWeekends)
        return ScrollViewReader { proxy in
            ScrollView {
                // One adaptive item, not a column count of my own: its minimum is one card, so the
                // window never has to be wider than that for the grid.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minimumCardWidth, maximum: maximumCardWidth), spacing: spacing, alignment: .top)],
                    spacing: spacing
                ) {
                    ForEach(rows) { row in
                        MacScheduleCard(row: row, isSelected: selection == row.id, days: shared.days, hours: shared.hours)
                            .id(row.id)
                            .onTapGesture(count: 2) {
                                select(row.id)
                                open(row.id)
                            }
                            .onTapGesture { select(row.id) }
                            .contextMenu { menu(row.id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(named: "Open") { open(row.id) }
                    }
                }
                .padding(padding)
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func select(_ id: UUID) {
        isFocused = true
        selection = id
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        switch key {
        case .return:
            guard let selection else { return .ignored }
            open(selection)
            return .handled
        case .delete, .deleteForward:
            guard let selection else { return .ignored }
            delete(selection)
            return .handled
        default:
            let current = rows.firstIndex { $0.id == selection }
            let step: Int
            switch key {
            case .leftArrow: step = -1
            case .rightArrow: step = 1
            case .upArrow: step = -columnCount
            default: step = columnCount
            }
            let start = current ?? (step > 0 ? -1 : rows.count)
            let next = min(max(start + step, 0), rows.count - 1)
            selection = rows[next].id
            return .handled
        }
    }
}

/// One schedule as a card: name, the week, the courses and the warnings.
private struct MacScheduleCard: View {
    var row: MacSchedulesOverview.Row
    var isSelected: Bool
    var days: [Int]
    var hours: ClosedRange<Int>

    @State private var isHovered = false

    private let courseLimit = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            header
            MacMiniWeek(events: row.resolved.events, days: days, hours: hours, emptyHint: emptyHint)
                .aspectRatio(2, contentMode: .fit)
            if !row.plan.courses.isEmpty {
                chips
            }
            MacWarningLabels(warnings: row.resolved.warnings.filter { $0.severity != .neutral })
            Spacer(minLength: 0)
            Text("Edited \(row.plan.updatedAt.macRelativeLabel)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay {
            shape.strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 0.5)
        }
        .background {
            if isSelected {
                shape.fill(Color.accentColor.opacity(0.08))
            }
        }
        .shadow(color: .black.opacity(isHovered ? 0.14 : 0.05), radius: isHovered ? 8 : 3, y: 1)
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.plan.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if row.plan.isPrimary {
                    TagLabel(text: "My Schedule", systemImage: "star.fill", tint: .orange)
                }
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        let count = row.plan.courses.count
        var parts = [count == 1 ? "1 course" : "\(count) courses"]
        if row.resolved.hasCatalog, row.resolved.credits.max > 0 { parts.append(row.resolved.creditsLabel) }
        return parts.joined(separator: " · ")
    }

    private var emptyHint: String {
        if row.plan.courses.isEmpty { return "No courses yet" }
        if !row.resolved.hasCatalog { return "Open to view" }
        return row.resolved.hasSelection ? "No fixed meeting times" : "Choose sections"
    }

    private var chips: some View {
        let entries = row.resolved.entries
        return CourseFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(entries.prefix(courseLimit)) { entry in
                PlanCourseChip(
                    key: entry.key,
                    colorIndex: entry.planCourse.colorIndex,
                    isRequired: entry.planCourse.isRequired,
                    hasSection: entry.chosen != nil || !row.resolved.hasCatalog
                )
            }
            if entries.count > courseLimit {
                Text("+\(entries.count - courseLimit)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts = [row.plan.name]
        if row.plan.isPrimary { parts.append("My Schedule") }
        parts.append(subtitle)
        parts.append(contentsOf: row.resolved.warnings.filter { $0.severity != .neutral }.map(\.text))
        return parts.joined(separator: ", ")
    }
}
