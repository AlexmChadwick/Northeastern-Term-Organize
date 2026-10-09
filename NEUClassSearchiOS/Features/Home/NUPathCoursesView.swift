//
//  NUPathCoursesView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Courses that satisfy one NUpath, grouped by subject, with a subject filter
/// and an "open seats only" toggle pinned above the list.
struct NUPathCoursesView: View {
    var termCode: String
    var nupath: NUPath

    var body: some View {
        BrowseIndexReader(termCode: termCode) { index in
            Group {
                if let index {
                    NUPathCoursesList(index: index, nupath: nupath)
                } else {
                    BrowseIndexUnavailable(termCode: termCode)
                }
            }
            .navigationTitle(nupath.name)
            .navigationSubtitle(nupath.short)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct NUPathCoursesList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var index: CatalogIndex
    var nupath: NUPath

    @State private var subject: String?
    @State private var openOnly = false

    var body: some View {
        let termCode = index.term.code
        let all = index.courses(with: nupath)
        let shown = all.filter { course in
            if let subject, course.subject != subject { return false }
            if openOnly, index.stats(for: course.key).openSectionCount == 0 { return false }
            return true
        }
        let openShown = openOnly ? shown.count : shown.filter { index.stats(for: $0.key).openSectionCount > 0 }.count
        let groups = Dictionary(grouping: shown, by: \.subject)
        let subjectCodes = groups.keys.sorted()

        List {
            if !all.isEmpty {
                BrowseSummaryRow(text: browseSummaryText(shown: shown.count, total: all.count, open: openShown, openOnly: openOnly))
            }
            ForEach(subjectCodes, id: \.self) { code in
                Section {
                    ForEach(groups[code] ?? []) { course in
                        BrowseCourseRow(
                            termCode: termCode,
                            course: course,
                            stats: index.stats(for: course.key)
                        )
                    }
                } header: {
                    sectionHeader(code: code, count: groups[code]?.count ?? 0)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if all.isEmpty {
                ContentUnavailableView(
                    "No courses",
                    systemImage: "tray",
                    description: Text("No courses in \(index.term.name) carry \(nupath.name).")
                )
            } else if shown.isEmpty {
                BrowseNoMatchesView(message: noMatchesMessage, showsClear: true) {
                    withAnimation(.browseSnappy(reduceMotion: reduceMotion)) {
                        subject = nil
                        openOnly = false
                    }
                }
            }
        }
        .safeAreaBar(edge: .top) {
            if !all.isEmpty {
                filterBar(all: all)
            }
        }
    }

    /// Names the filters that are actually hiding every course.
    private var noMatchesMessage: String {
        switch (subject, openOnly) {
        case let (subject?, true): "No \(subject) courses with \(nupath.short) have open seats right now."
        case (nil, true): "None of these courses have open seats right now."
        case let (subject?, false): "No \(subject) courses carry \(nupath.short) this term."
        case (nil, false): "No courses match these filters."
        }
    }

    private func sectionHeader(code: String, count: Int) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(headerTitle(code: code))
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            Text(count.formatted())
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func headerTitle(code: String) -> String {
        if let name = index.subjectName(code), name != code { return "\(code) · \(name)" }
        return code
    }

    private func filterBar(all: [Course]) -> some View {
        let counts = Dictionary(grouping: all, by: \.subject).mapValues(\.count)
        let codes = counts.keys.sorted()
        return GlassChipBar {
            BrowseOpenSeatsChip(isOn: $openOnly)
            if codes.count > 1 || subject != nil {
                Menu {
                    Picker("Subject", selection: $subject) {
                        Text("All subjects").tag(String?.none)
                        ForEach(codes, id: \.self) { code in
                            Text("\(headerTitle(code: code)) (\(counts[code] ?? 0))").tag(String?.some(code))
                        }
                    }
                } label: {
                    GlassChipLabel(
                        title: subject ?? "Subject",
                        systemImage: "square.grid.2x2",
                        isOn: subject != nil,
                        showsChevron: true
                    )
                }
                .glassChipStyle(isOn: subject != nil)
                .accessibilityLabel("Subject")
                .accessibilityValue(subject ?? "All subjects")
            }
        }
    }
}
