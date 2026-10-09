//
//  WatchlistService.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  SearchNEU (https://github.com/sandboxnu/searchneu) texts people through Twilio
//  when a seat opens. This app does the same job entirely on device: it re-checks
//  watched sections against Banner while the app is open (on the iPhone and iPad
//  also from iOS background refresh, on the Mac on a timer while the app runs),
//  and posts local notifications. No server, account or phone number is involved.
//

import Foundation
import UserNotifications
import Observation
#if os(iOS)
import BackgroundTasks
#endif

/// Checks watched sections for open seats and posts local notifications. Shared by the
/// iPhone/iPad app and the Mac app; only the background refresh (BackgroundTasks) is iOS-only.
@MainActor
@Observable
final class WatchlistService {
    static let shared = WatchlistService()

    #if os(iOS)
    /// Identifier of the background refresh task. It must be listed in the app's
    /// `BGTaskSchedulerPermittedIdentifiers` (Info.plist).
    nonisolated static var backgroundTaskIdentifier: String {
        // The app reads this while it builds its scene, before any view appears, which
        // makes it the earliest hook we have without an app delegate. Installing the
        // notification delegate here keeps a tap that launches the app from being lost.
        WatchlistNotificationDelegate.installOnce()
        return (Bundle.main.bundleIdentifier ?? "NEUClassSearch") + ".watchlist-refresh"
    }
    #endif

    /// Foreground checks never run more often than this unless the user asks.
    static let minimumRefreshInterval: TimeInterval = 2 * 60
    /// `refreshIfStale()` re-checks when the oldest check is older than this.
    static let staleInterval: TimeInterval = 10 * 60
    #if os(iOS)
    /// How soon iOS may start the next background check (it decides the actual time).
    nonisolated static let backgroundRefreshInterval: TimeInterval = 20 * 60
    #endif

    // MARK: Observable state

    private(set) var isRefreshing = false
    /// When a check last finished successfully in this session.
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// False until the notification settings have been read once (avoids flashing a prompt card).
    private(set) var hasLoadedAuthorization = false
    /// Watch item ids whose section Banner no longer lists.
    private(set) var missingItemIDs: Set<String> = []

    /// Whether alerts can currently be delivered.
    var canNotify: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    // MARK: Wiring

    @ObservationIgnored private weak var catalog: CatalogStore?
    @ObservationIgnored private weak var userData: UserDataStore?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var knownWatchCount = 0
    @ObservationIgnored private var hasRequestedAuthorization = false

    /// Connects the service to the stores and starts watching the watchlist.
    /// - Parameter openURL: opens a `termorganize://` link (what a tapped notification
    ///   carries); the app's router handles it.
    func configure(
        catalog: CatalogStore,
        userData: UserDataStore,
        openURL: @escaping WatchlistNotificationDelegate.URLHandler
    ) {
        self.catalog = catalog
        self.userData = userData

        WatchlistNotificationDelegate.installOnce()
        WatchlistNotificationDelegate.shared.setHandler(openURL)

        knownWatchCount = userData.watchlist.count
        observeWatchlist()

        Task { [weak self] in
            await self?.reconcileWithSavedWatchlist()
            await self?.refreshAuthorizationStatus()
            // Let the UI settle before touching the network.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.refreshIfStale()
        }
    }

    /// iOS can start the app in the background for a check, and the user may open it in
    /// that same process later. The background check saves new seat numbers to disk,
    /// while the live store still holds the older ones; left alone, the next foreground
    /// check would "discover" the same opening again and repeat the alert. Adopt the
    /// saved numbers whenever they are newer.
    private func reconcileWithSavedWatchlist() async {
        let saved = await Task.detached(priority: .utility) { () -> [WatchItem] in
            guard let raw = try? Data(contentsOf: AppPaths.userDataURL),
                  let decoded = try? JSONDecoder.userData.decode(UserData.self, from: raw) else { return [] }
            return decoded.watchlist
        }.value
        guard let userData, !saved.isEmpty else { return }

        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in userData.watchlist {
            guard let newer = savedByID[item.id],
                  let savedCheck = newer.lastCheckedAt,
                  savedCheck > (item.lastCheckedAt ?? .distantPast) else { continue }
            var merged = item
            merged.lastSeatsRemaining = newer.lastSeatsRemaining
            merged.lastWaitlistRemaining = newer.lastWaitlistRemaining
            merged.seatCapacity = newer.seatCapacity
            merged.lastCheckedAt = newer.lastCheckedAt
            merged.lastNotifiedAt = newer.lastNotifiedAt
            userData.updateWatchItem(merged)
        }
    }

    // MARK: Notification permission

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        hasLoadedAuthorization = true
    }

    /// Asks iOS for permission to show alerts, sounds and badges. Returns whether it was granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorizationStatus()
        return granted
    }

    /// Prompts once per session, and only while the user has never answered.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        await requestAuthorization()
    }

    /// Posts a notification a few seconds from now so users can check that alerts work.
    func sendTestNotification() async {
        await WatchlistNotifier.postTest()
    }

    /// Asks for permission the first time something is added to the watchlist, so
    /// the prompt appears in context and never at launch. Sections that arrive from
    /// another device through iCloud don't prompt: nothing was done on this one.
    private func observeWatchlist() {
        guard let userData else { return }
        withObservationTracking {
            _ = userData.watchlist.count
        } onChange: { [weak self, weak userData] in
            // Called synchronously by the mutation, on the main actor, so this sees whether
            // the change is being applied from iCloud.
            let isRemote = MainActor.assumeIsolated { userData?.isApplyingRemoteChanges ?? false }
            Task { @MainActor in self?.watchlistDidChange(isRemote: isRemote) }
        }
    }

    private func watchlistDidChange(isRemote: Bool) {
        defer { observeWatchlist() }
        guard let userData else { return }
        let count = userData.watchlist.count
        let grew = count > knownWatchCount
        knownWatchCount = count
        if grew && !isRemote {
            Task { await requestAuthorizationIfNeeded() }
        }
    }

    // MARK: Refreshing

    /// Re-checks the watchlist when its oldest check is more than ten minutes old.
    func refreshIfStale() async {
        await refreshAuthorizationStatus()
        await WatchlistNotifier.clearBadge()
        guard let userData, !userData.watchlist.isEmpty else { return }
        let oldest = userData.watchlist.map { $0.lastCheckedAt ?? .distantPast }.min() ?? .distantPast
        guard Date.now.timeIntervalSince(oldest) > Self.staleInterval else { return }
        await refresh(force: false)
    }

    /// Re-checks the watchlist when its oldest check is at least `interval` old. The Mac calls
    /// this on a timer while the app runs; a check that failed is retried after five minutes
    /// at the earliest, so being offline doesn't mean a request every tick.
    func refreshIfDue(interval: TimeInterval) async {
        guard let userData, !userData.watchlist.isEmpty else { return }
        let oldest = userData.watchlist.map { $0.lastCheckedAt ?? .distantPast }.min() ?? .distantPast
        guard Date.now.timeIntervalSince(oldest) >= interval else { return }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < min(interval, 5 * 60) { return }
        await refresh(force: false)
    }

    /// Fetches live seats for every watched section, updates the stored numbers and
    /// posts a notification for each section that gained seats (or waitlist room).
    /// Without `force`, nothing happens when a check started within the last two minutes.
    func refresh(force: Bool = false) async {
        if let refreshTask {
            // Join the check that is already running instead of starting another.
            await refreshTask.value
            return
        }
        guard catalog != nil, let userData, !userData.watchlist.isEmpty else { return }
        if !force, let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < Self.minimumRefreshInterval { return }

        lastAttempt = .now
        isRefreshing = true
        // Run unstructured so a cancelled pull-to-refresh can't leave a half-finished check behind.
        let task = Task { [weak self] in
            await self?.performRefresh()
            self?.finishRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func finishRefresh() {
        refreshTask = nil
        isRefreshing = false
    }

    private func performRefresh() async {
        guard let catalog, let userData else { return }
        lastError = nil

        var live: [String: [CourseKey: [CourseSection]]] = [:]
        var failures: [Error] = []
        let byTerm = Dictionary(grouping: userData.watchlist, by: \.termCode)
        for termCode in byTerm.keys.sorted(by: >) {
            let keys = Array(Set((byTerm[termCode] ?? []).map(\.courseKey))).sorted()
            do {
                live[termCode] = try await catalog.liveSections(for: keys, termCode: termCode)
            } catch {
                if Self.isCancellation(error) { return }
                failures.append(error)
            }
        }

        if !live.isEmpty {
            // Compare against the watchlist as it is now: the user may have edited it while we waited.
            let outcome = WatchlistComparison.compare(items: userData.watchlist, live: live)
            userData.replaceWatchlist(outcome.items)
            lastRefresh = .now
            let unchecked = outcome.items.filter { live[$0.termCode] == nil }.map(\.id)
            missingItemIDs = outcome.missingIDs.union(missingItemIDs.intersection(unchecked))
            let openCount = outcome.items.filter { $0.lastSeatsRemaining > 0 }.count
            await WatchlistNotifier.post(outcome.alerts, openCount: openCount)
        }

        if let error = failures.first {
            lastError = error.localizedDescription
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Forgets per-item state after the user erased their data.
    func didEraseWatchlist() {
        missingItemIDs = []
        lastError = nil
        WatchlistNotifier.removeAll()
        Task { await WatchlistNotifier.clearBadge() }
    }

    #if os(iOS)
    // MARK: Background refresh

    /// Asks iOS for a background check in about 20 minutes, or cancels the request.
    /// iOS decides when (and whether) it really runs; errors are expected on the
    /// simulator and are ignored.
    nonisolated static func scheduleBackgroundRefresh(enabled: Bool) {
        let scheduler = BGTaskScheduler.shared
        let identifier = backgroundTaskIdentifier
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: backgroundRefreshInterval)
        do {
            try scheduler.submit(request)
        } catch {
            // Not supported on the simulator, or background refresh is turned off for the app.
        }
    }

    /// Runs inside the app's `.backgroundTask(.appRefresh(...))`. Works on the live
    /// store when the app process is still around, otherwise on a fresh read of the
    /// JSON file, and talks to the repository directly (no `CatalogStore` needed).
    nonisolated static func performBackgroundRefresh() async {
        let store = await MainActor.run { WatchlistService.shared.userData ?? UserDataStore() }
        let plan = await MainActor.run { () -> (items: [WatchItem], enabled: Bool) in
            let items = store.watchlist
            return (items, store.preferences.backgroundRefreshEnabled && !items.isEmpty)
        }

        // Without permission to notify there is nothing worth waking the network for;
        // the next time the app moves to the background it asks for a new check.
        guard plan.enabled, await WatchlistNotifier.isAuthorized() else { return }

        // Queue the next check first so one that is cut short doesn't end the chain.
        scheduleBackgroundRefresh(enabled: true)

        var live: [String: [CourseKey: [CourseSection]]] = [:]
        let byTerm = Dictionary(grouping: plan.items, by: \.termCode)
        for termCode in byTerm.keys.sorted(by: >) {
            if Task.isCancelled { break }
            let keys = Array(Set((byTerm[termCode] ?? []).map(\.courseKey))).sorted()
            if let sections = try? await CatalogRepository.shared.refreshCourses(keys, termCode: termCode) {
                live[termCode] = sections
            }
        }
        guard !live.isEmpty else { return }
        let fetched = live

        // Save before notifying: a crash in between can then never produce duplicate alerts.
        let outcome = await MainActor.run { () -> WatchlistComparison.Outcome in
            let outcome = WatchlistComparison.compare(items: store.watchlist, live: fetched)
            store.replaceWatchlist(outcome.items)
            store.flushNow()
            WatchlistService.shared.recordBackgroundOutcome(outcome)
            return outcome
        }
        let openCount = outcome.items.filter { $0.lastSeatsRemaining > 0 }.count
        await WatchlistNotifier.post(outcome.alerts, openCount: openCount)
    }

    private func recordBackgroundOutcome(_ outcome: WatchlistComparison.Outcome) {
        lastRefresh = .now
        let unchecked = outcome.items.filter { !outcome.checkedTermCodes.contains($0.termCode) }.map(\.id)
        missingItemIDs = outcome.missingIDs.union(missingItemIDs.intersection(unchecked))
    }
    #endif
}
