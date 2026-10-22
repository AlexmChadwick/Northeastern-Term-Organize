//
//  DegreeNoteViews.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A sentence of the catalog's requirements (a credit minimum, a co-op, a GPA) and what the app
/// could check of it against the plan.
struct DegreeNoteEntry: Identifiable {
    var sectionID: String
    var text: String
    /// The check of the sentence; nil when the app can't check it.
    var check: DegreeAudit.NoteCheck?

    var id: String { "\(sectionID)|\(text)" }
}

extension DegreeRequirementsFilter {
    /// Whether a checked sentence shows for this filter. A check that doesn't count yet (the app is
    /// still missing course data) shows in All only, as the totals leave it out too.
    func includes(_ check: DegreeAudit.NoteCheck) -> Bool {
        check.counts ? includes(check.status) : self == .all
    }
}

/// Which sentences of a section the requirements page shows.
enum DegreeRequirementNotes {
    /// The section's sentences for a filter, checked ones first-class and the rest as plain notes.
    /// - All shows every sentence; Remaining and Done only the checked ones that match.
    /// - A sentence in a group without requirements is shown only when it has a check, as it has
    ///   never been shown otherwise.
    /// - A total-hours sentence the page's header already states isn't repeated unless it is checked.
    static func entries(of section: RequirementSection, audit: DegreeAudit, filter: DegreeRequirementsFilter,
                        statesTotalHours: Bool) -> [DegreeNoteEntry] {
        var seen = Set<String>()
        func entry(_ note: String, showsUnchecked: Bool) -> DegreeNoteEntry? {
            let entry = DegreeNoteEntry(sectionID: section.id, text: note, check: audit.noteCheck(sectionID: section.id, note: note))
            guard seen.insert(entry.id).inserted else { return nil }
            if let check = entry.check { return filter.includes(check) ? entry : nil }
            let isRestatedTotal = statesTotalHours && note.localizedCaseInsensitiveContains("total semester hours")
            return filter == .all && showsUnchecked && !isRestatedTotal ? entry : nil
        }
        let own = section.notes.compactMap { entry($0, showsUnchecked: true) }
        let inOtherGroups = section.groups.filter(\.rules.isEmpty).flatMap(\.notes).compactMap { entry($0, showsUnchecked: false) }
        return own + inOtherGroups
    }

    /// Only the checked ones, for a section that has requirements of its own (its unchecked
    /// sentences stay in its footer).
    static func checkedEntries(of section: RequirementSection, audit: DegreeAudit, filter: DegreeRequirementsFilter) -> [DegreeNoteEntry] {
        entries(of: section, audit: audit, filter: filter, statesTotalHours: false).filter { $0.check != nil }
    }

    /// Whether the page has something to show for a filter among the checked sentences.
    static func hasChecks(in audit: DegreeAudit, filter: DegreeRequirementsFilter) -> Bool {
        audit.noteChecks.contains { filter.includes($0) }
    }
}

// MARK: - Row

/// A sentence of the catalog with the app's check of it: a status icon, the sentence and how the plan
/// stands (`66 of 72 semester hours · 8 planned`, `COOP 3946 completed`). A check made of several
/// parts (each NUpath requirement) lists them below, behind a disclosure when there are many, and
/// offers to find courses for a NUpath requirement still open. A sentence the app can't check says so,
/// in neutral colors.
struct DegreeNoteRow: View {
    var entry: DegreeNoteEntry
    var isExpanded: Bool
    var onToggle: () -> Void
    /// Opens the courses that have a NUpath attribute, for a requirement of a NUpath check the plan
    /// doesn't meet yet.
    var onFindCourses: ((NUPath) -> Void)?

    /// A check with more parts than this lists them only when opened.
    static let inlineItemLimit = 5

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22

    var body: some View {
        if let check = entry.check {
            checked(check)
        } else {
            unchecked
        }
    }

    // MARK: Not checked

    private var unchecked: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "circle.dashed")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DegreeAudit.uncheckedReason(for: entry.text) ?? "Not checked by the app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Checked

    private func checked(_ check: DegreeAudit.NoteCheck) -> some View {
        let isLong = check.items.count > Self.inlineItemLimit
        let showsItems = !check.items.isEmpty && (!isLong || isExpanded)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header(check, isLong: isLong)
            if showsItems {
                items(check.items)
            }
        }
        .animation(.snappy, value: isExpanded)
    }

    @ViewBuilder
    private func header(_ check: DegreeAudit.NoteCheck, isLong: Bool) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: check.status.degreeSymbol)
                .font(.body)
                .foregroundStyle(check.counts ? check.status.degreeColor : Color.secondary)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(check.detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(check.counts ? check.status.degreeColor : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !check.counts {
                    Text("Not counted in the total yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isLong {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide the list" : "Show all \(check.items.count)")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        if isLong {
            Button(action: onToggle) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken(check))
                .accessibilityHint(isExpanded ? "Hides the list" : "Shows the list")
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken(check))
        }
    }

    private func spoken(_ check: DegreeAudit.NoteCheck) -> String {
        [entry.text, check.counts ? check.status.degreeLabel : nil, check.detail].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Parts

    /// The NUpath requirement of a part that is still open (nothing, or too few courses, in the plan).
    private func openPath(of item: DegreeAudit.NoteCheck.Item) -> NUPath? {
        guard onFindCourses != nil, item.status == .missing || item.status == .partial else { return nil }
        return NUPath(rawValue: item.id)
    }

    /// The parts of a check, compact, in the catalog's order.
    private func items(_ items: [DegreeAudit.NoteCheck.Item]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: item.status?.degreeSymbol ?? "circle.dashed")
                        .font(.subheadline)
                        .foregroundStyle(item.status?.degreeColor ?? Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let path = openPath(of: item) {
                            Button("Find courses") { onFindCourses?(path) }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                                .padding(.top, 1)
                                .accessibilityLabel("Find courses for \(item.title)")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: openPath(of: item) == nil ? .ignore : .contain)
                .accessibilityLabel([item.title, item.status?.degreeLabel, item.detail].compactMap { $0 }.joined(separator: ", "))
            }
        }
        .padding(.leading, iconWidth + Theme.Spacing.s)
        .padding(.top, 2)
    }
}
