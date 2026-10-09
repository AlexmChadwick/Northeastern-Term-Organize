//
//  WatchlistNotifications.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import UserNotifications
import os

/// The app's `UNUserNotificationCenter` delegate.
///
/// - Shows banners (with sound) while the app is in the foreground.
/// - Opens the `termorganize://section/<term>/<crn>` link carried by a
///   notification when the user taps it. Taps that arrive before the router is
///   known (cold launch) are queued and replayed by `setHandler(_:)`.
final class WatchlistNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    typealias URLHandler = @MainActor @Sendable (URL) -> Void

    static let shared = WatchlistNotificationDelegate()

    private struct State {
        var handler: URLHandler?
        var pending: [URL] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let installation: Void = {
        UNUserNotificationCenter.current().delegate = WatchlistNotificationDelegate.shared
    }()

    /// Makes the shared instance the notification center's delegate (idempotent, thread safe).
    static func installOnce() {
        _ = installation
    }

    /// Registers the closure that opens a link, and replays any taps received earlier.
    func setHandler(_ handler: @escaping URLHandler) {
        let pending = state.withLock { values -> [URL] in
            values.handler = handler
            let queued = values.pending
            values.pending = []
            return queued
        }
        for url in pending {
            Task { @MainActor in handler(url) }
        }
    }

    private func deliver(_ url: URL) {
        let handler = state.withLock { values -> URLHandler? in
            if values.handler == nil { values.pending.append(url) }
            return values.handler
        }
        if let handler {
            Task { @MainActor in handler(url) }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let string = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: string) else { return }
        deliver(url)
    }
}

/// Posts local notifications for seat alerts.
enum WatchlistNotifier {
    /// Whether the user allowed notifications.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// Delivers one notification per alert. `openCount` is the number of watched
    /// sections that currently have seats; it becomes the app icon badge until the
    /// app is opened again.
    static func post(_ alerts: [WatchlistAlert], openCount: Int) async {
        guard !alerts.isEmpty, await isAuthorized() else { return }
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            if !alert.courseTitle.isEmpty { content.subtitle = alert.courseTitle }
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = alert.threadIdentifier
            // `.timeSensitive` needs an entitlement we don't have.
            content.interruptionLevel = .active
            content.badge = NSNumber(value: max(1, openCount))
            var userInfo: [String: String] = ["termCode": alert.termCode, "crn": alert.crn]
            if let url = alert.url { userInfo["url"] = url.absoluteString }
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// A notification a few seconds from now so users can confirm alerts work.
    static func postTest() async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Seat alerts are on"
        content.body = "This is how you'll hear about open seats in the sections you watch."
        content.sound = .default
        content.threadIdentifier = "watch-test"
        content.interruptionLevel = .active
        content.userInfo = ["url": "\(AppLink.scheme)://watchlist"]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(identifier: "watch-test", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Clears the app icon badge (the user is looking at the app now).
    static func clearBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Removes delivered and pending notifications (used when the user erases their data).
    static func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }
}
