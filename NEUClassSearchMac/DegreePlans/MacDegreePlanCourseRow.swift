//
//  MacDegreePlanCourseRow.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// How the plan's course rows use the width of the list: in aligned columns (code, title, where
/// the degree requirements count the course, credits, prerequisites) when the list is wide, else
/// the code, title and credits with anything worth a second look under the title.
enum MacDegreePlanRowLayout: Sendable {
    case columns, compact
}

extension EnvironmentValues {
    /// How course rows lay themselves out (the plan list measures itself and sets it).
    @Entry var macPlanRowLayout: MacDegreePlanRowLayout = .compact
}

/// A course in a plan, one list row: its code, title and credits in aligned columns, and under
/// the title anything worth a second look: a prerequisite the plan doesn't cover yet, a course
/// that is no longer offered or listed twice, an equivalence, and where the degree requirements
/// count it. In a wide list, where the requirements count it and whether its prerequisites are
/// covered get columns of their own.
struct MacDegreePlanCourseRow: View {
    var course: DegreePlanCourse
    /// The title to show (the catalog's when available, else the plan's).
    var title: String
    /// Prerequisite check for planned courses; nil for completed ones.
    var status: DegreePlanAnalysis.PrerequisiteStatus?
    /// Duplicate flag, e.g. "Also planned in Fall 2027".
    var note: String?
    /// Whether a catalog was available, so "unchecked" is worth saying.
    var catalogAvailable = false
    /// Why the prerequisites weren't checked, when `status` is `.unknown`.
    var uncheckedReason: DegreePlanUncheckedReason?
    /// `No longer offered; last listed Spring 2025`, for a planned course the catalog no longer
    /// lists.
    var offeringNote: String?
    /// `Counts as CS 2100`, for a course the plan declares equivalent to another.
    var equivalenceNote: String?
    /// Where the degree requirements count the course, e.g. "Counts toward Khoury Elective
    /// Courses" (only when the plan's requirements are set up).
    var requirementNote: String?
    var caption: String? = nil
    var creditSpan: CreditSpan? = nil
    var onSetCredits: ((Double) -> Void)? = nil

    @Environment(\.macPlanRowLayout) private var layout

    /// Width of the code column, so codes and titles line up from one semester to the next.
    static let codeWidth: CGFloat = 96
    /// Width of the credits column.
    static let creditsWidth: CGFloat = 72
    /// Width of the column that says where the requirements count the course.
    static let countsWidth: CGFloat = 210
    /// Width of the prerequisites column.
    static let prerequisiteWidth: CGFloat = 150

    private var usesColumns: Bool { layout == .columns }
    private var showsStepper: Bool { creditSpan?.isVariable == true && onSetCredits != nil }

    @ViewBuilder
    private var creditControl: some View {
        if showsStepper, let creditSpan, let onSetCredits {
            CreditChoiceControl(span: creditSpan, credits: course.credits, onChange: onSetCredits)
        } else {
            Text(DegreePlanText.credits(course.credits))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            MacDegreeCodeText(text: course.key?.description ?? course.label, isCourse: course.key != nil)
                .frame(width: Self.codeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if !title.isEmpty {
                    Text(title)
                        .foregroundStyle(course.key == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                }
                if let caption {
                    CatalogCaption(text: caption)
                }
                flags
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if usesColumns {
                countsCell
                    .frame(width: Self.countsWidth, alignment: .leading)
            }
            creditControl
                .frame(width: showsStepper ? 220 : Self.creditsWidth, alignment: .trailing)
            if usesColumns {
                prerequisiteCell
                    .frame(width: Self.prerequisiteWidth, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    // MARK: Columns

    /// Where the requirements count the course: the requirement's name, without the sentence
    /// around it (the column's place says "counts toward").
    @ViewBuilder
    private var countsCell: some View {
        if let requirementNote {
            Label {
                Text(Self.countingName(from: requirementNote))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "graduationcap")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(requirementNote)
        }
    }

    /// `Khoury Elective Courses` from `Counts toward Khoury Elective Courses`; other wordings
    /// (`Counts as CS 2100`) stay as they are.
    static func countingName(from note: String) -> String {
        let prefix = "Counts toward "
        if note.hasPrefix(prefix) { return String(note.dropFirst(prefix.count)) }
        if note == "Counts as a general elective" { return "General elective" }
        return note
    }

    /// Whether the prerequisites are covered, for planned courses.
    @ViewBuilder
    private var prerequisiteCell: some View {
        switch status {
        case .met?:
            Label {
                Text("Prerequisites met")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.callout)
        case .missing(let requirement)?:
            Label("Needs \(requirement)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("Missing prerequisite: \(requirement)")
        case .unknown?:
            if let reason = uncheckedReason ?? (catalogAvailable ? .notChecked : nil) {
                switch reason {
                case .checking:
                    Label {
                        Text("Checking…")
                    } icon: {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                case .failed:
                    Label("Couldn’t check", systemImage: "wifi.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .notFound, .notChecked:
                    Label("Not checked", systemImage: "questionmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: Flags

    @ViewBuilder
    private var flags: some View {
        if let offeringNote {
            flag(offeringNote, systemImage: "calendar.badge.exclamationmark", color: .orange)
        }
        // With their own column, the prerequisites and where the course counts aren't repeated.
        if !usesColumns {
            if case .missing(let requirement) = status {
                flag("Needs \(requirement)", systemImage: "exclamationmark.triangle.fill", color: .orange)
                    .accessibilityLabel("Prerequisite missing: \(requirement)")
            } else if case .unknown = status, let reason = uncheckedReason ?? (catalogAvailable ? .notChecked : nil) {
                uncheckedFlag(reason)
            }
        }
        if let note {
            flag(note, systemImage: "square.on.square", color: .orange)
        }
        // (A renumbered course that counts as the requirement's course says it once.)
        if let equivalenceNote, equivalenceNote != requirementNote {
            flag(equivalenceNote, systemImage: "equal.circle", color: nil)
        }
        if !usesColumns, let requirementNote {
            flag(requirementNote, systemImage: "graduationcap", color: nil)
        }
    }

    private func flag(_ text: String, systemImage: String, color: Color?) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Checking prerequisites…", or why they couldn't be checked.
    @ViewBuilder
    private func uncheckedFlag(_ reason: DegreePlanUncheckedReason) -> some View {
        switch reason {
        case .checking:
            Label {
                Text("Checking prerequisites…")
            } icon: {
                ProgressView()
                    .controlSize(.mini)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Checking prerequisites")
        case .failed:
            flag("Couldn’t check prerequisites", systemImage: "wifi.exclamationmark", color: nil)
                .accessibilityLabel("Couldn’t check prerequisites, Banner couldn’t be reached")
        case .notFound:
            flag("Not in Banner’s catalog for recent terms", systemImage: "questionmark.circle", color: nil)
                .accessibilityLabel("Prerequisites not checked, the course isn’t in Banner’s catalog for recent terms")
        case .notChecked:
            flag("Prerequisites not checked", systemImage: "questionmark.circle", color: nil)
                .accessibilityLabel("Prerequisites not checked, course isn’t in the catalog on this Mac")
        }
    }
}
