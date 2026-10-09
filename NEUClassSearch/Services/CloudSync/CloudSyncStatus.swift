//
//  CloudSyncStatus.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation

/// What the UI can ask iCloud sync to do. Implemented by `CloudSyncController`.
@MainActor
protocol CloudSyncActions: AnyObject {
    func setCloudSyncEnabled(_ isEnabled: Bool)
    func syncCloudNow()
}

/// What iCloud sync is doing on this device, for Settings. Injected into the environment;
/// `CloudSyncController` keeps it current.
@MainActor
@Observable
final class CloudSyncStatus {
    enum UnavailableReason: Equatable, Sendable {
        /// No iCloud account is signed in.
        case noAccount
        /// Parental controls or device management block iCloud.
        case restricted
        /// This build has no iCloud container (or isn't signed for one).
        case notConfigured
        /// The account needs attention (for example, a password or new terms) before it can sync.
        case temporarilyUnavailable
    }

    enum State: Equatable, Sendable {
        /// The user turned sync off.
        case off
        case unavailable(UnavailableReason)
        case syncing
        case upToDate(lastSync: Date?)
        case error(String)
    }

    var state: State = .unavailable(.notConfigured)
    /// The "Sync with iCloud" switch. On unless the user turned it off (or sync turned itself
    /// off, see `notice`).
    var isEnabled = true
    /// Whether this build is set up for iCloud at all.
    var isConfiguredInBuild = false
    /// Why sync turned itself off, e.g. after the iCloud account changed. Cleared when the
    /// user flips the switch.
    var notice: String?
    /// Whether erasing the user's data on this device also deletes it from iCloud (and so
    /// from their other devices).
    var erasesICloudData = false

    @ObservationIgnored weak var actions: (any CloudSyncActions)?

    init() {}

    func setEnabled(_ isEnabled: Bool) {
        actions?.setCloudSyncEnabled(isEnabled)
    }

    func syncNow() {
        actions?.syncCloudNow()
    }

    /// Whether "Sync now" can do anything.
    var canSyncNow: Bool {
        switch state {
        case .upToDate, .error: true
        default: false
        }
    }
}

extension CloudSyncStatus.State {
    /// The status line, e.g. `Up to date · 2 min. ago`.
    func summary(relativeTo now: Date = .now) -> String {
        switch self {
        case .off:
            "Off"
        case .unavailable(.noAccount):
            "Sign in to iCloud in Settings to sync"
        case .unavailable(.restricted):
            "iCloud is restricted on this device"
        case .unavailable(.notConfigured):
            "iCloud sync isn't set up in this build"
        case .unavailable(.temporarilyUnavailable):
            "Check your Apple Account in Settings to sync"
        case .syncing:
            "Syncing…"
        case .upToDate(nil):
            "Up to date"
        case .upToDate(let lastSync?):
            "Up to date · \(Self.relativeLabel(for: lastSync, relativeTo: now))"
        case .error(let message):
            message
        }
    }

    /// SF Symbol for the status line.
    var symbolName: String {
        switch self {
        case .off: "icloud.slash"
        case .unavailable, .error: "exclamationmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        }
    }

    /// `just now`, `2 min. ago`, `3 hr. ago`.
    static func relativeLabel(for date: Date, relativeTo now: Date) -> String {
        let date = min(date, now)
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
