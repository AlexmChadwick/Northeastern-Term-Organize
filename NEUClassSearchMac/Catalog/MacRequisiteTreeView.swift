//
//  MacRequisiteTreeView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The presentation of requisite trees (nested "all of" / "one of" groups of courses and tests)
//  follows the structure of SearchNEU's Requisites.tsx
//  (https://github.com/sandboxnu/searchneu, apps/searchneu/components/catalog),
//  Copyright (C) Sandbox at Northeastern University and the SearchNEU contributors, licensed under
//  the GNU Affero General Public License v3. The iPhone and iPad drawing is
//  NEUClassSearchiOS/Features/Course/RequisiteTreeView.swift.
//  Modified 2026-10-04: reimplemented natively in SwiftUI for the Mac: courses are buttons that open a
//  course window, with hover states and context menus.
//

import SwiftUI

/// Renders a prerequisite or corequisite so its logic reads at a glance.
///
/// `RequisiteLayout` (see `RequisiteOutline.swift`) decides the shape; this draws it:
/// - one course or test: a row, a button that opens the course,
/// - courses grouped: "One of" or "All of these" over a line of chips,
/// - an "and" that mixes courses with choices: a checklist of those parts,
/// - an "or" with compound branches: numbered options joined by "or".
///
/// Completed courses carry a green check, and a group they satisfy says "Done with CS 2510".
struct MacRequisiteTreeView: View {
    var requisite: Requisite
    var termCode: String
    /// What the requirement is called in the sentence VoiceOver reads ("Prerequisites").
    var title: String
    /// A course's title, or nil when this term's catalog doesn't list the course.
    var courseTitle: (CourseKey) -> String?
    /// Whether the user has completed a course, and which course counted when it was a different one.
    var completion: (CourseKey) -> (isComplete: Bool, via: CourseKey?) = { _ in (false, nil) }

    var body: some View {
        if let layout = RequisiteLayout(requisite, isOffered: { courseTitle($0) != nil }, completion: completion) {
            VStack(alignment: .leading, spacing: 8) {
                MacRequisiteLayoutView(
                    layout: layout,
                    context: MacRequisiteContext(termCode: termCode, courseTitle: courseTitle),
                    spoken: layout.spokenDescription(title: title)
                )
                if layout.hasGreyedOutChips {
                    MacRequisiteUnofferedLegend()
                }
            }
        } else {
            Text("None")
                .foregroundStyle(.secondary)
        }
    }
}

/// What the requisite views need to know about the term around them.
private struct MacRequisiteContext {
    var termCode: String
    var courseTitle: (CourseKey) -> String?
}

/// Explains grey chips: a course this term's catalog doesn't list has no sections, though it still
/// opens to its catalog entry.
struct MacRequisiteUnofferedLegend: View {
    var body: some View {
        Text("Courses in gray aren't offered this term.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

// MARK: - Layouts

private struct MacRequisiteLayoutView: View {
    var layout: RequisiteLayout
    var context: MacRequisiteContext
    /// The whole requirement as a sentence, read by VoiceOver on the heading.
    var spoken: String

    var body: some View {
        switch layout {
        case .item(let item):
            MacRequisiteItemRow(item: item, context: context)
        case .group(let group):
            VStack(alignment: .leading, spacing: 5) {
                MacRequisiteHeading(text: group.headline, doneText: group.doneText, spoken: spoken)
                MacRequisiteChips(items: group.items, collapses: group.kind == .oneOf, context: context)
            }
        case .checklist(let checklist):
            VStack(alignment: .leading, spacing: 8) {
                MacRequisiteHeading(text: checklist.headline, doneText: checklist.isDone ? "Done" : nil, spoken: spoken)
                MacRequisitePartsView(parts: checklist.parts, context: context)
            }
        case .paths(let paths):
            VStack(alignment: .leading, spacing: 0) {
                MacRequisiteHeading(text: "Meet one of these", doneText: nil, spoken: spoken)
                    .padding(.bottom, 8)
                ForEach(Array(paths.enumerated()), id: \.offset) { position, path in
                    if position > 0 {
                        MacRequisiteOrDivider()
                    }
                    MacRequisiteOptionBox(number: position + 1, path: path, context: context)
                }
            }
        }
    }
}

/// The parts of a checklist, one under the other, each its own requirement.
private struct MacRequisitePartsView: View {
    var parts: [RequisitePart]
    var context: MacRequisiteContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { position, part in
                if position > 0 {
                    Divider()
                        .padding(.vertical, 6)
                }
                partView(part)
            }
        }
    }

    @ViewBuilder
    private func partView(_ part: RequisitePart) -> some View {
        switch part {
        case .item(let item):
            MacRequisiteItemRow(item: item, context: context, compact: true)
        case .group(let group):
            VStack(alignment: .leading, spacing: 3) {
                // Loose required courses need no label: the heading above says "all".
                if group.kind == .oneOf {
                    MacRequisiteGroupLabel(text: group.headline, doneText: group.doneText)
                }
                MacRequisiteChips(items: group.items, collapses: group.kind == .oneOf, context: context)
            }
        case .expression(let node):
            VStack(alignment: .leading, spacing: 3) {
                // Like the groups beside it, a compound choice says what it is.
                if case .oneOf = node {
                    MacRequisiteGroupLabel(text: "One of", doneText: node.doneText)
                }
                MacRequisiteInlineExpression(node: node, context: context)
            }
        }
    }
}

// MARK: - Options

/// One way to meet an "or": a tinted block with its own heading, between "or" dividers.
private struct MacRequisiteOptionBox: View {
    var number: Int
    var path: RequisitePath
    var context: MacRequisiteContext

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill), in: shape)
        .overlay {
            if path.isDone {
                shape.strokeBorder(Color.green.opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 2) {
            title
            if path.isDone {
                MacRequisiteDoneLabel(text: "Done")
            }
        }
        .accessibilityHidden(true)
    }

    /// "Option 1 · Both of these".
    private var title: Text {
        let name = Text("Option \(number)")
            .font(.callout.weight(.semibold))
        guard let qualifier = path.qualifier else { return name }
        let detail = Text("· \(qualifier)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
        return Text("\(name) \(detail)")
    }

    @ViewBuilder
    private var content: some View {
        switch path.content {
        case .item(let item):
            MacRequisiteItemRow(item: item, context: context, compact: true)
        case .group(let group):
            MacRequisiteChips(items: group.items, collapses: group.kind == .oneOf, context: context)
        case .checklist(let checklist):
            MacRequisitePartsView(parts: checklist.parts, context: context)
        }
    }
}

/// A hairline, "or" and another hairline, between two options.
private struct MacRequisiteOrDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            line
            Text("or")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            line
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
    }
}

// MARK: - Labels

/// The heading of a requirement. VoiceOver reads `spoken` (the whole requirement as a sentence) in its
/// place, so the structure around it is hidden from VoiceOver.
private struct MacRequisiteHeading: View {
    var text: String
    var doneText: String?
    var spoken: String

    var body: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 2) {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let doneText {
                MacRequisiteDoneLabel(text: doneText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The small label over a group of chips: "One of" in a requirement, "Required" in "Leads to". It is
/// decoration for VoiceOver, which reads the chips themselves.
struct MacRequisiteGroupLabel: View {
    var text: String
    var doneText: String?

    var body: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 2) {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let doneText {
                MacRequisiteDoneLabel(text: doneText)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A green check and a few words: "Done", "Done with CS 2510".
private struct MacRequisiteDoneLabel: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
    }
}

// MARK: - Chips

/// A wrapping line of chips for a group of courses and tests. A long "one of" list starts with its
/// first few and a "Show all" button (completed courses come first).
private struct MacRequisiteChips: View {
    var items: [RequisiteItem]
    var collapses: Bool
    var context: MacRequisiteContext

    @State private var isExpanded = false

    private static let collapseThreshold = 12
    private static let collapsedCount = 10

    private var isLong: Bool { collapses && items.count > Self.collapseThreshold }

    var body: some View {
        let visible = isLong && !isExpanded ? Array(items.prefix(Self.collapsedCount)) : items
        CourseFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(visible) { item in
                MacRequisiteChip(item: item, context: context)
            }
            if isLong {
                MacCatalogMoreChip(title: isExpanded ? "Show Fewer" : "Show All \(items.count)") {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
            }
        }
    }
}

private struct MacRequisiteChip: View {
    var item: RequisiteItem
    var context: MacRequisiteContext

    var body: some View {
        switch item.kind {
        case .course(let key):
            MacCatalogCourseChip(
                key: key,
                title: context.courseTitle(key),
                termCode: context.termCode,
                isComplete: item.isComplete,
                via: item.via
            )
        case .test(let name, _):
            MacRequisiteTestChip(name: name, scoreText: item.scoreText)
        }
    }
}

/// A course code in a capsule that opens the course in a window. When this term's catalog doesn't
/// list the course (`title` is nil) it is greyed out and opens its catalog entry instead, a page
/// without sections.
struct MacCatalogCourseChip: View {
    var key: CourseKey
    /// The course's title, or nil when this term's catalog doesn't list the course.
    var title: String?
    var termCode: String
    var isComplete = false
    /// The course that counted when it was not this one (course equivalences).
    var via: CourseKey?
    /// Words VoiceOver adds at the end, for what the chip's surroundings say but its text doesn't.
    var note: String?

    @Environment(\.openWindow) private var openWindow
    @State private var isHovering = false

    private var spokenSuffix: String {
        var suffix = ""
        if isComplete {
            suffix += via.map { ", completed via \($0.description)" } ?? ", completed"
        }
        if let note {
            suffix += ", \(note)"
        }
        return suffix
    }

    private var helpText: String {
        guard let title else { return "\(key.description) isn't offered this term. Open its catalog entry" }
        return isComplete ? "\(key.description), \(title). \(via.map { "Completed via \($0.description)" } ?? "Completed")" : "\(key.description), \(title)"
    }

    var body: some View {
        Button {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
        } label: {
            HStack(spacing: 4) {
                if isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.green)
                }
                Text(key.description)
            }
            .font(.callout.weight(title == nil ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: .capsule)
            .overlay(Capsule().fill(Color.primary.opacity(isHovering ? 0.08 : 0)).allowsHitTesting(false))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .contextMenu {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
            }
            Button("Copy Course Code", systemImage: "doc.on.doc") { MacCatalogClipboard.copy(key.description) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "\(key.description), \($0)\(spokenSuffix)" }
                            ?? "\(key.description), not offered this term\(spokenSuffix)")
        .accessibilityInputLabels([key.description])
        .accessibilityHint(title == nil ? "Opens its catalog entry" : "Opens the course")
        .accessibilityAddTraits(.isLink)
    }

    private var foreground: AnyShapeStyle {
        if isComplete { return AnyShapeStyle(.primary) }
        return title == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)
    }

    private var background: Color {
        if isComplete { return Color.green.opacity(0.16) }
        return title == nil ? Color(nsColor: .quaternarySystemFill) : Color.accentColor.opacity(0.12)
    }
}

/// A placement test or other non-course condition, outlined so it isn't mistaken for a course that
/// isn't offered.
private struct MacRequisiteTestChip: View {
    var name: String
    var scoreText: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal")
                .imageScale(.small)
            Text(scoreText.map { "\(name) · min. \($0)" } ?? name)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scoreText.map { "\(name), minimum score \($0)" } ?? name)
    }
}

/// The outlined "Show All 12" / "Show Fewer" capsule at the end of a long list of chips.
struct MacCatalogMoreChip: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inline expressions

/// A requirement too deep for boxes, as one wrapping line: `ME 4550 or ME 4570 or (IE 4510 and
/// IE 4515)`. Each course is still a chip you can click; a group inside another is outlined, which
/// does the work of parentheses.
private struct MacRequisiteInlineExpression: View {
    var node: RequisiteNode
    var context: MacRequisiteContext

    var body: some View {
        switch node {
        case .item(let item):
            MacRequisiteChip(item: item, context: context)
        case .all(let members):
            joined(members, by: "and")
        case .oneOf(let members):
            joined(members, by: "or")
        }
    }

    private func joined(_ members: [RequisiteNode], by word: String) -> some View {
        CourseFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(members.enumerated()), id: \.offset) { position, member in
                // The word travels with the member after it, so a line never ends on "or".
                HStack(spacing: 6) {
                    if position > 0 {
                        Text(word)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    memberView(member)
                }
            }
        }
    }

    @ViewBuilder
    private func memberView(_ member: RequisiteNode) -> some View {
        if case .item = member {
            MacRequisiteInlineExpression(node: member, context: context)
        } else {
            MacRequisiteInlineExpression(node: member, context: context)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                )
        }
    }
}

// MARK: - Rows

/// One required course or test: a row with the course's title, a button that opens the course.
private struct MacRequisiteItemRow: View {
    var item: RequisiteItem
    var context: MacRequisiteContext
    /// Tighter rows for inside a checklist or option.
    var compact = false

    var body: some View {
        switch item.kind {
        case .course(let key):
            MacRequisiteCourseRow(
                key: key,
                title: context.courseTitle(key),
                termCode: context.termCode,
                isComplete: item.isComplete,
                via: item.via,
                compact: compact
            )
        case .test(let name, _):
            MacRequisiteTestRow(name: name, scoreText: item.scoreText, compact: compact)
        }
    }
}

private struct MacRequisiteCourseRow: View {
    var key: CourseKey
    /// The course's title, or nil when this term's catalog doesn't list the course.
    var title: String?
    var termCode: String
    var isComplete: Bool
    var via: CourseKey?
    var compact: Bool

    @Environment(\.openWindow) private var openWindow

    private var completedText: String {
        via.map { "Completed via \($0.description)" } ?? "Completed"
    }

    private var completedSpoken: String {
        guard isComplete else { return "" }
        return via.map { ", completed via \($0.description)" } ?? ", completed"
    }

    var body: some View {
        Button {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    CourseFlowLayout(spacing: 8, lineSpacing: 2) {
                        Text(key.description)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(title == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        if isComplete {
                            Label(completedText, systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    if let title {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text("Not offered this term")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, compact ? 2 : 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MacCatalogTileButtonStyle(cornerRadius: 6))
        .padding(.horizontal, -6)
        .help(title == nil ? "Open the catalog entry for \(key.description)" : "Open \(key.description) in its own window")
        .contextMenu {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
            }
            Button("Copy Course Code", systemImage: "doc.on.doc") { MacCatalogClipboard.copy(key.description) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "\(key.description), \($0)\(completedSpoken)" }
                            ?? "\(key.description), not offered this term\(completedSpoken)")
        .accessibilityInputLabels([key.description])
        .accessibilityHint(title == nil ? "Opens its catalog entry" : "Opens the course")
        .accessibilityAddTraits(.isLink)
    }
}

private struct MacRequisiteTestRow: View {
    var name: String
    var scoreText: String?
    var compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout.weight(.semibold))
                if let scoreText {
                    Text("Minimum score \(scoreText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 2 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Leads to

/// The "Leads to" list: the courses that mention this one among their prerequisites, in two short
/// groups so it doesn't read as though this course is needed for all of them. "Required" comes
/// first (their prerequisites can't be met without this course), then "One option" (it is one of
/// several ways to meet them). A long list starts with its first dozen and a "Show all" button.
struct MacCourseDependentsView: View {
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    if let role = group.role {
                        MacRequisiteGroupLabel(text: role.caption, doneText: nil)
                    }
                    CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(group.dependents) { dependent in
                            MacCatalogCourseChip(
                                key: dependent.key,
                                title: courseTitle(dependent.key),
                                termCode: termCode,
                                note: dependent.role?.spokenNote
                            )
                        }
                        // The "Show all" button ends the last group that is showing.
                        if limited, group.id == groups.last?.id {
                            MacCatalogMoreChip(title: "Show All \(dependents.count)") {
                                withAnimation(.snappy) { showsAll = true }
                            }
                        }
                    }
                }
            }
            if visible.contains(where: { !$0.isOffered }) {
                MacRequisiteUnofferedLegend()
            }
        }
    }
}

// MARK: - Copy

private extension RequisiteGroup {
    /// "One of", "Both of these" or "All of these".
    var headline: String {
        switch kind {
        case .oneOf: "One of"
        case .all: items.count == 2 ? "Both of these" : "All of these"
        }
    }

    /// "Done with CS 2510" once a "one of" is met; "Done" once an "all of" is.
    var doneText: String? {
        guard isDone else { return nil }
        if let doneWith { return "Done with \(doneWith.description)" }
        return kind == .all ? "Done" : nil
    }
}

private extension RequisiteChecklist {
    var headline: String { requirementCount == 2 ? "Both of these" : "All of these" }
}

private extension RequisiteNode {
    /// "Done with CS 2510", or "Done" when an alternative with several courses did it.
    var doneText: String? {
        guard isDone else { return nil }
        return doneWith.map { "Done with \($0.description)" } ?? "Done"
    }
}

private extension RequisitePath {
    /// What the option asks for, when its heading should say: "Both of these".
    var qualifier: String? {
        switch content {
        case .item: nil
        case .group(let group): group.headline
        case .checklist(let checklist): checklist.headline
        }
    }
}
