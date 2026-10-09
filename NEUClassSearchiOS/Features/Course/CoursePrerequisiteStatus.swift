//
//  CoursePrerequisiteStatus.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Whether the primary degree plan already covers a course's prerequisites:
/// "You've completed the prerequisites", or what is "Still needed".
///
/// Draws nothing without a degree plan or without prerequisites to check, so
/// callers can include it unconditionally. Only show it once the course's
/// requisites are loaded: a stub course has none yet and would read as "met".
struct CoursePrerequisiteStatusLine: View {
    var prereqs: Requisite?

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Nil without a primary degree plan, or when there is nothing to check. A course counts
    /// as taken when an equivalent was (Banner's, cross-listed, or declared in the plan).
    private var status: DegreePlanAnalysis.PrerequisiteStatus? {
        guard let plan = userData.primaryDegreePlan, let tree = prereqs?.simplified() else { return nil }
        return DegreePlanAnalysis.status(
            of: tree,
            satisfiedBy: plan.completedKeys,
            equivalences: CourseInfoStore.shared.equivalences(for: plan)
        )
    }

    var body: some View {
        switch status {
        case .met:
            Label {
                Text("You've completed the prerequisites")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.subheadline.weight(.medium))
            .labelStyle(CourseInfoLabelStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("You've completed the prerequisites")
        case .missing(let needed):
            Label {
                // The prefix carries the color; the course list stays high-contrast.
                // Long expressions are cut off at regular sizes (the tree below spells
                // them out); with enlarged text nothing is truncated.
                Text("\(Text("Still needed:").foregroundStyle(.orange)) \(needed)")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline.weight(.medium))
            .labelStyle(CourseInfoLabelStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Still needed: \(needed)")
        case .unknown, nil:
            EmptyView()
        }
    }
}

/// "Based on your degree plan “Name”", linking to the plan.
struct CourseDegreePlanNote: View {
    var planID: UUID
    var planName: String

    var body: some View {
        NavigationLink(value: AppRoute.degreePlan(id: planID)) {
            // The chevron is part of the text so it follows the last line at
            // large type sizes; the no-break space keeps it with the plan name.
            Text("Based on your degree plan \(Text("“\(planName)”").foregroundStyle(.tint))\u{00A0}\(Text(Image(systemName: "chevron.right")).font(.caption2.weight(.bold)))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Based on your degree plan \(planName)")
        .accessibilityHint("Opens the degree plan")
        .accessibilityAddTraits(.isLink)
    }
}

/// A header tag saying what the primary degree plan does with a course:
/// "Completed", or "Planned · Spring 2027", and "via CS 2510" when a course that counts as
/// it is the one in the plan. Tapping it opens the plan.
struct CourseDegreePlanTag: View {
    typealias Kind = CourseDegreePlanStanding.Kind

    var planID: UUID
    var kind: Kind

    private var standing: CourseDegreePlanStanding {
        CourseDegreePlanStanding(planID: planID, kind: kind)
    }

    private var tint: Color {
        switch kind {
        case .completed: .green
        case .planned: .blue
        }
    }

    var body: some View {
        NavigationLink(value: AppRoute.degreePlan(id: planID)) {
            // Same metrics as `TagLabel`, plus a chevron because this tag is a link.
            HStack(spacing: 3) {
                Image(systemName: standing.symbol)
                    .imageScale(.small)
                Text(standing.text)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .opacity(0.7)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(standing.spokenText)
        .accessibilityHint("Opens the degree plan")
        .accessibilityAddTraits(.isLink)
    }
}

extension UserDataStore {
    /// The tag for a course: completed in the primary degree plan, else planned in one of its
    /// semesters (see `courseDegreePlanStanding(for:)`). Nil without a plan or when the plan omits
    /// the course.
    func courseDegreePlanTag(for key: CourseKey) -> CourseDegreePlanTag? {
        courseDegreePlanStanding(for: key).map { CourseDegreePlanTag(planID: $0.planID, kind: $0.kind) }
    }
}
