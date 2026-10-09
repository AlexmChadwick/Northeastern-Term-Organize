//
//  CourseRow.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The standard list row for a course: code, title, credits, NUpaths and
/// seat availability.
struct CourseRow: View {
    var course: Course
    var stats: CourseStats?
    /// Optional context line, e.g. "Taught by Jane Doe".
    var note: String?
    var showsAvailability = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(course.code)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tint)
                    .monospacedDigit()
                Text(course.creditsLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if showsAvailability, let stats, stats.sectionCount > 0 {
                    availability(stats)
                }
            }
            Text(course.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let stats, let first = stats.instructorNames.first {
                Text(stats.instructorNames.count > 1 ? "\(first) +\(stats.instructorNames.count - 1)" : first)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let nupaths = course.nupaths
            if !nupaths.isEmpty || (stats?.hasHonors ?? false) {
                HStack(spacing: 4) {
                    NUPathChipRow(nupaths: nupaths)
                    if stats?.hasHonors == true {
                        TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func availability(_ stats: CourseStats) -> some View {
        let color: Color = stats.openSectionCount == 0 ? .red : (stats.seatsRemaining <= 5 ? .orange : .green)
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(stats.openSectionCount == 0 ? "Full" : "\(stats.openSectionCount)/\(stats.sectionCount) open")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// A toolbar menu for switching the selected term.
struct TermMenu: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    /// Show only terms of this college (nil for all).
    var college: Term.College? = nil

    private var groups: [(college: Term.College, terms: [Term])] {
        let filter = college
        let visible = catalog.terms.filter { filter == nil || $0.college == filter }
        return Term.College.allCases.compactMap { group in
            let list = visible.filter { $0.college == group }
            guard !list.isEmpty else { return nil }
            return (group, Array(list.prefix(group == .neu ? 10 : 6)))
        }
    }

    var body: some View {
        Menu {
            ForEach(groups, id: \.college) { group in
                Section(group.college.displayName) {
                    ForEach(group.terms) { term in
                        termButton(term)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(catalog.selectedTerm?.name ?? "Select Term")
                    .fontWeight(.semibold)
                #if !os(macOS)
                // The Mac draws its own menu indicator; two would read as two controls.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .accessibilityLabel("Term: \(catalog.selectedTerm?.name ?? "none selected")")
        .accessibilityHint("Choose a different term")
    }

    private func termButton(_ term: Term) -> some View {
        Button {
            Task {
                await catalog.select(termCode: term.code)
                userData.preferences.selectedTermCode = term.code
            }
        } label: {
            if term.code == catalog.selectedTermCode {
                Label(term.name, systemImage: "checkmark")
            } else {
                Text(term.name)
            }
        }
    }
}
