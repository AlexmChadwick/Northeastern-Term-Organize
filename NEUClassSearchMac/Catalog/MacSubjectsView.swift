//
//  MacSubjectsView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Subjects of the selected term and their courses: a list of subjects (or NUpath attributes) on the
/// left, and the courses of the one chosen in a table on the right.
struct MacSubjectsView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    @State private var state = MacCatalogState.shared
    @State private var query = ""
    @State private var selection: Set<CourseKey> = []
    @State private var newSchedule: MacCatalogNewScheduleRequest?
    private let preview = MacCatalogPreviewMode()

    private var termCode: String { catalog.readyIndex?.term.code ?? "" }

    /// The least width of the subjects list, and of the courses beside it.
    private static let listMinWidth: CGFloat = 180
    private static let coursesMinWidth: CGFloat = 380

    /// Whether a subject (or NUpath attribute) is chosen, so there are courses to preview.
    private var hasCourses: Bool {
        state.subjectsMode == .subjects ? state.selectedSubject != nil : state.selectedNUPath != nil
    }

    var body: some View {
        MacCatalogGate { index in
            // Three columns when there is room: the subjects, their courses, and the chosen course's page.
            MacSplitPane(
                storageKey: "mac.split.catalog.subjectsList",
                paneEdge: .leading,
                defaultShare: 0.2,
                paneMinWidth: Self.listMinWidth,
                primaryMinWidth: Self.coursesMinWidth,
                maxShare: 0.4
            ) {
                MacSplitPane(
                    storageKey: "mac.split.catalog.subjects",
                    paneEdge: .trailing,
                    defaultShare: 0.4,
                    paneMinWidth: 340,
                    primaryMinWidth: Self.coursesMinWidth,
                    maxShare: 0.7,
                    isPaneShown: preview.binding(available: hasCourses)
                ) {
                    detail(index: index)
                } pane: {
                    MacCatalogCoursePreview(selection: selection, termCode: index.term.code)
                }
            } pane: {
                MacSubjectsSidebar(state: state, index: index, query: query)
            }
            // The subjects list can't be closed, so it never floats over the courses: the window gets
            // no narrower than the list and a table's worth of courses side by side.
            .frame(minWidth: Self.listMinWidth + Self.coursesMinWidth + MacSplitDivider.grip)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { preview.measure($0) }
        }
        .navigationTitle(state.subjectsMode == .subjects ? "Subjects" : "NUpath")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: state.subjectsMode == .subjects ? "Filter Subjects" : "Filter NUpath")
        .toolbar {
            if catalog.readyIndex != nil {
                MacCatalogSelectionToolbar(
                    stores: MacCatalogStores(catalog: catalog, userData: userData, navigator: navigator),
                    termCode: termCode,
                    selection: selection,
                    newSchedule: $newSchedule,
                    onOpen: open
                )
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button("Search This Subject", systemImage: "magnifyingglass") { searchSubject() }
                        .disabled(state.subjectsMode != .subjects || state.selectedSubject == nil)
                        .help("Search the catalog with this subject as a filter")
                }
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
        .onChange(of: state.selectedSubject) { selection = [] }
        .onChange(of: state.selectedNUPath) { selection = [] }
        .onChange(of: state.subjectsMode) { selection = [] }
        .task(id: DefaultKey(termCode: termCode, mode: state.subjectsMode)) { chooseDefault() }
        .focusedSceneValue(\.macReload, catalog.readyIndex != nil && !catalog.isSyncing ? MacMenuAction(title: "Update Seat Counts") { catalog.syncSelectedTerm() } : nil)
        .focusedSceneValue(\.macSidePane, preview.sidePane(available: hasCourses))
        .catalogNewScheduleAlert($newSchedule)
        .catalogToastHost()
        #if DEBUG
        .task {
            MacCatalogSnapshotArguments.applyToSubjects(state: state)
            // `-MacSnapshotSelectFirst YES`: the first course of what is chosen, once the choice has settled.
            guard MacSnapshot.isRequested, UserDefaults.standard.bool(forKey: "MacSnapshotSelectFirst") else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard let index = catalog.readyIndex else { return }
            let courses = state.subjectsMode == .subjects
                ? index.courses(inSubject: state.selectedSubject ?? "")
                : (state.selectedNUPath.map { index.courses(with: $0) } ?? [])
            if let first = courses.map(\.key).sorted().first { selection = [first] }
        }
        #endif
    }

    /// What decides whether a subject has to be chosen for the student.
    private struct DefaultKey: Hashable {
        var termCode: String
        var mode: MacCatalogState.SubjectsMode
    }

    /// Something is always chosen, so the courses are never an empty page: the busiest subject (or the first
    /// NUpath attribute) until the student picks another, and when the one chosen isn't taught this term.
    private func chooseDefault() {
        guard let index = catalog.readyIndex else { return }
        switch state.subjectsMode {
        case .subjects:
            if let code = state.selectedSubject, index.courseCountBySubject[code, default: 0] > 0 { return }
            state.selectedSubject = index.popularSubjects(limit: 1).first?.code
        case .nupath:
            if state.selectedNUPath == nil { state.selectedNUPath = NUPath.allCases.first }
        }
    }

    private var subtitle: String {
        guard let index = catalog.readyIndex else { return catalog.selectedTerm?.name ?? "" }
        switch state.subjectsMode {
        case .subjects:
            if let code = state.selectedSubject, let name = index.subjectName(code) { return "\(name) · \(index.term.name)" }
        case .nupath:
            if let nupath = state.selectedNUPath { return "\(nupath.name) · \(index.term.name)" }
        }
        return index.term.name
    }

    @ViewBuilder
    private func detail(index: CatalogIndex) -> some View {
        switch state.subjectsMode {
        case .subjects:
            if let code = state.selectedSubject {
                MacCatalogCourseListPane(
                    courses: index.courses(inSubject: code),
                    index: index,
                    narrowing: .level($state.subjectLevel),
                    keepsSelection: preview.isShown,
                    openOnly: $state.subjectOpenOnly,
                    selection: $selection,
                    sortOrder: $state.courseListSort,
                    emptyTitle: "No Courses",
                    emptyDescription: "\(index.subjectName(code) ?? code) has no courses in \(index.term.name).",
                    storageKey: "mac.catalog.subjectColumns",
                    onOpen: open
                )
                .id(code)
            } else {
                ContentUnavailableView("Choose a Subject", systemImage: "square.grid.2x2", description: Text("Pick a subject on the left to see its courses."))
            }
        case .nupath:
            if let nupath = state.selectedNUPath {
                MacCatalogCourseListPane(
                    courses: index.courses(with: nupath),
                    index: index,
                    narrowing: .subject($state.nupathSubject),
                    keepsSelection: preview.isShown,
                    openOnly: $state.subjectOpenOnly,
                    selection: $selection,
                    sortOrder: $state.courseListSort,
                    emptyTitle: "No Courses",
                    emptyDescription: "No courses in \(index.term.name) carry \(nupath.name).",
                    storageKey: "mac.catalog.nupathColumns",
                    onOpen: open
                )
                .id(nupath)
            } else {
                ContentUnavailableView("Choose an NUpath", systemImage: "graduationcap", description: Text("NUpath is Northeastern's general education framework. Pick an attribute on the left to see which courses count toward it this term."))
            }
        }
    }

    private func open(_ keys: [CourseKey]) {
        for key in keys {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
        }
    }

    private func searchSubject() {
        guard let code = state.selectedSubject else { return }
        var filters = SearchFilters()
        filters.subjects = [code]
        MacCatalogNavigation.search(filters: filters, navigator: navigator, openWindow: openWindow)
    }
}

// MARK: - Sidebar

/// The left list: subjects by letter, or the NUpath attributes, with a switch between them above.
private struct MacSubjectsSidebar: View {
    @Bindable var state: MacCatalogState
    var index: CatalogIndex
    var query: String

    var body: some View {
        VStack(spacing: 0) {
            Picker("Browse", selection: $state.subjectsMode) {
                ForEach(MacCatalogState.SubjectsMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch state.subjectsMode {
            case .subjects:
                MacSubjectList(state: state, index: index, query: query)
            case .nupath:
                MacNUPathList(state: state, index: index, query: query)
            }
        }
    }
}

private struct MacSubjectList: View {
    @Bindable var state: MacCatalogState
    var index: CatalogIndex
    var query: String

    private struct LetterSection: Identifiable {
        var letter: String
        var subjects: [Subject]
        var id: String { letter }
    }

    private var sections: [LetterSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjects = needle.isEmpty ? index.activeSubjects : index.activeSubjects.filter {
            $0.code.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
        }
        let grouped = Dictionary(grouping: subjects) { String($0.code.prefix(1)).uppercased() }
        return grouped.keys.sorted().map { LetterSection(letter: $0, subjects: grouped[$0] ?? []) }
    }

    var body: some View {
        let sections = self.sections
        ScrollViewReader { proxy in
            List(selection: $state.selectedSubject) {
                ForEach(sections) { section in
                    Section(section.letter) {
                        ForEach(section.subjects) { subject in
                            MacSubjectRow(subject: subject, count: index.courseCountBySubject[subject.code] ?? 0)
                                .tag(subject.code)
                                .id(subject.code)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .task(id: index.term.code) {
                // Coming back to the area: show the subject that was chosen, in the middle of the list.
                guard let code = state.selectedSubject else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                proxy.scrollTo(code, anchor: .center)
            }
            .onChange(of: state.selectedSubject) { _, code in
                // Sent here by another window: scroll only as far as it takes, so that a click on a
                // row that is showing moves nothing.
                guard let code else { return }
                withAnimation { proxy.scrollTo(code) }
            }
        }
    }
}

private struct MacSubjectRow: View {
    var subject: Subject
    var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(subject.code)
                .fontWeight(.semibold)
                .frame(width: 54, alignment: .leading)
            Text(subject.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count.formatted())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subject.name), \(subject.code)")
        .accessibilityValue(CourseFormat.count(count, "course"))
    }
}

private struct MacNUPathList: View {
    @Bindable var state: MacCatalogState
    var index: CatalogIndex
    var query: String

    /// Courses per NUpath, counted in one pass over the catalog.
    private var counts: [NUPath: Int] {
        var result: [NUPath: Int] = [:]
        for course in index.courses {
            for nupath in NUPath.allCases where course.attributes.contains(nupath.attributeCode) {
                result[nupath, default: 0] += 1
            }
        }
        return result
    }

    private var attributes: [NUPath] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return NUPath.allCases }
        return NUPath.allCases.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.short.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        let counts = self.counts
        let attributes = self.attributes
        List(selection: $state.selectedNUPath) {
            ForEach(attributes) { nupath in
                MacNUPathRow(nupath: nupath, count: counts[nupath] ?? 0)
                    .tag(nupath)
            }
        }
        .listStyle(.inset)
        .overlay {
            if attributes.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct MacNUPathRow: View {
    var nupath: NUPath
    var count: Int

    private var tint: Color {
        CourseColor.at(NUPath.allCases.firstIndex(of: nupath) ?? 0).base
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: nupath.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint.gradient, in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(nupath.name)
                    .lineLimit(1)
                Text(nupath.short)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(count.formatted())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nupath.name), \(nupath.short)")
        .accessibilityValue(CourseFormat.count(count, "course"))
    }
}
