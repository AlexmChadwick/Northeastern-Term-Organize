//
//  CourseFormat.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Foundation-only formatting helpers for the course, section and professor screens.
//

import Foundation

enum CourseFormat {
    private static let isoParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// `Sep 9` for an ISO `yyyy-MM-dd` string.
    static func shortDate(_ iso: String?) -> String? {
        guard let iso, let date = isoParser.date(from: iso) else { return nil }
        return dayFormatter.string(from: date)
    }

    /// `Sep 9 – Dec 13`, or a single date when both ends match or only one is known.
    static func dateRange(start: String?, end: String?) -> String? {
        let first = shortDate(start)
        let last = shortDate(end)
        switch (first, last) {
        case let (a?, b?): return a == b ? a : "\(a) – \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// `5 minutes ago`, `yesterday`, `now`.
    static func relative(_ date: Date, to now: Date = .now) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: max(now, date))
    }

    static func count(_ number: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// Deep links understood by `AppRouter.handle(url:)`.
enum CourseLinks {
    static func course(termCode: String, key: CourseKey) -> URL? {
        var components = URLComponents()
        components.scheme = AppLink.scheme
        components.host = "course"
        components.path = "/\(termCode)/\(key.subject)/\(key.number)"
        return components.url
    }

    static func section(termCode: String, crn: String) -> URL? {
        var components = URLComponents()
        components.scheme = AppLink.scheme
        components.host = "section"
        components.path = "/\(termCode)/\(crn)"
        return components.url
    }
}

