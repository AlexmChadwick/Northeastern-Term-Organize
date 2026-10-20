//
//  AppPaths.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// File locations used by the app. Everything lives on device.
enum AppPaths {
    /// App group shared with the widget extension.
    static let appGroupIdentifier = "group.com.alexchadwick.neuclasssearch"

    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Catalogs downloaded or refreshed on device.
    static var catalogsDirectory: URL {
        let url = applicationSupport.appendingPathComponent("Catalogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Degree requirements read from the academic catalog (catalog.northeastern.edu).
    static var programCatalogDirectory: URL {
        let url = applicationSupport.appendingPathComponent("ProgramCatalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Banner course catalog lookups (prerequisites and equivalents of courses outside the
    /// loaded term) and offering history.
    static var courseInfoDirectory: URL {
        let url = applicationSupport.appendingPathComponent("CourseInfo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Catalog snapshots shipped inside the app bundle.
    static var bundledCatalogURLs: [URL] {
        #if canImport(Darwin)
        let urls = Bundle.main.urls(forResourcesWithExtension: CatalogArchive.fileExtension, subdirectory: nil) ?? []
        let nested = Bundle.main.urls(forResourcesWithExtension: CatalogArchive.fileExtension, subdirectory: "Catalog") ?? []
        var seen = Set<String>()
        var unique: [URL] = []
        for url in urls + nested where seen.insert(url.path).inserted {
            unique.append(url)
        }
        return unique
        #else
        return []
        #endif
    }

    /// The user's plans, watchlist, bookmarks and preferences.
    static var userDataURL: URL { applicationSupport.appendingPathComponent("UserData.json") }

    /// Shared container for data the widget reads, if the app group is available.
    static var sharedContainer: URL? {
        #if canImport(Darwin)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        #else
        return nil
        #endif
    }
}
