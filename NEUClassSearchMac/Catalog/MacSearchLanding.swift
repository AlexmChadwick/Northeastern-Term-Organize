//
//  MacSearchLanding.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the search area shows before anything is typed or filtered: examples of what can be searched,
/// recent searches, the courses viewed and saved lately, the sections being watched, the courses that
/// are filling up, quick searches, and the NUpath requirements and busiest subjects to browse.
/// The sections are cards that fall into as many columns as the window has room for: one in a narrow
/// window, three or four on a full-screen display, so the page has something to offer all the way down.
struct MacSearchLanding: View {
    var index: CatalogIndex

    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    @State private var popularSubjects: [Subject] = []
    /// Courses per NUpath attribute.
    @State private var nupathCounts: [NUPath: Int] = [:]
    /// The courses with few seats left, fewest first.
    @State private var almostFull: [Course] = []

    private let state = MacCatalogState.shared
    private var termCode: String { index.term.code }

    private var examples: [SearchExample] { SearchExampleCache.examples(for: index) }

    private var recentCourses: [Course] {
        userData.recents(in: termCode)
            .compactMap { index.course($0.key) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                MacCatalogColumns(minColumnWidth: 340, maxColumnWidth: 580, spacing: 18) {
                    examplesCard
                    recentSearchesCard
                    recentCoursesCard
                    savedCard
                    watchingCard
                    subjectsCard
                    nupathCard
                    quickSearchesCard
                    almostFullCard
                }
                Text("Course data from Northeastern University’s public registration system. Not affiliated with Northeastern University or Sandbox.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: termCode) {
            popularSubjects = index.popularSubjects(limit: 16)
            nupathCounts = Self.nupathCounts(in: index)
            almostFull = Self.almostFull(in: index)
        }
    }

    /// Courses per NUpath, counted in one pass over the catalog.
    private static func nupathCounts(in index: CatalogIndex) -> [NUPath: Int] {
        var result: [NUPath: Int] = [:]
        for course in index.courses {
            for nupath in NUPath.allCases where course.attributes.contains(nupath.attributeCode) {
                result[nupath, default: 0] += 1
            }
        }
        return result
    }

    /// Courses of a good size with a tenth of their seats or less left (and at least one), fewest left first.
    private static func almostFull(in index: CatalogIndex) -> [Course] {
        index.courses
            .compactMap { course -> (course: Course, left: Int)? in
                let stats = index.stats(for: course.key)
                guard stats.openSectionCount > 0, stats.seatCapacity >= 25, stats.seatsRemaining > 0,
                      stats.seatsRemaining * 10 <= stats.seatCapacity else { return nil }
                return (course, stats.seatsRemaining)
            }
            .sorted { lhs, rhs in lhs.left != rhs.left ? lhs.left < rhs.left : lhs.course.key < rhs.course.key }
            .prefix(7)
            .map(\.course)
    }

    // MARK: Cards

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(index.term.name)
                .font(.largeTitle.weight(.bold))
            Text("\(index.courses.count.formatted()) courses · \(index.catalog.sections.count.formatted()) sections\(index.term.isViewOnly ? " · View only" : "")")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// A titled section in a card.
    private func card<Content: View>(
        _ title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MacCatalogSectionTitle(title: title, actionTitle: actionTitle, action: action)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macCatalogCard(cornerRadius: 12)
    }

    private var examplesCard: some View {
        card("Try Searching For") {
            VStack(spacing: 2) {
                ForEach(examples) { example in
                    Button {
                        search(example.title)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: example.symbol)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 30, height: 30)
                                .background(.tint.opacity(0.14), in: .rect(cornerRadius: 7))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(example.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(example.caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 8))
                    .accessibilityLabel("\(example.caption): \(example.title)")
                    .accessibilityHint("Searches for this")
                }
            }
        }
    }

    @ViewBuilder
    private var recentSearchesCard: some View {
        let history = userData.searchHistory
        if !history.isEmpty {
            card("Recent Searches", actionTitle: "Clear") {
                userData.clearSearchHistory()
            } content: {
                CourseFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(history, id: \.self) { term in
                        Button {
                            search(term)
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentCoursesCard: some View {
        let courses = recentCourses
        if !courses.isEmpty {
            card("Jump Back In") {
                VStack(spacing: 0) {
                    ForEach(courses) { course in
                        courseRow(course.key, tint: true)
                    }
                }
            }
        }
    }

    private var savedCard: some View {
        let saved = userData.savedCourses(in: termCode)
        return card("Saved", actionTitle: saved.isEmpty ? nil : "Show All") {
            navigator.selection = .saved
        } content: {
            if saved.isEmpty {
                Label("Use the bookmark in a course window to keep the courses you're considering here.", systemImage: "bookmark")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(saved.prefix(6)) { item in
                        courseRow(item.key, tint: false)
                    }
                }
            }
        }
    }

    /// A course on one line: its code, title and how many sections are open. Opens its window.
    private func courseRow(_ key: CourseKey, tint: Bool) -> some View {
        Button {
            open(key)
        } label: {
            HStack(spacing: 12) {
                Text(key.description)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .monospacedDigit()
                    .frame(width: 84, alignment: .leading)
                if let course = index.course(key) {
                    Text(course.title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    MacCourseAvailabilityLabel(stats: index.stats(for: key))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text("Not in \(index.term.name) catalog")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 6))
        .accessibilityHint("Opens the course in its own window")
    }

    private var quickSearchesCard: some View {
        card("Quick Searches") {
            CourseFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(HomeQuickSearch.allCases) { preset in
                    Button {
                        apply(preset.filters)
                    } label: {
                        Label(preset.title, systemImage: preset.symbol)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// The sections the student watches for open seats in this term, with the seats they have now.
    @ViewBuilder
    private var watchingCard: some View {
        let items = userData.watchItems(in: termCode)
        if !items.isEmpty {
            card("Watching", actionTitle: "Show All") {
                navigator.selection = .watchlist
            } content: {
                VStack(spacing: 0) {
                    ForEach(items.prefix(6)) { item in
                        watchedRow(item)
                    }
                }
            }
        }
    }

    private func watchedRow(_ item: WatchItem) -> some View {
        let section = index.section(crn: item.crn)
        return Button {
            open(item.courseKey)
        } label: {
            HStack(spacing: 12) {
                Text(item.courseKey.description)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(width: 84, alignment: .leading)
                Text(item.sectionLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let section {
                    Text(section.seatsRemaining > 0 ? "\(section.seatsRemaining) open" : "Full")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.seatColor(for: section))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 6))
        .accessibilityHint("Opens the course in its own window")
    }

    /// Big courses that are nearly full: the ones to sign up for first.
    @ViewBuilder
    private var almostFullCard: some View {
        if !almostFull.isEmpty {
            card("Almost Full") {
                VStack(spacing: 0) {
                    ForEach(almostFull) { course in
                        let stats = index.stats(for: course.key)
                        Button {
                            open(course.key)
                        } label: {
                            HStack(spacing: 12) {
                                Text(course.code)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                    .frame(width: 84, alignment: .leading)
                                Text(course.title)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(stats.seatsRemaining) left")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.seatColor(remaining: stats.seatsRemaining, capacity: stats.seatCapacity))
                                    .monospacedDigit()
                                    .fixedSize()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 6))
                        .accessibilityLabel("\(course.code), \(course.title)")
                        .accessibilityValue("\(stats.seatsRemaining) of \(stats.seatCapacity) seats left")
                        .accessibilityHint("Opens the course in its own window")
                    }
                }
            }
        }
    }

    /// Every NUpath attribute with the number of courses that count toward it: a shortcut to those courses.
    private var nupathCard: some View {
        card("Find NUpath Courses") {
            VStack(spacing: 0) {
                ForEach(NUPath.allCases) { nupath in
                    Button {
                        var filters = SearchFilters()
                        filters.nupaths = [nupath]
                        apply(filters)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: nupath.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Self.tint(of: nupath).gradient, in: .rect(cornerRadius: 5))
                                .accessibilityHidden(true)
                            Text(nupath.name)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(nupath.short)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text((nupathCounts[nupath] ?? 0).formatted())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 6))
                    .accessibilityLabel("NUpath \(nupath.name)")
                    .accessibilityValue(CourseFormat.count(nupathCounts[nupath] ?? 0, "course"))
                    .accessibilityHint("Searches for courses that count toward it")
                }
            }
        }
    }

    private static func tint(of nupath: NUPath) -> Color {
        CourseColor.at(NUPath.allCases.firstIndex(of: nupath) ?? 0).base
    }

    /// The busiest subjects with their names and the number of courses, each a shortcut to a search.
    @ViewBuilder
    private var subjectsCard: some View {
        if !popularSubjects.isEmpty {
            card("Popular Subjects", actionTitle: "All Subjects") {
                state.subjectsMode = .subjects
                navigator.selection = .subjects
            } content: {
                VStack(spacing: 0) {
                    ForEach(popularSubjects) { subject in
                        Button {
                            var filters = SearchFilters()
                            filters.subjects = [subject.code]
                            apply(filters)
                        } label: {
                            HStack(spacing: 10) {
                                Text(subject.code)
                                    .fontWeight(.semibold)
                                    .frame(width: 54, alignment: .leading)
                                Text(subject.name)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text((index.courseCountBySubject[subject.code] ?? 0).formatted())
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 6))
                        .accessibilityLabel("\(subject.name), \(subject.code)")
                        .accessibilityValue(CourseFormat.count(index.courseCountBySubject[subject.code] ?? 0, "course"))
                        .accessibilityHint("Shows courses in this subject")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func search(_ text: String) {
        state.userBroughtOwnSearch = true
        navigator.searchText = text
    }

    /// Replaces the current search with `filters`.
    private func apply(_ filters: SearchFilters) {
        state.userBroughtOwnSearch = true
        navigator.searchText = ""
        state.filters = filters
    }

    private func open(_ key: CourseKey) {
        openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
    }
}

/// Lays its subviews out in columns, each into the shortest column so far: a single column in a narrow
/// window, as many as fit (up to four, none wider than `maxColumnWidth`) in a wide one.
struct MacCatalogColumns: Layout {
    var minColumnWidth: CGFloat = 340
    var maxColumnWidth: CGFloat = 580
    var spacing: CGFloat = 18

    private func metrics(for width: CGFloat) -> (count: Int, columnWidth: CGFloat) {
        // An unbounded proposal (measuring the ideal size) gets one column of the usual width.
        guard width.isFinite else { return (1, minColumnWidth) }
        let count = max(1, min(4, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down))))
        let columnWidth = min(maxColumnWidth, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        return (count, max(columnWidth, 0))
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let (count, columnWidth) = metrics(for: width)
        var heights = Array(repeating: CGFloat(0), count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            frames.append(CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height))
            heights[column] += height + spacing
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? minColumnWidth
        let width = proposed.isFinite ? max(proposed, minColumnWidth) : minColumnWidth
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arranged.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}

// MARK: - Card styling

extension View {
    /// A tile for a group of content: the card fill with a hairline border.
    func macCatalogCard(cornerRadius: CGFloat = 10) -> some View {
        background(Theme.cardFill, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
