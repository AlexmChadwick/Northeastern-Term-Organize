//
//  SearchResultsList.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Search results: an exact CRN match, matching subjects and professors, then
/// the courses themselves. Shows a helpful empty state when nothing matches.
///
/// Everything it shows, including the empty states, describes `query`: the
/// query `response` was computed for, which can lag behind what is currently
/// typed in the search field. It is `Equatable` on `revision` (bumped whenever
/// the results are replaced) so that typing, which re-renders the parent on
/// every keystroke, does not make SwiftUI diff thousands of rows again.
struct SearchResultsList: View, Equatable {
    var index: CatalogIndex
    var response: SearchResponse
    /// The query that produced `response`.
    var query: SearchQuery
    var revision: Int
    var onClearFilters: () -> Void

    nonisolated static func == (lhs: SearchResultsList, rhs: SearchResultsList) -> Bool {
        lhs.revision == rhs.revision
            && lhs.query == rhs.query
            && lhs.index.term.code == rhs.index.term.code
    }

    private var searchText: String { query.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasFilters: Bool { !query.filters.isEmpty }

    private var isEmpty: Bool {
        response.results.isEmpty && response.crnMatch == nil && response.subjects.isEmpty && response.instructors.isEmpty
    }

    var body: some View {
        if isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    // MARK: Results

    /// Row stats. When section-level filters (campus, days, open seats…) are
    /// active, availability is counted over only the sections that match them,
    /// so a row never promises seats in a section the filters would hide.
    private func stats(for result: SearchResult) -> CourseStats {
        let filters = query.filters
        guard filters.hasSectionFilters else { return result.stats }
        let matching = index.sections(for: result.course.key).filter { filters.matches(section: $0) }
        return CatalogIndex.makeStats(matching)
    }

    private var resultsList: some View {
        let termCode = index.term.code
        return List {
            if let section = response.crnMatch {
                Section {
                    SearchCRNRow(termCode: termCode, section: section)
                } header: {
                    SearchSectionHeader(title: "CRN match")
                }
            }

            if !response.subjects.isEmpty {
                Section {
                    ForEach(response.subjects) { subject in
                        NavigationLink(value: AppRoute.subject(termCode: termCode, code: subject.code)) {
                            SearchSubjectRow(subject: subject, courseCount: index.courseCountBySubject[subject.code] ?? 0)
                        }
                    }
                } header: {
                    SearchSectionHeader(title: "Subjects")
                }
            }

            if !response.instructors.isEmpty {
                Section {
                    ForEach(response.instructors) { instructor in
                        NavigationLink(value: AppRoute.professor(termCode: termCode, name: instructor.name)) {
                            SearchProfessorRow(instructor: instructor)
                        }
                    }
                } header: {
                    SearchSectionHeader(title: "Professors")
                }
            }

            if !response.results.isEmpty {
                Section {
                    ForEach(response.results) { result in
                        BrowseCourseRow(
                            termCode: termCode,
                            course: result.course,
                            stats: stats(for: result),
                            note: result.matchNote
                        )
                    }
                } header: {
                    SearchSectionHeader(title: response.results.count == 1 ? "1 course" : "\(response.results.count.formatted()) courses")
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView {
                Label("No matching courses", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No courses match these filters. Try removing some of them.")
            } actions: {
                if hasFilters {
                    Button("Clear filters", action: onClearFilters)
                        .buttonStyle(.glass)
                }
            }
        } else if hasFilters {
            ContentUnavailableView {
                Label("No results for “\(searchText)”", systemImage: "magnifyingglass")
            } description: {
                Text("Check the spelling, try a new search, or remove some filters.")
            } actions: {
                Button("Clear filters", action: onClearFilters)
                    .buttonStyle(.glass)
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }
}

// MARK: - Rows

/// A header for a block of results in the plain results list.
private struct SearchSectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .monospacedDigit()
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section whose CRN exactly matches the query: "CRN 12345 · CS 3000 Section 02".
private struct SearchCRNRow: View {
    var termCode: String
    var section: CourseSection

    var body: some View {
        NavigationLink(value: AppRoute.section(termCode: termCode, crn: section.crn)) {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CRN \(section.crn) · \(section.courseKey.description) Section \(section.sectionNumber)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tint)
                        .monospacedDigit()
                    Text(section.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(section.classType) · \(section.scheduleSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.s)
                SeatsBadge(section: section)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.accentColor.opacity(0.1))
    }
}

private struct SearchSubjectRow: View {
    var subject: Subject
    var courseCount: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            BrowseSubjectLabel(
                subject: subject,
                detail: courseCount == 1 ? "1 course" : "\(courseCount.formatted()) courses"
            )
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subject: \(subject.name), \(subject.code)")
        .accessibilityValue(courseCount == 1 ? "1 course" : "\(courseCount) courses")
    }
}

private struct SearchProfessorRow: View {
    var instructor: InstructorSummary

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    private var detail: String {
        let courses = instructor.courseKeys.count
        let sections = instructor.crns.count
        return "\(courses == 1 ? "1 course" : "\(courses) courses") · \(sections == 1 ? "1 section" : "\(sections) sections")"
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(instructor.displayName)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Professor: \(instructor.displayName)")
        .accessibilityValue(detail)
    }
}
