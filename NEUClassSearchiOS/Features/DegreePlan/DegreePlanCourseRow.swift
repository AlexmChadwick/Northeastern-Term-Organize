//
//  DegreePlanCourseRow.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What a plan's sections and rows can ask the screen to do. The screen owns the
/// state (sheets, confirmations, undo), so rows just call these.
struct DegreePlanActions {
    /// Opens the add-course sheet for a semester (by id).
    var addCourse: (UUID) -> Void = { _ in }
    /// Creates a schedule from a semester's courses (by id).
    var buildSchedule: (UUID) -> Void = { _ in }
    var removeSemester: (UUID) -> Void = { _ in }
    var removePlanned: (DegreePlanCourse) -> Void = { _ in }
    var removeCompleted: (DegreePlanCourse) -> Void = { _ in }
    /// Moves a planned course (first id) to a semester (second id).
    var move: (UUID, UUID) -> Void = { _, _ in }
    var markCompleted: (DegreePlanCourse) -> Void = { _ in }
    /// Looks up again the courses whose prerequisites couldn't be checked.
    var retryChecks: () -> Void = {}
    /// Opens the equivalence sheet for a course of the plan ("Counts as another course…").
    var addEquivalence: (CourseKey) -> Void = { _ in }
    /// Puts a course in a planned course's place (a retired course's current equivalent).
    var replaceCourse: (DegreePlanCourse, CourseKey) -> Void = { _, _ in }
    /// Sets the credits of one row (its id, then the chosen value).
    var setCredits: (UUID, Double) -> Void = { _, _ in }
}

/// A course in a plan: tinted code, title, credits and anything worth a second look —
/// a prerequisite the plan doesn't cover yet, or a course that's listed twice.
struct DegreePlanCourseRow: View {
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
    /// `No longer offered; last listed Spring 2025`, for a planned course the catalog no
    /// longer lists.
    var offeringNote: String?
    /// `Counts as CS 2100`, for a course the plan declares equivalent to another.
    var equivalenceNote: String?
    /// Where the degree requirements count the course, e.g. "Counts toward Khoury Elective
    /// Courses" (only when the plan's requirements are set up).
    var requirementNote: String?
    /// CPS restriction note, when the catalog has loaded section restrictions.
    var caption: String? = nil
    /// When false, the parent draws the variable-credit stepper outside a navigation link.
    var showsCredits = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            codeLine
            if !title.isEmpty {
                Text(title)
                    .font(.body)
                    .foregroundStyle(course.key == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption {
                CatalogCaption(text: caption)
            }
            flags
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var codeLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                code
                Spacer(minLength: Theme.Spacing.s)
                credits
            }
            VStack(alignment: .leading, spacing: 2) {
                code
                credits
            }
        }
    }

    private var code: some View {
        Text(course.key?.description ?? course.label)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(course.key == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .monospacedDigit()
    }

    @ViewBuilder
    private var credits: some View {
        if showsCredits {
            Text(DegreePlanText.credits(course.credits))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var flags: some View {
        if let offeringNote {
            Label(offeringNote, systemImage: "calendar.badge.exclamationmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if case .missing(let requirement) = status {
            Label("Needs \(requirement)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Prerequisite missing: \(requirement)")
        } else if case .unknown = status, let reason = uncheckedReason ?? (catalogAvailable ? .notChecked : nil) {
            uncheckedFlag(reason)
        }
        if let note {
            Label(note, systemImage: "square.on.square")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A course declared equivalent to the one a requirement names says so once, under the requirement.
        if let equivalenceNote, equivalenceNote != requirementNote {
            Label(equivalenceNote, systemImage: "equal.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let requirementNote {
            Label(requirementNote, systemImage: "graduationcap")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Checking prerequisites")
        case .failed:
            Label("Couldn’t check prerequisites", systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Couldn’t check prerequisites, Banner couldn’t be reached")
        case .notFound:
            Label("Not in Banner’s catalog for recent terms", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Prerequisites not checked, the course isn’t in Banner’s catalog for recent terms")
        case .notChecked:
            Label("Prerequisites not checked", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Prerequisites not checked, course isn’t in the catalog on this device")
        }
    }
}
