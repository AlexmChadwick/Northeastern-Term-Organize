//
//  ProfessorsDirectoryView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// An alphabetical, searchable directory of everyone teaching in a term.
struct ProfessorsDirectoryView: View {
    var termCode: String

    @Environment(CatalogStore.self) private var catalog

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var resolver = CourseIndexResolver()
    @State private var query = ""
    @State private var entries: [ProfessorDirectoryEntry] = []
    @State private var hasBuilt = false

    private var index: CatalogIndex? {
        resolver.index(for: termCode, in: catalog)
    }

    /// Changes whenever an index changes (a load, a sync or a live course refresh,
    /// which rebuilds the instructor directory), so the directory is rebuilt.
    private struct BuildID: Hashable {
        var termCode: String
        var hasIndex: Bool
        var indexVersion: Int
    }

    private var buildID: BuildID {
        BuildID(termCode: termCode, hasIndex: index != nil, indexVersion: catalog.indexVersion)
    }

    private var termName: String {
        resolver.term(for: termCode, in: catalog)?.name ?? "this term"
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entries matching every word of the query, grouped by last-name initial.
    private var groups: [ProfessorDirectoryGroup] {
        let tokens = ProfessorDirectoryEntry.fold(trimmedQuery)
            .split(separator: " ")
            .map(String.init)
        let matches = tokens.isEmpty
            ? entries
            : entries.filter { entry in tokens.allSatisfy { entry.searchText.contains($0) } }
        return ProfessorDirectoryGroup.grouping(matches)
    }

    var body: some View {
        content
            .navigationTitle("Professors")
            .navigationBarTitleDisplayMode(.large)
            .navigationSubtitle(termName)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search professors or courses"
            )
            .task(id: termCode) {
                await resolver.resolve(termCode: termCode, catalog: catalog)
            }
            .courseReloadsIndex(resolver, termCode: termCode)
            .task(id: buildID) {
                guard let index else { return }
                let build = Task.detached(priority: .userInitiated) {
                    ProfessorDirectoryEntry.build(from: index)
                }
                let built = await withTaskCancellationHandler {
                    await build.value
                } onCancel: {
                    build.cancel()
                }
                // A newer build supersedes this one: never let an older result overwrite it.
                guard !Task.isCancelled else { return }
                entries = built
                hasBuilt = true
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if index == nil && resolver.isLoading(termCode: termCode, in: catalog) {
            ProgressView("Loading professors…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if index == nil {
            ContentUnavailableView {
                Label("Catalog unavailable", systemImage: "icloud.slash")
            } description: {
                Text("The catalog for \(termName) isn't on this device yet.")
            } actions: {
                Button("Try Again") {
                    Task { await resolver.resolve(termCode: termCode, catalog: catalog) }
                }
                .buttonStyle(.bordered)
            }
        } else if !hasBuilt {
            ProgressView("Loading professors…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No instructors yet",
                systemImage: "person.2",
                description: Text("Instructor names load as you open courses. Open a few courses, then come back.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        let groups = self.groups
        return List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text(group.letter)
                }
                .sectionIndexLabel(group.letter)
            }
            if trimmedQuery.isEmpty {
                Text("\(entries.count.formatted()) professors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .listSectionIndexVisibility(trimmedQuery.isEmpty ? .visible : .hidden)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    private func row(_ entry: ProfessorDirectoryEntry) -> some View {
        let count = CourseFormat.count(entry.sectionCount, "section")
        let stacksCount = dynamicTypeSize.isAccessibilitySize
        return NavigationLink(value: AppRoute.professor(termCode: termCode, name: entry.id)) {
            HStack(spacing: Theme.Spacing.m) {
                ProfessorMonogram(name: entry.id, font: .footnote.weight(.semibold), diameter: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.body)
                    Text(entry.courseSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(stacksCount ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if stacksCount {
                        Text(count)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if !stacksCount {
                    Spacer(minLength: Theme.Spacing.s)
                    Text(count)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.displayName), \(entry.courseSummary), \(count)")
        }
    }
}
