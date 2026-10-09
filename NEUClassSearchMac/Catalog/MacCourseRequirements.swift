//
//  MacCourseRequirements.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Prerequisites, corequisites and the courses this course leads to, as a form of labeled rows.
///
/// Takes the course's requisites rather than a `Course`, so it also serves the window of a course the
/// loaded term doesn't list, whose requisites come from Banner's course catalog.
struct MacCourseRequirements: View {
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
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.macCourseCompact) private var compact

    var body: some View {
        // Read once: what the user completed and what counts as what.
        let completed = userData.completedCourses()
        VStack(alignment: .leading, spacing: 8) {
            Text("Requirements")
                .font(compact ? .headline : .title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if compact {
                // Little room: each title sits above its content instead of beside it.
                VStack(alignment: .leading, spacing: 12) {
                    stackedRow("Prerequisites") { prerequisiteContent(completed) }
                    Divider()
                    stackedRow("Corequisites") { requisiteContent(coreqs, title: "Corequisites", completed: completed) }
                    Divider()
                    stackedRow("Leads To") { dependentsContent }
                    if status == .unavailable {
                        Divider()
                        retryRow
                    }
                }
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 12) {
                    requirementRow("Prerequisites") { prerequisiteContent(completed) }
                    Divider().gridCellColumns(2)
                    requirementRow("Corequisites") { requisiteContent(coreqs, title: "Corequisites", completed: completed) }
                    Divider().gridCellColumns(2)
                    requirementRow("Leads To") { dependentsContent }
                    if status == .unavailable {
                        Divider().gridCellColumns(2)
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            retryRow
                        }
                    }
                }
            }
        }
    }

    private func stackedRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func requirementRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
                .gridColumnAlignment(.trailing)
                .accessibilityAddTraits(.isHeader)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Prerequisites and corequisites

    /// With a primary degree plan, the prerequisites also say whether the plan already covers them,
    /// and where that answer comes from.
    @ViewBuilder
    private func prerequisiteContent(_ completed: CompletedCourses) -> some View {
        if status == .ready, prereqs?.simplified() != nil, let plan = userData.primaryDegreePlan {
            VStack(alignment: .leading, spacing: 8) {
                MacPrerequisiteStatusLine(prereqs: prereqs)
                requisiteContent(prereqs, title: "Prerequisites", completed: completed)
                Button {
                    MacCatalogNavigation.showDegreePlan(plan.id, navigator: navigator, openWindow: openWindow)
                } label: {
                    Text("Based on your degree plan “\(plan.name)”")
                }
                .buttonStyle(.link)
                .font(.callout)
                .help("Show the degree plan in the main window")
            }
        } else {
            requisiteContent(prereqs, title: "Prerequisites", completed: completed)
        }
    }

    /// A requisite drawn by `MacRequisiteTreeView`, or the loading, unavailable and "None" states.
    /// With a degree plan, a question may follow it: "Did CS 2510 count as CS 2100?"
    @ViewBuilder
    private func requisiteContent(_ requisite: Requisite?, title: String, completed: CompletedCourses) -> some View {
        switch status {
        case .loading:
            VStack(alignment: .leading, spacing: 1) {
                Text("CS 0000")
                    .font(.callout.weight(.semibold))
                Text("Placeholder course title")
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading")
        case .unavailable:
            notLoaded
        case .ready:
            if let requisite, requisite.simplified() != nil {
                VStack(alignment: .leading, spacing: 0) {
                    MacRequisiteTreeView(
                        requisite: requisite,
                        termCode: termCode,
                        title: title,
                        courseTitle: { index.course($0)?.title },
                        completion: { completed.completion(for: $0) }
                    )
                    if userData.primaryDegreePlan != nil {
                        CourseEquivalencePrompts(requisite: requisite) { prompt, confirm, dismiss in
                            MacCourseEquivalencePromptRow(prompt: prompt, onConfirm: confirm, onDismiss: dismiss)
                        }
                    }
                }
            } else {
                none
            }
        }
    }

    private var none: some View {
        Text("None")
            .foregroundStyle(.secondary)
    }

    /// A part whose details could not be loaded; one retry control below covers all three.
    private var notLoaded: some View {
        Label("Not loaded", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
    }

    private var retryRow: some View {
        HStack(spacing: 10) {
            Label("The course details couldn't be loaded.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
            Button("Try Again", action: onRetry)
                .controlSize(.small)
        }
    }

    // MARK: Leads to

    /// The courses that mention this one among their prerequisites: the ones that need it first, then
    /// the ones where it is one option, and offered this term before the rest.
    private var dependents: [CourseDependent] {
        CourseDependent.arranged(
            postreqs,
            of: key,
            prerequisites: { index.course($0)?.prereqs },
            isOffered: { index.course($0) != nil }
        )
    }

    /// Known dependents are always shown. An empty list only reads "None" once the course's details
    /// are loaded: until then (or when they could not be loaded) it follows the same loading and
    /// unavailable states as the other two parts.
    @ViewBuilder
    private var dependentsContent: some View {
        let all = dependents
        if all.isEmpty {
            switch status {
            case .loading:
                CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        Text("CS 0000")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .quaternarySystemFill), in: .capsule)
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading")
            case .unavailable: notLoaded
            case .ready: none
            }
        } else {
            MacCourseDependentsView(
                dependents: all,
                termCode: termCode,
                courseTitle: { index.course($0)?.title }
            )
        }
    }
}

/// Whether the primary degree plan already covers a course's prerequisites: "You've completed the
/// prerequisites", or what is "Still needed".
///
/// Draws nothing without a degree plan or without prerequisites to check, so callers can include it
/// unconditionally. Only show it once the course's requisites are loaded: a stub course has none yet
/// and would read as "met".
struct MacPrerequisiteStatusLine: View {
    var prereqs: Requisite?

    @Environment(UserDataStore.self) private var userData

    /// Nil without a primary degree plan, or when there is nothing to check. A course counts as taken
    /// when an equivalent was (Banner's, cross-listed, or declared in the plan).
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
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .fontWeight(.medium)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("You've completed the prerequisites")
        case .missing(let needed):
            Label {
                // The prefix carries the color; the course list stays high-contrast.
                Text("\(Text("Still needed:").foregroundStyle(.orange)) \(needed)")
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            .fontWeight(.medium)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Still needed: \(needed)")
        case .unknown, nil:
            EmptyView()
        }
    }
}

/// One question under a requirement: the question with the reason it is asked, a button to confirm and
/// a quiet "Dismiss" that turns the guess down for good.
struct MacCourseEquivalencePromptRow: View {
    var prompt: EquivalencePrompt
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Did \(prompt.taken.description) count as \(prompt.required.description)?")
                    .fontWeight(.semibold)
                Text(prompt.evidence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button("Confirm", action: onConfirm)
                .controlSize(.small)
                .help("Save to your degree plan that \(prompt.taken.description) counts as \(prompt.required.description)")
                .accessibilityLabel("Confirm that \(prompt.taken.description) counts as \(prompt.required.description)")
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Don't suggest \(prompt.taken.description) as \(prompt.required.description) again")
                .accessibilityHint("\(prompt.taken.description) won't be suggested as \(prompt.required.description) again")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
    }
}
