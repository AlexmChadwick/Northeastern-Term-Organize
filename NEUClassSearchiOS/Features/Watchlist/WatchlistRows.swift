//
//  WatchlistRows.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UserNotifications

/// `Checked 5 min ago`, refreshed every minute.
struct WatchlistCheckedLabel: View {
    var date: Date?

    var body: some View {
        if let date {
            TimelineView(.everyMinute) { context in
                Text("Checked \(WatchlistFormat.ago(date, now: context.date))")
            }
        } else {
            Text("Not checked yet")
        }
    }
}

/// One watched section: status icon, section name, CRN, seats and when it was last checked.
struct WatchlistRow: View {
    var item: WatchItem
    var isMissing: Bool

    private var status: WatchlistStatus { WatchlistStatus(item: item, isMissing: isMissing) }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: status.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.title2)
                .foregroundStyle(status.color)
                .frame(width: 30)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.sectionLabel)
                    .font(.body.weight(.semibold))
                Text(status.detail(for: item))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(status.color)
                    .monospacedDigit()
                if status != .missing, item.seatCapacity > 0 {
                    SeatMeter(remaining: item.lastSeatsRemaining, capacity: item.seatCapacity)
                        .padding(.vertical, 2)
                }
                // One line when it fits, two at large text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        crnLabel
                        Text("·")
                        WatchlistCheckedLabel(date: item.lastCheckedAt)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        crnLabel
                        WatchlistCheckedLabel(date: item.lastCheckedAt)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if item.notifyOnWaitlist {
                    TagLabel(text: "Waitlist alerts", systemImage: "bell.badge", tint: .orange)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var crnLabel: some View {
        Text("CRN \(item.crn)")
            .monospacedDigit()
    }

    private var accessibilityText: String {
        var parts = [
            "\(item.courseKey.description), \(item.sectionLabel)",
            "CRN \(item.crn)",
            status.spokenDetail(for: item),
        ]
        if let checked = item.lastCheckedAt {
            parts.append("Checked \(WatchlistFormat.ago(checked, now: .now))")
        }
        if item.notifyOnWaitlist { parts.append("Waitlist alerts on") }
        return parts.joined(separator: ". ")
    }
}

/// The header above a course's watched sections: code, title and an optional term tag.
struct WatchlistGroupHeader: View {
    var key: CourseKey
    var title: String
    /// Shown when the watchlist spans several terms.
    var termName: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(key.description)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.tint)
                        if let termName {
                            TagLabel(text: termName, systemImage: "calendar")
                        }
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Theme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.vertical, 2)
        .accessibilityLabel("\(key.description), \(title)\(termName.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens course details")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Inline card asking for notification permission, or explaining how to turn it back on.
struct WatchlistPermissionCard: View {
    var status: UNAuthorizationStatus
    var requestAction: () -> Void
    var openSettingsAction: () -> Void

    private var isDenied: Bool { status == .denied }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: isDenied ? "bell.slash.fill" : "bell.badge.fill")
                    .font(.title2)
                    .foregroundStyle(isDenied ? Color.red : Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isDenied ? "Notifications are turned off" : "Turn on notifications to get alerted when seats open")
                        .font(.headline)
                    Text(isDenied
                         ? "Term Organize can't tell you about open seats until notifications are allowed in Settings."
                         : "Alerts are delivered on this device. No account or phone number needed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: isDenied ? openSettingsAction : requestAction) {
                Text(isDenied ? "Open Settings" : "Turn On Notifications")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
