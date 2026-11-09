//
//  CloudSyncDiagnostics.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Which CloudKit database a build talks to, and the one-line Settings readout.
//
//  `aps-environment` is the push environment. It does not choose the database. CloudKit
//  uses `com.apple.developer.icloud-container-environment` when the signature has it
//  (Xcode adds it from the provisioning profile at sign time). Otherwise a development
//  profile (`get-task-allow`) is Development and a distribution profile (Developer ID,
//  App Store, TestFlight, or Ad Hoc) is Production. The two databases do not share records,
//  and Production does not create custom record types on first save.
//

import Foundation

/// The CloudKit container environment a signed app uses.
enum CloudSyncContainerEnvironment: String, Equatable, Sendable {
    case development = "Development"
    case production = "Production"
}

enum CloudSyncDiagnostics {
    /// Entitlement that pins the container environment. Absent from the checked-in
    /// entitlements; Xcode injects it into the signature from the profile.
    static let containerEnvironmentEntitlement = "com.apple.developer.icloud-container-environment"

    /// How many times to retry an indeterminate account check while the app stays open.
    /// The attempt count is incremented before this check, so `1` is the first retry and
    /// `maxAccountStatusAttempts` is the last one that still runs.
    static let maxAccountStatusAttempts = 5

    static func retriesAccountStatus(afterAttempt attempt: Int) -> Bool {
        attempt <= maxAccountStatusAttempts
    }

    /// Where to read the embedded provisioning profile. `Bundle.url(forResource:)` finds
    /// `embedded.mobileprovision` and `embedded.provisionprofile` in Resources. A Mac app
    /// keeps the profile at `Contents/embedded.provisionprofile`, beside the executable.
    static func embeddedProvisioningProfileURL(resourceURL: URL?, bundleURL: URL) -> URL {
        if let resourceURL { return resourceURL }
        return bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
    }

    /// What the status row should show once a pass has settled. A retryable failure sets
    /// `fetchFailed` or `sendFailed` without a status-line message. That is still syncing,
    /// so the row does not say up to date while the footnote shows the error.
    enum SettledState: Equatable, Sendable {
        case syncing
        case error
        case upToDate
    }

    static func settledState(
        hasVisibleIssue: Bool,
        fetchFailed: Bool,
        sendFailed: Bool,
        zoneIsSaved: Bool,
        engineIsRunning: Bool
    ) -> SettledState {
        if hasVisibleIssue { return .error }
        if fetchFailed || sendFailed || !engineIsRunning || !zoneIsSaved { return .syncing }
        return .upToDate
    }

    /// A definite account answer replaces the "couldn't check" error. Sync errors stay.
    static func lastErrorSummary(isAccountDefinite: Bool, previous: String?, accountCheckMessage: String) -> String? {
        guard isAccountDefinite, previous == accountCheckMessage else { return previous }
        return nil
    }

    /// Whether a finished fetch or send stored something. A fetch that completes before
    /// the `UserData` zone exists, or that failed (including errors the engine will retry),
    /// has not synced.
    static func countsAsSynced(zoneIsSaved: Bool, failed: Bool, hasVisibleIssue: Bool) -> Bool {
        zoneIsSaved && !failed && !hasVisibleIssue
    }

    /// The environment CloudKit will use for this signature and profile.
    /// The signed entitlement wins. The profile's copy is next. A profile that only says
    /// whether a debugger may attach decides the rest: allowed means Development.
    static func environment(
        entitlements: [String: Any]?,
        provisioningProfile: [String: Any]?
    ) -> CloudSyncContainerEnvironment? {
        if let named = namedEnvironment(in: entitlements) { return named }
        let profileEntitlements = provisioningProfile?["Entitlements"] as? [String: Any]
        if let named = namedEnvironment(in: profileEntitlements) { return named }
        guard let allowsDebugger = profileEntitlements?["get-task-allow"] as? Bool else { return nil }
        return allowsDebugger ? .development : .production
    }

    /// The plist inside a CMS provisioning profile (`.mobileprovision` or `.provisionprofile`).
    static func propertyList(inProvisioningProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              start.lowerBound < end.lowerBound else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }

    /// One read-only Settings line. `lastSync` and `lastError` are already display text.
    /// Until the signature has been read, the environment is "Checking". "Unknown" means
    /// the read finished and neither the signature nor the profile named a database.
    static func summary(
        environment: CloudSyncContainerEnvironment?,
        environmentResolved: Bool,
        accountStatus: String,
        lastSync: String,
        lastError: String
    ) -> String {
        let environmentName: String
        if let environment {
            environmentName = environment.rawValue
        } else if environmentResolved {
            environmentName = "Unknown"
        } else {
            environmentName = "Checking"
        }
        return "CloudKit \(environmentName) · Account \(accountStatus) · Last sync \(lastSync) · Last error \(lastError)"
    }

    private static func namedEnvironment(in entitlements: [String: Any]?) -> CloudSyncContainerEnvironment? {
        guard let raw = entitlements?[containerEnvironmentEntitlement] as? String else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development": return .development
        case "production": return .production
        default: return nil
        }
    }
}
