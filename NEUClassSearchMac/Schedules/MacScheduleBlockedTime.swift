//
//  MacScheduleBlockedTime.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The small editors of the "ideal week" survey: one blocked time, and the instructors to prefer or avoid.
//

import SwiftUI

/// How a blocked time reads in the survey's list.
struct MacBlockedTimeRow: View {
    var block: BlockedTime
    var isFilledIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(block.label.isEmpty ? "Blocked time" : block.label)
                    .foregroundStyle(block.isActive ? Color.primary : Color.secondary)
                if isFilledIn {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            Text(block.listDetail)
                .font(.callout)
                .foregroundStyle(block.isValid ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Edits one blocked time: a name, the days it repeats on, and the hours. Classes won't be scheduled
/// over it (or, when the student prefers, are only ranked lower).
struct MacBlockedTimeEditor: View {
    @Binding var block: BlockedTime
    /// Day indices to offer (0 = Sunday).
    var days: [Int]
    var onDelete: () -> Void

    @FocusState private var isNameFocused: Bool

    private static let nameIdeas = ["Club meeting", "Work", "Commute", "Team practice", "Appointment", "Study group"]

    private var startDate: Binding<Date> {
        Binding(
            get: { ScheduleClock.date(forMinutes: block.start) },
            set: { date in
                let minutes = ScheduleClock.minutes(from: date)
                block.start = minutes
                // Keep the block at least an hour long when the start moves past its end.
                if block.end <= minutes { block.end = min(minutes + 60, 24 * 60 - 1) }
            }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { ScheduleClock.date(forMinutes: block.end) },
            set: { block.end = ScheduleClock.minutes(from: $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $block.label)
                    .focused($isNameFocused)
                CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Self.nameIdeas, id: \.self) { idea in
                        Button(idea) {
                            block.label = idea
                            isNameFocused = false
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("What is it?")
            }

            Section {
                ScheduleDayChips(selection: $block.days, days: days, onValue: "Blocked", offValue: "Free", diameter: 30)
            } header: {
                Text("Repeats every week on")
            } footer: {
                if block.days.isEmpty {
                    Label("Choose at least one day.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                DatePicker("Starts", selection: startDate, displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: endDate, displayedComponents: .hourAndMinute)
            } header: {
                Text("Time")
            } footer: {
                if block.end <= block.start {
                    Label("It has to end after it starts.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Classes during this time", selection: $block.strength) {
                    Text("Never").tag(PreferenceStrength.required)
                    Text("If I must").tag(PreferenceStrength.preferred)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Classes during this time")
            } footer: {
                Text(block.strength == .required
                     ? "Sections that meet during this time are left out of your schedules."
                     : "Schedules that avoid this time come first, but sections that overlap it can still show up.")
            }

            Section {
                Toggle("Use this blocked time", isOn: $block.isEnabled)
            } footer: {
                if !block.isEnabled { Text("Turned off, it is kept but ignored.") }
            }

            Section {
                Button("Delete Blocked Time", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 560)
        .task {
            // A new block starts with the name field ready, once the popover has appeared.
            guard block.label.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { isNameFocused = true }
        }
    }
}

/// Chooses instructors to prefer or avoid among those teaching the schedule's courses.
struct MacInstructorPreferences: View {
    @Binding var preferred: [String]
    @Binding var avoided: [String]
    var instructors: [ScheduleInstructorOption]

    @State private var search = ""

    private enum Choice: String, CaseIterable, Identifiable {
        case none, prefer, avoid
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "No Preference"
            case .prefer: "Prefer"
            case .avoid: "Avoid"
            }
        }
    }

    private var visible: [ScheduleInstructorOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return instructors }
        return instructors.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func choice(for name: String) -> Choice {
        if preferred.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return .prefer }
        if avoided.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return .avoid }
        return .none
    }

    private func binding(for name: String) -> Binding<Choice> {
        Binding(
            get: { choice(for: name) },
            set: { choice in
                preferred.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
                avoided.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
                switch choice {
                case .none: break
                case .prefer: preferred.append(name)
                case .avoid: avoided.append(name)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search instructors", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if instructors.isEmpty {
                ContentUnavailableView {
                    Label("No instructors yet", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Add courses to this schedule and their instructors will show up here.")
                }
            } else {
                List {
                    Section {
                        ForEach(visible) { instructor in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(instructor.displayName)
                                    Text(instructor.courses.map(\.description).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Picker(instructor.displayName, selection: binding(for: instructor.name)) {
                                    ForEach(Choice.allCases) { Text($0.title).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 130)
                            }
                        }
                    } footer: {
                        Text("Schedules with instructors you prefer come first; ones with instructors you avoid come last. Nothing is removed.")
                            .padding(.top, 6)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 440, height: 420)
    }
}
