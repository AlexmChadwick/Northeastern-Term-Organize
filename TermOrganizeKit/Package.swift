// swift-tools-version: 5.9
//
// Package.swift
// Term Organize
//
// Copyright (C) 2026 Term Organize contributors.
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE and NOTICE.md in the project root for details.

import PackageDescription

let package = Package(
    name: "TermOrganizeKit",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .library(name: "TermOrganizeKit", targets: ["TermOrganizeKit"]),
        .executable(name: "term-organize-mcp", targets: ["TermOrganizeMCP"]),
    ],
    targets: [
        .target(
            name: "TermOrganizeKit",
            path: "Sources/TermOrganizeKit",
            sources: [
                "Core",
                "MCP",
                "Logic/DegreePlan/DegreeCourseRepeats.swift",
                "Logic/DegreePlan/DegreePlanFormat.swift",
                "Logic/DegreePlan/DegreePlanLogic.swift",
                "Logic/DegreePlan/DegreePlanReordering.swift",
                "Logic/Schedule/ScheduleGenerator.swift",
                "Logic/Schedule/SchedulePreferenceRules.swift",
                "Logic/Schedule/SchedulePreferences.swift",
                "Logic/Schedule/SchedulePreferencesContext.swift",
                "Logic/Schedule/ScheduleScoring.swift",
                "Services/AppPaths.swift",
                "Services/CatalogIndex.swift",
                "Services/CourseEquivalences+Catalog.swift",
                "Services/OfferingHistory.swift",
                "Services/SearchEngine.swift",
                "Services/TermCalendar.swift",
                "Services/UserDataFile.swift",
                "Services/UserModels.swift",
            ]
        ),
        .executableTarget(
            name: "TermOrganizeMCP",
            dependencies: ["TermOrganizeKit"],
            path: "Sources/TermOrganizeMCP"
        ),
        .testTarget(
            name: "TermOrganizeMCPTests",
            dependencies: ["TermOrganizeKit"],
            path: "Tests/TermOrganizeMCPTests"
        ),
    ]
)
