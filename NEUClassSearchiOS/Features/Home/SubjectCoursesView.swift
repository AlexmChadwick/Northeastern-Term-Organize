//
//  SubjectCoursesView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The courses of one subject, with a level filter and an "open seats only"
/// toggle pinned above the list.
struct SubjectCoursesView: View {
    var termCode: String
    var subjectCode: String

    var body: some View {
        BrowseIndexReader(termCode: termCode) { index in
            let name = index?.subjectName(subjectCode)
            Group {
                if let index {
                    SubjectCoursesList(index: index, subjectCode: subjectCode)
                } else {
                    BrowseIndexUnavailable(termCode: termCode)
                }
            }
            .navigationTitle(name ?? subjectCode)
            .navigationSubtitle(name == nil || name == subjectCode ? "" : subjectCode)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct SubjectCoursesList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var index: CatalogIndex
    var subjectCode: String

    @State private var level: Int?
    @State private var openOnly = false

    var body: some View {
        let termCode = index.term.code
        let all = index.courses(inSubject: subjectCode)
        let levels = Array(Set(all.compactMap { $0.key.level })).sorted()
        let shown = all.filter { course in
            if let level, course.key.level != level { return false }
            if openOnly, index.stats(for: course.key).openSectionCount == 0 { return false }
            return true
        }
        let openShown = openOnly ? shown.count : shown.filter { index.stats(for: $0.key).openSectionCount > 0 }.count

        List {
            if !all.isEmpty {
                BrowseSummaryRow(text: browseSummaryText(shown: shown.count, total: all.count, open: openShown, openOnly: openOnly))
            }
            ForEach(shown) { course in
                BrowseCourseRow(
                    termCode: termCode,
                    course: course,
                    stats: index.stats(for: course.key)
                )
            }
        }
        .listStyle(.plain)
        .overlay {
            if all.isEmpty {
                ContentUnavailableView(
                    "No courses",
                    systemImage: "tray",
                    description: Text("\(index.subjectName(subjectCode) ?? subjectCode) has no courses in \(index.term.name).")
                )
            } else if shown.isEmpty {
                BrowseNoMatchesView(message: noMatchesMessage, showsClear: true) {
                    withAnimation(.browseSnappy(reduceMotion: reduceMotion)) {
                        level = nil
                        openOnly = false
                    }
                }
            }
        }
        .safeAreaBar(edge: .top) {
            if !all.isEmpty {
                filterBar(levels: levels)
            }
        }
    }

    /// Names the filters that are actually hiding every course.
    private var noMatchesMessage: String {
        switch (level, openOnly) {
        case let (level?, true): "No \(browseLevelNoun(level)) have open seats right now."
        case (nil, true): "None of these courses have open seats right now."
        case let (level?, false): "This subject has no \(browseLevelNoun(level))."
        case (nil, false): "No courses match these filters."
        }
    }

    private func filterBar(levels: [Int]) -> some View {
        GlassChipBar {
            BrowseOpenSeatsChip(isOn: $openOnly)
            if levels.count > 1 || level != nil {
                Menu {
                    Picker("Level", selection: $level) {
                        Text("All levels").tag(Int?.none)
                        ForEach(levels, id: \.self) { level in
                            Text(browseLevelTitle(level)).tag(Int?.some(level))
                        }
                    }
                } label: {
                    GlassChipLabel(
                        title: level.map(browseLevelTitle) ?? "Level",
                        systemImage: "square.stack.3d.up",
                        isOn: level != nil,
                        showsChevron: true
                    )
                }
                .glassChipStyle(isOn: level != nil)
                .accessibilityLabel("Course level")
                .accessibilityValue(level.map(browseLevelTitle) ?? "All levels")
            }
        }
    }
}
