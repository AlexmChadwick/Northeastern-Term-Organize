//
//  ScheduleInstructorPreferencesList.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Chooses instructors to prefer or avoid among those teaching the plan's courses.
struct ScheduleInstructorPreferencesList: View {
    @Binding var preferred: [String]
    @Binding var avoided: [String]
    var instructors: [ScheduleInstructorOption]

    @State private var search = ""

    private enum Choice: String, CaseIterable, Identifiable {
        case none, prefer, avoid
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "No preference"
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
        List {
            if instructors.isEmpty {
                ContentUnavailableView {
                    Label("No instructors yet", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Add courses to this schedule and their instructors will show up here.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(visible) { instructor in
                        Picker(selection: binding(for: instructor.name)) {
                            ForEach(Choice.allCases) { Text($0.title).tag($0) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instructor.displayName)
                                Text(instructor.courses.map(\.description).joined(separator: ", "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } footer: {
                    Text("Schedules with instructors you prefer come first; ones with instructors you avoid come last. Nothing is removed.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search instructors")
        .navigationTitle("Instructors")
        .navigationBarTitleDisplayMode(.inline)
    }
}
