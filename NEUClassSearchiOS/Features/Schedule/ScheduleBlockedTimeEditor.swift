//
//  ScheduleBlockedTimeEditor.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Edits one blocked time: a name, the days it repeats on, and the hours. Classes won't be scheduled
/// over it (or, when the student prefers, are only ranked lower).
struct ScheduleBlockedTimeEditor: View {
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
                    .textInputAutocapitalization(.sentences)
                    .focused($isNameFocused)
                    .submitLabel(.done)
                ideas
            } header: {
                Text("What is it?")
            }

            Section {
                ScheduleDayChips(selection: $block.days, days: days, onValue: "Blocked", offValue: "Free")
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
                Button(role: .destructive, action: onDelete) {
                    Label("Delete blocked time", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(block.label.isEmpty ? "Blocked time" : block.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A new block starts with the name field ready, once the screen has finished pushing.
            guard block.label.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { isNameFocused = true }
        }
    }

    /// One-tap names for the usual commitments.
    private var ideas: some View {
        PlanFlowLayout(spacing: 8, lineSpacing: 8) {
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
    }
}

/// How a blocked time reads in the survey's list.
struct ScheduleBlockedTimeRow: View {
    var block: BlockedTime
    var isFilledIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(block.label.isEmpty ? "Blocked time" : block.label)
                    .font(.body)
                    .foregroundStyle(block.isActive ? Color.primary : Color.secondary)
                if isFilledIn {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(block.isValid ? Color.secondary : Color.orange)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String { block.listDetail }
}
