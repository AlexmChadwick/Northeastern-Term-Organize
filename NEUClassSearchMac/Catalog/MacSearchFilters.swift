//
//  MacSearchFilters.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Every search filter in one popover, the Mac counterpart of the iPhone's filters sheet. Edits
/// apply live, so the results behind the popover change as they are made.
struct MacSearchFiltersForm: View {
    @Bindable var state: MacCatalogState
    var index: CatalogIndex

    private static let creditChoices: [Double] = [0, 1, 2, 3, 4, 5, 6, 8]
    /// Monday first, as students think of the week.
    private static let dayOrder = [1, 2, 3, 4, 5, 6, 0]

    private var filters: SearchFilters { state.filters }

    private var levelChoices: [Int] {
        let available = Set(index.courses.compactMap { $0.key.level })
        return Array((available.isEmpty ? Set(1...9) : available).union(filters.levels)).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Open seats only", isOn: $state.filters.openSeatsOnly)
                    Toggle("Honors only", isOn: $state.filters.honorsOnly)
                }

                Section("Course Level") {
                    CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(levelChoices, id: \.self) { level in
                            Toggle(SearchFilterTitles.level(level), isOn: membership(\.levels, level))
                                .toggleStyle(.button)
                        }
                    }
                }

                Section {
                    ForEach(NUPath.allCases) { nupath in
                        Toggle(isOn: membership(\.nupaths, nupath)) {
                            Label {
                                Text("\(nupath.name) (\(nupath.short))")
                            } icon: {
                                Image(systemName: nupath.symbol)
                                    .frame(width: 20)
                            }
                        }
                    }
                } header: {
                    Text("NUpath")
                } footer: {
                    Text("Shows courses that satisfy every selected NUpath.")
                }

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

                if !index.campusNames.isEmpty {
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

                if !index.classTypes.isEmpty {
                    Section("Class Type") {
                        ForEach(index.classTypes, id: \.self) { type in
                            Toggle(type, isOn: membership(\.classTypes, type))
                        }
                    }
                }

                Section("Instruction") {
                    Picker("Instruction", selection: $state.filters.instruction) {
                        ForEach(InstructionFilter.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    Toggle("Limit meeting days", isOn: limitsDays)
                    if let allowed = filters.allowedDays {
                        HStack(spacing: 4) {
                            ForEach(Self.dayOrder, id: \.self) { day in
                                Toggle(DaySet.shortNames[day], isOn: Binding(
                                    get: { allowed.contains(day: day) },
                                    set: { _ in toggleDay(day) }
                                ))
                                .toggleStyle(.button)
                            }
                        }
                    }
                } header: {
                    Text("Meeting Days")
                } footer: {
                    Text(filters.allowedDays == nil
                         ? "Turn on to hide sections that meet on other days."
                         : "Only shows sections that meet on the selected days. Online sections without set times always match.")
                }

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
                    Text("Time of Day")
                } footer: {
                    Text("Only shows sections whose weekly meetings fit inside this window.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Reset Filters", role: .destructive) { state.filters = SearchFilters() }
                    .disabled(filters.isEmpty)
                Spacer()
                Text(filters.isEmpty ? "No filters" : "\(filters.activeCount) active")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(width: 380, height: 560)
    }

    // MARK: Bindings

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

    private var minCredits: Binding<Double?> {
        Binding(
            get: { state.filters.minCredits },
            set: { newValue in
                state.filters.minCredits = newValue
                if let newValue, let maximum = state.filters.maxCredits, newValue > maximum {
                    state.filters.maxCredits = newValue
                }
            }
        )
    }

    private var maxCredits: Binding<Double?> {
        Binding(
            get: { state.filters.maxCredits },
            set: { newValue in
                state.filters.maxCredits = newValue
                if let newValue, let minimum = state.filters.minCredits, newValue < minimum {
                    state.filters.minCredits = newValue
                }
            }
        )
    }

    /// Whether meeting days are restricted. Turning it on starts from Monday to Friday.
    private var limitsDays: Binding<Bool> {
        Binding(
            get: { state.filters.allowedDays != nil },
            set: { isOn in
                state.filters.allowedDays = isOn ? (state.filters.allowedDays ?? .weekdays) : nil
            }
        )
    }

    private func toggleDay(_ day: Int) {
        var days = state.filters.allowedDays ?? .weekdays
        if days.contains(day: day) {
            days.remove(DaySet(day: day))
        } else {
            days.insert(DaySet(day: day))
        }
        state.filters.allowedDays = days
    }

    /// Whether a time bound is set; enabling it starts from `defaultMinutes`.
    private func hasTime(_ keyPath: WritableKeyPath<SearchFilters, Int?>, defaultMinutes: Int) -> Binding<Bool> {
        Binding(
            get: { state.filters[keyPath: keyPath] != nil },
            set: { isOn in
                state.filters[keyPath: keyPath] = isOn ? (state.filters[keyPath: keyPath] ?? defaultMinutes) : nil
            }
        )
    }

    /// A time-of-day binding for a minutes-after-midnight filter value.
    private func time(_ keyPath: WritableKeyPath<SearchFilters, Int?>, fallback: Int) -> Binding<Date> {
        Binding(
            get: { SearchTimeOfDay.date(fromMinutes: state.filters[keyPath: keyPath] ?? fallback) },
            set: { state.filters[keyPath: keyPath] = SearchTimeOfDay.minutes(from: $0) }
        )
    }
}

/// A searchable multi-select list of every subject offered this term.
struct MacSubjectPicker: View {
    @Bindable var state: MacCatalogState
    var index: CatalogIndex

    @State private var query = ""

    var body: some View {
        let selected = state.filters.subjects
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = index.activeSubjects
        let matches = needle.isEmpty ? all : all.filter {
            $0.code.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
        }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter Subjects", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Clear") { state.filters.subjects = [] }
                    .disabled(selected.isEmpty)
            }
            .padding(10)
            Divider()
            List {
                ForEach(matches) { subject in
                    Toggle(isOn: Binding(
                        get: { state.filters.subjects.contains(subject.code) },
                        set: { isOn in
                            if isOn {
                                state.filters.subjects.insert(subject.code)
                            } else {
                                state.filters.subjects.remove(subject.code)
                            }
                        }
                    )) {
                        HStack(spacing: 8) {
                            Text(subject.code)
                                .fontWeight(.semibold)
                                .frame(width: 56, alignment: .leading)
                            Text(subject.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text((index.courseCountBySubject[subject.code] ?? 0).formatted())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if !needle.isEmpty && matches.isEmpty {
                    ContentUnavailableView.search(text: needle)
                }
            }
        }
        .frame(width: 360, height: 440)
    }
}
