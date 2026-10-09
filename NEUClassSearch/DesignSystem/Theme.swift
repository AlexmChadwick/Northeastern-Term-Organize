//
//  Theme.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Shared design tokens. Prefer system materials, semantic colors and
/// Liquid Glass for controls; keep content surfaces calm.
enum Theme {
    /// Northeastern red, used sparingly as the app tint.
    static let accent = Color.accentColor

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let chip: CGFloat = 10
        static let card: CGFloat = 22
        static let block: CGFloat = 8
    }

    /// Color describing seat availability.
    static func seatColor(remaining: Int, capacity: Int) -> Color {
        guard remaining > 0 else { return .red }
        guard capacity > 0 else { return .green }
        let fraction = Double(remaining) / Double(capacity)
        return fraction <= 0.1 || remaining <= 2 ? .orange : .green
    }

    static func seatColor(for section: CourseSection) -> Color {
        seatColor(remaining: section.seatsRemaining, capacity: section.seatCapacity)
    }

    /// The fill of content cards: the grouped background on iPhone and iPad, the control
    /// background on the Mac.
    static var cardFill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}

extension View {
    /// A rounded content card with a subtle grouped background (not glass:
    /// Liquid Glass is reserved for controls and navigation).
    func cardBackground(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        background(Theme.cardFill, in: .rect(cornerRadius: cornerRadius))
    }
}

extension CourseColor {
    /// A stable color for a course key when no plan color is assigned.
    static func forCourse(_ key: CourseKey) -> CourseColor { forCode(key.description) }
}
