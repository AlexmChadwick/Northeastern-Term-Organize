//
//  MacCatalogCourseTable.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The table of courses behind search results, a subject's courses and the saved list: sortable
//  columns the user can show, hide and reorder, double-click or Return to open a course window,
//  a context menu, and codes that can be dragged out.
//

import SwiftUI

/// One course in a table of courses.
struct MacCatalogCourseRow: Identifiable {
    var key: CourseKey
    /// Nil when the term's catalog doesn't list the course (a saved course of another term).
    var course: Course?
    /// Availability over the sections that count (those matching the section filters, if any).
    var stats: CourseStats
    /// Why the course matched a search when its title doesn't say ("Taught by Jane Doe").
    var note: String?
    /// Muted restriction note, such as a CPS-only caption.
    var caption: String?
    /// When the course was saved (the saved list).
    var savedAt: Date?

    var id: CourseKey { key }

    init(course: Course, stats: CourseStats, note: String? = nil, caption: String? = nil, savedAt: Date? = nil) {
        self.key = course.key
        self.course = course
        self.stats = stats
        self.note = note
        self.caption = caption
        self.savedAt = savedAt
    }

    /// A course the term's catalog doesn't list.
    init(missing key: CourseKey, savedAt: Date? = nil) {
        self.key = key
        self.course = nil
        self.stats = CourseStats()
        self.note = nil
        self.caption = nil
        self.savedAt = savedAt
    }

    // Sort keys: the table's columns sort by these.
    var title: String { course?.title ?? "" }
    var minCredits: Double { course?.minCredits ?? 0 }
    var openSeats: Int { stats.seatsRemaining }
    var openSections: Int { stats.openSectionCount }
    var instructorSort: String { stats.instructorNames.first ?? "" }
    var campusSort: String { stats.campuses.sorted().joined(separator: ", ") }
    var meetingDaysSort: Int { Int(stats.meetingDays.rawValue) }
    var savedSortDate: Date { savedAt ?? .distantPast }

    /// `4` or `1–4`.
    var creditsText: String {
        guard let course else { return "–" }
        let low = CreditFormatter.number(course.minCredits)
        return course.minCredits == course.maxCredits ? low : "\(low)–\(CreditFormatter.number(course.maxCredits))"
    }
}

/// How a table of courses behaves where it is used.
enum MacCatalogCourseTableStyle {
    /// Search results and a subject's courses: Save toggles.
    case browse
    /// The saved list: the save action removes, and there is a column for when it was saved.
    case saved
}

/// How much room a table of courses has, as the columns that room is enough for. Each tier shows the
/// columns of the one before and more. A table adds about 17 points to each column and about 15 to
/// itself, and a column is only shown where its narrowest width fits: course, title and sections need
/// about 380 points, credits and seats make that 560, and every column after those needs 90 to 110 more.
enum MacCatalogColumnTier: Int, Comparable, Hashable {
    case minimal, compact, regular, roomy, wide, widest

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The tier of a table this wide.
    init(width: CGFloat) {
        switch width {
        case ..<560: self = .minimal
        case ..<700: self = .compact
        case ..<860: self = .regular
        case ..<1_000: self = .roomy
        case ..<1_150: self = .wide
        default: self = .widest
        }
    }
}

struct MacCatalogCourseTable: View, Equatable {
    var rows: [MacCatalogCourseRow]
    var termCode: String
    var style: MacCatalogCourseTableStyle = .browse
    /// Changes whenever `rows` is replaced, so typing doesn't make SwiftUI compare thousands of rows.
    var revision = 0
    /// Whether the table keeps a row selected, for a preview pane beside it that always has a course to
    /// show: the first row when nothing is selected (a new list, a new search, the selected row removed).
    var keepsSelection = false
    @Binding var selection: Set<CourseKey>
    @Binding var sortOrder: [KeyPathComparator<MacCatalogCourseRow>]
    /// Opens course windows for the courses (double-click, Return, the context menu).
    var onOpen: ([CourseKey]) -> Void
    /// Removes courses from the saved list (the `.saved` style's Delete key and menu item).
    var onRemove: (([CourseKey]) -> Void)?

    @AppStorage private var customization: TableColumnCustomization<MacCatalogCourseRow>
    @State private var newSchedule: MacCatalogNewScheduleRequest?

    init(
        rows: [MacCatalogCourseRow],
        termCode: String,
        style: MacCatalogCourseTableStyle = .browse,
        revision: Int = 0,
        keepsSelection: Bool = false,
        storageKey: String,
        selection: Binding<Set<CourseKey>>,
        sortOrder: Binding<[KeyPathComparator<MacCatalogCourseRow>]>,
        onOpen: @escaping ([CourseKey]) -> Void,
        onRemove: (([CourseKey]) -> Void)? = nil
    ) {
        self.rows = rows
        self.termCode = termCode
        self.style = style
        self.revision = revision
        self.keepsSelection = keepsSelection
        self._selection = selection
        self._sortOrder = sortOrder
        self.onOpen = onOpen
        self.onRemove = onRemove
        self._customization = AppStorage(wrappedValue: TableColumnCustomization<MacCatalogCourseRow>(), storageKey)
    }

    nonisolated static func == (lhs: MacCatalogCourseTable, rhs: MacCatalogCourseTable) -> Bool {
        lhs.revision == rhs.revision && lhs.termCode == rhs.termCode && lhs.style == rhs.style && lhs.keepsSelection == rhs.keepsSelection
    }

    private var sortedRows: [MacCatalogCourseRow] {
        sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    private var selectedRows: [MacCatalogCourseRow] {
        rows.filter { selection.contains($0.key) }
    }

    /// What decides whether the selection has to be looked at again.
    private struct KeepKey: Hashable {
        var revision: Int
        var keeps: Bool
        var isEmpty: Bool
    }

    var body: some View {
        MacCatalogAdaptiveTable(tierForWidth: { MacCatalogColumnTier(width: $0) }) { tier in
            table(tier: tier)
        }
        .task(id: KeepKey(revision: revision, keeps: keepsSelection, isEmpty: selection.isEmpty)) {
            keepSelection()
        }
    }

    /// While `keepsSelection` holds: only courses the list has stay selected, and when none is, the
    /// first one the table shows is.
    private func keepSelection() {
        guard keepsSelection else { return }
        let kept = selection.intersection(Set(rows.map(\.key)))
        if !kept.isEmpty {
            if kept != selection { selection = kept }
        } else if let first = sortedRows.first {
            selection = [first.key]
        }
    }

    private func table(tier: MacCatalogColumnTier) -> some View {
        let dropped = Self.optionalColumnIDs.filter { Self.firstTier(of: $0, style: style) > tier }
        return Table(
            sortedRows,
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
        .contextMenu(forSelectionType: CourseKey.self) { keys in
            if !keys.isEmpty {
                MacCatalogCourseMenu(
                    termCode: termCode,
                    rows: rows.filter { keys.contains($0.key) },
                    style: style,
                    newSchedule: $newSchedule,
                    onOpen: onOpen,
                    onRemove: onRemove
                )
            }
        } primaryAction: { keys in
            open(keys)
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            open(selection)
            return .handled
        }
        .onCopyCommand {
            let codes = selectedRows.map(\.key.description)
            return codes.isEmpty ? [] : [NSItemProvider(object: codes.joined(separator: "\n") as NSString)]
        }
        .catalogNewScheduleAlert($newSchedule)
    }

    /// The columns that are only shown when the table has room, in the order they come back.
    private static let optionalColumnIDs = ["credits", "seats", "saved", "nupath", "instructors", "campus", "days"]

    /// The narrowest tier that shows a column. The saved list has the date it was saved as a column of
    /// its own, which takes the room NUpath, instructors, campus and days would have had.
    private static func firstTier(of id: String, style: MacCatalogCourseTableStyle) -> MacCatalogColumnTier {
        switch id {
        case "credits", "seats": .compact
        case "saved": .regular
        case "nupath": style == .saved ? .roomy : .regular
        case "instructors": style == .saved ? .wide : .roomy
        case "campus", "days": style == .saved ? .widest : .wide
        default: .minimal
        }
    }

    /// Opens the courses in the order the table shows them; a handful at most, so one stray Return on
    /// a big selection doesn't bury the screen in windows.
    private func open(_ keys: Set<CourseKey>) {
        let ordered = sortedRows.map(\.key).filter { keys.contains($0) }
        onOpen(Array(ordered.prefix(8)))
    }

    // MARK: Columns

    @TableColumnBuilder<MacCatalogCourseRow, KeyPathComparator<MacCatalogCourseRow>>
    private var columns: some TableColumnContent<MacCatalogCourseRow, KeyPathComparator<MacCatalogCourseRow>> {
        TableColumn("Course", value: \.key) { row in
            MacCourseCodeCell(row: row, termCode: termCode, showsSaved: style != .saved)
                .draggable(row.key.description)
        }
        .width(min: 92, ideal: 104, max: 140)
        .customizationID("course")

        TableColumn("Title", value: \.title, comparator: .localizedStandard) { row in
            MacCourseTitleCell(row: row)
        }
        .width(min: 140, ideal: 200)
        .customizationID("title")

        TableColumn("Credits", value: \.minCredits) { row in
            Text(row.creditsText).monospacedDigit()
        }
        .width(min: 46, ideal: 56, max: 76)
        .alignment(.numeric)
        .customizationID("credits")

        TableColumn("Sections", value: \.openSections) { row in
            MacCourseAvailabilityLabel(stats: row.stats)
        }
        .width(min: 100, ideal: 124, max: 170)
        .customizationID("sections")

        TableColumn("Seats", value: \.openSeats) { row in
            MacSeatsCell(stats: row.stats)
        }
        .width(min: 84, ideal: 98, max: 130)
        .alignment(.numeric)
        .customizationID("seats")

        TableColumn("NUpath") { row in
            MacNUPathCell(course: row.course, hasHonors: row.stats.hasHonors)
        }
        .width(min: 70, ideal: 96, max: 190)
        .customizationID("nupath")

        TableColumn("Instructors", value: \.instructorSort, comparator: .localizedStandard) { row in
            Text(MacCatalogCourseTableText.instructors(row.stats.instructorNames))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .width(min: 90, ideal: 124)
        .customizationID("instructors")

        TableColumn("Campus", value: \.campusSort, comparator: .localizedStandard) { row in
            Text(row.campusSort).foregroundStyle(.secondary).lineLimit(1)
        }
        .width(min: 70, ideal: 100)
        .customizationID("campus")

        TableColumn("Days", value: \.meetingDaysSort) { row in
            Text(row.stats.meetingDays.compactLabel).monospacedDigit().foregroundStyle(.secondary)
        }
        .width(min: 54, ideal: 66, max: 90)
        .customizationID("days")

        if style == .saved {
            TableColumn("Saved", value: \.savedSortDate) { row in
                if let savedAt = row.savedAt {
                    Text(savedAt, format: .dateTime.month(.abbreviated).day().year())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100, max: 130)
            .customizationID("saved")
        }
    }
}

enum MacCatalogCourseTableText {
    /// `Jane Doe` or `Jane Doe +2`.
    static func instructors(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }
}

// MARK: - Cells

private struct MacCourseCodeCell: View {
    var row: MacCatalogCourseRow
    var termCode: String
    /// Whether to mark a saved course (not in the saved list itself, where every course is).
    var showsSaved = true

    /// Optional: a table builds a cell before it has handed it the window's environment, and a layout in
    /// that gap (the window being resized) must not find the store missing.
    @Environment(UserDataStore.self) private var userData: UserDataStore?

    var body: some View {
        HStack(spacing: 5) {
            Text(row.key.description)
                .fontWeight(.semibold)
                .monospacedDigit()
            if showsSaved, let userData, userData.isSaved(row.key, termCode: termCode) {
                Image(systemName: "bookmark.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .help("Saved")
                    .accessibilityLabel("Saved")
            }
        }
    }
}

private struct MacCourseTitleCell: View {
    var row: MacCatalogCourseRow

    var body: some View {
        if row.course == nil {
            Text("Not in this term's catalog")
                .foregroundStyle(.secondary)
        } else if let note = row.note {
            Text("\(row.title)\(Text("  \(note)").foregroundStyle(.secondary))")
                .lineLimit(1)
        } else {
            Text(row.title)
                .lineLimit(1)
        }
        if let caption = row.caption {
            CatalogCaption(text: caption)
                .lineLimit(2)
        }
    }
}

private struct MacNUPathCell: View {
    var course: Course?
    var hasHonors: Bool

    private static let limit = 3

    var body: some View {
        HStack(spacing: 3) {
            if let course {
                let nupaths = course.nupaths
                ForEach(nupaths.prefix(Self.limit)) { nupath in
                    // Compact tags: capsules as tall as the shared chips would make these rows taller.
                    Text(nupath.short)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.7), in: .capsule)
                        .help(nupath.name)
                        .accessibilityLabel("NUpath \(nupath.name)")
                }
                if nupaths.count > Self.limit {
                    Text("+\(nupaths.count - Self.limit)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(nupaths.dropFirst(Self.limit).map(\.name).joined(separator: "\n"))
                }
            }
            if hasHonors {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(.purple)
                    .help("Has an honors section")
                    .accessibilityLabel("Honors")
            }
        }
    }
}

private struct MacSeatsCell: View {
    var stats: CourseStats

    var body: some View {
        if stats.sectionCount == 0 {
            Text("–").foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 3) {
                Text("\(stats.seatsRemaining)")
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.seatColor(remaining: stats.seatsRemaining, capacity: stats.seatCapacity))
                Text("/ \(stats.seatCapacity)")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(stats.seatsRemaining) of \(stats.seatCapacity) seats open")
        }
    }
}

// MARK: - Context menu

/// The context menu of a course row, for the courses that are selected.
struct MacCatalogCourseMenu: View {
    var termCode: String
    var rows: [MacCatalogCourseRow]
    var style: MacCatalogCourseTableStyle
    @Binding var newSchedule: MacCatalogNewScheduleRequest?
    var onOpen: ([CourseKey]) -> Void
    var onRemove: (([CourseKey]) -> Void)?

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    private var keys: [CourseKey] { rows.map(\.key) }
    private var isSingle: Bool { rows.count == 1 }
    private var allSaved: Bool { keys.allSatisfy { userData.isSaved($0, termCode: termCode) } }

    var body: some View {
        Button(isSingle ? "Open in New Window" : "Open \(rows.count) Courses in New Windows", systemImage: "macwindow.badge.plus") {
            onOpen(keys)
        }
        Divider()
        switch style {
        case .saved:
            Button(isSingle ? "Remove from Saved" : "Remove \(rows.count) from Saved", systemImage: "bookmark.slash", role: .destructive) {
                onRemove?(keys)
            }
        case .browse:
            Button(allSaved ? "Unsave" : "Save", systemImage: allSaved ? "bookmark.slash" : "bookmark") {
                for key in keys where userData.isSaved(key, termCode: termCode) == allSaved {
                    userData.toggleSaved(key, termCode: termCode)
                }
            }
        }
        MacCatalogAddToScheduleMenu(
            termCode: termCode,
            additions: rows.filter { $0.course != nil }.map { MacCatalogScheduleAddition(key: $0.key, crn: nil) },
            newSchedule: $newSchedule
        )
        Divider()
        Button(isSingle ? "Copy Course Code" : "Copy Course Codes", systemImage: "doc.on.doc") {
            MacCatalogClipboard.copy(keys.map(\.description).joined(separator: "\n"))
        }
        if let key = keys.first, isSingle {
            if let link = CourseLinks.course(termCode: termCode, key: key) {
                Button("Copy Link", systemImage: "link") { MacCatalogClipboard.copy(link.absoluteString) }
            }
            instructorItems(for: key)
            Divider()
            Button("Show \(key.subject) Courses", systemImage: "square.grid.2x2") {
                MacCatalogNavigation.showSubject(key.subject, navigator: navigator, openWindow: openWindow)
            }
            if let url = BannerClient.catalogPageURL(term: termCode, course: key) {
                Button("View on Northeastern Website", systemImage: "safari") { openURL(url) }
            }
        }
    }

    /// "Open Professor ▸" with the course's instructors.
    @ViewBuilder
    private func instructorItems(for key: CourseKey) -> some View {
        let instructors = catalog.cachedIndex(for: termCode)?.macCatalogInstructors(key) ?? []
        if !instructors.isEmpty {
            Menu("Open Professor", systemImage: "person") {
                ForEach(instructors, id: \.name) { instructor in
                    Button(instructor.displayName) {
                        openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: instructor.name))
                    }
                }
            }
        }
    }
}
