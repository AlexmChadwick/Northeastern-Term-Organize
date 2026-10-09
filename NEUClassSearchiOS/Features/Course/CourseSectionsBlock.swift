//
//  CourseSectionsBlock.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The "Sections" part of the course page: seat summary, filters, an optional
/// side-by-side time comparison and one card per section.
struct CourseSectionsBlock: View {
    var course: Course
    var sections: [CourseSection]
    var termCode: String
    var isLoadingDetails: Bool
    var lastUpdated: Date?
    var isRefreshing: Bool
    var refreshFailed: Bool
    var onRefresh: () -> Void
    /// Brings a section's card on screen (used by the comparison calendar).
    var scrollTo: (String) -> Void
    /// Pushes a destination from a card's context menu.
    var onNavigate: (AppRoute) -> Void = { _ in }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var typeFilter: String?
    @State private var campusFilter: String?
    @State private var openOnly = false
    @State private var showsCompare = false
    @State private var selectedCRN: String?

    // MARK: Derived data

    private struct Entry: Identifiable {
        var position: Int
        var section: CourseSection
        var id: String { section.crn }
    }

    private struct SectionGroup: Identifiable {
        var title: String?
        var entries: [Entry]
        var id: String { title ?? "all" }
    }

    private var classTypes: [String] {
        var seen = Set<String>()
        return sections.map(\.classType).filter { seen.insert($0).inserted }
    }

    /// Campuses with sections, most common first.
    private var campuses: [String] {
        let counts = Dictionary(grouping: sections.compactMap(\.courseDisplayCampus), by: { $0 }).mapValues(\.count)
        return counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }.map(\.key)
    }

    // A live refresh can remove the sections a filter was built for; a filter
    // only counts while its chip is still offered.
    private var activeTypeFilter: String? {
        typeFilter.flatMap { classTypes.contains($0) ? $0 : nil }
    }

    private var activeCampusFilter: String? {
        campusFilter.flatMap { campuses.contains($0) ? $0 : nil }
    }

    private var isOpenOnly: Bool { openOnly && showsOpenChip }

    private var isComparing: Bool { showsCompare && showsCompareChip }

    private var filtered: [CourseSection] {
        let type = activeTypeFilter
        let campus = activeCampusFilter
        let openOnly = isOpenOnly
        return sections.filter { section in
            (type == nil || section.classType == type)
                && (campus == nil || section.courseDisplayCampus == campus)
                && (!openOnly || section.isOpen)
        }
    }

    private var hasActiveFilters: Bool {
        activeTypeFilter != nil || activeCampusFilter != nil || isOpenOnly
    }

    private var openCount: Int { sections.filter(\.isOpen).count }

    private var groups: [SectionGroup] {
        let entries = filtered.enumerated().map { Entry(position: $0.offset, section: $0.element) }
        guard activeTypeFilter == nil, classTypes.count > 1 else {
            return [SectionGroup(title: nil, entries: entries)]
        }
        return classTypes.compactMap { type in
            let matching = entries.filter { $0.section.classType == type }
            return matching.isEmpty ? nil : SectionGroup(title: type, entries: matching)
        }
    }

    private var scheduledCount: Int {
        sections.filter { section in section.courseMeetingPatterns.contains(where: \.hasTime) }.count
    }

    private var columns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.m, alignment: .top), count: count)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
                .padding(.horizontal, Theme.Spacing.l)
            if !sections.isEmpty {
                filterBar
                compareCard
                list
            } else {
                emptyState
                    .padding(.horizontal, Theme.Spacing.l)
            }
        }
        .task(id: selectedCRN) {
            guard selectedCRN != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { selectedCRN = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("Sections")
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Spacing.s)
                refreshButton
            }
            if !sections.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(openCount > 0 ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("\(openCount) of \(sections.count) open")
                        .monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
                .accessibilityElement(children: .combine)
            }
            if let lastUpdated {
                CourseUpdatedLabel(date: lastUpdated)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if refreshFailed {
                HStack(spacing: 6) {
                    Label("Couldn't refresh. Showing saved seat counts.", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var refreshButton: some View {
        CourseRefreshButton(isRefreshing: isRefreshing, action: onRefresh)
    }

    // MARK: Filters

    private var showsTypeChips: Bool { classTypes.count > 1 }
    private var showsOpenChip: Bool { sections.count >= 4 }
    private var showsCampusChip: Bool { campuses.count > 1 }
    private var showsCompareChip: Bool { scheduledCount > 1 }

    @ViewBuilder
    private var filterBar: some View {
        if showsTypeChips || showsOpenChip || showsCampusChip || showsCompareChip {
            GlassChipBar {
                if showsTypeChips {
                    GlassChip(title: "All \(sections.count)", isOn: activeTypeFilter == nil) {
                        typeFilter = nil
                    }
                    ForEach(classTypes, id: \.self) { type in
                        GlassChip(title: "\(type) \(sections.filter { $0.classType == type }.count)", isOn: activeTypeFilter == type) {
                            typeFilter = (activeTypeFilter == type) ? nil : type
                        }
                    }
                }
                if showsOpenChip {
                    GlassChip(title: "Open seats", systemImage: "chair", isOn: isOpenOnly) {
                        openOnly = !isOpenOnly
                    }
                }
                if showsCampusChip {
                    campusMenu
                }
                if showsCompareChip {
                    GlassChip(title: "Compare times", systemImage: "calendar", isOn: isComparing) {
                        withAnimation(.snappy) { showsCompare = !isComparing }
                    }
                }
            }
        }
    }

    private var campusMenu: some View {
        let selected = activeCampusFilter
        return Menu {
            Button {
                campusFilter = nil
            } label: {
                if selected == nil {
                    Label("All Campuses", systemImage: "checkmark")
                } else {
                    Text("All Campuses")
                }
            }
            ForEach(campuses, id: \.self) { campus in
                Button {
                    campusFilter = campus
                } label: {
                    if selected == campus {
                        Label(campus, systemImage: "checkmark")
                    } else {
                        Text(campus)
                    }
                }
            }
        } label: {
            GlassChipLabel(
                title: selected ?? "Campus",
                systemImage: "mappin.and.ellipse",
                isOn: selected != nil,
                showsChevron: true
            )
        }
        .glassChipStyle(isOn: selected != nil)
    }

    // MARK: Compare calendar

    private var compareEvents: [CalendarEvent] {
        filtered.enumerated().flatMap { offset, section in
            CalendarEvent.events(for: section, color: CourseColor.at(offset), title: "Sec \(section.sectionNumber)")
        }
    }

    @ViewBuilder
    private var compareCard: some View {
        if isComparing {
            let events = compareEvents
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if events.isEmpty {
                    Label("None of these sections has scheduled meeting times.", systemImage: "calendar.badge.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    WeekCalendarView(events: events, hourHeight: 40, showsNowIndicator: false) { event in
                        guard let crn = event.payload else { return }
                        selectedCRN = crn
                        scrollTo(crn)
                    }
                    Text("Each section has its own color. Tap a block to jump to its card.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .courseCard()
            .padding(.horizontal, Theme.Spacing.l)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            noMatches
                .padding(.horizontal, Theme.Spacing.l)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        if let title = group.title {
                            groupHeader(title: title, count: group.entries.count)
                        }
                        LazyVGrid(columns: columns, alignment: .center, spacing: Theme.Spacing.m) {
                            ForEach(group.entries) { entry in
                                card(for: entry)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }

    private func card(for entry: Entry) -> some View {
        // A section without meeting times has no block on the comparison calendar, so no color.
        let showsColor = isComparing && entry.section.courseMeetingPatterns.contains(where: \.hasTime)
        return CourseSectionCard(
            section: entry.section,
            course: course,
            termCode: termCode,
            isLoadingDetails: isLoadingDetails,
            compareColor: showsColor ? CourseColor.at(entry.position) : nil,
            isHighlighted: selectedCRN == entry.section.crn,
            onNavigate: onNavigate
        )
        .id(entry.section.crn)
    }

    private func groupHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.headline)
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var noMatches: some View {
        VStack(spacing: Theme.Spacing.m) {
            Label("No sections match", systemImage: "line.3.horizontal.decrease.circle")
                .font(.headline)
            if hasActiveFilters {
                Button("Clear Filters") {
                    typeFilter = nil
                    campusFilter = nil
                    openOnly = false
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .cardBackground()
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.s) {
            Label("No sections this term", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
            Text("Northeastern hasn't published any sections of \(course.code) for this term.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .cardBackground()
    }
}
