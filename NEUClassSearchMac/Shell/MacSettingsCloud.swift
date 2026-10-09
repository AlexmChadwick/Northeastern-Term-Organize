//
//  MacSettingsCloud.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Settings › iCloud: the sync switch, what sync is doing, and "Sync Now".
struct MacCloudSettingsPane: View {
    @Environment(CloudSyncStatus.self) private var cloudSync
    /// Refreshes "2 min. ago" as time passes. A ticker in state rather than a `TimelineView`.
    @State private var now = Date.now

    var body: some View {
        Form {
            Section {
                Toggle("Sync with iCloud", isOn: enabledBinding)
                    .disabled(!cloudSync.isConfiguredInBuild)
                if let notice = cloudSync.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if cloudSync.isEnabled || !cloudSync.isConfiguredInBuild {
                    statusRow
                }
                if cloudSync.isEnabled, cloudSync.canSyncNow || cloudSync.state == .syncing {
                    Button("Sync Now") {
                        cloudSync.syncNow()
                    }
                    .disabled(!cloudSync.canSyncNow)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Schedules, degree plans, your watchlist, saved courses, and your campus and calendar settings sync through your private iCloud database, which the developers can't read. Recent courses, search history and student details from degree audits stay on this Mac.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .task { await MacShellClock.everyMinute { now = $0 } }
    }

    /// Reads as off in a build without iCloud; the stored choice (on by default) is kept for
    /// a build that has it.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { cloudSync.isEnabled && cloudSync.isConfiguredInBuild },
            set: { cloudSync.setEnabled($0) }
        )
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Image(systemName: cloudSync.state.symbolName)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: cloudSync.state == .syncing)
                    .accessibilityHidden(true)
                Text(cloudSync.state.summary(relativeTo: now))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud sync status: \(cloudSync.state.summary(relativeTo: now))")
    }

    private var tint: Color {
        switch cloudSync.state {
        case .upToDate: .green
        case .syncing: .accentColor
        case .off: .secondary
        case .unavailable, .error: .orange
        }
    }
}
