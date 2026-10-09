//
//  MacCatalogCourseListPane.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  A filterable table of courses with a count underneath, used by the subject and NUpath lists, and
//  the toolbar items that act on the courses selected in a course table.
//

import SwiftUI

/// The toolbar items for the courses selected in a table: open, save, add to a schedule. (And, in the
/// saved list, remove.)
struct MacCatalogSelectionToolbar: ToolbarContent {
    var stores: MacCatalogStores
    var termCode: String
    var selection: Set<CourseKey>
    @Binding var newSchedule: MacCatalogNewScheduleRequest?
    var style: MacCatalogCourseTableStyle = .browse
    var onOpen: ([CourseKey]) -> Void
    var onRemove: (([CourseKey]) -> Void)?

    private var userData: UserDataStore { stores.userData }
    private var keys: [CourseKey] { selection.sorted() }
    private var allSaved: Bool { !selection.isEmpty && selection.allSatisfy { userData.isSaved($0, termCode: termCode) } }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { onOpen(keys) }
                .disabled(selection.isEmpty)
                .help("Open the selected courses in their own windows")
            switch style {
            case .saved:
                Button("Remove from Saved", systemImage: "bookmark.slash") { onRemove?(keys) }
                    .disabled(selection.isEmpty)
                    .help("Remove the selected courses from your saved courses")
            case .browse:
                Button(allSaved ? "Unsave" : "Save", systemImage: allSaved ? "bookmark.fill" : "bookmark") {
                    for key in keys where userData.isSaved(key, termCode: termCode) == allSaved {
                        userData.toggleSaved(key, termCode: termCode)
                    }
                }
                .disabled(selection.isEmpty)
                .help(allSaved ? "Remove the selected courses from your saved courses" : "Save the selected courses")
            }
            MacCatalogAddToScheduleMenu(
                termCode: termCode,
                additions: keys.map { MacCatalogScheduleAddition(key: $0, crn: nil) },
                newSchedule: $newSchedule
            ) {
                Label("Add to Schedule", systemImage: "calendar.badge.plus")
            }
            .macCatalogStores(stores)
            .help("Add the selected courses to a schedule")
        }
    }
}

/// Courses of one subject or NUpath in a table, with an "open seats" toggle and a level or subject
/// filter above it and counts below.
struct MacCatalogCourseListPane: View {
    enum Narrowing {
        /// Filter by course level (1000-level…): a subject's courses.
        case level(Binding<Int?>)
        /// Filter by subject: the courses of an NUpath.
        case subject(Binding<String?>)
    }

    var courses: [Course]
    var index: CatalogIndex
    var narrowing: Narrowing
    /// Whether the table keeps a row selected, for a preview pane beside it.
    var keepsSelection = false
    @Binding var openOnly: Bool
    @Binding var selection: Set<CourseKey>
    @Binding var sortOrder: [KeyPathComparator<MacCatalogCourseRow>]
    /// What the empty list says when the term has no courses here at all.
    var emptyTitle: String
    var emptyDescription: String
    var storageKey: String
    var onOpen: ([CourseKey]) -> Void

    private var termCode: String { index.term.code }

    private var shown: [Course] {
        courses.filter { course in
            switch narrowing {
            case .level(let level):
                if let level = level.wrappedValue, course.key.level != level { return false }
            case .subject(let subject):
                if let subject = subject.wrappedValue, course.subject != subject { return false }
            }
            if openOnly, index.stats(for: course.key).openSectionCount == 0 { return false }
            return true
        }
    }

    var body: some View {
        let shown = self.shown
        let rows = shown.map { MacCatalogCourseRow(course: $0, stats: index.stats(for: $0.key)) }
        VStack(spacing: 0) {
            if !courses.isEmpty {
                filterBar
                Divider()
            }
            if courses.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyDescription))
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Courses", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(noMatchesMessage)
                } actions: {
                    Button("Clear Filters", action: clearFilters)
                }
            } else {
                MacCatalogCourseTable(
                    rows: rows,
                    termCode: termCode,
                    revision: Self.fingerprint(of: rows, termCode: termCode, index: index),
                    keepsSelection: keepsSelection,
                    storageKey: storageKey,
                    selection: $selection,
                    sortOrder: $sortOrder,
                    onOpen: onOpen
                )
                .equatable()
            }
            MacCatalogStatusBar(summary: summary(shown: rows))
        }
    }

    /// A number that changes when the courses shown or their seat counts do, so the table's equality
    /// check notices (and nothing else).
    private static func fingerprint(of rows: [MacCatalogCourseRow], termCode: String, index: CatalogIndex) -> Int {
        var hasher = Hasher()
        hasher.combine(termCode)
        hasher.combine(index.catalog.sectionsUpdatedAt)
        for row in rows {
            hasher.combine(row.key)
            hasher.combine(row.stats.seatsRemaining)
            hasher.combine(row.stats.openSectionCount)
        }
        return hasher.finalize()
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $openOnly) {
                Label("Open Seats", systemImage: "chair")
            }
            .toggleStyle(.button)
            .help("Show only courses with an open seat")
            switch narrowing {
            case .level(let level):
                levelMenu(level)
            case .subject(let subject):
                subjectMenu(subject)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func levelMenu(_ level: Binding<Int?>) -> some View {
        let levels = Array(Set(courses.compactMap { $0.key.level })).sorted()
        return Group {
            if levels.count > 1 || level.wrappedValue != nil {
                Menu {
                    Picker("Level", selection: level) {
                        Text("All Levels").tag(Int?.none)
                        ForEach(levels, id: \.self) { value in
                            Text(browseLevelTitle(value)).tag(Int?.some(value))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(level.wrappedValue.map(browseLevelTitle) ?? "Level")
                }
                .menuStyle(.button)
                .menuIndicator(.visible)
                .tint(level.wrappedValue != nil ? Color.accentColor : nil)
                .fixedSize()
                .help("Show one level of course")
            }
        }
    }

    private func subjectMenu(_ subject: Binding<String?>) -> some View {
        let counts = Dictionary(grouping: courses, by: \.subject).mapValues(\.count)
        let codes = counts.keys.sorted()
        return Group {
            if codes.count > 1 || subject.wrappedValue != nil {
                Menu {
                    Picker("Subject", selection: subject) {
                        Text("All Subjects").tag(String?.none)
                        ForEach(codes, id: \.self) { code in
                            Text("\(subjectTitle(code)) (\(counts[code] ?? 0))").tag(String?.some(code))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(subject.wrappedValue ?? "Subject")
                }
                .menuStyle(.button)
                .menuIndicator(.visible)
                .tint(subject.wrappedValue != nil ? Color.accentColor : nil)
                .fixedSize()
                .help("Show one subject")
            }
        }
    }

    private func subjectTitle(_ code: String) -> String {
        if let name = index.subjectName(code), name != code { return "\(code) · \(name)" }
        return code
    }

    private func clearFilters() {
        openOnly = false
        switch narrowing {
        case .level(let level): level.wrappedValue = nil
        case .subject(let subject): subject.wrappedValue = nil
        }
    }

    /// Names the filters that are actually hiding every course.
    private var noMatchesMessage: String {
        switch narrowing {
        case .level(let level):
            switch (level.wrappedValue, openOnly) {
            case let (level?, true): "No \(browseLevelNoun(level)) have open seats right now."
            case (nil, true): "None of these courses have open seats right now."
            case let (level?, false): "This subject has no \(browseLevelNoun(level))."
            case (nil, false): "No courses match these filters."
            }
        case .subject(let subject):
            switch (subject.wrappedValue, openOnly) {
            case let (subject?, true): "No \(subject) courses here have open seats right now."
            case (nil, true): "None of these courses have open seats right now."
            case let (subject?, false): "No \(subject) courses count toward this."
            case (nil, false): "No courses match these filters."
            }
        }
    }

    private func summary(shown rows: [MacCatalogCourseRow]) -> String {
        var text = browseSummaryText(
            shown: rows.count,
            total: courses.count,
            open: rows.filter { $0.openSections > 0 }.count,
            openOnly: openOnly
        )
        if !selection.isEmpty { text += " · \(selection.count.formatted()) selected" }
        return text
    }
}
