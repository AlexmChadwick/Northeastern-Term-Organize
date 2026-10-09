//
//  SchedulePreferencesComponents.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Day chips

/// A row of weekday circles; tapping one toggles it. Wraps onto a second line at very large text sizes.
struct ScheduleDayChips: View {
    @Binding var selection: DaySet
    /// Day indices to offer (0 = Sunday).
    var days: [Int]
    /// What the chip means when it is on, for VoiceOver ("Day off", "Blocked").
    var onValue = "Selected"
    var offValue = "Not selected"
    /// The circles' diameter; by default 40 points, scaled with the text size.
    var diameter: CGFloat?

    @ScaledMetric(relativeTo: .subheadline) private var scaledSize: CGFloat = 40

    private var size: CGFloat { diameter ?? scaledSize }

    var body: some View {
        PlanFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(days, id: \.self) { day in
                chip(day)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func chip(_ day: Int) -> some View {
        let isOn = selection.contains(day: day)
        return Button {
            if isOn {
                selection.remove(DaySet(day: day))
            } else {
                selection.insert(DaySet(day: day))
            }
        } label: {
            Text(DaySet.shortNames[day])
                .font(.subheadline.weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: size, height: size)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(DaySet.fullNames[day])
        .accessibilityValue(isOn ? onValue : offValue)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - Presets

/// A glass capsule that turns a preset on or off. Like `GlassChip`, but at accessibility text sizes it
/// spans the row and lets its title wrap instead of cutting it off.
struct SchedulePresetChip: View {
    var preset: SchedulePreset
    var isOn: Bool
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let spansRow = dynamicTypeSize.isAccessibilitySize
        Button(action: action) {
            // An HStack, not a Label: a Label spaces its icon on a column grid, which makes the chip wide.
            HStack(spacing: 5) {
                Image(systemName: preset.symbol).imageScale(.small)
                Text(preset.title)
                    .lineLimit(spansRow ? 3 : 1)
                    .multilineTextAlignment(.leading)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: spansRow ? .infinity : nil, alignment: .leading)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(preset.detail)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - Survey rows

/// The label of a survey row: an optional symbol, the title, an optional second line, and a sparkle
/// when Apple Intelligence filled the row in.
struct SurveyRowLabel: View {
    var title: String
    var subtitle: String?
    var systemImage: String?
    var isFilledIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
                Text(title)
                if isFilledIn {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, systemImage == nil ? 0 : 30)
            }
        }
    }
}

extension View {
    /// Tints a survey row that Apple Intelligence filled in, so the student reviews it.
    func filledInHighlight(_ isFilledIn: Bool) -> some View {
        listRowBackground(isFilledIn ? Color.accentColor.opacity(0.14) : nil)
            .accessibilityHint(isFilledIn ? "Filled in by Apple Intelligence. Review it." : "")
    }
}

// MARK: - Summary row

/// "Mornings · Fridays off · 2 blocked times": the generator screen's one-line view of the
/// preferences, and the way back into the survey.
struct SchedulePreferencesSummaryRow: View {
    var preferences: SchedulePreferences
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(preferences.hasWishes ? preferences.summary() : "Describe your ideal week")
                    .font(.footnote.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your ideal week")
        .accessibilityValue(preferences.hasWishes ? preferences.summaryParts.joined(separator: ", ") : "Not set")
        .accessibilityHint("Opens your schedule preferences")
    }
}

/// A list row for the plan screen: the preferences summary with a chevron.
struct SchedulePreferencesListRow: View {
    var preferences: SchedulePreferences

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your ideal week")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(preferences.hasWishes ? preferences.summary(limit: 4) : "Describe the schedule you want, or answer a few questions")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Reason tags

/// Small tags saying why a schedule suits the student's preferences, and where it doesn't.
struct ScheduleReasonTags: View {
    var reasons: [ScheduleReason]

    var body: some View {
        PlanFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(reasons) { reason in
                ScheduleReasonTag(reason: reason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speech)
    }

    /// `Fits your ideal week: Fridays off, no classes before 10 AM. Not ideal: lunch often busy.`
    var speech: String {
        let good = reasons.filter { !$0.isCaveat }.map(\.text)
        let bad = reasons.filter(\.isCaveat).map(\.text)
        var parts: [String] = []
        if !good.isEmpty { parts.append("Fits your ideal week: " + good.joined(separator: ", ")) }
        if !bad.isEmpty { parts.append("Not ideal: " + bad.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }
}

struct ScheduleReasonTag: View {
    var reason: ScheduleReason

    var body: some View {
        let tint: Color = reason.isCaveat ? .orange : .green
        HStack(spacing: 4) {
            Image(systemName: reason.symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(reason.text)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reason.isCaveat ? "Not ideal: \(reason.text)" : reason.text)
    }
}
