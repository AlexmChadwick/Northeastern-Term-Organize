//
//  DegreePlanSemesterSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One planned semester: a header with its credits and a menu (add a course, build a
/// schedule, remove it), then its courses with prerequisite checks.
struct DegreePlanSemesterSection: View {
    var plan: DegreePlan
    var term: DegreePlanTerm
    var review: DegreePlanReview
    var catalog: DegreePlanCatalogSnapshot
    var actions: DegreePlanActions
    /// Where the degree requirements count a course of this semester, when they're set up.
    var requirementNote: (DegreePlanCourse) -> String? = { _ in nil }
    /// What to plan instead of a course that is no longer offered: a current course it counts as.
    var replacement: (DegreePlanCourse) -> CourseKey? = { _ in nil }

    @Environment(AppRouter.self) private var router

    var body: some View {
        Section {
            if term.courses.isEmpty {
                Text("No courses yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(term.courses) { course in
                courseRow(course)
            }
            Button {
                actions.addCourse(term.id)
            } label: {
                Label("Add course", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
            }
        } header: {
            header
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(term.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(term.degreePlanSummaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: Theme.Spacing.s)
            menu
        }
        .textCase(nil)
    }

    private var menu: some View {
        Menu {
            Button {
                actions.addCourse(term.id)
            } label: {
                Label("Add course…", systemImage: "plus")
            }
            buildScheduleItem
            Divider()
            Button(role: .destructive) {
                actions.removeSemester(term.id)
            } label: {
                Label("Remove semester", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 36)
                .contentShape(.rect)
        }
        .accessibilityLabel("\(term.name) options")
    }

    /// "Build schedule…", or a disabled item that says why it can't be used yet.
    @ViewBuilder
    private var buildScheduleItem: some View {
        let hasCourses = term.courses.contains { $0.key != nil }
        let reason = catalog.scheduleUnavailableReason(for: term) ?? (hasCourses ? nil : "Add courses first")
        if let reason {
            Section(reason) {
                Button {} label: {
                    Label("Build schedule…", systemImage: "calendar.badge.plus")
                }
                .disabled(true)
            }
        } else {
            Button {
                actions.buildSchedule(term.id)
            } label: {
                Label("Build schedule…", systemImage: "calendar.badge.plus")
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func courseRow(_ course: DegreePlanCourse) -> some View {
        let row = DegreePlanCourseRow(
            course: course,
            title: catalog.title(for: course),
            status: review.status(for: course),
            note: review.note(for: course),
            catalogAvailable: review.hasCatalog,
            uncheckedReason: review.uncheckedReason(for: course),
            offeringNote: review.offeringNote(for: course),
            equivalenceNote: plan.degreeEquivalenceNote(for: course.key),
            requirementNote: requirementNote(course)
        )
        let courseTermCode = course.key.flatMap { catalog.routeTermCode(for: $0, in: term) }
        Group {
            if let key = course.key, let courseTermCode {
                NavigationLink(value: AppRoute.course(termCode: courseTermCode, key: key)) { row }
            } else {
                row
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                actions.removePlanned(course)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                actions.markCompleted(course)
            } label: {
                Label("Completed", systemImage: "checkmark.circle")
            }
            .tint(.green)
        }
        .contextMenu {
            if let key = course.key, let courseTermCode {
                Button {
                    router.navigate(to: .course(termCode: courseTermCode, key: key))
                } label: {
                    Label("View course", systemImage: "book")
                }
            }
            let others = plan.terms.filter { $0.id != term.id }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { other in
                        Button(other.name) { actions.move(course.id, other.id) }
                    }
                } label: {
                    Label("Move to", systemImage: "arrow.right.circle")
                }
            }
            Button {
                actions.markCompleted(course)
            } label: {
                Label("Mark as completed", systemImage: "checkmark.circle")
            }
            if let replacement = replacement(course) {
                Button {
                    actions.replaceCourse(course, replacement)
                } label: {
                    Label("Replace with \(replacement.description)", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let key = course.key {
                Button {
                    actions.addEquivalence(key)
                } label: {
                    Label("Counts as another course…", systemImage: "equal.circle")
                }
            }
            if review.uncheckedReason(for: course) == .failed {
                Button {
                    actions.retryChecks()
                } label: {
                    Label("Check prerequisites again", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                actions.removePlanned(course)
            } label: {
                Label("Remove from \(term.name)", systemImage: "trash")
            }
        }
    }
}
