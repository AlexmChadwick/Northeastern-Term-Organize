//
//  MacProfessorWindow.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A professor in its own window: what they teach this term, when and where, and a way to look them
/// up on Rate My Professors.
struct MacProfessorWindow: View {
    var value: ProfessorWindowValue

    @Environment(CatalogStore.self) private var catalog
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    @State private var resolver = CourseIndexResolver()

    private var index: CatalogIndex? { resolver.index(for: value.termCode, in: catalog) }
    private var summary: InstructorSummary? { index?.instructor(named: value.name) }
    private var displayName: String { summary?.displayName ?? Instructor.displayName(from: value.name) }
    private var termName: String { resolver.term(for: value.termCode, in: catalog)?.name ?? "this term" }

    /// The surname, for searching the catalog.
    private var lastName: String {
        value.name.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? value.name
    }

    var body: some View {
        content
            .navigationTitle(displayName)
            .navigationSubtitle(termName)
            .task(id: value.termCode) {
                await resolver.resolve(termCode: value.termCode, catalog: catalog)
            }
            .courseReloadsIndex(resolver, termCode: value.termCode)
            .frame(minWidth: 560, minHeight: 480)
    }

    @ViewBuilder
    private var content: some View {
        if let index, let summary {
            MacProfessorContent(summary: summary, index: index, termCode: value.termCode)
        } else if index == nil, resolver.isLoading(termCode: value.termCode, in: catalog) {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if index == nil {
            ContentUnavailableView {
                Label("Catalog Unavailable", systemImage: "icloud.slash")
            } description: {
                Text("The catalog for \(termName) isn't on this Mac yet.")
            } actions: {
                Button("Try Again") {
                    Task { await resolver.resolve(termCode: value.termCode, catalog: catalog) }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Sections Found", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("\(displayName) isn't listed as teaching any sections in \(termName).")
            } actions: {
                Button("Search for \(lastName)") {
                    MacCatalogNavigation.search(text: lastName, navigator: navigator, openWindow: openWindow)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The body of a professor's page: a header, their sections in a table and their week. Wide, the
/// week sits beside the table; narrower, under it. In a preview pane (the professors directory) the
/// actions that the window keeps in its toolbar are a row under the header.
struct MacProfessorContent: View {
    var summary: InstructorSummary
    var index: CatalogIndex
    var termCode: String
    var presentation: MacCoursePresentation = .window

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator

    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<CourseSection>] = [KeyPathComparator(\.macCatalogSortCourse), KeyPathComparator(\.sectionNumber, comparator: .localizedStandard)]
    @State private var newSchedule: MacCatalogNewScheduleRequest?
    @AppStorage private var customization: TableColumnCustomization<CourseSection>
    /// The page's width, measured after it is laid out (nothing is measured on the first pass).
    @State private var width: CGFloat = 0

    /// The width from which the table and the week sit side by side.
    private static let twoColumnWidth: CGFloat = 980
    private static let compactWidth: CGFloat = 560

    init(summary: InstructorSummary, index: CatalogIndex, termCode: String, presentation: MacCoursePresentation = .window) {
        self.summary = summary
        self.index = index
        self.termCode = termCode
        self.presentation = presentation
        _customization = AppStorage(wrappedValue: TableColumnCustomization<CourseSection>(), "mac.catalog.professorSectionColumns")
    }

    // MARK: Derived data

    private var sections: [CourseSection] {
        ProfessorPage.sections(of: summary, in: index)
    }

    private var courseColors: [CourseKey: CourseColor] {
        ProfessorPage.courseColors(for: summary.courseKeys)
    }

    private func color(for key: CourseKey) -> CourseColor {
        courseColors[key] ?? CourseColor.forCourse(key)
    }

    private func title(of section: CourseSection) -> String {
        index.course(section.courseKey)?.title ?? section.title
    }

    private var calendarEvents: [CalendarEvent] {
        let colors = courseColors
        return sections.flatMap { section in
            CalendarEvent.events(for: section, color: colors[section.courseKey] ?? CourseColor.forCourse(section.courseKey))
        }
    }

    private var selectedSections: [CourseSection] {
        sections.filter { selection.contains($0.crn) }
    }

    // MARK: Body

    var body: some View {
        let sections = self.sections.sorted(using: sortOrder)
        let compact = width > 0 && width < Self.compactWidth
        page(sections, wide: width >= Self.twoColumnWidth, compact: compact)
            .environment(\.macCourseCompact, compact)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .macCatalogToolbar { toolbarContent }
        .catalogNewScheduleAlert($newSchedule)
        .catalogToastHost()
    }

    @ViewBuilder
    private func page(_ sections: [CourseSection], wide: Bool, compact: Bool) -> some View {
        if sections.isEmpty {
            VStack(spacing: 0) {
                header(compact: compact)
                    .padding(.horizontal, compact ? 16 : 20)
                    .padding(.vertical, 14)
                Divider()
                ContentUnavailableView("No Sections", systemImage: "calendar.badge.exclamationmark", description: Text("None of this instructor's sections is in the catalog right now."))
            }
        } else if wide {
            // The table (under the header) and the week, side by side.
            MacSplitPane(
                storageKey: "mac.split.catalog.professor",
                paneEdge: .trailing,
                defaultShare: 0.46,
                paneMinWidth: 440,
                primaryMinWidth: 460,
                maxShare: 0.7
            ) {
                VStack(spacing: 0) {
                    header(compact: compact)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    Divider()
                    sectionsTable(sections)
                }
            } pane: {
                schedulePane
            }
        } else {
            VStack(spacing: 0) {
                header(compact: compact)
                    .padding(.horizontal, compact ? 16 : 20)
                    .padding(.vertical, 14)
                Divider()
                MacCatalogStackedSplit(storageKey: "mac.split.catalog.professorStacked", defaultBottomShare: 0.45, topMinHeight: 150, bottomMinHeight: 220) {
                    sectionsTable(sections)
                } bottom: {
                    schedulePane
                }
            }
        }
    }

    /// The window's toolbar: open the courses, add to a schedule, Rate My Professors.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if presentation == .window {
            ToolbarItemGroup(placement: .primaryAction) {
                openCoursesButton
                addToScheduleMenu
                    .macCatalogStores(MacCatalogStores(catalog: catalog, userData: userData, navigator: navigator))
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                if let url = ProfessorPage.rateMyProfessorsURL(for: summary.displayName) {
                    Button("Rate My Professors", systemImage: "star.bubble") { openURL(url) }
                        .help(Self.ratingsHelp(for: summary.displayName))
                }
            }
        }
    }

    private static func ratingsHelp(for name: String) -> String {
        "Search for \(name) on ratemyprofessors.com in your browser. Ratings and reviews there come from students and aren't affiliated with Northeastern or this app."
    }

    private var openCoursesButton: some View {
        Button("Open Course", systemImage: "macwindow.badge.plus") { openCourses(of: selectedSections) }
            .disabled(selection.isEmpty)
            .help("Open the courses of the selected sections in their own windows")
    }

    private var addToScheduleMenu: some View {
        MacCatalogAddToScheduleMenu(
            termCode: termCode,
            additions: selectedSections.map { MacCatalogScheduleAddition(key: $0.courseKey, crn: $0.crn) },
            newSchedule: $newSchedule
        ) {
            Label("Add to Schedule", systemImage: "calendar.badge.plus")
        }
        .help("Add the selected sections to a schedule")
    }

    // MARK: Header

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: compact ? 12 : 16) {
                ProfessorMonogram(name: summary.name, font: compact ? .headline : .title2.weight(.semibold), diameter: compact ? 44 : 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.displayName)
                        .font(compact ? .title2.weight(.semibold) : .title.weight(.semibold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let email = summary.email, let url = URL(string: "mailto:\(email)") {
                        Link(destination: url) {
                            Label(email, systemImage: "envelope")
                        }
                        .help("Write to \(summary.displayName)")
                    }
                    Text(ProfessorPage.summaryText(for: sections))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if presentation == .window {
                    searchCatalogButton
                }
            }
            if presentation == .pane {
                CourseFlowLayout(spacing: 8, lineSpacing: 8) {
                    Button {
                        openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: summary.name))
                    } label: {
                        Label("Open", systemImage: "macwindow.badge.plus")
                    }
                    .help("Open \(summary.displayName) in their own window")
                    openCoursesButton
                    addToScheduleMenu
                        .menuStyle(.button)
                        .fixedSize()
                    searchCatalogButton
                    if let url = ProfessorPage.rateMyProfessorsURL(for: summary.displayName) {
                        Button("Rate My Professors", systemImage: "star.bubble") { openURL(url) }
                            .help(Self.ratingsHelp(for: summary.displayName))
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var searchCatalogButton: some View {
        Button {
            MacCatalogNavigation.search(text: summary.displayName, navigator: navigator, openWindow: openWindow)
        } label: {
            Label("Search Catalog", systemImage: "magnifyingglass")
        }
        .help("Search the catalog for \(summary.displayName)")
    }

    // MARK: Sections

    /// The columns a table of this width has room for. A table adds about 17 points to each column and 15 to
    /// itself, so course, section, meets and seats need 410, the room 80 more and the title 130 more.
    private enum ColumnTier: Int, Comparable, Hashable {
        case minimal, compact, regular

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(width: CGFloat) {
            switch width {
            case ..<500: self = .minimal
            case ..<640: self = .compact
            default: self = .regular
            }
        }

        /// The narrowest tier that shows the column.
        static func first(showing id: String) -> Self {
            switch id {
            case "location": .compact
            case "title", "type": .regular
            default: .minimal
            }
        }
    }

    private static let optionalColumnIDs = ["location", "title", "type"]

    private func sectionsTable(_ sections: [CourseSection]) -> some View {
        MacCatalogAdaptiveTable(tierForWidth: { ColumnTier(width: $0) }) { tier in
            sectionsTable(sections, tier: tier)
        }
    }

    private func sectionsTable(_ sections: [CourseSection], tier: ColumnTier) -> some View {
        let dropped = Self.optionalColumnIDs.filter { ColumnTier.first(showing: $0) > tier }
        return Table(
            sections,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: MacCatalogTableColumns.binding($customization, dropping: dropped)
        ) {
            columns
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .focusable()
        .focusSection()
        .macScrollsTableSelectionIntoView(when: selection)
        .contextMenu(forSelectionType: String.self) { crns in
            if !crns.isEmpty {
                MacCourseSectionMenu(
                    termCode: termCode,
                    sections: sections.filter { crns.contains($0.crn) },
                    courseTitle: title(of:),
                    offersCourse: true,
                    newSchedule: $newSchedule
                )
            }
        } primaryAction: { crns in
            openCourses(of: sections.filter { crns.contains($0.crn) })
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            openCourses(of: selectedSections)
            return .handled
        }
        .onCopyCommand {
            let crns = selectedSections.map(\.crn)
            return crns.isEmpty ? [] : [NSItemProvider(object: crns.joined(separator: "\n") as NSString)]
        }
    }

    @TableColumnBuilder<CourseSection, KeyPathComparator<CourseSection>>
    private var columns: some TableColumnContent<CourseSection, KeyPathComparator<CourseSection>> {
        TableColumn("Course", value: \.macCatalogSortCourse) { section in
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: section.courseKey).stroke)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(section.courseKey.description)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .width(min: 98, ideal: 108, max: 140)
        .customizationID("course")

        TableColumn("Section", value: \.sectionNumber, comparator: .localizedStandard) { section in
            Text(section.sectionNumber).monospacedDigit()
        }
        .width(min: 44, ideal: 48, max: 80)
        .customizationID("section")

        TableColumn("Title", value: \.title, comparator: .localizedStandard) { section in
            Text(title(of: section))
                .lineLimit(1)
        }
        .width(min: 110, ideal: 150)
        .customizationID("title")

        TableColumn("Type", value: \.classType, comparator: .localizedStandard) { section in
            Text(section.classType)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .width(min: 70, ideal: 100)
        .defaultVisibility(.hidden)
        .customizationID("type")

        TableColumn("Meets", value: \.macCatalogSortStart) { section in
            Text(section.courseScheduleLine)
                .monospacedDigit()
                .lineLimit(1)
                .help(section.courseScheduleLine)
        }
        .width(min: 130, ideal: 160)
        .customizationID("meets")

        TableColumn("Location", value: \.macCatalogSortLocation, comparator: .localizedStandard) { section in
            Text(section.macCatalogLocationLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .width(min: 64, ideal: 76)
        .customizationID("location")

        TableColumn("Seats", value: \.macCatalogSortSeats) { section in
            MacSectionSeatsLabel(section: section)
        }
        .width(min: 62, ideal: 70, max: 110)
        .alignment(.numeric)
        .customizationID("seats")
    }

    // MARK: Week

    private var schedulePane: some View {
        MacProfessorWeekPane(events: calendarEvents, legend: legend) { crn in
            selection = [crn]
        }
    }

    private var legend: some View {
        CourseFlowLayout(spacing: 14, lineSpacing: 6) {
            ForEach(summary.courseKeys, id: \.self) { key in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(for: key).stroke)
                        .frame(width: 9, height: 9)
                    Text(key.description)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Actions

    private func openCourses(of sections: [CourseSection]) {
        var seen = Set<CourseKey>()
        for key in sections.map(\.courseKey) where seen.insert(key).inserted {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
        }
    }
}

/// A professor's week: their sections' meetings on a calendar, each hour as tall as the room the pane
/// has for it (a tall pane in a big window gets a roomy week, a short one the compact one).
private struct MacProfessorWeekPane<Legend: View>: View {
    var events: [CalendarEvent]
    var legend: Legend
    var onSelect: (String) -> Void

    @State private var height: CGFloat = 0

    var body: some View {
        let startHour = max(0, (events.map(\.start).min() ?? 0) / 60 - 1)
        let endHour = min(24, Int((Double(events.map(\.end).max() ?? 0) / 60).rounded(.up)) + 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Weekly Schedule")
                    .font(.headline)
                if events.isEmpty {
                    Label("None of these sections has set meeting times.", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                } else {
                    WeekCalendarView(
                        events: events,
                        startHour: startHour,
                        endHour: endHour,
                        hourHeight: hourHeight(hours: endHour - startHour),
                        showsNowIndicator: false
                    ) { event in
                        if let crn = event.payload { onSelect(crn) }
                    }
                    legend
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
    }

    /// The room the pane has (less the title, the day headings and the legend), shared by the hours
    /// shown, but never cramped and never absurd.
    private func hourHeight(hours: Int) -> CGFloat {
        min(max((height - 170) / CGFloat(max(hours, 1)), 38), 84)
    }
}
