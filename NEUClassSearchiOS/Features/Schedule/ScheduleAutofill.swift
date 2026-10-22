//
//  ScheduleAutofill.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Chip

/// A suggested course: its plan color, code and (when the catalog is loaded) title.
struct ScheduleAutofillChip: View {
    var key: CourseKey
    var title: String?
    var colorIndex: Int

    var body: some View {
        let color = CourseColor.at(colorIndex)
        HStack(spacing: 5) {
            Circle()
                .fill(color.stroke)
                .frame(width: 7, height: 7)
            Text(key.description)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .layoutPriority(1)
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.fill, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.flatMap { $0.isEmpty ? nil : "\(key.description), \($0)" } ?? key.description)
    }
}

// MARK: - Card (empty schedule)

/// "Start with your planned courses": shown at the top of an empty schedule. Previews the
/// best suggestion (a degree plan's semester or another schedule), lists what isn't
/// offered this term, and adds everything in one tap.
struct ScheduleAutofillCard: View {
    /// Best first; never empty.
    var suggestions: [ScheduleAutofillSuggestion]
    /// The suggestion being previewed (nil means the best one).
    @Binding var choice: String?
    /// The schedule being filled (the chips preview the colors the courses will get).
    var plan: SchedulePlan
    var index: CatalogIndex?
    var onAdd: (ScheduleAutofillSuggestion) -> Void

    private var current: ScheduleAutofillSuggestion {
        ScheduleAutofillSupport.preview(of: suggestions, choice: choice) ?? suggestions[0]
    }

    private var symbol: String {
        if case .degreePlan = current.source { return "graduationcap.fill" }
        return "square.on.square"
    }

    /// `Your plan for this term · 5 courses · 17 credits` (credits once the catalog can say).
    private func summary(of suggestion: ScheduleAutofillSuggestion) -> String {
        let count = suggestion.courses.count
        guard count > 0 else { return suggestion.detail }
        var parts = [suggestion.detail, ScheduleAutofillSupport.courseCountLabel(count)]
        let credits = suggestion.courses.compactMap { index?.course($0)?.defaultChoiceCredits }
        let total = credits.reduce(0, +)
        if credits.count == count, total > 0 {
            parts.append(CreditFormatter.label(min: total, max: total))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let suggestion = current
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Start with your planned courses")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(suggestion.title)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary(of: suggestion))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if !suggestion.courses.isEmpty {
                let colors = ScheduleAutofillSupport.colorIndices(for: suggestion.courses, in: plan)
                PlanFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(suggestion.courses.enumerated()), id: \.element) { offset, key in
                        ScheduleAutofillChip(
                            key: key,
                            title: index?.course(key)?.title,
                            colorIndex: colors[offset]
                        )
                    }
                }
            }

            if !suggestion.unavailable.isEmpty {
                Label {
                    Text(ScheduleAutofillSupport.unavailableLine(suggestion.unavailable))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                GlassEffectContainer {
                    Button {
                        onAdd(suggestion)
                    } label: {
                        Text(addTitle(for: suggestion))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(suggestion.courses.isEmpty)
                    .accessibilityHint("Adds these courses to this schedule")
                }

                if suggestions.count > 1 {
                    otherSuggestions(selected: suggestion)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func addTitle(for suggestion: ScheduleAutofillSuggestion) -> String {
        let count = suggestion.courses.count
        if count == 0 { return "Nothing to add" }
        return count == 1 ? "Add 1 course" : "Add \(count) courses"
    }

    /// Switches the preview between the degree plans' semesters and other schedules.
    private func otherSuggestions(selected: ScheduleAutofillSuggestion) -> some View {
        Menu {
            Picker("Suggestion", selection: Binding(get: { selected.id }, set: { choice = $0 })) {
                ForEach(suggestions) { suggestion in
                    let count = suggestion.courses.isEmpty ? "none offered" : ScheduleAutofillSupport.courseCountLabel(suggestion.courses.count)
                    Text("\(suggestion.title) · \(count)").tag(suggestion.id)
                }
            }
        } label: {
            Label("Other suggestions", systemImage: "chevron.up.chevron.down")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Other suggestions")
        .accessibilityValue(selected.title)
    }
}

// MARK: - Banner (schedule with courses)

/// A compact, dismissible nudge on a partly built schedule: "2 more courses from
/// “New Plan” · Spring 2027". The plan's name gives way (truncates) before its semester does.
struct ScheduleAutofillBanner: View {
    var suggestion: ScheduleAutofillSuggestion
    var onAdd: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var count: Int { suggestion.courses.count }

    private var headline: String {
        "\(count) more \(count == 1 ? "course" : "courses")"
    }

    /// The codes to add, and how many planned courses aren't offered this term.
    private var detail: String {
        let codes = suggestion.courses.map(\.description).joined(separator: ", ")
        let missing = suggestion.unavailable.count
        guard missing > 0 else { return codes }
        return "\(codes) · \(missing) not offered this term"
    }

    var body: some View {
        let source = ScheduleAutofillSupport.sourceParts(of: suggestion)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // The buttons share the first line only, so the lines below get the full width.
                HStack(spacing: 8) {
                    // VoiceOver reads the whole message from here, before the buttons.
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(headline) from \(ScheduleAutofillSupport.sourceName(of: suggestion))")
                        .accessibilityValue(detail)
                    Spacer(minLength: 4)
                    Button("Add", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .accessibilityLabel("Add \(ScheduleAutofillSupport.courseCountLabel(count))")
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss suggestion")
                }
                VStack(alignment: .leading, spacing: 2) {
                    sourceLine(source)
                        .font(.footnote)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
            }
        }
    }

    /// `from “New Plan” · Spring 2027`: one line where the plan's name gives way before its
    /// semester does; at accessibility sizes it simply wraps.
    @ViewBuilder
    private func sourceLine(_ source: (name: String, term: String?)) -> some View {
        if typeSize.isAccessibilitySize {
            Text("from \(ScheduleAutofillSupport.sourceName(of: suggestion))")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 0) {
                Text("from \(source.name)")
                    .lineLimit(1)
                if let term = source.term {
                    Text(" · \(term)")
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}
