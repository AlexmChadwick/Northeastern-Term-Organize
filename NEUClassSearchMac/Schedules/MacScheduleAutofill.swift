//
//  MacScheduleAutofill.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Starting a schedule from the courses a degree plan (or another schedule) has for the term.
//

import SwiftUI

/// A suggested course: its plan color, code and (when the catalog is loaded) title.
struct MacCourseChip: View {
    var key: CourseKey
    var title: String?
    var colorIndex: Int

    var body: some View {
        let color = CourseColor.at(colorIndex)
        HStack(spacing: 5) {
            Circle().fill(color.stroke).frame(width: 7, height: 7)
            Text(key.description)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .layoutPriority(1)
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.fill, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.flatMap { $0.isEmpty ? nil : "\(key.description), \($0)" } ?? key.description)
    }
}

/// The courses of a suggestion as chips (with the colors they will get in `plan`), and the ones the
/// term doesn't offer.
struct MacAutofillCourses: View {
    var suggestion: ScheduleAutofillSuggestion
    var plan: SchedulePlan
    var index: CatalogIndex?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestion.courses.isEmpty {
                let colors = ScheduleAutofillSupport.colorIndices(for: suggestion.courses, in: plan)
                CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(suggestion.courses.enumerated()), id: \.element) { offset, key in
                        MacCourseChip(key: key, title: index?.course(key)?.title, colorIndex: colors[offset])
                    }
                }
            }
            if !suggestion.unavailable.isEmpty {
                Label(ScheduleAutofillSupport.unavailableLine(suggestion.unavailable), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Card (empty schedule)

/// "Start with your planned courses": shown at the top of an empty schedule. Previews the best
/// suggestion (a degree plan's semester or another schedule), lists what isn't offered this term,
/// and adds everything in one click.
struct MacAutofillCard: View {
    /// Best first; never empty.
    var suggestions: [ScheduleAutofillSuggestion]
    /// The suggestion being previewed (nil means the best one).
    @Binding var choice: String?
    var plan: SchedulePlan
    var index: CatalogIndex?
    var onAdd: (ScheduleAutofillSuggestion) -> Void

    private var current: ScheduleAutofillSuggestion {
        ScheduleAutofillSupport.preview(of: suggestions, choice: choice) ?? suggestions[0]
    }

    /// `Your plan for this term · 5 courses · 17 credits` (credits once the catalog can say).
    private func summary(of suggestion: ScheduleAutofillSuggestion) -> String {
        let count = suggestion.courses.count
        guard count > 0 else { return suggestion.detail }
        var parts = [suggestion.detail, ScheduleAutofillSupport.courseCountLabel(count)]
        let credits = suggestion.courses.compactMap { index?.course($0)?.maxCredits }
        let total = credits.reduce(0, +)
        if credits.count == count, total > 0 {
            parts.append(CreditFormatter.label(min: total, max: total))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let suggestion = current
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text("Start with your planned courses")
                        .font(.headline)
                } icon: {
                    Image(systemName: suggestion.isDegreePlan ? "graduationcap.fill" : "square.on.square")
                        .foregroundStyle(.tint)
                }
                Text(suggestion.title)
                    .font(.callout)
                Text(summary(of: suggestion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            MacAutofillCourses(suggestion: suggestion, plan: plan, index: index)

            CourseFlowLayout(spacing: 10, lineSpacing: 6) {
                Button {
                    onAdd(suggestion)
                } label: {
                    Text(addTitle(for: suggestion))
                }
                .buttonStyle(.borderedProminent)
                .disabled(suggestion.courses.isEmpty)
                .accessibilityHint("Adds these courses to this schedule")
                if suggestions.count > 1 {
                    Menu("Other Suggestions") {
                        Picker("Suggestion", selection: Binding(get: { suggestion.id }, set: { choice = $0 })) {
                            ForEach(suggestions) { other in
                                let count = other.courses.isEmpty ? "none offered" : ScheduleAutofillSupport.courseCountLabel(other.courses.count)
                                Text("\(other.title) · \(count)").tag(other.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
    }

    private func addTitle(for suggestion: ScheduleAutofillSuggestion) -> String {
        let count = suggestion.courses.count
        if count == 0 { return "Nothing to Add" }
        return count == 1 ? "Add 1 Course" : "Add \(count) Courses"
    }
}

extension ScheduleAutofillSuggestion {
    /// The suggestion comes from a degree plan (rather than another schedule).
    var isDegreePlan: Bool {
        if case .degreePlan = source { return true }
        return false
    }
}

// MARK: - Nudge (schedule with courses)

/// A compact, dismissible nudge on a partly built schedule: "2 more courses from “New Plan” ·
/// Spring 2027".
struct MacAutofillNudge: View {
    var suggestion: ScheduleAutofillSuggestion
    var onAdd: () -> Void
    var onDismiss: () -> Void

    private var count: Int { suggestion.courses.count }

    private var detail: String {
        let codes = suggestion.courses.map(\.description).joined(separator: ", ")
        let missing = suggestion.unavailable.count
        guard missing > 0 else { return codes }
        return "\(codes) · \(missing) not offered this term"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "graduationcap.fill")
                .foregroundStyle(.tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) more \(count == 1 ? "course" : "courses") from \(ScheduleAutofillSupport.sourceName(of: suggestion))")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Add", action: onAdd)
                .controlSize(.small)
                .accessibilityLabel("Add \(ScheduleAutofillSupport.courseCountLabel(count))")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss this suggestion")
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 8, style: .continuous))
    }
}
