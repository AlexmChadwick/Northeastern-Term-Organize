//
//  SearchSubjectPicker.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A searchable multi-select list of every subject offered this term, pushed
/// inside the filters sheet.
struct SearchSubjectPicker: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(SearchModel.self) private var searchModel

    @State private var query = ""

    var body: some View {
        let selected = searchModel.filters.subjects
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = catalog.readyIndex
        let all = index?.activeSubjects ?? []
        let matches = needle.isEmpty ? all : all.filter {
            $0.code.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
        }
        List {
            if let index {
                if needle.isEmpty, !selected.isEmpty {
                    Section("Selected") {
                        ForEach(all.filter { selected.contains($0.code) }) { subject in
                            row(subject, index: index, isSelected: true)
                        }
                    }
                }
                Section(needle.isEmpty ? "All subjects" : "Results") {
                    ForEach(matches) { subject in
                        row(subject, index: index, isSelected: selected.contains(subject.code))
                    }
                }
            }
        }
        .navigationTitle("Subjects")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search subjects"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    searchModel.filters.subjects = []
                }
                .disabled(selected.isEmpty)
            }
        }
        .overlay {
            if index != nil, !needle.isEmpty, matches.isEmpty {
                ContentUnavailableView.search(text: needle)
            }
        }
    }

    private func row(_ subject: Subject, index: CatalogIndex, isSelected: Bool) -> some View {
        Button {
            if isSelected {
                searchModel.filters.subjects.remove(subject.code)
            } else {
                searchModel.filters.subjects.insert(subject.code)
            }
        } label: {
            SubjectPickerRow(
                subject: subject,
                courseCount: index.courseCountBySubject[subject.code] ?? 0,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SubjectPickerRow: View {
    var subject: Subject
    var courseCount: Int
    var isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            BrowseSubjectLabel(
                subject: subject,
                detail: courseCount == 1 ? "1 course" : "\(courseCount.formatted()) courses"
            )
            Spacer(minLength: Theme.Spacing.s)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subject.name), \(subject.code)")
        .accessibilityValue(courseCount == 1 ? "1 course" : "\(courseCount) courses")
    }
}
