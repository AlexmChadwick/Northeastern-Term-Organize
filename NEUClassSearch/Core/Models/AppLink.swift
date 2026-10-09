//
//  AppLink.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// The app's own links (`termorganize://course/202710/CS/3000`). Links made before the app was
/// renamed use `neuclasssearch://`; they still open, but new links use the current scheme.
enum AppLink {
    static let scheme = "termorganize"
    /// Schemes the app still opens.
    static let legacySchemes: Set<String> = ["neuclasssearch"]

    /// Whether a URL is one of the app's links, under either name.
    static func isAppLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == Self.scheme || legacySchemes.contains(scheme)
    }

    /// `termorganize://<path>`, e.g. `url("watchlist")` or `url("section/202710/12345")`.
    static func url(_ path: String) -> URL? {
        URL(string: "\(scheme)://\(path)")
    }
}
