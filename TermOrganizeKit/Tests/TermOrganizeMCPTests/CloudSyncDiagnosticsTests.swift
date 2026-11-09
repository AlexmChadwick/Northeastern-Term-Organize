//
//  CloudSyncDiagnosticsTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import TermOrganizeKit

@Suite struct CloudSyncDiagnosticsTests {
    private static let pushKey = "aps-environment"
    private static let macPushKey = "com.apple.developer.aps-environment"

    @Test func signedEntitlementChoosesTheDatabase() {
        let developmentProfile = profile(getTaskAllow: false, environment: nil)
        #expect(CloudSyncDiagnostics.environment(
            entitlements: [CloudSyncDiagnostics.containerEnvironmentEntitlement: "Development"],
            provisioningProfile: developmentProfile
        ) == .development)
        #expect(CloudSyncDiagnostics.environment(
            entitlements: [CloudSyncDiagnostics.containerEnvironmentEntitlement: " production "],
            provisioningProfile: profile(getTaskAllow: true, environment: "Development")
        ) == .production)
    }

    @Test func profileDecidesWhenTheSignatureDoesNotNameAnEnvironment() {
        #expect(CloudSyncDiagnostics.environment(
            entitlements: [:],
            provisioningProfile: profile(getTaskAllow: true, environment: nil)
        ) == .development)
        #expect(CloudSyncDiagnostics.environment(
            entitlements: nil,
            provisioningProfile: profile(getTaskAllow: false, environment: nil)
        ) == .production)
        #expect(CloudSyncDiagnostics.environment(
            entitlements: [:],
            provisioningProfile: profile(getTaskAllow: true, environment: "Production")
        ) == .production)
    }

    @Test func pushEnvironmentIsNotTheCloudKitDatabase() {
        let pushOnly: [String: Any] = [Self.pushKey: "development", Self.macPushKey: "development"]
        #expect(CloudSyncDiagnostics.environment(
            entitlements: pushOnly,
            provisioningProfile: profile(getTaskAllow: true, environment: nil)
        ) == .development)
        #expect(CloudSyncDiagnostics.environment(
            entitlements: pushOnly,
            provisioningProfile: profile(getTaskAllow: false, environment: nil)
        ) == .production)
        #expect(CloudSyncDiagnostics.environment(entitlements: pushOnly, provisioningProfile: nil) == nil)
        #expect(CloudSyncDiagnostics.environment(entitlements: nil, provisioningProfile: [:]) == nil)
    }

    @Test func checkedInEntitlementsLeaveTheDatabaseToTheProfile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ios = try propertyList(root.appendingPathComponent("NEUClassSearchiOS/NEUClassSearch.entitlements"))
        let mac = try propertyList(root.appendingPathComponent("NEUClassSearchMac/NEUClassSearchMac.entitlements"))
        #expect(ios[CloudSyncDiagnostics.containerEnvironmentEntitlement] == nil)
        #expect(mac[CloudSyncDiagnostics.containerEnvironmentEntitlement] == nil)
        #expect(ios[Self.pushKey] as? String == "development")
        #expect(mac[Self.macPushKey] as? String == "development")
        // Xcode Run signs with a development profile. A notarized Developer ID build does not.
        #expect(CloudSyncDiagnostics.environment(entitlements: ios, provisioningProfile: profile(getTaskAllow: true, environment: nil)) == .development)
        #expect(CloudSyncDiagnostics.environment(entitlements: mac, provisioningProfile: profile(getTaskAllow: false, environment: nil)) == .production)
    }

    @Test func readsThePlistInsideAProvisioningProfile() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: profile(getTaskAllow: false, environment: "Production"),
            format: .xml,
            options: 0
        )
        var wrapped = Data("CMS junk".utf8)
        wrapped.append(plist)
        wrapped.append(Data("trailer".utf8))
        let read = try #require(CloudSyncDiagnostics.propertyList(inProvisioningProfile: wrapped))
        #expect(CloudSyncDiagnostics.environment(entitlements: [:], provisioningProfile: read) == .production)
        #expect(CloudSyncDiagnostics.propertyList(inProvisioningProfile: Data("not a profile".utf8)) == nil)
    }

    @Test func summaryLineNamesEnvironmentAccountSyncAndError() {
        #expect(CloudSyncDiagnostics.summary(
            environment: .development,
            accountStatus: "Available",
            lastSync: "never",
            lastError: "None"
        ) == "CloudKit Development · Account Available · Last sync never · Last error None")
        #expect(CloudSyncDiagnostics.summary(
            environment: .production,
            accountStatus: "No Account",
            lastSync: "just now",
            lastError: "You're offline. Changes will sync when you're back online."
        ) == "CloudKit Production · Account No Account · Last sync just now · Last error You're offline. Changes will sync when you're back online.")
        #expect(CloudSyncDiagnostics.summary(
            environment: nil,
            accountStatus: "Not Checked",
            lastSync: "never",
            lastError: "None"
        ) == "CloudKit Unknown · Account Not Checked · Last sync never · Last error None")
    }

    @Test func indeterminateAccountChecksRetryThenStop() {
        #expect(CloudSyncDiagnostics.retriesAccountStatus(afterAttempt: 1))
        #expect(CloudSyncDiagnostics.retriesAccountStatus(afterAttempt: 4))
        #expect(!CloudSyncDiagnostics.retriesAccountStatus(afterAttempt: 5))
        #expect(CloudSyncDiagnostics.countsAsSynced(zoneIsSaved: true, failed: false, hasVisibleIssue: false))
        #expect(!CloudSyncDiagnostics.countsAsSynced(zoneIsSaved: false, failed: false, hasVisibleIssue: false))
        #expect(!CloudSyncDiagnostics.countsAsSynced(zoneIsSaved: true, failed: true, hasVisibleIssue: false))
        #expect(!CloudSyncDiagnostics.countsAsSynced(zoneIsSaved: true, failed: false, hasVisibleIssue: true))
    }

    private func profile(getTaskAllow: Bool, environment: String?) -> [String: Any] {
        var entitlements: [String: Any] = ["get-task-allow": getTaskAllow]
        if let environment {
            entitlements[CloudSyncDiagnostics.containerEnvironmentEntitlement] = environment
        }
        return ["Entitlements": entitlements]
    }

    private func propertyList(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
