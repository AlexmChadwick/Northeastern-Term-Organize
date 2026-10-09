//
//  PlanCourseRow.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One course of a plan: color dot, code and title, the chosen section (days,
/// time, place, instructor, seats) and the Required / Optional switch.
struct PlanCourseRow: View {
    var entry: ResolvedPlan.Entry
    var termName: String
    /// Courses whose chosen sections overlap this course's section.
    var conflictingKeys: [CourseKey] = []
    var onOpen: () -> Void
    var onToggleRequired: () -> Void

    var body: some View {
        // The summary spans the full width; the Required/Optional switch floats at the
        // top trailing corner, beside the course code only.
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 12) {
                PlanColorDot(colorIndex: entry.planCourse.colorIndex, size: 12)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 4) {
                    header
                    sectionLines
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Choose a section")
            .accessibilityAction(.default, onOpen)

            requiredButton
        }
        .padding(.vertical, 2)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.key.description)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(entry.color.text)
                    .monospacedDigit()
                if let course = entry.course {
                    Text(course.creditsLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // As tall as the switch beside it, so the title never slides underneath.
            .frame(minHeight: 28, alignment: .leading)
            if !entry.title.isEmpty {
                Text(entry.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    @ViewBuilder
    private var sectionLines: some View {
        if let section = entry.chosen {
            Text(ScheduleFormat.sectionSummary(section))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            if let detail = detail(for: section) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                SeatsBadge(section: section)
                if !conflictingKeys.isEmpty {
                    ScheduleConflictTag(text: conflictText)
                }
            }
            .padding(.top, 2)
            if entry.selected.count > 1 {
                Text("+\(entry.selected.count - 1) more section\(entry.selected.count == 2 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !entry.catalogAvailable {
            Label("Course data unavailable", systemImage: "icloud.slash")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        } else if entry.isMissing {
            Label("Not offered in \(termName)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
        } else if entry.hasNoSections {
            Label("No sections in \(termName)", systemImage: "calendar.badge.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
        } else {
            Label {
                Text("No section chosen")
            } icon: {
                Image(systemName: "circle.dashed")
            }
            .font(.footnote.weight(.medium))
            // Optional courses may legitimately stay out of the schedule.
            .foregroundStyle(entry.planCourse.isRequired ? Color.orange : Color.secondary)
            Text("Tap to choose from \(entry.availableSections.count) \(entry.availableSections.count == 1 ? "section" : "sections")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        if !entry.planCourse.excludedCRNs.isEmpty, !entry.isMissing {
            Label("\(entry.planCourse.excludedCRNs.count) skipped when generating", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var conflictText: String {
        conflictingKeys.count == 1 ? "Overlaps \(conflictingKeys[0])" : "Overlaps \(conflictingKeys.count) courses"
    }

    private func detail(for section: CourseSection) -> String? {
        var parts: [String] = []
        if let location = ScheduleFormat.location(of: section) { parts.append(location) }
        if let instructors = ScheduleFormat.instructors(of: section) { parts.append(instructors) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var requiredButton: some View {
        let required = entry.planCourse.isRequired
        return Button(action: onToggleRequired) {
            Text(required ? "Required" : "Optional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(required ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(required ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color.secondary.opacity(0.1)), in: .capsule)
                .overlay {
                    if !required {
                        Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(entry.key.description) is \(required ? "required" : "optional")")
        .accessibilityHint("Required courses appear in every generated schedule. Double tap to make it \(required ? "optional" : "required").")
    }
}
