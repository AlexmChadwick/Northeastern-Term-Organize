//
//  ScheduleFiltersView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The generator's filters as a sheet. Changes are saved to the plan as they
/// are made, so the screen behind the sheet can regenerate live.
struct ScheduleFiltersSheet: View {
    var planID: UUID
    /// Campus names offered by the term's catalog.
    var campusNames: [String]
    /// Number of courses in the plan (the largest "number of courses" choice).
    var courseCount: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScheduleFiltersForm(planID: planID, campusNames: campusNames, courseCount: courseCount)
                .navigationTitle("Filters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Reset lives at the bottom of the form (destructive), away from Done.
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ScheduleFiltersForm: View {
    var planID: UUID
    var campusNames: [String]
    var courseCount: Int

    @Environment(UserDataStore.self) private var userData
    @State private var haptic = PlanHaptic()

    private var filters: ScheduleFilters { userData.plan(id: planID)?.filters ?? ScheduleFilters() }

    /// The earliest start is at or after the latest end, so no section can satisfy both.
    private var hasImpossibleTimeRange: Bool {
        guard let start = filters.earliestStart, let end = filters.latestEnd else { return false }
        return start >= end
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ScheduleFilters, T>) -> Binding<T> {
        Binding(
            get: { filters[keyPath: keyPath] },
            set: { newValue in userData.updatePlan(id: planID) { $0.filters[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: Time of day

    private static func date(forMinutes minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    private static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func isOn(_ keyPath: WritableKeyPath<ScheduleFilters, Int?>, default minutes: Int) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath] != nil },
            set: { enabled in
                userData.updatePlan(id: planID) { $0.filters[keyPath: keyPath] = enabled ? ($0.filters[keyPath: keyPath] ?? minutes) : nil }
            }
        )
    }

    private func time(_ keyPath: WritableKeyPath<ScheduleFilters, Int?>, default minutes: Int) -> Binding<Date> {
        Binding(
            get: { Self.date(forMinutes: filters[keyPath: keyPath] ?? minutes) },
            set: { date in userData.updatePlan(id: planID) { $0.filters[keyPath: keyPath] = Self.minutes(from: date) } }
        )
    }

    // MARK: Free days

    private var selectableDays: [Int] {
        var days = [1, 2, 3, 4, 5]
        if userData.preferences.showWeekends || filters.freeDays.contains(day: 6) { days.append(6) }
        if userData.preferences.showWeekends || filters.freeDays.contains(day: 0) { days.insert(0, at: 0) }
        return days
    }

    private func toggleFreeDay(_ day: Int) {
        userData.updatePlan(id: planID) { plan in
            if plan.filters.freeDays.contains(day: day) {
                plan.filters.freeDays.remove(DaySet(day: day))
            } else {
                plan.filters.freeDays.insert(DaySet(day: day))
            }
        }
    }

    private var usableCampuses: [String] {
        campusNames.filter { !$0.localizedCaseInsensitiveContains("online") && !$0.localizedCaseInsensitiveContains("no campus") }
    }

    private var countChoices: [Int] {
        let current = filters.courseCount ?? 0
        return Array(1...max(1, courseCount, current))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Start no earlier than", isOn: isOn(\.earliestStart, default: 9 * 60))
                if filters.earliestStart != nil {
                    DatePicker("Earliest start", selection: time(\.earliestStart, default: 9 * 60), displayedComponents: .hourAndMinute)
                }
                Toggle("End no later than", isOn: isOn(\.latestEnd, default: 17 * 60))
                if filters.latestEnd != nil {
                    DatePicker("Latest end", selection: time(\.latestEnd, default: 17 * 60), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Time of day")
            } footer: {
                if hasImpossibleTimeRange, let start = filters.earliestStart, let end = filters.latestEnd {
                    Label("The earliest start (\(TimeOfDay.label(start))) isn’t before the latest end (\(TimeOfDay.label(end))), so no section can fit.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(selectableDays, id: \.self) { day in
                        freeDayButton(day)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } header: {
                Text("Keep days free")
            } footer: {
                Text("Sections that meet on a selected day are skipped.")
            }

            Section {
                Toggle("Include honors sections", isOn: binding(\.includeHonors))
                Toggle("Include online sections", isOn: binding(\.includeOnline))
                Toggle("Hide full sections", isOn: binding(\.hideFullSections))
                Stepper(value: binding(\.minSeats), in: 0...50) {
                    HStack {
                        Text("Minimum open seats")
                        Spacer()
                        Text(filters.minSeats == 0 ? "Any" : "\(filters.minSeats)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Sections")
            }

            Section {
                if !usableCampuses.isEmpty || filters.campus != nil {
                    Picker("Campus", selection: binding(\.campus)) {
                        Text("Any campus").tag(String?.none)
                        ForEach(campusChoices, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
                Picker("Number of courses", selection: binding(\.courseCount)) {
                    Text("All that fit").tag(Int?.none)
                    ForEach(countChoices, id: \.self) { count in
                        Text(count == 1 ? "1 course" : "\(count) courses").tag(Int?.some(count))
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Online sections are always allowed for any campus. With “All that fit” every required course is used, plus as many optional courses as fit.")
            }

            Section {
                Button(role: .destructive) {
                    userData.updatePlan(id: planID) { $0.filters = ScheduleFilters() }
                    haptic.fire(.warning)
                } label: {
                    Label("Reset All Filters", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(filters.activeCount == 0)
            }
        }
        .planHaptic(haptic)
    }

    private var campusChoices: [String] {
        var names = usableCampuses
        if let campus = filters.campus, !names.contains(campus) { names.append(campus) }
        return names
    }

    private func freeDayButton(_ day: Int) -> some View {
        let isFree = filters.freeDays.contains(day: day)
        return Button {
            toggleFreeDay(day)
        } label: {
            Text(DaySet.shortNames[day])
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isFree ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(minWidth: 40, minHeight: 40)
                .background(isFree ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DaySet.fullNames[day])
        .accessibilityValue(isFree ? "Kept free" : "Classes allowed")
        .accessibilityAddTraits(isFree ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isFree)
    }
}
