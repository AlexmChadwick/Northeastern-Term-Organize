//
//  CourseMeetingRow.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Small circles for the days of the week (M T W R F), highlighting the active ones.
struct CourseWeekdayStrip: View {
    var days: DaySet
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 22

    /// Scales with Dynamic Type, but seven circles must still fit a card at the largest sizes.
    private var size: CGFloat { min(diameter, 34) }

    /// Monday to Friday, plus the weekend when the pattern uses it.
    private var visibleDays: [Int] {
        var result = [1, 2, 3, 4, 5]
        if days.contains(day: 6) || days.contains(day: 0) { result += [6, 0] }
        return result
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(visibleDays, id: \.self) { day in
                let isOn = days.contains(day: day)
                Text(DaySet.letters[day])
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .frame(width: size, height: size)
                    .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One meeting pattern: day circles, time range, location and (optionally) dates.
///
/// When `roomTermCode` is set, a known classroom (building code and room)
/// links to its classroom page; online and to-be-announced locations stay
/// plain text.
struct CourseMeetingRow: View {
    var pattern: CourseMeetingPattern
    /// Always show the date range (the detail screen does; cards only for irregular schedules).
    var showsDates = false
    /// Use the building's full name instead of its code.
    var usesLongLocation = true
    /// The term whose classroom page the location links to; nil keeps the location as text.
    var roomTermCode: String?
    /// Inside a tappable card the static text passes touches through to the card
    /// and the card describes it to VoiceOver; only the classroom link stays interactive.
    var isEmbedded = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var dateText: String? {
        if showsDates || pattern.isDatedList { return pattern.datesLabel }
        return nil
    }

    /// `Sep 9 – Dec 13` read as "Sep 9 to Dec 13".
    private var spokenDates: String? {
        dateText?.replacingOccurrences(of: " – ", with: " to ")
    }

    private var roomRoute: AppRoute? {
        guard let roomTermCode, let reference = pattern.roomReference else { return nil }
        return .room(termCode: roomTermCode, buildingCode: reference.buildingCode, room: reference.room)
    }

    /// One VoiceOver element for the whole row, unless a link has to stay separate.
    private var isSpokenAsOne: Bool { !isEmbedded && roomRoute == nil }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Spacing.m))
        layout {
            leading
                .courseDecorative(if: isEmbedded)
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CourseMeetingRowSpeech(isSpokenAsOne: isSpokenAsOne, label: spokenLabel))
    }

    // MARK: Pieces

    @ViewBuilder
    private var leading: some View {
        if pattern.days.isEmpty {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            CourseWeekdayStrip(days: pattern.days)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            staticPiece(timeLine, spoken: pattern.spokenSchedule)
            locationLine
            if let dateText {
                staticPiece(
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(spokenDates ?? dateText),
                    spoken: nil
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeLine: some View {
        HStack(spacing: 6) {
            Text(pattern.timeLabel)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            if pattern.kind.caseInsensitiveCompare("Class") != .orderedSame, !pattern.kind.isEmpty {
                TagLabel(text: pattern.kind)
            }
        }
    }

    @ViewBuilder
    private var locationLine: some View {
        let text = pattern.locationLabel(long: usesLongLocation)
        if let route = roomRoute {
            NavigationLink(value: route) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(text)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
                .font(.footnote)
                .foregroundStyle(.tint)
                .padding(.vertical, 3)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("Opens the classroom page")
            .accessibilityAddTraits(.isLink)
        } else {
            staticPiece(
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary),
                spoken: nil
            )
        }
    }

    /// Static text is hidden inside a card, its own VoiceOver element beside a
    /// classroom link, and part of the row's single element otherwise.
    @ViewBuilder
    private func staticPiece<Content: View>(_ content: Content, spoken: String?) -> some View {
        if isEmbedded {
            content.courseDecorative()
        } else if roomRoute != nil, let spoken {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        } else {
            content
        }
    }

    private var spokenLabel: String {
        var text = pattern.spokenDescription(longLocation: usesLongLocation)
        if let spokenDates { text += ", \(spokenDates)" }
        return text
    }
}

/// Speaks a row as a single VoiceOver element (days, time, place and dates).
private struct CourseMeetingRowSpeech: ViewModifier {
    var isSpokenAsOne: Bool
    var label: String

    func body(content: Content) -> some View {
        if isSpokenAsOne {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}

/// The schedule of a section as rows, with fallbacks for online, unscheduled
/// and time-to-be-announced sections.
struct CourseScheduleList: View {
    var section: CourseSection
    var showsDates = false
    var usesLongLocation = true
    /// The term whose classroom pages known locations link to; nil keeps them as text.
    var roomTermCode: String?
    /// Inside a tappable card (see `CourseMeetingRow`).
    var isEmbedded = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let patterns = section.courseMeetingPatterns
        VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? Theme.Spacing.l : Theme.Spacing.m) {
            if patterns.isEmpty {
                Label(emptyText, systemImage: emptyIcon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .courseDecorative(if: isEmbedded)
            } else {
                ForEach(patterns) { pattern in
                    CourseMeetingRow(
                        pattern: pattern,
                        showsDates: showsDates,
                        usesLongLocation: usesLongLocation,
                        roomTermCode: roomTermCode,
                        isEmbedded: isEmbedded
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyText: String {
        if section.isOnline { return "Online · asynchronous" }
        return section.meetings.isEmpty ? "No scheduled meetings" : "Times to be announced"
    }

    private var emptyIcon: String {
        section.isOnline ? "laptopcomputer" : "clock"
    }

    /// Spoken equivalent used by containers that describe the rows themselves.
    static func spokenSummary(for section: CourseSection) -> String {
        let patterns = section.courseMeetingPatterns
        if patterns.isEmpty {
            if section.isOnline { return "Online, asynchronous" }
            return section.meetings.isEmpty ? "No scheduled meetings" : "Times to be announced"
        }
        return patterns.map { $0.spokenDescription(longLocation: true) }.joined(separator: "; ")
    }
}

/// A title on the leading edge and its value on the trailing edge (stacked at
/// accessibility text sizes).
struct CourseKeyValueRow: View {
    var title: String
    var value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Spacing.m))
        layout {
            Text(title)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(isLarge ? .leading : .trailing)
                .frame(maxWidth: .infinity, alignment: isLarge ? .leading : .trailing)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
