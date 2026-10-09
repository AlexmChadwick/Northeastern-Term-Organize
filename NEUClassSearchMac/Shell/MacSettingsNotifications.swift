//
//  MacSettingsNotifications.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI
import UserNotifications

/// Settings › Notifications: whether seat alerts can be delivered, and how often the Watchlist
/// is checked while the app runs.
struct MacNotificationSettingsPane: View {
    @Environment(UserDataStore.self) private var userData
    @AppStorage(MacWatchlistMonitor.intervalKey) private var minutes = MacWatchlistMonitor.defaultMinutes

    /// Shows a given permission instead of the real one (snapshots only).
    var previewStatus: UNAuthorizationStatus?

    private let alerts = WatchlistService.shared
    @State private var now = Date.now

    init(previewStatus: UNAuthorizationStatus? = nil) {
        self.previewStatus = previewStatus
    }

    private var status: UNAuthorizationStatus { previewStatus ?? alerts.authorizationStatus }

    var body: some View {
        Form {
            alertsSection
            checkingSection
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            guard previewStatus == nil else { return }
            await alerts.refreshAuthorizationStatus()
        }
        .task { await MacShellClock.everyMinute { now = $0 } }
        // The user may have changed the permission in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard previewStatus == nil else { return }
            Task { await alerts.refreshAuthorizationStatus() }
        }
    }

    // MARK: Alerts

    private var alertsSection: some View {
        Section {
            LabeledContent("Notifications") {
                switch status {
                case .authorized, .provisional, .ephemeral:
                    Label("On", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .denied:
                    Label("Off", systemImage: "bell.slash.fill")
                        .foregroundStyle(.red)
                default:
                    Text("Not turned on")
                        .foregroundStyle(.secondary)
                }
            }
            actionRow
        } header: {
            Text("Seat Alerts")
        } footer: {
            Text("You're notified on this Mac when a seat or waitlist spot opens in a section you watch. No account or phone number needed.")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch status {
        case .authorized, .provisional, .ephemeral:
            Button("Send a Test Notification") {
                Task { await alerts.sendTestNotification() }
            }
        case .denied:
            Button("Open Notification Settings…") {
                MacSystemSettings.openNotifications()
            }
        default:
            Button("Turn On Notifications") {
                Task { await alerts.requestAuthorization() }
            }
        }
    }

    // MARK: Checking

    private var checkingSection: some View {
        Section {
            Toggle("Check for open seats automatically", isOn: userData.macPreferenceBinding(\.backgroundRefreshEnabled))
            Picker("Check every", selection: $minutes) {
                ForEach(MacWatchlistMonitor.intervalChoices, id: \.self) { value in
                    Text(Self.label(minutes: value)).tag(value)
                }
            }
            .disabled(!userData.preferences.backgroundRefreshEnabled)
            LabeledContent("Last checked") {
                if let date = lastChecked {
                    Text(WatchlistFormat.ago(date, now: now))
                } else {
                    Text(userData.watchlist.isEmpty ? "Nothing watched" : "Not yet")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = alerts.lastError {
                Label {
                    Text("Couldn't check seats. \(error)")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            Button("Check Now") {
                Task { await alerts.refresh(force: true) }
            }
            .disabled(userData.watchlist.isEmpty || alerts.isRefreshing)
        } header: {
            Text("Checking")
        } footer: {
            Text("Term Organize checks your Watchlist while it's running, even with its windows closed. A Mac can't wake an app that isn't running, so quit it and the checks stop until you open it again. You can also check any time from the Watchlist with ⌘R.")
        }
    }

    /// When a section last had its seats checked, on this Mac or (through iCloud) another device.
    private var lastChecked: Date? {
        alerts.lastRefresh ?? userData.watchlist.compactMap(\.lastCheckedAt).max()
    }

    private static func label(minutes: Int) -> String {
        switch minutes {
        case 60: "Hour"
        default: "\(minutes) minutes"
        }
    }
}
