//
//  MacDegreeNoteRows.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A requirement the catalog states as a sentence ("Complete 72 semester hours in the major",
/// "… is satisfied through co-op", the NUpath requirements). When the plan can be checked against
/// it, the row shows how it stands, like any requirement: a status icon, how far the plan gets
/// (`46 of 72 semester hours · 56 planned`) and, for a sentence made of several parts, each
/// part. A sentence the plan can't answer (the GPA, where credits were earned) says it isn't
/// checked, and why when the audit knows. A check that can't tell yet (NUpath data still being
/// looked up) shows what it found in neutral colors.
struct MacDegreeNoteRow: View {
    var note: String
    var check: DegreeAudit.NoteCheck?
    /// Whether the parts of a long check are shown.
    var isExpanded = false
    var onToggle: () -> Void = {}
    /// Searches the catalog for courses with an NUpath attribute, for a part of the NUpath
    /// check the plan doesn't meet yet.
    var onFindCourses: ((NUPath) -> Void)?

    @Environment(\.macDegreeRowLayout) private var layout

    /// A check with more parts than this folds them away until opened.
    static let foldThreshold = 5

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(note)
                    .fixedSize(horizontal: false, vertical: true)
                if let check {
                    Text(check.detail)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(check.counts ? check.status.degreeColor : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !check.items.isEmpty {
                        parts(of: check)
                    }
                } else {
                    Text(DegreeAudit.uncheckedReason(for: note) ?? "Not checked by the app")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenLabel)
    }

    @ViewBuilder
    private var icon: some View {
        if let check {
            Image(systemName: check.status.degreeSymbol)
                .foregroundStyle(check.counts ? check.status.degreeColor : Color.secondary)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Parts

    /// The parts of a check: all of them when there are few, else a button that opens them.
    @ViewBuilder
    private func parts(of check: DegreeAudit.NoteCheck) -> some View {
        let isFolded = check.items.count > Self.foldThreshold
        if isFolded {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Text(isExpanded ? "Hide the \(check.items.count) requirements" : "Show the \(check.items.count) requirements")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 2)
        }
        if !isFolded || isExpanded {
            VStack(alignment: .leading, spacing: layout == .table ? 4 : 6) {
                ForEach(check.items) { item in
                    MacDegreeNoteItemRow(item: item, onFindCourses: findAction(for: item, in: check))
                }
            }
            .padding(.top, 4)
        }
    }

    /// "Find Courses" for an NUpath requirement the plan doesn't meet: the item's id is the NUpath's.
    private func findAction(for item: DegreeAudit.NoteCheck.Item, in check: DegreeAudit.NoteCheck) -> (() -> Void)? {
        guard case .nupath = check.kind, let onFindCourses, let status = item.status, !status.isSatisfied,
              let nupath = NUPath(rawValue: item.id) else { return nil }
        return { onFindCourses(nupath) }
    }

    private var spokenLabel: String {
        guard let check else { return "\(note), \(DegreeAudit.uncheckedReason(for: note) ?? "not checked by the app")" }
        return "\(note), \(check.status.degreeLabel), \(check.detail)"
    }
}

/// One part of a checked sentence: `Interpreting Culture (IC)` and how it stands. A part the app
/// can't check (the GPA) is neutral, never red.
struct MacDegreeNoteItemRow: View {
    var item: DegreeAudit.NoteCheck.Item
    /// Searches the catalog for courses that would meet it.
    var onFindCourses: (() -> Void)?

    @Environment(\.macDegreeRowLayout) private var layout

    var body: some View {
        Group {
            if layout == .table {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    Text(item.title)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 240, alignment: .leading)
                    Text(item.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    findButton
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .fontWeight(.medium)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        findButton
                    }
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onFindCourses {
                Button("Find Courses", action: onFindCourses)
            }
        }
    }

    @ViewBuilder
    private var findButton: some View {
        if let onFindCourses {
            Button("Find Courses", systemImage: "magnifyingglass", action: onFindCourses)
                .buttonStyle(.link)
                .labelStyle(.titleAndIcon)
                .help("Search the catalog for courses that meet \(item.title)")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let status = item.status {
            Image(systemName: status.degreeSymbol)
                .foregroundStyle(status.degreeColor)
                .frame(width: 16)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }
}
