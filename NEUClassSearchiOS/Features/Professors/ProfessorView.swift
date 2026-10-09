//
//  ProfessorView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// An instructor's page: what they teach this term, when, and a way to look
/// them up on Rate My Professors.
struct ProfessorView: View {
    var termCode: String
    /// Banner name, `Last, First`.
    var name: String

    @Environment(CatalogStore.self) private var catalog
    @Environment(AppRouter.self) private var router

    @State private var resolver = CourseIndexResolver()

    private var index: CatalogIndex? {
        resolver.index(for: termCode, in: catalog)
    }

    private var summary: InstructorSummary? {
        index?.instructor(named: name)
    }

    private var displayName: String {
        summary?.displayName ?? Instructor.displayName(from: name)
    }

    private var termName: String {
        resolver.term(for: termCode, in: catalog)?.name ?? "this term"
    }

    /// The surname, for searching the catalog.
    private var lastName: String {
        name.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    var body: some View {
        content
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(termName)
            .task(id: termCode) {
                await resolver.resolve(termCode: termCode, catalog: catalog)
            }
            .courseReloadsIndex(resolver, termCode: termCode)
    }

    @ViewBuilder
    private var content: some View {
        if let index, let summary {
            ProfessorContent(summary: summary, index: index, termCode: termCode)
        } else if index == nil, resolver.isLoading(termCode: termCode, in: catalog) {
            ProgressView("Loading…")
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
        } else {
            ContentUnavailableView {
                Label("No sections found", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("\(displayName) isn't listed as teaching any sections in \(termName).")
            } actions: {
                Button("Search for \(lastName)") {
                    router.search(for: lastName)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
