//
//  SubjectsDirectoryView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Every subject offered in the term, sectioned alphabetically with a section
/// index and a local filter.
struct SubjectsDirectoryView: View {
    var termCode: String

    @State private var query = ""

    var body: some View {
        BrowseIndexReader(termCode: termCode) { index in
            Group {
                if let index {
                    SubjectsDirectoryList(index: index, query: $query)
                } else {
                    BrowseIndexUnavailable(termCode: termCode)
                }
            }
            .navigationTitle("Subjects")
            .navigationSubtitle(index?.term.name ?? "")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct SubjectsDirectoryList: View {
    var index: CatalogIndex
    @Binding var query: String

    private struct LetterSection: Identifiable {
        var letter: String
        var subjects: [Subject]
        var id: String { letter }
    }

    private var sections: [LetterSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjects: [Subject]
        if needle.isEmpty {
            subjects = index.activeSubjects
        } else {
            subjects = index.activeSubjects.filter {
                $0.code.localizedCaseInsensitiveContains(needle) || $0.name.localizedCaseInsensitiveContains(needle)
            }
        }
        let grouped = Dictionary(grouping: subjects) { String($0.code.prefix(1)).uppercased() }
        return grouped.keys.sorted().map { LetterSection(letter: $0, subjects: grouped[$0] ?? []) }
    }

    var body: some View {
        let sections = sections
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.subjects) { subject in
                        NavigationLink(value: AppRoute.subject(termCode: index.term.code, code: subject.code)) {
                            SubjectDirectoryRow(
                                subject: subject,
                                courseCount: index.courseCountBySubject[subject.code] ?? 0
                            )
                        }
                    }
                } header: {
                    Text(section.letter)
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(query.isEmpty ? .visible : .hidden)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search subjects"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct SubjectDirectoryRow: View {
    var subject: Subject
    var courseCount: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            BrowseSubjectLabel(subject: subject)
            Spacer(minLength: Theme.Spacing.s)
            Text(courseCount.formatted())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(subject.name), \(subject.code)")
        .accessibilityValue(courseCount == 1 ? "1 course" : "\(courseCount) courses")
    }
}
