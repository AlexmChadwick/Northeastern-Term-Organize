//
//  ScheduleDroppedCourse.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A course, and optionally one of its sections, dropped on a schedule from a course table: one
/// `CS 3000` or `CS 3000 12345` (course and CRN) per line of the dragged text.
struct ScheduleDroppedCourse: Hashable, Sendable {
    var key: CourseKey
    var crn: String?

    init?(line: Substring) {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let key = CourseKey(string: "\(parts[0]) \(parts[1])"),
              key.number.contains(where: \.isNumber) else { return nil }
        self.key = key
        if parts.count >= 3, parts[2].count == 5, parts[2].allSatisfy(\.isNumber) {
            crn = String(parts[2])
        } else {
            crn = nil
        }
    }

    /// Every course in the dragged text, in order and without repeats. Text that isn't a course
    /// (a professor's name, say) is skipped.
    static func parse(_ items: [String]) -> [ScheduleDroppedCourse] {
        var seen = Set<ScheduleDroppedCourse>()
        return items.flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { ScheduleDroppedCourse(line: $0) }
            .filter { seen.insert($0).inserted }
    }
}
