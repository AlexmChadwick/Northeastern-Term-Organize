//
//  SearchFiltersSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Screens that can be pushed inside the filters sheet.
enum SearchFilterRoute: Hashable {
    case subjects
}

/// Asks the filters sheet to show something: when it is first presented or,
/// because the results behind it stay interactive at the medium detent, while
/// it is already up and a chip in the bar behind it is tapped.
struct SearchFiltersRequest: Equatable {
    enum Target: Hashable {
        /// The multi-select subject list.
        case subjects
        /// The "Meeting days" section.
        case days
    }

    var target: Target?
    /// Changes with every request, so asking for the same target twice still
    /// registers as a change.
    var token = 0
}

/// Scroll anchors inside the form.
private enum SearchFilterAnchor: Hashable {
    case days
}

/// Every search filter in one sheet. Edits apply live to `SearchModel.filters`,
/// and at the medium detent the results behind the sheet stay interactive so
/// the effect of each change is visible immediately.
struct SearchFiltersSheet: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(SearchModel.self) private var searchModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Number of courses matching the current filters, shown as the subtitle.
    var resultCount: Int?
    var request: SearchFiltersRequest

    @State private var path: [SearchFilterRoute]
    @State private var detent: PresentationDetent
    @State private var availableLevels: [Int] = []
    @ScaledMetric(relativeTo: .body) private var levelChipMinimum: CGFloat = 76
    @ScaledMetric(relativeTo: .body) private var dayChipMinimum: CGFloat = 56

    init(resultCount: Int? = nil, request: SearchFiltersRequest = SearchFiltersRequest()) {
        self.resultCount = resultCount
        self.request = request
        _path = State(initialValue: request.target == .subjects ? [.subjects] : [])
        _detent = State(initialValue: request.target == nil ? .medium : .large)
    }

    private var filters: SearchFilters { searchModel.filters }
    private var index: CatalogIndex? { catalog.readyIndex }

    private static let creditChoices: [Double] = [0, 1, 2, 3, 4, 5, 6, 8]
    /// Monday first, as students think of the week.
    private static let dayOrder = [1, 2, 3, 4, 5, 6, 0]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                Form {
                    quickSection
                    subjectsSection
                    levelSection
                    nupathSection
                    creditsSection
                    campusSection
                    classTypeSection
                    instructionSection
                    daysSection
                    timeSection
                }
                .navigationTitle("Filters")
                .navigationSubtitle(subtitle)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: SearchFilterRoute.self) { route in
                    switch route {
                    case .subjects:
                        SearchSubjectPicker()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset", role: .destructive) {
                            withAnimation(.browseSnappy(reduceMotion: reduceMotion)) { searchModel.filters = SearchFilters() }
                        }
                        .disabled(filters.isEmpty)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .task {
                    // Presented straight to the days section.
                    if request.target == .days { scrollToDaysSoon(proxy) }
                }
                .onChange(of: request) { _, newRequest in
                    show(newRequest, proxy: proxy)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .onChange(of: path) { _, newPath in
            // The subject list needs room, so opening it expands the sheet.
            if !newPath.isEmpty { detent = .large }
        }
        .task(id: index?.term.code) {
            guard let index else { availableLevels = []; return }
            availableLevels = Array(Set(index.courses.compactMap { $0.key.level })).sorted()
        }
    }

    private var subtitle: String {
        guard let resultCount else { return "" }
        return resultCount == 1 ? "1 course" : "\(resultCount.formatted()) courses"
    }

    /// Moves a sheet that is already open to what a chip behind it asked for.
    private func show(_ request: SearchFiltersRequest, proxy: ScrollViewProxy) {
        switch request.target {
        case .subjects:
            detent = .large
            path = [.subjects]
        case .days:
            detent = .large
            path = []
            scrollToDaysSoon(proxy)
        case nil:
            path = []
        }
    }

    /// Scrolls to the days section once the sheet has finished resizing.
    private func scrollToDaysSoon(_ proxy: ScrollViewProxy) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            proxy.scrollTo(SearchFilterAnchor.days, anchor: .top)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var quickSection: some View {
        Section {
            Toggle("Open seats only", isOn: filter(\.openSeatsOnly))
            Toggle("Honors only", isOn: filter(\.honorsOnly))
        }
        Section {
            Toggle("No prerequisites", isOn: filter(\.noPrerequisites))
            Toggle("No corequisites", isOn: filter(\.noCorequisites))
        } footer: {
            Text("A course matches only when its catalog details were loaded and list none. A course whose requisites have not been loaded yet is left out.")
        }
    }

    private var subjectsSection: some View {
        Section {
            NavigationLink(value: SearchFilterRoute.subjects) {
                LabeledContent("Subjects") {
                    Text(subjectSummary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var subjectSummary: String {
        let codes = filters.subjects.sorted()
        switch codes.count {
        case 0: return "Any"
        case 1, 2, 3: return codes.joined(separator: ", ")
        default: return "\(codes.prefix(2).joined(separator: ", ")) +\(codes.count - 2)"
        }
    }

    private var levelChoices: [Int] {
        let base = availableLevels.isEmpty ? Array(1...9) : availableLevels
        return Array(Set(base).union(filters.levels)).sorted()
    }

    private var levelSection: some View {
        Section("Course level") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: levelChipMinimum), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
                ForEach(levelChoices, id: \.self) { level in
                    SearchToggleChip(title: SearchFilterTitles.level(level), isOn: filters.levels.contains(level)) {
                        if filters.levels.contains(level) {
                            searchModel.filters.levels.remove(level)
                        } else {
                            searchModel.filters.levels.insert(level)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private var nupathSection: some View {
        Section {
            ForEach(NUPath.allCases) { nupath in
                Toggle(isOn: membership(\.nupaths, nupath)) {
                    Label {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(nupath.name)
                            Text(nupath.short)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: nupath.symbol)
                    }
                }
            }
        } header: {
            Text("NUpath")
        } footer: {
            Text("Shows courses that satisfy every selected NUpath.")
        }
    }

    private var creditsSection: some View {
        Section {
            Picker("Minimum", selection: minCredits) {
                Text("Any").tag(Double?.none)
                ForEach(Self.creditChoices, id: \.self) { value in
                    Text(CreditFormatter.number(value)).tag(Double?.some(value))
                }
            }
            Picker("Maximum", selection: maxCredits) {
                Text("Any").tag(Double?.none)
                ForEach(Self.creditChoices, id: \.self) { value in
                    Text(CreditFormatter.number(value)).tag(Double?.some(value))
                }
            }
        } header: {
            Text("Credits")
        } footer: {
            Text("Includes courses whose credit range overlaps your selection.")
        }
    }

    @ViewBuilder
    private var campusSection: some View {
        if let index, !index.campusNames.isEmpty {
            Section {
                ForEach(index.campusNames, id: \.self) { name in
                    Toggle(name, isOn: membership(\.campuses, name))
                }
            } header: {
                Text("Campus")
            } footer: {
                Text("Shows courses with a section at any selected campus.")
            }
        }
    }

    @ViewBuilder
    private var classTypeSection: some View {
        if let index, !index.classTypes.isEmpty {
            Section("Class type") {
                ForEach(index.classTypes, id: \.self) { type in
                    Toggle(type, isOn: membership(\.classTypes, type))
                }
            }
        }
    }

    private var instructionSection: some View {
        Section("Instruction") {
            Picker("Instruction", selection: filter(\.instruction)) {
                ForEach(InstructionFilter.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var daysSection: some View {
        Section {
            Toggle("Limit meeting days", isOn: limitsDays)
                .id(SearchFilterAnchor.days)
            if let allowed = filters.allowedDays {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dayChipMinimum), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
                    ForEach(Self.dayOrder, id: \.self) { day in
                        SearchToggleChip(title: DaySet.shortNames[day], isOn: allowed.contains(day: day)) {
                            toggleDay(day)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        } header: {
            Text("Meeting days")
        } footer: {
            Text(filters.allowedDays == nil
                 ? "Turn on to hide sections that meet on other days."
                 : "Only shows sections that meet on the selected days. Online sections without set times always match.")
        }
    }

    private var timeSection: some View {
        Section {
            Toggle("Starts after", isOn: hasTime(\.startsAfter, defaultMinutes: 9 * 60))
            if filters.startsAfter != nil {
                DatePicker("Earliest start", selection: time(\.startsAfter, fallback: 9 * 60), displayedComponents: .hourAndMinute)
            }
            Toggle("Ends before", isOn: hasTime(\.endsBefore, defaultMinutes: 17 * 60))
            if filters.endsBefore != nil {
                DatePicker("Latest end", selection: time(\.endsBefore, fallback: 17 * 60), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Time of day")
        } footer: {
            Text("Only shows sections whose weekly meetings fit inside this window.")
        }
    }

    // MARK: Bindings

    /// A binding to one filter property.
    private func filter<Value>(_ keyPath: WritableKeyPath<SearchFilters, Value>) -> Binding<Value> {
        Binding(
            get: { searchModel.filters[keyPath: keyPath] },
            set: { searchModel.filters[keyPath: keyPath] = $0 }
        )
    }

    /// A binding that adds / removes `element` in one of the filter sets.
    private func membership<Element: Hashable>(
        _ keyPath: WritableKeyPath<SearchFilters, Set<Element>>,
        _ element: Element
    ) -> Binding<Bool> {
        Binding(
            get: { searchModel.filters[keyPath: keyPath].contains(element) },
            set: { isOn in
                if isOn {
                    searchModel.filters[keyPath: keyPath].insert(element)
                } else {
                    searchModel.filters[keyPath: keyPath].remove(element)
                }
            }
        )
    }

    private var minCredits: Binding<Double?> {
        Binding(
            get: { searchModel.filters.minCredits },
            set: { newValue in
                searchModel.filters.minCredits = newValue
                if let newValue, let maximum = searchModel.filters.maxCredits, newValue > maximum {
                    searchModel.filters.maxCredits = newValue
                }
            }
        )
    }

    private var maxCredits: Binding<Double?> {
        Binding(
            get: { searchModel.filters.maxCredits },
            set: { newValue in
                searchModel.filters.maxCredits = newValue
                if let newValue, let minimum = searchModel.filters.minCredits, newValue < minimum {
                    searchModel.filters.minCredits = newValue
                }
            }
        )
    }

    /// Whether meeting days are restricted. Turning it on starts from Monday to Friday.
    private var limitsDays: Binding<Bool> {
        Binding(
            get: { searchModel.filters.allowedDays != nil },
            set: { isOn in
                searchModel.filters.allowedDays = isOn ? (searchModel.filters.allowedDays ?? .weekdays) : nil
            }
        )
    }

    private func toggleDay(_ day: Int) {
        var days = searchModel.filters.allowedDays ?? .weekdays
        if days.contains(day: day) {
            days.remove(DaySet(day: day))
        } else {
            days.insert(DaySet(day: day))
        }
        searchModel.filters.allowedDays = days
    }

    /// Whether a time bound is set; enabling it starts from `defaultMinutes`.
    private func hasTime(_ keyPath: WritableKeyPath<SearchFilters, Int?>, defaultMinutes: Int) -> Binding<Bool> {
        Binding(
            get: { searchModel.filters[keyPath: keyPath] != nil },
            set: { isOn in
                searchModel.filters[keyPath: keyPath] = isOn ? (searchModel.filters[keyPath: keyPath] ?? defaultMinutes) : nil
            }
        )
    }

    /// A time-of-day binding for a minutes-after-midnight filter value.
    private func time(_ keyPath: WritableKeyPath<SearchFilters, Int?>, fallback: Int) -> Binding<Date> {
        Binding(
            get: { SearchTimeOfDay.date(fromMinutes: searchModel.filters[keyPath: keyPath] ?? fallback) },
            set: { searchModel.filters[keyPath: keyPath] = SearchTimeOfDay.minutes(from: $0) }
        )
    }
}
