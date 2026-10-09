//
//  MacCatalogCoursePreview.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The pane beside a table of courses: the course that is selected, as its whole page (description,
/// requirements, the sections table…), laid out for the width the pane has. What the table's columns
/// have no room for, without opening a window for every course that is looked at; a double-click on a
/// row still opens the window.
struct MacCatalogCoursePreview: View {
    /// The courses selected in the table.
    var selection: Set<CourseKey>
    var termCode: String

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Course preview")
    }

    @ViewBuilder
    private var content: some View {
        if selection.count == 1, let key = selection.first {
            MacCourseWindow(value: CourseWindowValue(termCode: termCode, key: key), presentation: .pane)
                // A new course starts afresh: its own section selection, filters and scroll position.
                .id(key)
        } else if selection.isEmpty {
            ContentUnavailableView(
                "No Course Selected",
                systemImage: "book.closed",
                description: Text("Select a course to see its page here. Double-click one to open it in its own window.")
            )
        } else {
            ContentUnavailableView(
                "\(selection.count) Courses Selected",
                systemImage: "books.vertical",
                description: Text("Select a single course to see its page here.")
            )
        }
    }
}
