//
//  SavedCoursesView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The user's bookmarked courses for a term, newest first. Swipe to remove.
/// Courses that are not in the term's catalog still show up so they can be
/// cleaned out.
struct SavedCoursesView: View {
    @Environment(CatalogStore.self) private var catalog

    var termCode: String

    var body: some View {
        BrowseIndexReader(termCode: termCode) { index in
            let termName = index?.term.name ?? catalog.terms.first { $0.code == termCode }?.name ?? ""
            SavedCoursesList(termCode: termCode, termName: termName, index: index)
                .navigationTitle("Saved")
                .navigationSubtitle(termName)
                .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct SavedCoursesList: View {
    @Environment(UserDataStore.self) private var userData

    var termCode: String
    var termName: String
    var index: CatalogIndex?

    var body: some View {
        let saved = userData.savedCourses(in: termCode)
        if saved.isEmpty {
            ContentUnavailableView(
                "No saved courses",
                systemImage: "bookmark",
                description: Text("Tap the bookmark on any course to save it here.")
            )
        } else {
            List {
                BrowseSummaryRow(text: saved.count == 1 ? "1 saved course" : "\(saved.count.formatted()) saved courses")
                ForEach(saved) { item in
                    row(for: item)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(for item: SavedCourse) -> some View {
        if let index, let course = index.course(item.key) {
            BrowseCourseRow(
                termCode: termCode,
                course: course,
                stats: index.stats(for: item.key),
                saveStyle: .remove
            )
        } else {
            BrowseMissingCourseRow(
                termCode: termCode,
                key: item.key,
                note: index == nil ? "Catalog not available" : "Not in \(termName) catalog"
            )
        }
    }
}
