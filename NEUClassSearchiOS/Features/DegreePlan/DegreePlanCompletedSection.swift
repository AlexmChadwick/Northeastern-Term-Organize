//
//  DegreePlanCompletedSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The courses the audit lists as completed (it includes courses in progress), in a
/// disclosure group that starts collapsed when the list is long.
struct DegreePlanCompletedSection: View {
    var plan: DegreePlan
    var review: DegreePlanReview
    var catalog: DegreePlanCatalogSnapshot
    @Binding var isExpanded: Bool
    var actions: DegreePlanActions
    /// Where the degree requirements count a completed course, when they're set up.
    var requirementNote: (DegreePlanCourse) -> String? = { _ in nil }

    @Environment(AppRouter.self) private var router

    var body: some View {
        Section {
            if plan.completed.isEmpty {
                Label("No completed courses", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(plan.completed) { course in
                        courseRow(course)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Completed courses")
                            .font(.headline)
                        Text("\(DegreePlanText.courses(plan.completed.count)) · \(DegreePlanText.credits(plan.completedCredits))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } footer: {
            Text("The degree audit counts courses you’re taking now as completed.")
        }
    }

    @ViewBuilder
    private func courseRow(_ course: DegreePlanCourse) -> some View {
        let row = DegreePlanCourseRow(
            course: course,
            title: catalog.title(for: course),
            status: nil,
            note: review.note(for: course),
            equivalenceNote: plan.degreeEquivalenceNote(for: course.key),
            requirementNote: requirementNote(course)
        )
        let courseTermCode = course.key.flatMap { catalog.routeTermCode(for: $0) }
        Group {
            if let key = course.key, let courseTermCode {
                NavigationLink(value: AppRoute.course(termCode: courseTermCode, key: key)) { row }
            } else {
                row
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                actions.removeCompleted(course)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            if let key = course.key, let courseTermCode {
                Button {
                    router.navigate(to: .course(termCode: courseTermCode, key: key))
                } label: {
                    Label("View course", systemImage: "book")
                }
            }
            if let key = course.key {
                Button {
                    actions.addEquivalence(key)
                } label: {
                    Label("Counts as another course…", systemImage: "equal.circle")
                }
                Divider()
            }
            Button(role: .destructive) {
                actions.removeCompleted(course)
            } label: {
                Label("Remove from completed", systemImage: "trash")
            }
        }
    }
}
