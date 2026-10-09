//
//  SettingsCloudSyncSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Settings › iCloud: the sync switch, what sync is doing, and "Sync now".
struct SettingsCloudSyncSection: View {
    @Environment(CloudSyncStatus.self) private var cloudSync

    var body: some View {
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
                Button {
                    cloudSync.syncNow()
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!cloudSync.canSyncNow)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Schedules, degree plans, your watchlist, saved courses, and your campus and calendar settings sync through your private iCloud database, which the developers can't read. Recent courses, search history and student details from degree audits stay on this device.")
        }
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
        // Refreshes "2 min. ago" as time passes.
        TimelineView(.everyMinute) { context in
            Label {
                Text(cloudSync.state.summary(relativeTo: context.date))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: cloudSync.state.symbolName)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: cloudSync.state == .syncing)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("iCloud sync status: \(cloudSync.state.summary(relativeTo: context.date))")
        }
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
