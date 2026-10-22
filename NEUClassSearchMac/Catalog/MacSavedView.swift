//
//  MacSavedView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The courses the user saved for the selected term, newest first. Double-click opens a course
/// window, Delete removes it from the list. Courses the term's catalog doesn't list are shown too,
/// so they can be cleaned out.
struct MacSavedView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    @State private var state = MacCatalogState.shared
    @State private var query = ""
    @State private var selection: Set<CourseKey> = []
    @State private var newSchedule: MacCatalogNewScheduleRequest?
    private let preview = MacCatalogPreviewMode()

    private var termCode: String { catalog.selectedTermCode ?? "" }

    private func rows(index: CatalogIndex) -> [MacCatalogCourseRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = userData.savedCourses(in: index.term.code).map { item -> MacCatalogCourseRow in
            if let course = index.course(item.key) {
                return MacCatalogCourseRow(
                    course: course,
                    stats: index.stats(for: item.key),
                    caption: CPSNote.courseCaption(sections: index.sections(for: item.key)),
                    savedAt: item.savedAt
                )
            }
            return MacCatalogCourseRow(missing: item.key, savedAt: item.savedAt)
        }
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.key.description.localizedCaseInsensitiveContains(needle) || $0.title.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        MacCatalogGate { index in
            let allSaved = userData.savedCourses(in: index.term.code)
            let rows = rows(index: index)
            // The selected course's page beside the list, when the window has room (or when asked).
            MacSplitPane(
                storageKey: "mac.split.catalog.saved",
                paneEdge: .trailing,
                defaultShare: 0.4,
                paneMinWidth: 340,
                primaryMinWidth: 420,
                maxShare: 0.7,
                isPaneShown: preview.binding(available: !allSaved.isEmpty)
            ) {
                VStack(spacing: 0) {
                    if allSaved.isEmpty {
                        ContentUnavailableView {
                            Label("No Saved Courses", systemImage: "bookmark")
                        } description: {
                            Text("Save a course with the bookmark button in its window, or choose Save from a course's context menu. The courses you save for \(index.term.name) appear here.")
                        }
                    } else if rows.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        MacCatalogCourseTable(
                            rows: rows,
                            termCode: index.term.code,
                            style: .saved,
                            revision: Self.fingerprint(rows, termCode: index.term.code, index: index),
                            keepsSelection: preview.isShown,
                            storageKey: "mac.catalog.savedColumns",
                            selection: $selection,
                            sortOrder: $state.savedSort,
                            onOpen: open,
                            onRemove: remove
                        )
                        .equatable()
                        .onDeleteCommand { remove(Array(selection)) }
                    }
                    MacCatalogStatusBar(summary: summary(rows: rows, total: allSaved.count))
                }
            } pane: {
                MacCatalogCoursePreview(selection: selection, termCode: index.term.code)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { preview.measure($0) }
        }
        .navigationTitle("Saved")
        .navigationSubtitle(catalog.selectedTerm?.name ?? "")
        .searchable(text: $query, placement: .toolbar, prompt: "Filter Saved Courses")
        .toolbar {
            if catalog.readyIndex != nil {
                MacCatalogSelectionToolbar(
                    stores: MacCatalogStores(catalog: catalog, userData: userData, navigator: navigator),
                    termCode: termCode,
                    selection: selection,
                    newSchedule: $newSchedule,
                    style: .saved,
                    onOpen: open,
                    onRemove: remove
                )
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    MacCatalogPreviewToggle(isShown: preview.binding())
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Update Seats", systemImage: "arrow.clockwise") { catalog.syncSelectedTerm() }
                        .disabled(catalog.isSyncing)
                        .help("Download the latest seat counts for \(catalog.selectedTerm?.name ?? "this term")")
                }
            }
        }
        .focusedSceneValue(\.macDelete, selection.isEmpty ? nil : MacMenuAction(title: selection.count == 1 ? "Remove from Saved" : "Remove \(selection.count) from Saved") {
            remove(Array(selection))
        })
        .focusedSceneValue(\.macReload, catalog.readyIndex != nil && !catalog.isSyncing ? MacMenuAction(title: "Update Seat Counts") { catalog.syncSelectedTerm() } : nil)
        .focusedSceneValue(\.macSidePane, preview.sidePane(available: !userData.savedCourses(in: termCode).isEmpty))
        .catalogNewScheduleAlert($newSchedule)
        .catalogToastHost()
        #if DEBUG
        .task { MacCatalogSnapshotArguments.applyToSaved(select: { key in selection = [key] }, termCode: termCode, userData: userData) }
        #endif
    }

    private static func fingerprint(_ rows: [MacCatalogCourseRow], termCode: String, index: CatalogIndex) -> Int {
        var hasher = Hasher()
        hasher.combine(termCode)
        hasher.combine(index.catalog.sectionsUpdatedAt)
        for row in rows {
            hasher.combine(row.key)
            hasher.combine(row.savedAt)
            hasher.combine(row.stats.seatsRemaining)
            hasher.combine(row.stats.openSectionCount)
            hasher.combine(row.caption)
        }
        return hasher.finalize()
    }

    private func summary(rows: [MacCatalogCourseRow], total: Int) -> String {
        var text = total == 1 ? "1 saved course" : "\(total.formatted()) saved courses"
        if rows.count != total { text = "\(rows.count.formatted()) of \(text)" }
        let open = rows.filter { $0.openSections > 0 }.count
        if open > 0 { text += " · \(open.formatted()) with open seats" }
        if !selection.isEmpty { text += " · \(selection.count.formatted()) selected" }
        return text
    }

    private func open(_ keys: [CourseKey]) {
        for key in keys {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
        }
    }

    private func remove(_ keys: [CourseKey]) {
        for key in keys where userData.isSaved(key, termCode: termCode) {
            userData.toggleSaved(key, termCode: termCode)
        }
        selection.subtract(keys)
    }
}
