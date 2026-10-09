//
//  CourseColor.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Shared by the app and the widget extension.
//

import SwiftUI

/// Colors assigned to courses in schedules and calendars. Each color works in
/// light and dark mode: use `fill` for block backgrounds, `stroke` for borders
/// and accents, `text` for labels drawn on `fill`.
struct CourseColor: Hashable, Sendable {
    let base: Color

    static let palette: [CourseColor] = [
        CourseColor(base: .blue),
        CourseColor(base: .orange),
        CourseColor(base: .green),
        CourseColor(base: .purple),
        CourseColor(base: .pink),
        CourseColor(base: .teal),
        CourseColor(base: .indigo),
        CourseColor(base: .brown),
        CourseColor(base: .mint),
        CourseColor(base: .red),
    ]

    static func at(_ index: Int) -> CourseColor {
        palette[((index % palette.count) + palette.count) % palette.count]
    }

    /// A stable color for a course code (e.g. `CS 3000`) when no plan color is assigned.
    static func forCode(_ code: String) -> CourseColor {
        var hash: UInt64 = 5381
        for byte in code.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return at(Int(hash % UInt64(palette.count)))
    }

    var fill: Color { base.opacity(0.18) }
    var stroke: Color { base }
    var text: Color { base }
}
