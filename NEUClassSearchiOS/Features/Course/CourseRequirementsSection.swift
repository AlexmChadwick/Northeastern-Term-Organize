//
//  CourseRequirementsSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Prerequisites, corequisites and the courses this course leads to.
///
/// Takes the course's requisites rather than a `Course`, so it also serves the page of a course the
/// loaded term doesn't list, whose requisites come from Banner's course catalog.
struct CourseRequirementsSection: View {
    var key: CourseKey
    var prereqs: Requisite?
    var coreqs: Requisite?
    /// The courses whose prerequisites mention this one.
    var postreqs: [CourseKey]
    var index: CatalogIndex
    var termCode: String
    var status: CourseDetailsStatus
    var onRetry: () -> Void

    @Environment(UserDataStore.self) private var userData

    var body: some View {
        // Read once: what the user completed and what counts as what.
        let completed = userData.completedCourses()
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Requirements")
                .padding(.horizontal, Theme.Spacing.l)
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                part(title: "Prerequisites") { prerequisiteContent(completed) }
                Divider()
                part(title: "Corequisites") { requisiteContent(coreqs, title: "Corequisites", completed: completed) }
                Divider()
                part(title: "Leads to") { dependentsContent }
                if status == .unavailable {
                    Divider()
                    retryRow
                }
            }
            .courseCard()
            .padding(.horizontal, Theme.Spacing.l)
        }
    }

    private func part<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Prerequisites and corequisites

    /// With a primary degree plan, the prerequisites also say whether the plan
    /// already covers them, and where that answer comes from.
    @ViewBuilder
    private func prerequisiteContent(_ completed: CompletedCourses) -> some View {
        if status == .ready, prereqs?.simplified() != nil, let plan = userData.primaryDegreePlan {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                CoursePrerequisiteStatusLine(prereqs: prereqs)
                requisiteContent(prereqs, title: "Prerequisites", completed: completed)
                CourseDegreePlanNote(planID: plan.id, planName: plan.name)
            }
        } else {
            requisiteContent(prereqs, title: "Prerequisites", completed: completed)
        }
    }

    /// A requisite drawn by `RequisiteTreeView`, or the loading, unavailable and "None"
    /// states. `title` names it for VoiceOver ("Prerequisites: either ..."). With a degree
    /// plan, a question may follow it: "Did CS 2510 count as CS 2100?"
    @ViewBuilder
    private func requisiteContent(_ requisite: Requisite?, title: String, completed: CompletedCourses) -> some View {
        switch status {
        case .loading:
            VStack(alignment: .leading, spacing: 2) {
                Text("CS 0000")
                    .font(.subheadline.weight(.semibold))
                Text("Placeholder course title")
                    .font(.footnote)
            }
            .padding(.vertical, 9)
            .courseShimmer(isActive: true)
        case .unavailable:
            unavailable
        case .ready:
            if let requisite, requisite.simplified() != nil {
                VStack(alignment: .leading, spacing: 0) {
                    RequisiteTreeView(
                        requisite: requisite,
                        termCode: termCode,
                        title: title,
                        courseTitle: { index.course($0)?.title },
                        completion: { completed.completion(for: $0) }
                    )
                    if userData.primaryDegreePlan != nil {
                        CourseEquivalencePrompts(requisite: requisite)
                    }
                }
            } else {
                noneLabel
            }
        }
    }

    private var noneLabel: some View {
        Text("None")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// A part whose details could not be loaded; one retry control below covers all three.
    private var unavailable: some View {
        Label("Not loaded", systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var retryRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label("The course details couldn't be loaded.", systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again", action: onRetry)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Leads to

    /// The courses that mention this one among their prerequisites: the ones that need it
    /// first, then the ones where it is one option, and offered this term before the rest.
    private var dependents: [CourseDependent] {
        CourseDependent.arranged(
            postreqs,
            of: key,
            prerequisites: { index.course($0)?.prereqs },
            isOffered: { index.course($0) != nil }
        )
    }

    /// Placeholder chips shown while the course's details are on their way.
    private var dependentsPlaceholder: some View {
        CourseFlowLayout(spacing: CourseChipMetrics.spacing, lineSpacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                Text("CS 0000")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, CourseChipMetrics.horizontalPadding)
                    .padding(.vertical, CourseChipMetrics.verticalPadding)
                    .background(Color(.tertiarySystemFill), in: .capsule)
                    .padding(.vertical, CourseChipMetrics.hitInset)
            }
        }
        .courseShimmer(isActive: true)
    }

    /// Known dependents are always shown. An empty list only reads "None" once the
    /// course's details are loaded: until then (or when they could not be loaded)
    /// it follows the same loading and unavailable states as the other two parts.
    @ViewBuilder
    private var dependentsContent: some View {
        let all = dependents
        if all.isEmpty {
            switch status {
            case .loading: dependentsPlaceholder
            case .unavailable: unavailable
            case .ready: noneLabel
            }
        } else {
            CourseDependentsView(
                dependents: all,
                termCode: termCode,
                courseTitle: { index.course($0)?.title }
            )
        }
    }
}
