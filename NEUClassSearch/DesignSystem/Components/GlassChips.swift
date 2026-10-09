//
//  GlassChips.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A Liquid Glass capsule used for quick filters. Selected chips are tinted.
struct GlassChip: View {
    var title: String
    var systemImage: String?
    var isOn: Bool
    var showsChevron = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassChipLabel(title: title, systemImage: systemImage, isOn: isOn, showsChevron: showsChevron)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// The label of a glass chip; use with `Menu` when the chip opens a menu:
/// `Menu { … } label: { GlassChipLabel(…) }.glassChipStyle(isOn:)`.
struct GlassChipLabel: View {
    var title: String
    var systemImage: String?
    var isOn: Bool
    var showsChevron = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .contentShape(.capsule)
    }
}

extension View {
    /// Applies the glass chip treatment to arbitrary content (e.g. a `Menu`).
    func glassChipStyle(isOn: Bool) -> some View {
        glassEffect(isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
    }
}

/// A horizontally scrolling row of glass chips that blend together.
struct GlassChipBar<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) {
                    content
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 6)
            }
        }
        .scrollClipDisabled()
    }
}
