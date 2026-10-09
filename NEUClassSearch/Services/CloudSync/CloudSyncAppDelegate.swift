//
//  CloudSyncAppDelegate.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import CloudKit
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app-delegate hooks iCloud sync needs. CloudKit tells the app about changes made on
/// other devices with silent pushes, which require registering for remote notifications (no
/// permission prompt is involved).
#if os(macOS)
final class CloudSyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CloudSyncController.shared.applicationDidFinishLaunching()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return }
        let containerIdentifier = notification.containerIdentifier
        Task { _ = await CloudSyncController.shared.handleRemoteNotification(fromContainer: containerIdentifier) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CloudSyncAppDelegate.logUnavailable(error)
    }
}
#else
final class CloudSyncAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CloudSyncController.shared.applicationDidFinishLaunching()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Only CloudKit's pushes matter here, and only which container they're for.
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            completionHandler(.noData)
            return
        }
        let containerIdentifier = notification.containerIdentifier
        Task {
            let result = await CloudSyncController.shared.handleRemoteNotification(fromContainer: containerIdentifier)
            switch result {
            case .newData: completionHandler(.newData)
            case .noData: completionHandler(.noData)
            case .failed: completionHandler(.failed)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CloudSyncAppDelegate.logUnavailable(error)
    }
}
#endif

extension CloudSyncAppDelegate {
    /// Expected in a build without the push entitlement. Sync still works; it just picks up
    /// other devices' changes when the app opens instead of in the background.
    static func logUnavailable(_ error: Error) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "NEUClassSearch", category: "CloudSync")
            .notice("Remote notifications unavailable: \(error.localizedDescription, privacy: .public)")
    }
}
