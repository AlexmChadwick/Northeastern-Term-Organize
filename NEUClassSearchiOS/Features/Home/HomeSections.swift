//
//  HomeSections.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// "Jump back in": a horizontally scrolling row of recently viewed courses.
/// Renders nothing when there is nothing to show.
struct HomeRecentsSection: View {
    @Environment(UserDataStore.self) private var userData

    var termCode: String
    var index: CatalogIndex

    private let limit = 10

    private var courses: [Course] {
        userData.recents(in: termCode)
            .compactMap { index.course($0.key) }
            .prefix(limit)
            .map { $0 }
    }

    var body: some View {
        let courses = courses
        if !courses.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Spacing.m) {
                        ForEach(courses) { course in
                            HomeRecentCard(termCode: termCode, course: course, stats: index.stats(for: course.key))
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .scrollClipDisabled()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                HomeSectionHeader(title: "Jump back in")
            }
        }
    }
}

/// The first few saved courses for the term, with a link to the full list.
struct HomeSavedSection: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    var termCode: String
    var index: CatalogIndex

    private let previewLimit = 5

    var body: some View {
        let saved = userData.savedCourses(in: termCode)
        Section {
            if saved.isEmpty {
                Label("Tap the bookmark on any course to save it here.", systemImage: "bookmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Spacing.xs)
            } else {
                ForEach(saved.prefix(previewLimit)) { item in
                    row(for: item)
                }
            }
        } header: {
            HomeSectionHeader(
                title: "Saved",
                actionTitle: saved.isEmpty ? nil : "See all",
                actionAccessibilityLabel: "See all saved courses"
            ) {
                router.show(.savedCourses(termCode: termCode), in: .catalog)
            }
        }
    }

    @ViewBuilder
    private func row(for item: SavedCourse) -> some View {
        if let course = index.course(item.key) {
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
                note: "Not in \(index.term.name) catalog"
            )
        }
    }
}

/// Entry points to the directories: subjects, NUpath, professors and free rooms.
struct HomeBrowseSection: View {
    @Environment(AppRouter.self) private var router

    var termCode: String
    var index: CatalogIndex?

    var body: some View {
        Section {
            NavigationLink(value: AppRoute.subjectsDirectory(termCode: termCode)) {
                HomeBrowseRow(
                    title: "Subjects",
                    systemImage: "square.grid.2x2.fill",
                    tint: .blue,
                    detail: index.map { $0.activeSubjects.count.formatted() }
                )
            }
            .disabled(index == nil)

            NavigationLink(value: AppRoute.nupathDirectory(termCode: termCode)) {
                HomeBrowseRow(
                    title: "NUpath",
                    systemImage: "graduationcap.fill",
                    tint: .red,
                    detail: NUPath.allCases.count.formatted()
                )
            }
            .disabled(index == nil)

            NavigationLink(value: AppRoute.professorsDirectory(termCode: termCode)) {
                HomeBrowseRow(
                    title: "Professors",
                    systemImage: "person.2.fill",
                    tint: .orange,
                    detail: index.map { $0.instructors.count.formatted() }
                )
            }
            .disabled(index == nil)

            Button {
                router.selectedTab = .rooms
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    HomeBrowseRow(
                        title: "Free rooms",
                        systemImage: "door.left.hand.open",
                        tint: .green,
                        detail: index.map { "\($0.buildings.count.formatted()) buildings" }
                    )
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Rooms tab")
        } header: {
            HomeSectionHeader(title: "Browse")
        }
    }
}
