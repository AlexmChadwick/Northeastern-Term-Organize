//
//  ProfessorMonogram.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A tinted circle with a person's initials. The color is stable per name.
struct ProfessorMonogram: View {
    /// The Banner name (`Last, First`).
    var name: String
    var font: Font = .title2.weight(.semibold)
    /// Diameter at the default text size; scales with Dynamic Type.
    var diameter: CGFloat = 64

    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        let color = CourseColor.forCode(name)
        Text(ProfessorNames.initials(for: name))
            .font(font)
            .foregroundStyle(color.text)
            .frame(width: diameter * min(scale, 1.8), height: diameter * min(scale, 1.8))
            .background(color.fill, in: .circle)
            .overlay(Circle().strokeBorder(color.stroke.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }
}
