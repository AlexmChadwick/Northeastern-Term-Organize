//
//  MacSearchFilterBar.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The row of filters above the search results: quick toggles, menus for NUpath, subject, level, days
/// and campus, and a popover with every filter. It edits `MacCatalogState.filters`, which the search
/// view reads, so results update as the filters change.
struct MacSearchFilterBar: View {
    @Bindable var state: MacCatalogState
    var index: CatalogIndex
    /// True while nothing is searched yet: a preferred-campus default that is the only filter then
    /// isn't shown as an active filter, since there are no results to filter.
    var isLanding: Bool

    @State private var showsAllFilters = false
    @State private var showsSubjectPicker = false
    @State private var popularSubjects: [Subject] = []

    private var filters: SearchFilters { state.filters }
    private var activeCount: Int { isLanding ? 0 : filters.activeCount }

    var body: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 6) {
            Toggle(isOn: $state.filters.openSeatsOnly) {
                Label("Open Seats", systemImage: "chair")
            }
            .toggleStyle(.button)
            .help("Show only courses with an open seat")

            Toggle(isOn: $state.filters.honorsOnly) {
                Label("Honors", systemImage: "star")
            }
            .toggleStyle(.button)
            .help("Show only courses with an honors section")

            nupathMenu
            subjectMenu
            levelMenu
            daysMenu
            if index.campusNames.count > 1 {
                campusMenu
            }
            allFiltersButton
            if !isLanding && !filters.isEmpty {
                Button {
                    state.filters = SearchFilters()
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .help("Remove every filter")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: index.term.code) {
            popularSubjects = index.popularSubjects()
        }
    }

    // MARK: Menus

    private var nupathMenu: some View {
        let isOn = !filters.nupaths.isEmpty
        return Menu {
            Section("Match All Selected") {
                ForEach(NUPath.allCases) { nupath in
                    Toggle(isOn: membership(\.nupaths, nupath)) {
                        Label("\(nupath.short) · \(nupath.name)", systemImage: nupath.symbol)
                    }
                }
            }
            if isOn {
                Divider()
                Button("Clear NUpath") { state.filters.nupaths = [] }
            }
        } label: {
            Text(isOn ? SearchFilterTitles.nupaths(filters.nupaths) : "NUpath")
        }
        .filterMenuStyle(isOn: isOn)
        .help("Show courses that satisfy NUpath requirements")
    }

    private var subjectMenu: some View {
        let isOn = !filters.subjects.isEmpty
        let popularCodes = Set(popularSubjects.map(\.code))
        let extraSelected = filters.subjects.subtracting(popularCodes).sorted()
        return Menu {
            if !extraSelected.isEmpty {
                Section("Selected") {
                    ForEach(extraSelected, id: \.self) { code in
                        Toggle(code, isOn: membership(\.subjects, code))
                    }
                }
            }
            Section("Popular Subjects") {
                ForEach(popularSubjects) { subject in
                    Toggle("\(subject.code) · \(subject.name)", isOn: membership(\.subjects, subject.code))
                }
            }
            Divider()
            Button("All Subjects…", systemImage: "list.bullet") { showsSubjectPicker = true }
            if isOn {
                Button("Clear Subjects") { state.filters.subjects = [] }
            }
        } label: {
            Text(SearchFilterTitles.subjects(filters.subjects))
        }
        .filterMenuStyle(isOn: isOn)
        .popover(isPresented: $showsSubjectPicker, arrowEdge: .bottom) {
            MacSubjectPicker(state: state, index: index)
        }
        .help("Show courses in certain subjects")
    }

    private var levelMenu: some View {
        let isOn = !filters.levels.isEmpty
        let levels = Array(Set(index.courses.compactMap { $0.key.level }).union(filters.levels)).sorted()
        return Menu {
            ForEach(levels, id: \.self) { level in
                Toggle(browseLevelTitle(level), isOn: membership(\.levels, level))
            }
            if isOn {
                Divider()
                Button("Clear Levels") { state.filters.levels = [] }
            }
        } label: {
            Text(isOn ? filters.levels.sorted().map(SearchFilterTitles.level).joined(separator: ", ") : "Level")
        }
        .filterMenuStyle(isOn: isOn)
        .help("Show courses at certain levels")
    }

    private var daysMenu: some View {
        let isOn = filters.allowedDays != nil
        return Menu {
            Picker("Meeting Days", selection: dayPreset) {
                ForEach(SearchDayPreset.allCases) { preset in
                    Text(preset.menuTitle).tag(preset)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(SearchFilterTitles.days(filters.allowedDays))
        }
        .filterMenuStyle(isOn: isOn)
        .help("Show sections that meet only on certain days")
    }

    private var campusMenu: some View {
        let isOn = !filters.campuses.isEmpty
        return Menu {
            ForEach(index.campusNames, id: \.self) { name in
                Toggle(name, isOn: membership(\.campuses, name))
            }
            if isOn {
                Divider()
                Button("Clear Campuses") { state.filters.campuses = [] }
            }
        } label: {
            Text(isOn ? filters.campuses.sorted().joined(separator: ", ") : "Campus")
        }
        .filterMenuStyle(isOn: isOn)
        .help("Show courses with a section at a campus")
    }

    private var allFiltersButton: some View {
        Button {
            showsAllFilters.toggle()
        } label: {
            Label(activeCount > 0 ? "Filters · \(activeCount)" : "More Filters…", systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.bordered)
        .tint(activeCount > 0 ? Color.accentColor : nil)
        .help("Credits, class type, time of day and every other filter")
        .popover(isPresented: $showsAllFilters, arrowEdge: .bottom) {
            MacSearchFiltersForm(state: state, index: index)
        }
    }

    // MARK: Bindings

    /// A binding that adds or removes `element` in one of the filter sets.
    private func membership<Element: Hashable>(
        _ keyPath: WritableKeyPath<SearchFilters, Set<Element>>,
        _ element: Element
    ) -> Binding<Bool> {
        Binding(
            get: { state.filters[keyPath: keyPath].contains(element) },
            set: { isOn in
                if isOn {
                    state.filters[keyPath: keyPath].insert(element)
                } else {
                    state.filters[keyPath: keyPath].remove(element)
                }
            }
        )
    }

    /// The day preset in effect. A day set that matches no preset reads as "Custom…", and choosing
    /// that opens the full filters at the days section.
    private var dayPreset: Binding<SearchDayPreset> {
        Binding(
            get: { SearchDayPreset.selection(for: state.filters.allowedDays) },
            set: { preset in
                if preset == .custom {
                    showsAllFilters = true
                } else {
                    state.filters.allowedDays = preset.days
                }
            }
        )
    }
}

private extension View {
    /// A pull-down button that is tinted while its filter is on.
    func filterMenuStyle(isOn: Bool) -> some View {
        self
            .menuStyle(.button)
            .menuIndicator(.visible)
            .buttonStyle(.bordered)
            .tint(isOn ? Color.accentColor : nil)
            .fixedSize()
    }
}
