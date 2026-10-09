//
//  DegreeRequirementsCatalogRows.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Course row

/// A titled action a row can offer in its menus.
struct DegreeRowAction {
    var title: String
    var systemImage: String?
    var action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

/// One course the catalog lists, annotated with where it stands in the plan: code, title and
/// credits, and a status chip. Courses that count toward the requirement are emphasized.
/// For a course that isn't in the plan, the chip opens a menu to add it to a semester or to
/// count another course instead.
///
/// A course counted by substitution is marked as one. One the requirement doesn't list
/// (`Connector.substitution`) is indented under the requirement it replaces, behind an arrow, and
/// starts with "Substitution for <requirement>", so it reads as part of that requirement and never
/// as a requirement of its own. One the requirement lists carries a "Substitution" tag.
struct DegreeCatalogCourseRow: View {
    enum Connector: String {
        case and, or
        /// A course counted by substitution that the requirement doesn't list.
        case substitution
    }

    var key: CourseKey
    var title: String?
    var credits: Double?
    /// `and` for a course taken together with the one above, `or` for an alternative.
    var connector: Connector?
    var status: DegreeCourseStatus
    /// The audit counts this course toward the requirement shown.
    var isCountedHere: Bool
    var bySubstitution = false
    var isWaived = false
    /// e.g. `Counts toward Khoury Elective Courses`, or a substitution's note.
    var caption: String?
    /// The course "Add to plan" adds, when it isn't this one (a current equivalent of a course
    /// that is no longer offered).
    var addKey: CourseKey?
    /// Semesters "Add to plan" offers.
    var addTargets: [DegreePlanTerm] = []
    var onOpen: () -> Void
    var onAdd: ((DegreePlanTerm) -> Void)?
    var onCountCourse: (() -> Void)?
    /// Opens the course's page.
    var onViewCourse: (() -> Void)?
    /// "Same course, different number…" for a listed course the plan may have under another
    /// number.
    var equivalenceAction: DegreeRowAction?
    /// What else a course counted by substitution offers: edit the substitution, or make it the
    /// same course under a new number.
    var substitutionActions: [DegreeRowAction] = []
    /// The requirement a `Connector.substitution` row replaces, by its name (`CS 4500 or CS 4530`).
    var substitutionFor: String?
    /// Tapping opens the requirement (on the requirements page; in a requirement's own sheet,
    /// tapping opens the course instead).
    var opensRequirement = true

    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 18
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isSubstituteChild: Bool { connector == .substitution }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            if isSubstituteChild {
                Image(systemName: "arrow.turn.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.indigo)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if isSubstituteChild {
                    Text(substitutionFor.map { "Substitution for \($0)" } ?? "Substitution")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.indigo)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 1)
                }
                // The status chip shares only the code's line (stacking under it when there's no
                // room), so titles and notes get the full width.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        codeLine
                        Spacer(minLength: Theme.Spacing.s)
                        statusControl
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        codeLine
                        statusControl
                    }
                }
                if let detailLine {
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, isSubstituteChild ? min(indent, DegreeSuggestionRow.maxIndent) : 0)
        .padding(.vertical, 1)
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        // One element for VoiceOver; adding or substituting are its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(opensRequirement ? "Shows the requirement" : "Shows the course")
        .accessibilityAction(.default, onOpen)
        .contextMenu {
            if let onViewCourse {
                Button("View course", systemImage: "book", action: onViewCourse)
            }
            if opensRequirement {
                Button("Requirement details", systemImage: "checklist", action: onOpen)
            }
            if showsMenu {
                Divider()
                if let onAdd, !addTargets.isEmpty {
                    Menu(addKey.flatMap { $0 == key ? nil : "Add \($0.description) to plan" } ?? "Add to plan", systemImage: "calendar.badge.plus") {
                        ForEach(addTargets, id: \.name) { term in
                            Button(term.shortName) { onAdd(term) }
                        }
                    }
                }
                if let onCountCourse {
                    Button("Count another course toward this…", systemImage: "arrow.left.arrow.right", action: onCountCourse)
                }
            }
            if let equivalenceAction {
                Button(equivalenceAction.title, systemImage: "equal.circle", action: equivalenceAction.action)
            }
            if !substitutionActions.isEmpty {
                Divider()
                ForEach(substitutionActions.indices, id: \.self) { index in
                    let action = substitutionActions[index]
                    Button(action.title, systemImage: action.systemImage ?? "arrow.left.arrow.right", action: action.action)
                }
            }
        }
        .accessibilityActions {
            if let onViewCourse {
                Button("View course", action: onViewCourse)
            }
            ForEach(substitutionActions.indices, id: \.self) { index in
                Button(substitutionActions[index].title, action: substitutionActions[index].action)
            }
            if showsMenu {
                if let onAdd {
                    ForEach(addTargets, id: \.name) { term in
                        Button("Add \((addKey ?? key).description) to \(term.shortName)") { onAdd(term) }
                    }
                }
                if let onCountCourse {
                    Button("Count another course toward this", action: onCountCourse)
                }
            }
            if let equivalenceAction {
                Button(equivalenceAction.title, action: equivalenceAction.action)
            }
        }
    }

    private var isEmphasized: Bool { isCountedHere || bySubstitution }

    private var showsMenu: Bool {
        !isWaived && !bySubstitution && status == .notInPlan && (onAdd != nil || onCountCourse != nil || equivalenceAction != nil)
    }

    /// The code with its connector and, for a listed course counted by substitution, the tag; the tag
    /// moves under the code when they don't fit on a line.
    private var codeLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 5) { codeParts }
                .fixedSize()
            VStack(alignment: .leading, spacing: 4) { codeParts }
                .fixedSize()
        }
    }

    @ViewBuilder
    private var codeParts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let connector, !isSubstituteChild {
                Text(connector.rawValue)
                    .font(.footnote.italic())
                    .foregroundStyle(Color.secondary)
            }
            Text(key.description)
                .font(.body.weight(isEmphasized ? .semibold : .regular))
                .foregroundStyle(status.isInPlan || bySubstitution ? Color.primary : Color.secondary)
                .monospacedDigit()
        }
        if bySubstitution, !isWaived, !isSubstituteChild {
            statusLabel("Substitution", color: .indigo, isProminent: true)
                .accessibilityHidden(true)
        }
    }

    /// A status as a chip; at accessibility text sizes, colored text that wraps instead, since a
    /// chip can't and would run past the row's edge.
    @ViewBuilder
    private func statusLabel(_ text: String, color: Color, isProminent: Bool, showsMenuIndicator: Bool = false) -> some View {
        if typeSize.isAccessibilitySize {
            HStack(spacing: 4) {
                Text(text)
                    .multilineTextAlignment(.leading)
                if showsMenuIndicator {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isProminent ? color : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            DegreeStatusChip(text: text, color: color, isProminent: isProminent, showsMenuIndicator: showsMenuIndicator)
        }
    }

    /// `Algorithms and Data · 4 credits`.
    private var detailLine: String? {
        let parts = [title, credits.map(DegreePlanText.credits)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusControl: some View {
        if isWaived {
            statusLabel("Waived", color: .gray, isProminent: false)
                .accessibilityHidden(true)
        } else if showsMenu {
            Menu {
                if let onAdd, !addTargets.isEmpty {
                    Section("Add \((addKey ?? key).description) to") {
                        ForEach(addTargets, id: \.name) { term in
                            Button(term.shortName) { onAdd(term) }
                        }
                    }
                }
                if let onCountCourse {
                    Button("Count another course toward this…", systemImage: "arrow.left.arrow.right", action: onCountCourse)
                }
                if let equivalenceAction {
                    Button(equivalenceAction.title, systemImage: "equal.circle", action: equivalenceAction.action)
                }
            } label: {
                statusLabel(status.label, color: status.color, isProminent: false, showsMenuIndicator: true)
            }
            .accessibilityHidden(true)
        } else {
            statusLabel(status.label, color: status.color, isProminent: isCountedHere)
                .accessibilityHidden(true)
        }
    }

    private var spokenLabel: String {
        var parts = [key.description]
        if let title { parts.append(title) }
        if isWaived {
            parts.append("waived")
        } else {
            parts.append(status.spoken)
            if isSubstituteChild { parts.append(substitutionFor.map { "substitution for \($0)" } ?? "substitution") }
            else if bySubstitution { parts.append("substitution") }
            else if isCountedHere { parts.append("counts toward this requirement") }
        }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Rule header

/// The heading of a list of options or an hours requirement: the catalog's wording
/// (`Complete one of the following`), progress (`1 of 1 done`, `Needs 4 more semester hours`)
/// and any petition or waiver.
struct DegreeRuleHeaderRow: View {
    var title: String
    /// A second line: what a petition replaced the requirement with.
    var wording: String?
    var progress: String
    var status: DegreeAudit.Status
    /// `Petition`, for a requirement replaced by petition.
    var badge: String?
    /// Substitution notes and the area's notes.
    var details: [String] = []
    var action: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                DegreeStatusIcon(status: status)
                    .font(.body)
                    .frame(width: iconWidth)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                        if let badge {
                            DegreeStatusChip(text: badge, color: .indigo, isProminent: true)
                        }
                    }
                    if let wording {
                        Text(wording)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Text(progress)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(status.degreeColor)
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title, badge.map { _ in "replaced by petition" }, status.degreeLabel, wording, progress].compactMap { $0 } + details).joined(separator: ", "))
        .accessibilityHint("Shows the requirement")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Other rows

/// An area header within a section, like the catalog's shaded rows (`Computer Science
/// Required Courses`).
struct DegreeAreaHeaderRow: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.vertical, 1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A category subheader within a list of options (`Biology`), as the catalog shows them.
struct DegreeCategoryRow: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .italic()
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Show all 22 options" under a long list that shows only the options that matter.
struct DegreeListDisclosureRow: View {
    var total: Int
    var isExpanded: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(isExpanded ? "Show fewer options" : "Show all \(total) options")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
    }
}

/// A range of course numbers a requirement accepts (`CS 2500 or higher, except CS 5010`).
struct DegreeRangeRow: View {
    var label: String

    var body: some View {
        Label {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "number")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Any course in \(label)")
    }
}
