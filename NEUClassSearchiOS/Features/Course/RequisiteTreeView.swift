//
//  RequisiteTreeView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The presentation of requisite trees (nested "all of" / "one of" groups of
//  courses and tests) follows the structure of SearchNEU's Requisites.tsx
//  (https://github.com/sandboxnu/searchneu, apps/searchneu/components/catalog),
//  Copyright (C) Sandbox at Northeastern University and the SearchNEU
//  contributors, licensed under the GNU Affero General Public License v3.
//  Modified 2026-10-03: reimplemented natively in SwiftUI.
//  Modified 2026-10-04: groups are flattened, alternative branches become numbered
//  options and "one of" lists become chips, instead of one nested box per level.
//

import SwiftUI

/// Renders a prerequisite or corequisite so its logic reads at a glance.
///
/// `RequisiteLayout` (see `RequisiteOutline.swift`) decides the shape; this draws it:
/// - one course or test: a row, tappable when the course is offered this term,
/// - courses grouped: "One of" or "All of these" over a line of chips,
/// - an "and" that mixes courses with choices: a checklist of those parts,
/// - an "or" with compound branches: numbered options joined by "or".
///
/// Completed courses carry a green check and a group they satisfy says "Done with
/// CS 2510". VoiceOver reads the whole requirement as one sentence, then each course.
struct RequisiteTreeView: View {
    var requisite: Requisite
    var termCode: String
    /// What the requirement is called in the sentence VoiceOver reads ("Prerequisites").
    var title: String
    /// A course's title, or nil when this term's catalog doesn't list the course
    /// (so there is no page to open).
    var courseTitle: (CourseKey) -> String?
    /// Whether the user has completed a course, and which course counted if it was a
    /// different one. Pass `UserDataStore.completion(for:)`; the default marks nothing.
    var completion: (CourseKey) -> (isComplete: Bool, via: CourseKey?) = { _ in (false, nil) }

    var body: some View {
        if let layout = RequisiteLayout(requisite, isOffered: { courseTitle($0) != nil }, completion: completion) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                RequisiteLayoutView(
                    layout: layout,
                    context: RequisiteContext(termCode: termCode, courseTitle: courseTitle),
                    spoken: layout.spokenDescription(title: title)
                )
                if layout.hasGreyedOutChips {
                    CourseUnofferedLegend()
                }
            }
        } else {
            Text("None")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// What the requisite views need to know about the term around them.
private struct RequisiteContext {
    var termCode: String
    var courseTitle: (CourseKey) -> String?
}

// MARK: - Layouts

private struct RequisiteLayoutView: View {
    var layout: RequisiteLayout
    var context: RequisiteContext
    /// The whole requirement as a sentence, read by VoiceOver on the heading.
    var spoken: String

    var body: some View {
        switch layout {
        case .item(let item):
            RequisiteItemRow(item: item, context: context)
        case .group(let group):
            VStack(alignment: .leading, spacing: 2) {
                RequisiteHeading(text: group.headline, doneText: group.doneText, spoken: spoken)
                RequisiteChips(items: group.items, collapses: group.kind == .oneOf, context: context)
            }
        case .checklist(let checklist):
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                RequisiteHeading(
                    text: checklist.headline,
                    doneText: checklist.isDone ? "Done" : nil,
                    spoken: spoken
                )
                RequisitePartsView(parts: checklist.parts, context: context)
            }
        case .paths(let paths):
            VStack(alignment: .leading, spacing: 0) {
                RequisiteHeading(text: "Meet one of these", doneText: nil, spoken: spoken)
                    .padding(.bottom, Theme.Spacing.s)
                ForEach(Array(paths.enumerated()), id: \.offset) { position, path in
                    if position > 0 {
                        RequisiteOrDivider()
                    }
                    RequisiteOptionBox(number: position + 1, path: path, context: context)
                }
            }
        }
    }
}

/// The parts of a checklist, one under the other, each its own requirement.
private struct RequisitePartsView: View {
    var parts: [RequisitePart]
    var context: RequisiteContext

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
            RequisiteItemRow(item: item, context: context, compact: true)
        case .group(let group):
            VStack(alignment: .leading, spacing: 2) {
                // Loose required courses need no label: the heading above says "all".
                if group.kind == .oneOf {
                    RequisiteGroupLabel(text: group.headline, doneText: group.doneText)
                }
                RequisiteChips(items: group.items, collapses: group.kind == .oneOf, context: context)
            }
        case .expression(let node):
            VStack(alignment: .leading, spacing: 2) {
                // Like the groups beside it, a compound choice says what it is.
                if case .oneOf = node {
                    RequisiteGroupLabel(text: "One of", doneText: node.doneText)
                }
                RequisiteInlineExpression(node: node, context: context)
            }
        }
    }
}

// MARK: - Options

/// One way to meet an "or": a tinted block with its own heading, between "or" dividers.
private struct RequisiteOptionBox: View {
    var number: Int
    var path: RequisitePath
    var context: RequisiteContext

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header
            content
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: shape)
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
                RequisiteDoneLabel(text: "Done")
            }
        }
        .accessibilityHidden(true)
    }

    /// "Option 1 · Both of these".
    private var title: Text {
        let name = Text("Option \(number)")
            .font(.subheadline.weight(.semibold))
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
            RequisiteItemRow(item: item, context: context, compact: true)
        case .group(let group):
            RequisiteChips(items: group.items, collapses: group.kind == .oneOf, context: context)
        case .checklist(let checklist):
            RequisitePartsView(parts: checklist.parts, context: context)
        }
    }
}

/// A hairline, "or" and another hairline, between two options.
private struct RequisiteOrDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            line
            Text("or")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            line
        }
        .padding(.vertical, Theme.Spacing.s)
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1 / displayScale)
    }
}

// MARK: - Labels

/// The heading of a requirement. VoiceOver reads `spoken` (the whole requirement as
/// a sentence) in its place, so the structure around it is hidden from VoiceOver.
private struct RequisiteHeading: View {
    var text: String
    var doneText: String?
    var spoken: String

    var body: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 2) {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let doneText {
                RequisiteDoneLabel(text: doneText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The small label over a group of chips: "One of" in a requirement, "Required" in the
/// "Leads to" list. It is decoration for VoiceOver, which reads the chips themselves.
struct RequisiteGroupLabel: View {
    var text: String
    var doneText: String?

    var body: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 2) {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let doneText {
                RequisiteDoneLabel(text: doneText)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A green check and a few words: "Done", "Done with CS 2510".
private struct RequisiteDoneLabel: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
    }
}

// MARK: - Chips

/// Metrics shared by the course chips here and in the "Leads to" list.
enum CourseChipMetrics {
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 7
    /// Invisible padding that makes the touch target 44 points tall.
    static let hitInset: CGFloat = 5
    static let spacing: CGFloat = 8
}

/// A wrapping line of chips for a group of courses and tests. A long "one of" list
/// starts with its first few and a "Show all" chip (completed courses come first).
private struct RequisiteChips: View {
    var items: [RequisiteItem]
    var collapses: Bool
    var context: RequisiteContext

    @State private var isExpanded = false

    private static let collapseThreshold = 12
    private static let collapsedCount = 10

    private var isLong: Bool { collapses && items.count > Self.collapseThreshold }

    var body: some View {
        let visible = isLong && !isExpanded ? Array(items.prefix(Self.collapsedCount)) : items
        CourseFlowLayout(spacing: CourseChipMetrics.spacing, lineSpacing: 0) {
            ForEach(visible) { item in
                RequisiteChip(item: item, context: context)
            }
            if isLong {
                CourseMoreChip(
                    title: isExpanded ? "Show fewer" : "Show all \(items.count)",
                    accessibilityLabel: isExpanded ? "Show fewer options" : "Show all \(items.count) options"
                ) {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
            }
        }
    }
}

private struct RequisiteChip: View {
    var item: RequisiteItem
    var context: RequisiteContext

    var body: some View {
        switch item.kind {
        case .course(let key):
            CourseCodeChip(
                key: key,
                title: context.courseTitle(key),
                termCode: context.termCode,
                isComplete: item.isComplete,
                via: item.via
            )
        case .test(let name, _):
            RequisiteTestChip(name: name, scoreText: item.scoreText)
        }
    }
}

/// A course code in a capsule that opens the course. When this term's catalog doesn't list the
/// course (`title` is nil) it is greyed out and opens its catalog entry from Banner instead, a page
/// without sections (`CourseCatalogEntryView`); VoiceOver says which.
struct CourseCodeChip: View {
    var key: CourseKey
    /// The course's title, or nil when this term's catalog doesn't list the course.
    var title: String?
    var termCode: String
    var isComplete = false
    /// The course that counted when it was not this one (course equivalences).
    var via: CourseKey?
    /// Words VoiceOver adds at the end, for what the chip's surroundings say but its
    /// text doesn't ("one option among its prerequisites").
    var note: String?

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

    var body: some View {
        NavigationLink(value: AppRoute.course(termCode: termCode, key: key)) {
            chip
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "\(key.description), \($0)\(spokenSuffix)" }
                            ?? "\(key.description), not offered this term\(spokenSuffix)")
        .accessibilityInputLabels([key.description])
        .accessibilityHint(title == nil ? "Opens its catalog entry" : "Opens the course")
        .accessibilityAddTraits(.isLink)
    }

    private var chip: some View {
        HStack(spacing: 5) {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.green)
            }
            Text(key.description)
        }
        .font(.subheadline.weight(title == nil ? .medium : .semibold))
        .foregroundStyle(foreground)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, CourseChipMetrics.horizontalPadding)
        .padding(.vertical, CourseChipMetrics.verticalPadding)
        .background(background, in: .capsule)
        .padding(.vertical, CourseChipMetrics.hitInset)
        .contentShape(.rect)
    }

    private var foreground: AnyShapeStyle {
        if isComplete { return AnyShapeStyle(.primary) }
        return title == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)
    }

    private var background: Color {
        if isComplete { return Color.green.opacity(0.14) }
        return title == nil ? Color(.tertiarySystemFill) : Color.accentColor.opacity(0.12)
    }
}

/// A placement test or other non-course condition, outlined so it isn't mistaken for
/// a course that isn't offered.
private struct RequisiteTestChip: View {
    var name: String
    var scoreText: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.seal")
                .imageScale(.small)
            Text(scoreText.map { "\(name) · min. \($0)" } ?? name)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, CourseChipMetrics.horizontalPadding)
        .padding(.vertical, CourseChipMetrics.verticalPadding)
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 1))
        .padding(.vertical, CourseChipMetrics.hitInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scoreText.map { "\(name), minimum score \($0)" } ?? name)
    }
}

/// The outlined "Show all 12" / "Show fewer" capsule at the end of a long list of chips.
struct CourseMoreChip: View {
    var title: String
    var accessibilityLabel: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, CourseChipMetrics.horizontalPadding)
                .padding(.vertical, CourseChipMetrics.verticalPadding)
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                .padding(.vertical, CourseChipMetrics.hitInset)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Explains grey chips. A course this term's catalog doesn't list has no sections, though it
/// still opens to its catalog entry; a lone course is a row that says so itself, but a chip has
/// no room for a caption. Used under the requirements and under the "Leads to" list.
struct CourseUnofferedLegend: View {
    var body: some View {
        Text("Courses in gray aren't offered this term.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // Each grey chip already says "not offered this term" to VoiceOver.
            .accessibilityHidden(true)
    }
}

// MARK: - Inline expressions

/// A requirement too deep for boxes, as one wrapping line: `ME 4550 or ME 4570 or
/// (IE 4510 and IE 4515)`. Each course is still a chip you can tap; a group inside
/// another is outlined, which does the work of parentheses.
private struct RequisiteInlineExpression: View {
    var node: RequisiteNode
    var context: RequisiteContext

    var body: some View {
        switch node {
        case .item(let item):
            RequisiteChip(item: item, context: context)
        case .all(let members):
            joined(members, by: "and")
        case .oneOf(let members):
            joined(members, by: "or")
        }
    }

    private func joined(_ members: [RequisiteNode], by word: String) -> some View {
        CourseFlowLayout(spacing: CourseChipMetrics.spacing, lineSpacing: 0) {
            ForEach(Array(members.enumerated()), id: \.offset) { position, member in
                // The word travels with the member after it, so a line never ends on "or".
                HStack(spacing: CourseChipMetrics.spacing) {
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
            RequisiteInlineExpression(node: member, context: context)
        } else {
            RequisiteInlineExpression(node: member, context: context)
                .padding(.horizontal, Theme.Spacing.s)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 1)
                        .allowsHitTesting(false)
                )
        }
    }
}

// MARK: - Rows

/// One required course or test: a row with the course's title, tappable when the
/// course is offered this term.
private struct RequisiteItemRow: View {
    var item: RequisiteItem
    var context: RequisiteContext
    /// Tighter rows for inside a checklist or option.
    var compact = false

    var body: some View {
        switch item.kind {
        case .course(let key):
            RequisiteCourseRow(
                key: key,
                title: context.courseTitle(key),
                termCode: context.termCode,
                isComplete: item.isComplete,
                via: item.via,
                compact: compact
            )
        case .test(let name, _):
            RequisiteTestRow(name: name, scoreText: item.scoreText, compact: compact)
        }
    }
}

private struct RequisiteCourseRow: View {
    var key: CourseKey
    /// The course's title, or nil when this term's catalog doesn't list the course.
    var title: String?
    var termCode: String
    var isComplete: Bool
    var via: CourseKey?
    var compact: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var verticalPadding: CGFloat { compact ? 4 : 9 }

    private var completedText: String {
        via.map { "Completed via \($0.description)" } ?? "Completed"
    }

    private var completedSpoken: String {
        guard isComplete else { return "" }
        return via.map { ", completed via \($0.description)" } ?? ", completed"
    }

    /// A course the term lists opens the course; one it doesn't opens its catalog entry from
    /// Banner. Either way the row is a link.
    var body: some View {
        NavigationLink(value: AppRoute.course(termCode: termCode, key: key)) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    codeLine(style: title == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    if let title {
                        Text(title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            // Two lines at regular sizes; nothing is cut off once text is enlarged.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Not offered this term")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: Theme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "\(key.description), \($0)\(completedSpoken)" }
                            ?? "\(key.description), not offered this term\(completedSpoken)")
        .accessibilityInputLabels([key.description])
        .accessibilityHint(title == nil ? "Opens its catalog entry" : "Opens the course")
        .accessibilityAddTraits(.isLink)
    }

    /// The course code, followed by a green "Completed" mark when it is done.
    private func codeLine(style: AnyShapeStyle) -> some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 2) {
            Text(key.description)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(style)
            if isComplete {
                Label(completedText, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct RequisiteTestRow: View {
    var name: String
    var scoreText: String?
    var compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                if let scoreText {
                    Text("Minimum score \(scoreText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 4 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

// MARK: - Previews

private enum RequisitePreviewData {
    static func course(_ code: String) -> Requisite {
        .course(CourseKey(string: code) ?? CourseKey(subject: "XX", number: "0000"))
    }

    static let titles: [String: String] = [
        "CS 2100": "Program Design and Implementation 1",
        "CS 2510": "Fundamentals of Computer Science 2",
        "DS 2500": "Intermediate Programming with Data",
        "CS 1800": "Discrete Structures",
        "MATH 209M": "Discrete Structures",
        "EECE 2160": "Embedded Design",
        "CS 2700": "Fundamentals of Computer Science for Majors",
        "ACC 3410": "Managerial Accounting",
        "ACC 3202": "Financial Accounting Reporting",
        "ECON 1115": "Principles of Microeconomics",
    ]

    /// CS 3000: `((CS 2100 or CS 201M or CS 2510 or DS 2500) and (CS 1800 or MATH 209M or EECE 2160)) or CS 2700`.
    static let cs3000: Requisite = .or([
        .and([
            .or(["CS 2100", "CS 201M", "CS 2510", "DS 2500"].map(course)),
            .or(["CS 1800", "MATH 209M", "EECE 2160"].map(course)),
        ]),
        course("CS 2700"),
    ])

    static let mixed: [(title: String, requisite: Requisite)] = [
        ("One course", course("CS 2700")),
        ("A choice of courses", .or(["CS 2100", "CS 201M", "CS 2510", "DS 2500"].map(course))),
        ("A choice or a test", .or([course("CS 2510"), .test(name: "Graduate Admission", score: nil)])),
        ("Two required courses", .and(["ACC 3410", "ACC 3202"].map(course))),
        ("A course and a choice", .and([course("ACC 3410"), .or(["ACC 3202", "ACC 4307"].map(course))])),
        ("Two choices", .and([
            .or(["CS 2100", "CS 2510", "DS 2500"].map(course)),
            .or(["ECON 1115", "ECON 1116"].map(course)),
        ])),
        ("Courses or a sequence", .or([
            .or(["AAI 6600", "AAI 6610", "AAI 6620"].map(course)),
            .and(["EAI 6600", "EAI 6610", "EAI 6620"].map(course)),
        ])),
        ("Too deep for boxes", .or([
            .and([
                .or(["MATH 2321", "MATH 316M"].map(course)),
                .or([course("BIOE 2365"), .and(["CHME 3315", "CHME 4315"].map(course))]),
            ]),
            .test(name: "Graduate Admission", score: nil),
        ])),
    ]
}

private struct RequisitePreviewCard: View {
    var heading = "Prerequisites"
    var requisite: Requisite
    var completed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            RequisiteTreeView(
                requisite: requisite,
                termCode: "202710",
                title: heading,
                courseTitle: { RequisitePreviewData.titles[$0.description] },
                completion: { (completed.contains($0.description), nil) }
            )
        }
        .courseCard()
    }
}

#Preview("CS 3000") {
    NavigationStack {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                RequisitePreviewCard(requisite: RequisitePreviewData.cs3000)
                RequisitePreviewCard(requisite: RequisitePreviewData.cs3000, completed: ["CS 2510", "CS 1800"])
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("Shapes") {
    NavigationStack {
        ScrollView {
            VStack(spacing: Theme.Spacing.l) {
                ForEach(RequisitePreviewData.mixed.indices, id: \.self) { position in
                    RequisitePreviewCard(
                        heading: RequisitePreviewData.mixed[position].title,
                        requisite: RequisitePreviewData.mixed[position].requisite,
                        completed: ["ACC 3202"]
                    )
                }
            }
            .padding(Theme.Spacing.l)
        }
        .background(Color(.systemGroupedBackground))
    }
}

#Preview("CS 3000, dark, large text") {
    NavigationStack {
        ScrollView {
            RequisitePreviewCard(requisite: RequisitePreviewData.cs3000, completed: ["CS 2510"])
                .padding(Theme.Spacing.l)
        }
        .background(Color(.systemGroupedBackground))
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}
