//
//  MacDegreeCoursePickers.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A popover that picks one of the plan's courses, completed or planned: a search field above
/// the list. Choosing one closes it.
struct MacDegreeCoursePicker: View {
    var choices: [DegreePlanCourseChoice]
    @Binding var selection: CourseKey?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        let filtered = DegreeSubstitutionEditing.matching(choices, query: searchText)
        VStack(spacing: 0) {
            TextField("Find a course in your plan", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if filtered.isEmpty {
                Text(choices.isEmpty ? "This plan has no courses yet." : "No course matches “\(searchText)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { choice in
                    let isSelected = selection == choice.key
                    Button {
                        selection = choice.key
                        dismiss()
                    } label: {
                        MacDegreeChoiceRow(choice: choice, trailing: isSelected ? "checkmark" : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: 360)
    }
}

/// A popover that picks several of the plan's courses (a petition's specific courses).
struct MacDegreeCourseMultiPicker: View {
    var choices: [DegreePlanCourseChoice]
    @Binding var selection: Set<CourseKey>

    @State private var searchText = ""

    var body: some View {
        let filtered = DegreeSubstitutionEditing.matching(choices, query: searchText)
        VStack(spacing: 0) {
            TextField("Find a course", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if filtered.isEmpty {
                Text(choices.isEmpty ? "Your plan has no courses yet." : "No course matches “\(searchText)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { choice in
                    let isSelected = selection.contains(choice.key)
                    Button {
                        if isSelected { selection.remove(choice.key) } else { selection.insert(choice.key) }
                    } label: {
                        MacDegreeChoiceRow(choice: choice, trailing: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: 360)
    }
}

/// A course of the plan in a picker: code, then its title and when it is taken.
struct MacDegreeChoiceRow: View {
    var choice: DegreePlanCourseChoice
    var caption: String?
    /// The name of an SF Symbol at the trailing edge: a checkmark for the selection.
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.key.description)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text([choice.title.nilIfBlank, choice.whenLine].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing)
                    .foregroundStyle(trailing == "circle" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
