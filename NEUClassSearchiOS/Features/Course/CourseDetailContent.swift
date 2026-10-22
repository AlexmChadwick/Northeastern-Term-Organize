//
//  CourseDetailContent.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The scrolling body of the course page once the course has been found.
struct CourseDetailContent: View {
    var course: Course
    var index: CatalogIndex
    var termCode: String
    var detailsStatus: CourseDetailsStatus
    /// Whether lazily loaded details (instructors, topic descriptions) may still arrive.
    var isLoadingDetails: Bool
    var refreshFailed: Bool
    var onRetryDetails: () -> Void
    var onRefresh: () async -> Void

    @Environment(CatalogStore.self) private var catalog
    @Environment(AppRouter.self) private var router

    private var sections: [CourseSection] { index.sections(for: course.key) }

    /// When the seat counts on screen were last refreshed: live this session, or when the catalog was built.
    private var lastUpdated: Date? {
        catalog.liveRefreshedAt[course.key] ?? index.catalog.sectionsUpdatedAt
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    CourseHeaderView(
                        course: course,
                        term: index.term,
                        hasHonorsSections: index.stats(for: course.key).hasHonors,
                        caption: CPSNote.courseCaption(sections: index.sections(for: course.key))
                    )
                    .padding(.horizontal, Theme.Spacing.l)

                    CourseActionBar(course: course, termCode: termCode, termName: index.term.name)
                        .padding(.horizontal, Theme.Spacing.l)

                    CourseDescriptionSection(course: course, status: detailsStatus, onRetry: onRetryDetails)

                    CourseRequirementsSection(
                        key: course.key,
                        prereqs: course.prereqs,
                        coreqs: course.coreqs,
                        postreqs: course.postreqs,
                        index: index,
                        termCode: termCode,
                        status: detailsStatus,
                        onRetry: onRetryDetails
                    )

                    CourseSectionsBlock(
                        course: course,
                        sections: sections,
                        termCode: termCode,
                        isLoadingDetails: isLoadingDetails,
                        lastUpdated: lastUpdated,
                        isRefreshing: catalog.refreshingCourses.contains(course.key),
                        refreshFailed: refreshFailed,
                        onRefresh: { Task { await onRefresh() } },
                        scrollTo: { crn in
                            withAnimation(.snappy) { proxy.scrollTo(crn, anchor: .center) }
                        },
                        // Menus push through the router, like the rest of the app.
                        onNavigate: { router.navigate(to: $0) }
                    )
                }
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.xl)
                .courseReadableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await onRefresh() }
        }
        .courseLoadsEquivalents(for: namedCourses)
    }

    /// This course and the ones its requirements name: whether the user's completed courses
    /// count for them depends on equivalences the course store has to look up.
    private var namedCourses: [CourseKey] {
        [course.key] + (course.prereqs?.referencedCourses ?? []) + (course.coreqs?.referencedCourses ?? [])
    }
}
