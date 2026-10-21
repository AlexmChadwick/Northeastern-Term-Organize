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
    /// App group shared with the iOS widget extension. The Mac plans file does not use this.
    static let appGroupIdentifier = "group.com.alexchadwick.neuclasssearch"

    /// Mac app and `term-organize-mcp`. Team 832J6JB4V7 must register this group
    /// for the Mac App ID. The iOS widget group is unchanged.
    static let macPlanAppGroupIdentifier = "832J6JB4V7.com.alexchadwick.termorganize"

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
    ///
    /// On macOS this is `UserData.json` inside the Mac plan app group when that
    /// container is available. A sandboxed build that does not have the group
    /// (an ad hoc local build) keeps the file in its own Application Support
    /// directory. The first launch that can see the group copies the old
    /// container file across and leaves `UserData.json.premigration.bak`.
    static var userDataURL: URL {
        #if os(macOS)
        if let grouped = macGroupUserDataURL() {
            UserDataMigration.migrateLegacyContainerIfNeeded(to: grouped)
            return grouped
        }
        #endif
        return applicationSupport.appendingPathComponent("UserData.json")
    }

    #if os(macOS)
    /// Group container when the entitlement is granted. An unsandboxed helper
    /// whose `containerURL` is nil still uses the well-known group path, which
    /// is the same directory the signed app receives.
    static func macGroupUserDataURL() -> URL? {
        let directory: URL
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: macPlanAppGroupIdentifier) {
            directory = container.appendingPathComponent("Library/Application Support", isDirectory: true)
        } else if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return nil
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/\(macPlanAppGroupIdentifier)/Library/Application Support", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("UserData.json")
    }
    #endif

    /// Shared container for data the widget reads, if the app group is available.
    static var sharedContainer: URL? {
        #if canImport(Darwin)
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        #else
        return nil
        #endif
    }
}
