//
//  CourseSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Small building blocks shared by the course, section and professor screens:
//  placeholders, card styling and the icon controls. (Index resolution lives in
//  Logic/Course/CourseIndexResolver.swift and the wrapping layout in
//  DesignSystem/Components/CourseFlowLayout.swift, both shared with the Mac app.)
//

import SwiftUI

// MARK: - View helpers

extension View {
    /// A rounded content card (not glass) filling the available width.
    func courseCard(padding: CGFloat = Theme.Spacing.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
    }

    /// Marks purely visual content so it passes touches to a link underneath it
    /// and stays out of the accessibility tree (the container describes it).
    func courseDecorative() -> some View {
        self
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// `courseDecorative()` only when `condition` holds (e.g. inside a tappable card).
    @ViewBuilder
    func courseDecorative(if condition: Bool) -> some View {
        if condition {
            courseDecorative()
        } else {
            self
        }
    }

    /// Redacts the view and gently pulses it while `isActive`.
    ///
    /// The pulse is a `TimelineView`, so only put this on a small placeholder. Never wrap
    /// a region that holds another `TimelineView` (a `WeekCalendarView`, a
    /// `CourseUpdatedLabel`): nested timelines can loop forever while a screen is pushed.
    func courseShimmer(isActive: Bool) -> some View {
        modifier(CourseShimmerModifier(isActive: isActive))
    }

    /// Constrains content to a comfortable reading width and centers it (iPad).
    func courseReadableWidth(_ width: CGFloat = 820) -> some View {
        self
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }
}

private struct CourseShimmerModifier: ViewModifier {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 2.6
                content
                    .redacted(reason: .placeholder)
                    .opacity(reduceMotion ? 0.7 : 0.62 + 0.38 * (0.5 + 0.5 * sin(phase)))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
        } else {
            content
        }
    }
}

// MARK: - Shared components

/// A block title ("Sections", "Requirements") with an optional trailing control.
struct CourseBlockHeader<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.s)
            accessory
        }
    }
}

extension CourseBlockHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// `Updated 5 minutes ago`, refreshed every 30 seconds.
struct CourseUpdatedLabel: View {
    var date: Date
    var prefix = "Updated"

    var body: some View {
        // Anchored to `date`, not `.now`: a schedule that changes on every evaluation
        // restarts the timeline each time the view is rebuilt. Keep this TimelineView
        // on the small label; never nest it in another one (see `courseShimmer`).
        TimelineView(.periodic(from: date, by: 30)) { context in
            Text("\(prefix) \(CourseFormat.relative(date, to: context.date))")
        }
    }
}

/// The label of a circular icon control (bookmark, share, more); pair it with
/// `.glassEffect(.regular.interactive(), in: .circle)`.
struct CourseIconLabel: View {
    var systemName: String
    var tint: Color?

    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 48

    init(_ systemName: String, tint: Color? = nil) {
        self.systemName = systemName
        self.tint = tint
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            .frame(width: min(diameter, 64), height: min(diameter, 64))
            .contentShape(.circle)
    }
}

/// A circular glass refresh control that shows a spinner while refreshing.
struct CourseRefreshButton: View {
    var isRefreshing: Bool
    var action: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 40

    var body: some View {
        // Not `.disabled`: the spinner should stay fully visible while refreshing.
        Button {
            if !isRefreshing { action() }
        } label: {
            ZStack {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: min(diameter, 56), height: min(diameter, 56))
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(isRefreshing ? "Refreshing seats" : "Refresh seats")
    }
}

/// Press feedback for a card-sized `NavigationLink` placed behind the card's content.
struct CourseCardLinkStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Radius.card

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect(cornerRadius: cornerRadius))
            .background(
                configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                in: .rect(cornerRadius: cornerRadius)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
