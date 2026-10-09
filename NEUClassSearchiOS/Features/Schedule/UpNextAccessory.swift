//
//  UpNextAccessory.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Content of the tab bar bottom accessory showing the next class.
///
/// Uses the active "My Schedule" (`UserDataStore.activePrimaryPlan`: the term in
/// session, else the next to start) whichever term is being browsed. It shows the
/// class in progress, today's next class, or the next day's first class (the
/// first class of the term before it starts). Updates every minute.
struct UpNextAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button(action: openSchedule) {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your schedule")
        // The accessory bar can't grow taller, so (like the tab bar) cap the text
        // size and offer the Large Content Viewer at accessibility sizes.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer {
            Label("Up next", systemImage: "calendar")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(now: Date) -> some View {
        let plan = userData.activePrimaryPlan(now: now)
        // Any loaded term works (it is observable); a plan for a term that isn't loaded
        // yet is loaded in the background and the label fills in when it arrives.
        let index = plan.flatMap { catalog.cachedIndex(for: $0.termCode) }
        Group {
            switch UpNextClass.find(plan: plan, index: index, now: now) {
            case .class(let item):
                if placement == .inline {
                    inlineLabel(item)
                } else {
                    expandedLabel(item)
                }
            case .termEnded:
                plainLabel("Term complete", detail: nil)
            case .noClasses, .unavailable:
                plainLabel("My Schedule", detail: placement == .inline ? nil : "Open your schedule")
            }
        }
        .task(id: plan?.termCode) {
            if let code = plan?.termCode { _ = await catalog.index(for: code) }
        }
    }

    private func expandedLabel(_ item: UpNextClass.Item) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(CourseColor.at(item.meeting.colorIndex).stroke)
                .frame(width: 10, height: 10)
            // Drops the "Up next" prefix, then the room, when the line would not fit.
            ViewThatFits(in: .horizontal) {
                expandedText(item, .full)
                expandedText(item, .withoutPrefix)
                expandedText(item, .compact)
            }
            Spacer(minLength: 4)
            Text(item.relativeText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(item.isInProgress ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private func expandedText(_ item: UpNextClass.Item, _ level: UpNextClass.Item.TextLevel) -> some View {
        Text(item.expandedText(level))
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
    }

    private func inlineLabel(_ item: UpNextClass.Item) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(CourseColor.at(item.meeting.colorIndex).stroke)
                .frame(width: 8, height: 8)
            Text(item.inlineText)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private func plainLabel(_ title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
            Text(title)
                .font(.footnote.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .lineLimit(1)
    }

    // MARK: Action

    private func openSchedule() {
        router.selectedTab = .schedule
        if let plan = userData.activePrimaryPlan() {
            // Go straight to the plan rather than stacking on whatever was open.
            router.setPath([.plan(id: plan.id)], for: .schedule)
        }
    }
}
