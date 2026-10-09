//
//  CourseDependentsView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The "Leads to" list: the courses that mention this one among their prerequisites, in
/// two short groups so it doesn't read as though this course is needed for all of them.
///
/// "Required" comes first (their prerequisites can't be met without this course), then
/// "One option" (it is one of several ways to meet them). A long list starts with its
/// first dozen and a "Show all" chip. `dependents` arrives in display order, see
/// `CourseDependent.arranged`.
struct CourseDependentsView: View {
    var dependents: [CourseDependent]
    var termCode: String
    /// A course's title, or nil when this term's catalog doesn't list the course.
    var courseTitle: (CourseKey) -> String?

    @State private var showsAll = false

    private static let limit = 12

    /// Dependents sharing a role, which `arranged` keeps next to each other.
    private struct DependentGroup: Identifiable {
        var role: CourseDependent.Role?
        var dependents: [CourseDependent]
        var id: String { role?.rawValue ?? "other" }
    }

    private static func groups(of dependents: [CourseDependent]) -> [DependentGroup] {
        var groups: [DependentGroup] = []
        for dependent in dependents {
            if let last = groups.last, last.role == dependent.role {
                groups[groups.count - 1].dependents.append(dependent)
            } else {
                groups.append(DependentGroup(role: dependent.role, dependents: [dependent]))
            }
        }
        return groups
    }

    var body: some View {
        let limited = !showsAll && dependents.count > Self.limit
        let visible = limited ? Array(dependents.prefix(Self.limit)) : dependents
        let groups = Self.groups(of: visible)
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    if let role = group.role {
                        RequisiteGroupLabel(text: role.caption, doneText: nil)
                    }
                    CourseFlowLayout(spacing: CourseChipMetrics.spacing, lineSpacing: 0) {
                        ForEach(group.dependents) { dependent in
                            CourseCodeChip(
                                key: dependent.key,
                                title: courseTitle(dependent.key),
                                termCode: termCode,
                                note: dependent.role?.spokenNote
                            )
                        }
                        // The "Show all" chip ends the last group that is showing.
                        if limited, group.id == groups.last?.id {
                            CourseMoreChip(
                                title: "Show all \(dependents.count)",
                                accessibilityLabel: "Show all \(dependents.count) courses"
                            ) {
                                withAnimation(.snappy) { showsAll = true }
                            }
                        }
                    }
                }
            }
            if visible.contains(where: { !$0.isOffered }) {
                CourseUnofferedLegend()
            }
        }
    }
}
