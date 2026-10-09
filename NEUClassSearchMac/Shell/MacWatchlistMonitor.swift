//
//  MacWatchlistMonitor.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The Mac has no background refresh like iOS, so it checks the watchlist on a timer for as
//  long as the app runs (closing the window doesn't stop it) and posts the same local
//  notifications as the iPhone. The checking itself is `WatchlistService`, shared with iOS.
//

import Foundation

/// Re-checks the watched sections every few minutes while the app runs.
@MainActor
final class MacWatchlistMonitor {
    static let shared = MacWatchlistMonitor()

    /// Settings › Notifications › "Check every": minutes between automatic checks.
    static let intervalKey = "mac.watchlist.checkMinutes"
    static let defaultMinutes = 15
    static let intervalChoices = [5, 10, 15, 30, 60]

    /// The interval in force, in minutes.
    static var minutes: Int {
        let stored = UserDefaults.standard.integer(forKey: intervalKey)
        return stored > 0 ? stored : defaultMinutes
    }

    private var loop: Task<Void, Never>?

    private init() {}

    /// Starts watching the watchlist (once; later calls only point notification links at the
    /// window that called). `openLink` opens the `termorganize://` link a tapped alert carries.
    func start(
        catalog: CatalogStore,
        userData: UserDataStore,
        openLink: @escaping WatchlistNotificationDelegate.URLHandler
    ) {
        guard loop == nil else {
            WatchlistNotificationDelegate.shared.setHandler(openLink)
            return
        }
        WatchlistService.shared.configure(catalog: catalog, userData: userData, openURL: openLink)
        loop = Task { [weak userData] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let userData, userData.preferences.backgroundRefreshEnabled else { continue }
                await WatchlistService.shared.refreshIfDue(interval: TimeInterval(Self.minutes * 60))
            }
        }
    }
}
