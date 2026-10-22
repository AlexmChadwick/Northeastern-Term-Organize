//
//  SearchFilterBar.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The pinned row of Liquid Glass filter chips above the search results:
/// filters sheet, quick toggles, NUpath / subject / days / sort menus.
///
/// The two multi-select menus (NUpath, subject) keep a fixed title: they stay
/// open while toggles change, and a chip that resized under an open menu
/// would move its anchor. Their state shows through the chip tint and the
/// checkmarks in the menu. The days and sort menus close after a choice, so
/// their titles describe the current value.
struct SearchFilterBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: SearchModel
    /// True while nothing is being searched yet (the landing screen). A
    /// preferred-campus default that is the only filter then is not shown as
    /// an active filter: it would only add a "Filters · 1" badge and a Clear
    /// chip to a screen that has no results to filter.
    var isLanding: Bool
    /// Subjects with the most courses, offered directly in the subject menu.
    var popularSubjects: [Subject]
    /// Opens the filters sheet, optionally straight to a sub-screen. Also
    /// moves the sheet when it is already open.
    var openFilters: (SearchFiltersRequest.Target?) -> Void

    private var filters: SearchFilters { model.filters }
    private var activeCount: Int { isLanding ? 0 : filters.activeCount }
    private var hasActiveState: Bool { !isLanding && (!filters.isEmpty || model.sort != .relevance) }

    var body: some View {
        GlassChipBar {
            filtersChip
            DegreeLevelFilterPicker(filters: $model.filters)
                .frame(maxWidth: 260)
            openSeatsChip
            honorsChip
            noPrerequisitesChip
            noCorequisitesChip
            nupathMenu
            subjectMenu
            daysMenu
            sortMenu
            if hasActiveState {
                clearChip
            }
        }
        .animation(.browseSnappy(reduceMotion: reduceMotion), value: hasActiveState)
    }

    // MARK: Buttons

    private var filtersChip: some View {
        let count = activeCount
        return GlassChip(
            title: count > 0 ? "Filters · \(count)" : "Filters",
            systemImage: "line.3.horizontal.decrease",
            isOn: count > 0
        ) {
            openFilters(nil)
        }
        .accessibilityLabel(count > 0 ? "Filters, \(count) active" : "Filters")
        .accessibilityHint("Opens all search filters")
    }

    private var clearChip: some View {
        GlassChip(title: "Clear", systemImage: "xmark.circle.fill", isOn: false) {
            withAnimation(.browseSnappy(reduceMotion: reduceMotion)) {
                model.filters = SearchFilters()
                model.sort = .relevance
            }
        }
        .accessibilityLabel("Clear filters and sorting")
    }

    private var openSeatsChip: some View {
        GlassChip(title: "Open seats", systemImage: "chair", isOn: filters.openSeatsOnly) {
            model.filters.openSeatsOnly.toggle()
        }
    }

    private var honorsChip: some View {
        GlassChip(title: "Honors", systemImage: "star", isOn: filters.honorsOnly) {
            model.filters.honorsOnly.toggle()
        }
    }

    private var noPrerequisitesChip: some View {
        GlassChip(title: "No prerequisites", systemImage: "checklist", isOn: filters.noPrerequisites) {
            model.filters.noPrerequisites.toggle()
        }
        .accessibilityHint("Shows courses whose loaded catalog entry lists no prerequisites")
    }

    private var noCorequisitesChip: some View {
        GlassChip(title: "No corequisites", systemImage: "link", isOn: filters.noCorequisites) {
            model.filters.noCorequisites.toggle()
        }
        .accessibilityHint("Shows courses whose loaded catalog entry lists no corequisites")
    }

    // MARK: Menus

    private var nupathMenu: some View {
        let isOn = !filters.nupaths.isEmpty
        return Menu {
            Section("Match all selected") {
                ForEach(NUPath.allCases) { nupath in
                    Toggle(isOn: membership(\.nupaths, nupath)) {
                        Label("\(nupath.short) · \(nupath.name)", systemImage: nupath.symbol)
                    }
                    .menuActionDismissBehavior(.disabled)
                }
            }
            if isOn {
                Button("Clear NUpath", role: .destructive) {
                    model.filters.nupaths = []
                }
            }
        } label: {
            // Fixed title: this menu stays open while its toggles change.
            GlassChipLabel(title: "NUpath", systemImage: "graduationcap", isOn: isOn, showsChevron: true)
        }
        .glassChipStyle(isOn: isOn)
        .accessibilityLabel("NUpath")
        .accessibilityValue(isOn ? SearchFilterTitles.nupaths(filters.nupaths) : "Any")
    }

    private var subjectMenu: some View {
        let isOn = !filters.subjects.isEmpty
        let popularCodes = Set(popularSubjects.map(\.code))
        let extraSelected = filters.subjects.subtracting(popularCodes).sorted()
        return Menu {
            if !extraSelected.isEmpty {
                Section("Selected") {
                    ForEach(extraSelected, id: \.self) { code in
                        Toggle(isOn: membership(\.subjects, code)) {
                            Text(code)
                        }
                        .menuActionDismissBehavior(.disabled)
                    }
                }
            }
            Section("Popular subjects") {
                ForEach(popularSubjects) { subject in
                    Toggle(isOn: membership(\.subjects, subject.code)) {
                        Text("\(subject.code) · \(subject.name)")
                    }
                    .menuActionDismissBehavior(.disabled)
                }
            }
            Button {
                openFilters(.subjects)
            } label: {
                Label("All subjects…", systemImage: "list.bullet")
            }
        } label: {
            // Fixed title: this menu stays open while its toggles change.
            GlassChipLabel(title: "Subject", systemImage: "square.grid.2x2", isOn: isOn, showsChevron: true)
        }
        .glassChipStyle(isOn: isOn)
        .accessibilityLabel("Subject")
        .accessibilityValue(isOn ? filters.subjects.sorted().joined(separator: ", ") : "Any")
    }

    private var daysMenu: some View {
        let isOn = filters.allowedDays != nil
        return Menu {
            Picker("Meeting days", selection: dayPreset) {
                ForEach(SearchDayPreset.allCases) { preset in
                    Text(preset.menuTitle).tag(preset)
                }
            }
        } label: {
            GlassChipLabel(
                title: SearchFilterTitles.days(filters.allowedDays),
                systemImage: "calendar",
                isOn: isOn,
                showsChevron: true
            )
        }
        .glassChipStyle(isOn: isOn)
        .accessibilityLabel("Meeting days")
        .accessibilityValue(SearchFilterTitles.days(filters.allowedDays))
    }

    private var sortMenu: some View {
        let isOn = model.sort != .relevance
        return Menu {
            Picker("Sort by", selection: $model.sort) {
                ForEach(SearchSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.symbol).tag(sort)
                }
            }
        } label: {
            GlassChipLabel(
                title: isOn ? model.sort.label : "Sort",
                systemImage: "arrow.up.arrow.down",
                isOn: isOn,
                showsChevron: true
            )
        }
        .glassChipStyle(isOn: isOn)
        .accessibilityLabel("Sort by")
        .accessibilityValue(model.sort.label)
    }

    // MARK: Bindings

    /// A binding that adds / removes `element` in one of the filter sets.
    private func membership<Element: Hashable>(
        _ keyPath: WritableKeyPath<SearchFilters, Set<Element>>,
        _ element: Element
    ) -> Binding<Bool> {
        Binding(
            get: { model.filters[keyPath: keyPath].contains(element) },
            set: { isOn in
                if isOn {
                    model.filters[keyPath: keyPath].insert(element)
                } else {
                    model.filters[keyPath: keyPath].remove(element)
                }
            }
        )
    }

    /// The day preset in effect. A day set that matches no preset reads as
    /// "Custom…" (so the picker never holds an invalid selection); choosing
    /// that entry opens the sheet at the days section instead of changing anything.
    private var dayPreset: Binding<SearchDayPreset> {
        Binding(
            get: { SearchDayPreset.selection(for: model.filters.allowedDays) },
            set: { preset in
                if preset == .custom {
                    openFilters(.days)
                } else {
                    model.filters.allowedDays = preset.days
                }
            }
        )
    }
}
