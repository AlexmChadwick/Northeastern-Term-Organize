//
//  MacCourseSections.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The sections of a course in the course window: how many are open and how fresh that is, filters
/// for the type, campus and open seats, a table (CRN, type, days and times, location, instructors,
/// seats and waitlist) and the details of the section that is selected.
struct MacCourseSectionsPane: View {
    var course: Course
    var sections: [CourseSection]
    var termCode: String
    var isLoadingDetails: Bool
    var lastUpdated: Date?
    var isRefreshing: Bool
    var refreshFailed: Bool
    /// Whether the week of all the sections' meetings is drawn under the table (a wide page has the
    /// room), instead of behind the "Compare Times" button.
    var showsWeek = false
    var onRefresh: () -> Void
    @Binding var selection: Set<String>
    @Binding var newSchedule: MacCatalogNewScheduleRequest?

    @Environment(\.catalogToast) private var toast
    @Environment(\.macCourseCompact) private var compact

    @State private var typeFilter: String?
    @State private var campusFilter: String?
    @State private var openOnly = false
    @State private var showsCompare = false
    @State private var sortOrder: [KeyPathComparator<CourseSection>] = []
    @AppStorage private var customization: TableColumnCustomization<CourseSection>

    init(
        course: Course,
        sections: [CourseSection],
        termCode: String,
        isLoadingDetails: Bool,
        lastUpdated: Date?,
        isRefreshing: Bool,
        refreshFailed: Bool,
        showsWeek: Bool = false,
        onRefresh: @escaping () -> Void,
        selection: Binding<Set<String>>,
        newSchedule: Binding<MacCatalogNewScheduleRequest?>
    ) {
        self.course = course
        self.sections = sections
        self.termCode = termCode
        self.isLoadingDetails = isLoadingDetails
        self.lastUpdated = lastUpdated
        self.isRefreshing = isRefreshing
        self.refreshFailed = refreshFailed
        self.showsWeek = showsWeek
        self.onRefresh = onRefresh
        self._selection = selection
        self._newSchedule = newSchedule
        _customization = AppStorage(wrappedValue: TableColumnCustomization<CourseSection>(), "mac.catalog.courseSectionColumns")
    }

    // MARK: Derived data

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

    // A live refresh can remove the sections a filter was built for; a filter only counts while
    // it is still offered.
    private var activeTypeFilter: String? {
        typeFilter.flatMap { classTypes.contains($0) ? $0 : nil }
    }

    private var activeCampusFilter: String? {
        campusFilter.flatMap { campuses.contains($0) ? $0 : nil }
    }

    private var showsOpenToggle: Bool { sections.count >= 3 }
    private var isOpenOnly: Bool { openOnly && showsOpenToggle }

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

    private var scheduledCount: Int {
        sections.filter { section in section.courseMeetingPatterns.contains(where: \.hasTime) }.count
    }

    private var selectedSections: [CourseSection] {
        sections.filter { selection.contains($0.crn) }
    }

    // MARK: Body

    var body: some View {
        let rows = filtered.sorted(using: sortOrder)
        VStack(spacing: 0) {
            header
            if sections.count > 1 {
                filterBar
            }
            Divider()
            if inlineWeek {
                // The table above, the week of its sections below, the divider between them to drag.
                MacCatalogStackedSplit(storageKey: "mac.split.catalog.sectionsWeek", defaultBottomShare: 0.42, topMinHeight: 200, bottomMinHeight: 240) {
                    tableAndDetails(rows)
                } bottom: {
                    VStack(spacing: 0) {
                        Divider()
                        MacCourseSectionCompareView(sections: filtered, isEmbedded: true) { selection = [$0] }
                    }
                }
            } else {
                tableAndDetails(rows)
            }
            statusBar(rows)
        }
    }

    /// Whether the week is drawn here: asked for, and there are meeting times to draw.
    private var inlineWeek: Bool { showsWeek && scheduledCount > 1 }

    private func tableAndDetails(_ rows: [CourseSection]) -> some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                noMatches
            } else {
                table(rows)
            }
            if selectedSections.count == 1, let section = selectedSections.first {
                Divider()
                MacCourseSectionDetails(section: section, course: course, termCode: termCode, isLoadingDetails: isLoadingDetails)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Sections")
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if !sections.isEmpty {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(openCount > 0 ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text("\(openCount) of \(sections.count) open")
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                if let lastUpdated, !compact {
                    MacCatalogRelativeDateText(date: lastUpdated)
                        .foregroundStyle(.secondary)
                }
                if refreshFailed, !compact {
                    Label("Couldn't refresh. Showing saved seat counts.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing seats")
                } else {
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Download the latest seat counts for this course")
                }
            }
            if compact {
                // Under the title, where a narrow pane has the room for the sentence.
                if refreshFailed {
                    Label("Couldn't refresh. Showing saved seat counts.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let lastUpdated {
                    MacCatalogRelativeDateText(date: lastUpdated)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Filters

    @ViewBuilder
    private var filterBar: some View {
        // One row when it fits (with the comparison pushed to the right), wrapping when it doesn't.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                filterControls
                Spacer(minLength: 8)
                compareControl
            }
            CourseFlowLayout(spacing: 8, lineSpacing: 6) {
                filterControls
                compareControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var filterControls: some View {
        if classTypes.count > 1 {
            typePicker
        }
        if campuses.count > 1 {
            campusMenu
        }
        if showsOpenToggle {
            Toggle(isOn: $openOnly) {
                Label("Open Seats", systemImage: "chair")
            }
            .toggleStyle(.button)
            .help("Show only sections with an open seat")
        }
    }

    @ViewBuilder
    private var compareControl: some View {
        if scheduledCount > 1, !inlineWeek {
            MacCourseSectionCompareButton(
                sections: filtered,
                isPresented: $showsCompare,
                select: { selection = [$0] }
            )
        }
    }

    @ViewBuilder
    private var typePicker: some View {
        let selection = Binding<String?>(get: { activeTypeFilter }, set: { typeFilter = $0 })
        if classTypes.count <= 3 {
            Picker("Type", selection: selection) {
                Text("All \(sections.count)").tag(String?.none)
                ForEach(classTypes, id: \.self) { type in
                    Text("\(type) \(sections.filter { $0.classType == type }.count)").tag(String?.some(type))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } else {
            Menu {
                Picker("Type", selection: selection) {
                    Text("All \(sections.count)").tag(String?.none)
                    ForEach(classTypes, id: \.self) { type in
                        Text("\(type) \(sections.filter { $0.classType == type }.count)").tag(String?.some(type))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(activeTypeFilter ?? "All Types")
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }

    private var campusMenu: some View {
        let selected = activeCampusFilter
        return Menu {
            Picker("Campus", selection: Binding<String?>(get: { selected }, set: { campusFilter = $0 })) {
                Text("All Campuses").tag(String?.none)
                ForEach(campuses, id: \.self) { campus in
                    Text(campus).tag(String?.some(campus))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(selected ?? "Campus")
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .tint(selected != nil ? Color.accentColor : nil)
        .fixedSize()
        .help("Show the sections at one campus")
    }

    // MARK: Table

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No Sections Match", systemImage: "line.3.horizontal.decrease.circle")
        } actions: {
            if hasActiveFilters {
                Button("Clear Filters") {
                    typeFilter = nil
                    campusFilter = nil
                    openOnly = false
                }
            }
        }
    }

    /// The columns a table of this width has room for. A table adds about 17 points to each column and 15 to
    /// itself, so the six that are always there need 485, and each of the others 55 to 120 more.
    private enum ColumnTier: Int, Comparable, Hashable {
        case minimal, compact, regular, wide

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(width: CGFloat) {
            switch width {
            case ..<560: self = .minimal
            case ..<640: self = .compact
            case ..<760: self = .regular
            default: self = .wide
            }
        }

        /// The narrowest tier that shows the column.
        static func first(showing id: String) -> Self {
            switch id {
            case "type": .compact
            case "topic", "location": .regular
            case "waitlist": .wide
            default: .minimal
            }
        }
    }

    private static let optionalColumnIDs = ["type", "topic", "location", "waitlist"]

    private func table(_ rows: [CourseSection]) -> some View {
        MacCatalogAdaptiveTable(tierForWidth: { ColumnTier(width: $0) }) { tier in
            sectionsTable(rows, tier: tier)
        }
    }

    private func sectionsTable(_ rows: [CourseSection], tier: ColumnTier) -> some View {
        let dropped = Self.optionalColumnIDs.filter { ColumnTier.first(showing: $0) > tier }
        return Table(
            rows,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: MacCatalogTableColumns.binding($customization, dropping: dropped)
        ) {
            columns
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .macFocusesOnClick()
        .macScrollsTableSelectionIntoView(when: selection)
        .contextMenu(forSelectionType: String.self) { crns in
            if !crns.isEmpty {
                MacCourseSectionMenu(
                    termCode: termCode,
                    sections: sections.filter { crns.contains($0.crn) },
                    courseTitle: { _ in course.title },
                    newSchedule: $newSchedule
                )
            }
        } primaryAction: { crns in
            copyCRNs(of: rows.filter { crns.contains($0.crn) })
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            copyCRNs(of: rows.filter { selection.contains($0.crn) })
            return .handled
        }
        .onCopyCommand {
            let crns = rows.filter { selection.contains($0.crn) }.map(\.crn)
            return crns.isEmpty ? [] : [NSItemProvider(object: crns.joined(separator: "\n") as NSString)]
        }
    }

    /// Double-click and Return copy the CRN, the thing most often wanted from this table.
    private func copyCRNs(of sections: [CourseSection]) {
        guard !sections.isEmpty else { return }
        MacCatalogClipboard.copy(sections.map(\.crn).joined(separator: "\n"))
        toast(sections.count == 1 ? "Copied CRN \(sections[0].crn)" : "Copied \(sections.count) CRNs", systemImage: "doc.on.doc.fill")
    }

    /// Whether the table has a Type column. A special topic's sections show their topic instead, and
    /// only get a type when they aren't all the same.
    private var showsTypeColumn: Bool { !course.specialTopics || classTypes.count > 1 }

    @TableColumnBuilder<CourseSection, KeyPathComparator<CourseSection>>
    private var columns: some TableColumnContent<CourseSection, KeyPathComparator<CourseSection>> {
        TableColumn("") { section in
            MacSectionWatchButton(section: section, courseTitle: course.title, termCode: termCode)
        }
        .width(26)
        .disabledCustomizationBehavior(.all)
        .customizationID("watch")

        TableColumn("CRN", value: \.crn, comparator: .localizedStandard) { section in
            MacSectionCRNButton(crn: section.crn)
        }
        .width(min: 62, ideal: 70, max: 110)
        .customizationID("crn")

        TableColumn("Sec", value: \.sectionNumber, comparator: .localizedStandard) { section in
            HStack(spacing: 4) {
                Text(section.sectionNumber)
                    .monospacedDigit()
                if section.honors {
                    Image(systemName: "star.fill")
                        .imageScale(.small)
                        .foregroundStyle(.purple)
                        .help("Honors section")
                        .accessibilityLabel("Honors")
                }
                if !section.crossListCRNs.isEmpty {
                    Image(systemName: "link")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help("Cross-listed with another course")
                        .accessibilityLabel("Cross-listed")
                }
            }
        }
        .width(min: 34, ideal: 40, max: 80)
        .customizationID("section")

        if showsTypeColumn {
            TableColumn("Type", value: \.classType, comparator: .localizedStandard) { section in
                Text(section.classType)
                    .lineLimit(1)
            }
            .width(min: 54, ideal: 66, max: 170)
            .customizationID("type")
        }

        if course.specialTopics {
            TableColumn("Topic", value: \.title, comparator: .localizedStandard) { section in
                Text(section.title)
                    .lineLimit(1)
                    .help(section.title)
            }
            .width(min: 100, ideal: 200)
            .customizationID("topic")
        }

        TableColumn("Meets", value: \.macCatalogSortStart) { section in
            Text(section.courseScheduleLine)
                .monospacedDigit()
                .lineLimit(1)
                .help(section.courseScheduleLine)
        }
        .width(min: 112, ideal: 146)
        .customizationID("meets")

        if !course.specialTopics {
            TableColumn("Location", value: \.macCatalogSortLocation, comparator: .localizedStandard) { section in
                Text(section.macCatalogLocationLabel)
                    .lineLimit(1)
                    .help(section.courseMeetingPatterns.map { $0.locationLabel(long: true) }.joined(separator: "\n"))
            }
            .width(min: 50, ideal: 58)
            .customizationID("location")
        }

        TableColumn("Instructors", value: \.macCatalogSortInstructor, comparator: .localizedStandard) { section in
            MacSectionInstructorLinks(section: section, termCode: termCode, isLoadingDetails: isLoadingDetails)
        }
        .width(min: 70, ideal: 84)
        .customizationID("instructors")

        TableColumn("Seats", value: \.macCatalogSortSeats) { section in
            MacSectionSeatsLabel(section: section)
        }
        .width(min: 62, ideal: 70, max: 100)
        .alignment(.numeric)
        .customizationID("seats")

        TableColumn("Waitlist", value: \.macCatalogSortWaitlist) { section in
            MacSectionWaitlistLabel(section: section)
        }
        .width(min: 40, ideal: 44, max: 90)
        .alignment(.numeric)
        .customizationID("waitlist")
    }

    // MARK: Status

    private func statusBar(_ rows: [CourseSection]) -> some View {
        HStack(spacing: 12) {
            Text(statusText(rows))
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 12)
            if selection.isEmpty && !sections.isEmpty && !compact {
                Text("Click a CRN to copy it. Select a section for its details.")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func statusText(_ rows: [CourseSection]) -> String {
        var text = rows.count == sections.count
            ? CourseFormat.count(sections.count, "section")
            : "\(rows.count) of \(CourseFormat.count(sections.count, "section"))"
        if !selection.isEmpty { text += " · \(selection.count) selected" }
        return text
    }
}

// MARK: - Compare times

/// "Compare Times": every section's meetings side by side on one week, in a popover, so a clash or a
/// fit shows at a glance. Clicking a block selects that section's row.
private struct MacCourseSectionCompareButton: View {
    var sections: [CourseSection]
    @Binding var isPresented: Bool
    var select: (String) -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Compare Times", systemImage: "calendar")
        }
        .help("See all of these sections' meeting times on one week")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MacCourseSectionCompareView(sections: sections) { crn in
                select(crn)
                isPresented = false
            }
        }
    }
}

/// A week with one color per section: in the "Compare Times" popover, or (`isEmbedded`) under the sections
/// table of a wide page, where each hour is as tall as the room allows.
struct MacCourseSectionCompareView: View {
    var sections: [CourseSection]
    var isEmbedded = false
    var select: (String) -> Void

    /// The height of the embedded week's pane, for the height of an hour.
    @State private var height: CGFloat = 0

    private var events: [CalendarEvent] {
        sections.enumerated().flatMap { offset, section in
            CalendarEvent.events(for: section, color: CourseColor.at(offset), title: "Sec \(section.sectionNumber)")
        }
    }

    var body: some View {
        let events = self.events
        let startHour = max(0, (events.map(\.start).min() ?? 0) / 60 - 1)
        let endHour = min(24, Int((Double(events.map(\.end).max() ?? 0) / 60).rounded(.up)) + 1)
        VStack(alignment: .leading, spacing: 10) {
            Text(isEmbedded ? "Week at a Glance" : "Compare Times")
                .font(.headline)
            if events.isEmpty {
                Label("None of these sections has scheduled meeting times.", systemImage: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    WeekCalendarView(
                        events: events,
                        startHour: startHour,
                        endHour: endHour,
                        hourHeight: isEmbedded ? hourHeight(hours: endHour - startHour) : 34,
                        showsNowIndicator: false
                    ) { event in
                        if let crn = event.payload { select(crn) }
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
                Text("Each section has its own color. Click a block to select its row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(isEmbedded ? EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20) : EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
        .macCatalogApplying(if: !isEmbedded) { $0.frame(width: 640, height: 460) }
    }

    /// The room the scroll view has (less the day headings), shared by the hours shown.
    private func hourHeight(hours: Int) -> CGFloat {
        min(max((height - 40) / CGFloat(max(hours, 1)), 28), 64)
    }
}
