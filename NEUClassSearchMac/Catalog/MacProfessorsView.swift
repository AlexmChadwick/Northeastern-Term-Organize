//
//  MacProfessorsView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Instructors of the selected term: a sortable, searchable table, with the selected instructor's page
/// beside it when the window has room. Double-click or Return opens an instructor's window.
struct MacProfessorsView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    @State private var query = ""
    @State private var entries: [ProfessorDirectoryEntry] = []
    @State private var builtFor: String?
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\ProfessorDirectoryEntry.id, comparator: .localizedStandard)]
    @AppStorage private var customization: TableColumnCustomization<ProfessorDirectoryEntry>
    private let preview = MacCatalogPreviewMode()

    init() {
        _customization = AppStorage(wrappedValue: TableColumnCustomization<ProfessorDirectoryEntry>(), "mac.catalog.professorColumns")
    }

    private var termCode: String { catalog.readyIndex?.term.code ?? "" }

    /// Changes whenever an index changes (a load, a sync or a live course refresh, which rebuilds the
    /// instructor directory), so the directory is rebuilt.
    private struct BuildID: Hashable {
        var termCode: String?
        var indexVersion: Int
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Entries matching every word of the query, in the table's order.
    private var shown: [ProfessorDirectoryEntry] {
        let tokens = ProfessorDirectoryEntry.fold(trimmedQuery).split(separator: " ").map(String.init)
        let matches = tokens.isEmpty ? entries : entries.filter { entry in tokens.allSatisfy { entry.searchText.contains($0) } }
        return matches.sorted(using: sortOrder)
    }

    var body: some View {
        MacCatalogGate { index in
            if builtFor != index.term.code {
                ProgressView("Loading professors…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No Instructors Yet",
                    systemImage: "person.2",
                    description: Text("Instructor names load as you open courses. Open a few courses, then come back.")
                )
            } else {
                directory(index: index)
            }
        }
        .navigationTitle("Professors")
        .navigationSubtitle(catalog.selectedTerm?.name ?? "")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Professors or Courses")
        .toolbar {
            if catalog.readyIndex != nil && !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open in New Window", systemImage: "macwindow.badge.plus") { open(selection) }
                        .disabled(selection.isEmpty)
                        .help("Open the selected professors in their own windows")
                }
                ToolbarItem(placement: .primaryAction) {
                    MacCatalogPreviewToggle(isShown: preview.binding(), subject: "professor")
                }
            }
        }
        .focusedSceneValue(\.macSidePane, preview.sidePane(available: !entries.isEmpty))
        .task(id: BuildID(termCode: catalog.readyIndex?.term.code, indexVersion: catalog.indexVersion)) {
            guard let index = catalog.readyIndex else { return }
            let build = Task.detached(priority: .userInitiated) {
                ProfessorDirectoryEntry.build(from: index)
            }
            let built = await withTaskCancellationHandler {
                await build.value
            } onCancel: {
                build.cancel()
            }
            // A newer build supersedes this one: never let an older result overwrite it.
            guard !Task.isCancelled else { return }
            entries = built
            builtFor = index.term.code
        }
        .catalogToastHost()
        #if DEBUG
        .task { MacCatalogSnapshotArguments.applyToProfessors(query: $query) }
        .task(id: builtFor) {
            // `-MacSnapshotSelectFirst YES`: the first professor, once the directory is built.
            guard MacSnapshot.isRequested, UserDefaults.standard.bool(forKey: "MacSnapshotSelectFirst"), builtFor != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if let first = shown.first { selection = [first.id] }
        }
        #endif
    }

    // MARK: Table

    /// What decides whether the selection has to be looked at again.
    private struct KeepKey: Hashable {
        var first: String?
        var count: Int
        var keeps: Bool
        var isEmpty: Bool
    }

    private func directory(index: CatalogIndex) -> some View {
        let rows = shown
        return MacSplitPane(
            storageKey: "mac.split.catalog.professors",
            paneEdge: .trailing,
            defaultShare: 0.5,
            paneMinWidth: 380,
            primaryMinWidth: 400,
            maxShare: 0.7,
            isPaneShown: preview.binding()
        ) {
            table(rows, index: index)
        } pane: {
            MacProfessorPreview(names: selection, index: index, termCode: index.term.code)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { preview.measure($0) }
        .task(id: KeepKey(first: rows.first?.id, count: rows.count, keeps: preview.isShown, isEmpty: selection.isEmpty)) {
            keepSelection(in: rows)
        }
    }

    /// While the preview pane is shown, a professor is selected for it to show: only ones the table has stay
    /// selected, and when none is, the first one it shows is.
    private func keepSelection(in rows: [ProfessorDirectoryEntry]) {
        guard preview.isShown else { return }
        let kept = selection.intersection(Set(rows.map(\.id)))
        if !kept.isEmpty {
            if kept != selection { selection = kept }
        } else if let first = rows.first {
            selection = [first.id]
        }
    }

    /// The columns a table of this width has room for: the email address needs 1000 points.
    private enum ColumnTier: Hashable {
        case regular, wide

        init(width: CGFloat) { self = width >= 1_000 ? .wide : .regular }
    }

    private func table(_ rows: [ProfessorDirectoryEntry], index: CatalogIndex) -> some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                MacCatalogAdaptiveTable(tierForWidth: { ColumnTier(width: $0) }) { tier in
                    professorsTable(rows, index: index, tier: tier)
                }
            }
            MacCatalogStatusBar(summary: summary(shown: rows.count), showsFreshness: false)
        }
    }

    private func professorsTable(_ rows: [ProfessorDirectoryEntry], index: CatalogIndex, tier: ColumnTier) -> some View {
        Table(
            of: ProfessorDirectoryEntry.self,
            selection: $selection,
            sortOrder: $sortOrder,
            columnCustomization: MacCatalogTableColumns.binding($customization, dropping: tier == .wide ? [] : ["email"])
        ) {
            columns(index: index)
        } rows: {
            ForEach(rows) { entry in
                TableRow(entry).draggable(entry.displayName)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { names in
            if !names.isEmpty {
                menu(for: names, index: index)
            }
        } primaryAction: { names in
            open(names)
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            open(selection)
            return .handled
        }
    }

    @TableColumnBuilder<ProfessorDirectoryEntry, KeyPathComparator<ProfessorDirectoryEntry>>
    private func columns(index: CatalogIndex) -> some TableColumnContent<ProfessorDirectoryEntry, KeyPathComparator<ProfessorDirectoryEntry>> {
        TableColumn("Name", value: \.id, comparator: .localizedStandard) { entry in
            HStack(spacing: 8) {
                ProfessorMonogram(name: entry.id, font: .caption2.weight(.semibold), diameter: 22)
                Text(entry.displayName)
                    .lineLimit(1)
            }
        }
        .width(min: 150, ideal: 240)
        .customizationID("name")

        TableColumn("Courses", value: \.courseSummary, comparator: .localizedStandard) { entry in
            Text(entry.courseSummary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .width(min: 110, ideal: 260)
        .customizationID("courses")

        TableColumn("Sections", value: \.sectionCount) { entry in
            Text(entry.sectionCount.formatted())
                .monospacedDigit()
        }
        .width(min: 60, ideal: 76, max: 100)
        .alignment(.numeric)
        .customizationID("sections")

        TableColumn("Email") { entry in
            Text(index.instructorsByName[entry.id]?.email ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .width(min: 120, ideal: 220)
        .customizationID("email")
    }

    @ViewBuilder
    private func menu(for names: Set<String>, index: CatalogIndex) -> some View {
        let ordered = shown.filter { names.contains($0.id) }
        let single = ordered.count == 1 ? ordered[0] : nil
        Button(ordered.count == 1 ? "Open in New Window" : "Open \(ordered.count) Professors in New Windows", systemImage: "macwindow.badge.plus") {
            open(names)
        }
        Divider()
        Button(ordered.count == 1 ? "Copy Name" : "Copy Names", systemImage: "doc.on.doc") {
            MacCatalogClipboard.copy(ordered.map(\.displayName).joined(separator: "\n"))
        }
        if let single {
            if let email = index.instructorsByName[single.id]?.email {
                Button("Copy Email Address", systemImage: "envelope") { MacCatalogClipboard.copy(email) }
            }
            Divider()
            Button("Search for \(single.displayName)", systemImage: "magnifyingglass") {
                MacCatalogNavigation.search(text: single.displayName, navigator: navigator, openWindow: openWindow)
            }
            if let url = ProfessorPage.rateMyProfessorsURL(for: single.displayName) {
                Button("Search on Rate My Professors", systemImage: "star.bubble") { openURL(url) }
            }
        }
    }

    private func summary(shown count: Int) -> String {
        var text = count == entries.count
            ? "\(entries.count.formatted()) professors"
            : "\(count.formatted()) of \(entries.count.formatted()) professors"
        if !selection.isEmpty { text += " · \(selection.count.formatted()) selected" }
        return text
    }

    /// Opens the instructors in the order the table shows them, a handful at most.
    private func open(_ names: Set<String>) {
        let ordered = shown.map(\.id).filter { names.contains($0) }
        for name in ordered.prefix(8) {
            openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: name))
        }
    }
}

/// The pane beside the professors table: the selected instructor's page.
struct MacProfessorPreview: View {
    /// The names (Banner's) selected in the table.
    var names: Set<String>
    var index: CatalogIndex
    var termCode: String

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Professor preview")
    }

    @ViewBuilder
    private var content: some View {
        if names.count == 1, let name = names.first, let summary = index.instructor(named: name) {
            MacProfessorContent(summary: summary, index: index, termCode: termCode, presentation: .pane)
                .id(name)
        } else if names.isEmpty {
            ContentUnavailableView(
                "No Professor Selected",
                systemImage: "person",
                description: Text("Select a professor to see what they teach this term. Double-click one to open their own window.")
            )
        } else {
            ContentUnavailableView(
                "\(names.count) Professors Selected",
                systemImage: "person.2",
                description: Text("Select a single professor to see their page here.")
            )
        }
    }
}
