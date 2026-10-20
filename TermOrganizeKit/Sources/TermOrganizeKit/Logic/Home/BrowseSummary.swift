//
//  BrowseSummary.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Count lines and level names for the lists of courses (subject, NUpath, saved), shared by the
//  iPhone, iPad and Mac interfaces.
//

import Foundation

/// A count line such as "12 of 42 courses · 9 with open seats".
///
/// `open` is the number of courses with open seats among the ones shown. It is
/// left out when "open seats only" is already applied, since it would only
/// repeat the shown count.
func browseSummaryText(shown: Int, total: Int, open: Int, openOnly: Bool = false, noun: String = "course") -> String {
    func plural(_ count: Int) -> String { count == 1 ? noun : noun + "s" }
    var text = shown == total
        ? "\(total.formatted()) \(plural(total))"
        : "\(shown.formatted()) of \(total.formatted()) \(plural(total))"
    if open > 0, !openOnly { text += " · \(open.formatted()) with open seats" }
    return text
}

/// "1000-level", or a neutral label for course numbers that do not start with 1…9.
func browseLevelTitle(_ level: Int) -> String {
    level == 0 ? "Under 1000" : "\(level)000-level"
}

/// "3000-level courses", or "courses under 1000" for numbers that do not start with 1…9.
func browseLevelNoun(_ level: Int) -> String {
    level == 0 ? "courses under 1000" : "\(level)000-level courses"
}
