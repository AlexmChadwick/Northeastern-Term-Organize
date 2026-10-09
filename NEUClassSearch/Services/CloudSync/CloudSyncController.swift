//
//  CloudSyncController.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  iCloud sync, part 3: the CloudKit side. Runs a CKSyncEngine on the user's private
//  database, feeds it local changes, merges what it fetches into UserDataStore and keeps
//  CloudSyncStatus current. Decisions are made by the pure code in CloudSyncModel and
//  CloudSyncState; this file only moves data between them, CloudKit and the store.
//
//  CloudKit is touched only when sync is on, Info.plist names a container, the app is
//  signed for that container and an iCloud account is available. Otherwise the app works
//  exactly as without sync, and Settings explains why.
//
//  Accounts: signing in merges this device's data with the account's (uploading what's
//  only here). Signing out keeps the data here, forgets the sync bookkeeping and stops.
//  A different account turns sync off until the user turns it on again, so two people's
//  data never mix by accident.
//

import CloudKit
import Foundation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// What a push-triggered fetch found; the iOS app delegate maps it to `UIBackgroundFetchResult`.
enum CloudSyncFetchResult: Sendable {
    case newData, noData, failed
}

@MainActor
final class CloudSyncController {
    static let shared = CloudSyncController()

    /// What Settings shows.
    let status = CloudSyncStatus()

    /// The shortest time between fetches started by the app becoming active.
    static let minimumFetchInterval: TimeInterval = 60
    private static let enabledDefaultsKey = "CloudSyncEnabled"
    /// Errors CKSyncEngine retries on its own; they aren't shown unless the user tapped "Sync now".
    private static let retriedErrorCodes: Set<CKError.Code> = [
        .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
        .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled,
    ]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NEUClassSearch", category: "CloudSync")
    private let files = CloudSyncFiles()

    private weak var userData: UserDataStore?
    private var metadata = CloudSyncMetadata()
    private var isPrepared = false

    private var container: CKContainer?
    private var engine: CKSyncEngine?
    private var entitlements: CloudSyncEntitlements.Availability?
    private var unavailableReason: CloudSyncStatus.UnavailableReason?
    private var accountIssue: String?
    private var fetchIssue: String?
    private var sendIssue: String?
    private var isFetching = false
    private var isSending = false
    private var isSyncingManually = false
    /// The first sync with an account looks at iCloud before sending anything, so values
    /// that already match aren't uploaded again.
    private var isAwaitingFirstFetch = false
    private var lastFetchRequest: Date?
    private var evaluationTask: Task<Void, Never>?
    private var needsEvaluation = false
    private var metadataSaveTask: Task<Void, Never>?
    private var accountObserver: (any NSObjectProtocol)?
    /// Fingerprints of the values in the batch being sent, by record.
    private var sentFingerprints: [CloudSyncKey: String] = [:]

    private init() {}

    // MARK: Lifecycle

    /// Connects sync to the store. Call once, as early as possible (the app's initializer):
    /// iOS may launch the app in the background just to deliver a change from iCloud.
    func attach(to userData: UserDataStore) {
        guard self.userData == nil else { return }
        self.userData = userData
        status.actions = self
        status.isEnabled = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
        status.isConfiguredInBuild = CloudSyncConfig.containerIdentifier() != nil
        guard status.isConfiguredInBuild else {
            // Without a container nothing is tracked and CloudKit is never touched.
            refreshStatus()
            return
        }
        userData.didChange = { [weak self] in self?.syncLocalChanges() }
        refreshStatus()
        // Read the bookkeeping once launch has finished.
        Task { [weak self] in self?.prepare() }
    }

    private func prepare() {
        guard !isPrepared, let userData else { return }
        metadata = files.loadMetadata() ?? CloudSyncMetadata()
        isPrepared = true
        metadata.observeLocalData(CloudSyncSnapshot(userData.data), now: .now)
        saveMetadata()
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestEvaluation() }
        }
        refreshStatus()
        requestEvaluation()
    }

    /// From the app delegate: CloudKit tells the app about changes with silent pushes.
    func applicationDidFinishLaunching() {
        guard status.isConfiguredInBuild, status.isEnabled else { return }
        Self.registerForRemoteNotifications()
    }

    /// Silent pushes need no permission prompt on either platform.
    private static func registerForRemoteNotifications() {
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Fetches when the app comes to the foreground (at most once a minute), or reconnects
    /// if the account changed in the meantime.
    func appDidBecomeActive() {
        guard isPrepared, status.isEnabled else { return }
        guard engine != nil else {
            requestEvaluation()
            return
        }
        fetchIfDue(force: false)
    }

    func appDidEnterBackground() {
        saveMetadata(immediately: true)
    }

    /// From the app delegate, for a CloudKit push (silent; another device changed something).
    func handleRemoteNotification(fromContainer containerIdentifier: String?) async -> CloudSyncFetchResult {
        guard let containerIdentifier, containerIdentifier == CloudSyncConfig.containerIdentifier() else { return .noData }
        prepare()
        guard isPrepared, status.isEnabled else { return .noData }
        if engine == nil {
            requestEvaluation()
            await evaluationTask?.value
        }
        guard let engine else { return .noData }
        do {
            try await engine.fetchChanges()
            return .newData
        } catch {
            return .failed
        }
    }

    // MARK: Account and engine

    private func requestEvaluation() {
        guard isPrepared else { return }
        guard evaluationTask == nil else {
            needsEvaluation = true
            return
        }
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.needsEvaluation = false
                await self.evaluate()
            } while self.needsEvaluation
            self.evaluationTask = nil
        }
    }

    /// Starts or stops the engine to match the switch, the build and the iCloud account.
    private func evaluate() async {
        guard status.isEnabled, status.isConfiguredInBuild,
              let identifier = CloudSyncConfig.containerIdentifier() else {
            retireEngine()
            refreshStatus()
            return
        }
        if entitlements == nil {
            entitlements = await Task.detached(priority: .utility) {
                CloudSyncEntitlements.cloudKitAvailability(containerIdentifier: identifier)
            }.value
        }
        guard entitlements != .missing else {
            logger.error("This build isn't signed for \(identifier, privacy: .public), so iCloud sync stays off.")
            status.isConfiguredInBuild = false
            retireEngine()
            refreshStatus()
            return
        }

        let container = self.container ?? CKContainer(identifier: identifier)
        self.container = container
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            accountIssue = "Couldn't check your iCloud account. Sync will try again later."
            logger.error("Account status failed: \(error.localizedDescription, privacy: .public)")
            refreshStatus()
            return
        }
        accountIssue = nil
        // The switch may have been turned off while waiting.
        guard status.isEnabled else {
            refreshStatus()
            return
        }

        switch accountStatus {
        case .available:
            unavailableReason = nil
            guard engine == nil else { break }
            let savedState = files.loadEngineState()
            if savedState == nil, let known = metadata.accountRecordName {
                // Signed out earlier: merge only into the same account.
                let current: CKRecord.ID
                do {
                    current = try await container.userRecordID()
                } catch {
                    accountIssue = "Couldn't check your iCloud account. Sync will try again later."
                    logger.error("User record lookup failed: \(error.localizedDescription, privacy: .public)")
                    break
                }
                guard status.isEnabled, engine == nil else { break }
                guard current.recordName == known else {
                    accountDidSwitch()
                    return
                }
            }
            startEngine(container: container, savedState: savedState)
        case .noAccount:
            unavailableReason = .noAccount
            retireEngine()
        case .restricted:
            unavailableReason = .restricted
            retireEngine()
        case .temporarilyUnavailable:
            // Keep everything; CKAccountChanged arrives once the account is usable again.
            unavailableReason = .temporarilyUnavailable
            retireEngine()
        case .couldNotDetermine:
            accountIssue = "Couldn't check your iCloud account. Sync will try again later."
        @unknown default:
            accountIssue = "Couldn't check your iCloud account. Sync will try again later."
        }
        refreshStatus()
    }

    private func startEngine(container: CKContainer, savedState: CKSyncEngine.State.Serialization?) {
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: savedState,
            delegate: self
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        fetchIssue = nil
        sendIssue = nil
        if !metadata.isZoneSaved {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CloudSyncRecords.zone)])
        }
        if savedState == nil {
            isAwaitingFirstFetch = true
            lastFetchRequest = .now
            Task { [weak self] in
                var failure: Error?
                do {
                    try await engine.fetchChanges()
                } catch {
                    failure = error
                }
                self?.finishFirstFetch(of: engine, failure: failure)
            }
        } else {
            syncLocalChanges()
            fetchIfDue(force: true)
        }
        refreshStatus()
    }

    private func finishFirstFetch(of engine: CKSyncEngine, failure: Error?) {
        guard engine === self.engine else { return }
        isAwaitingFirstFetch = false
        if let failure { note(failure, userInitiated: false) }
        syncLocalChanges()
        refreshStatus()
    }

    /// Stops the engine. Events it still delivers are ignored.
    private func retireEngine() {
        guard let engine else { return }
        self.engine = nil
        isFetching = false
        isSending = false
        isSyncingManually = false
        isAwaitingFirstFetch = false
        sentFingerprints = [:]
        Task { await engine.cancelOperations() }
    }

    /// Forgets all sync bookkeeping (local data stays), so the next sync starts with a merge.
    private func forgetICloud() {
        metadata.forgetICloud()
        files.deleteEngineState()
        fetchIssue = nil
        sendIssue = nil
        saveMetadata(immediately: true)
    }

    /// Turns sync off by itself, keeping the local data, and says why.
    private func turnOff(notice: String) {
        retireEngine()
        metadata.accountRecordName = nil
        forgetICloud()
        status.isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        status.notice = notice
        refreshStatus()
    }

    // MARK: Local changes

    /// Notes local changes and queues what iCloud doesn't have yet. Runs after every local
    /// save (through `UserDataStore.didChange`) and after each batch of iCloud events.
    private func syncLocalChanges() {
        guard isPrepared, let userData else { return }
        let snapshot = CloudSyncSnapshot(userData.data)
        metadata.observeLocalData(snapshot, now: .now)
        if let engine, !isAwaitingFirstFetch {
            // The engine's queue mirrors what the comparison says: missing changes are added,
            // and ones that no longer apply (say, a delete for a value just restored from
            // iCloud) are removed.
            let changes = metadata.pendingChanges(for: snapshot)
            let wanted = changes.saves.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudSyncRecords.recordID(for: $0)) }
                + changes.deletes.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(CloudSyncRecords.recordID(for: $0)) }
            let wantedSet = Set(wanted)
            let queued = engine.state.pendingRecordZoneChanges
            let queuedSet = Set(queued)
            let stale = queued.filter { change in
                !wantedSet.contains(change) && change.cloudSyncRecordID?.zoneID == CloudSyncRecords.zoneID
            }
            if !stale.isEmpty { engine.state.remove(pendingRecordZoneChanges: stale) }
            let new = wanted.filter { !queuedSet.contains($0) }
            if !new.isEmpty { engine.state.add(pendingRecordZoneChanges: new) }
        }
        saveMetadata()
        refreshStatus()
    }

    private func fetchIfDue(force: Bool) {
        guard let engine, !isAwaitingFirstFetch else { return }
        if !force, let lastFetchRequest, Date.now.timeIntervalSince(lastFetchRequest) < Self.minimumFetchInterval { return }
        lastFetchRequest = .now
        Task { [weak self] in
            do {
                try await engine.fetchChanges()
            } catch {
                guard let self, engine === self.engine else { return }
                self.note(error, userInitiated: false)
            }
        }
    }

    // MARK: Events

    private func handle(_ event: CKSyncEngine.Event, from engine: CKSyncEngine) {
        // A retired engine's events would write stale state.
        guard engine === self.engine else { return }
        switch event {
        case .stateUpdate(let update):
            files.saveEngineState(update.stateSerialization)
        case .accountChange(let change):
            handleAccountChange(change, engine: engine)
        case .fetchedDatabaseChanges(let changes):
            handleFetchedDatabaseChanges(changes)
        case .fetchedRecordZoneChanges(let changes):
            handleFetchedRecordZoneChanges(changes)
        case .sentDatabaseChanges(let sent):
            handleSentDatabaseChanges(sent)
        case .sentRecordZoneChanges(let sent):
            handleSentRecordZoneChanges(sent, engine: engine)
        case .willFetchChanges:
            isFetching = true
        case .didFetchRecordZoneChanges(let finished):
            if let error = finished.error {
                note(error, userInitiated: false)
            } else if finished.zoneID == CloudSyncRecords.zoneID {
                fetchIssue = nil
            }
        case .didFetchChanges:
            isFetching = false
            if fetchIssue == nil { markSynced() }
        case .willSendChanges:
            isSending = true
        case .didSendChanges:
            isSending = false
            if sendIssue == nil { markSynced() }
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
        refreshStatus()
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange, engine: CKSyncEngine) {
        switch change.changeType {
        case .signIn(let currentUser):
            if let known = metadata.accountRecordName, known != currentUser.recordName {
                accountDidSwitch()
                return
            }
            // Merge: the engine starts over after an account change, so the zone and every
            // local value are queued again; values iCloud already has are matched by the fetch.
            metadata.accountRecordName = currentUser.recordName
            unavailableReason = nil
            if !metadata.isZoneSaved {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CloudSyncRecords.zone)])
            }
            saveMetadata(immediately: true)
            syncLocalChanges()
        case .signOut(let previousUser):
            // Keep the data on this device; forget the account's bookkeeping and stop. The
            // account is remembered so that signing in to a different one doesn't merge.
            retireEngine()
            forgetICloud()
            metadata.accountRecordName = previousUser.recordName
            saveMetadata(immediately: true)
            unavailableReason = .noAccount
        case .switchAccounts:
            accountDidSwitch()
        @unknown default:
            requestEvaluation()
        }
    }

    /// Someone else's account (or another account of the user) is signed in now. Its iCloud
    /// data shouldn't mix with what's on this device unless the user asks, so sync turns off.
    private func accountDidSwitch() {
        turnOff(notice: "The iCloud account on this device changed, so iCloud sync was turned off. Your data is still on this device. Turn sync on to sync it with this account.")
    }

    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        guard let deletion = changes.deletions.first(where: { $0.zoneID == CloudSyncRecords.zoneID }) else { return }
        // The user deleted the app's iCloud data in Settings, or reset their encrypted data.
        // Apple asks apps not to upload that data again; this app also keeps its own copy,
        // since it's the user's only one, and leaves re-uploading to the user.
        switch deletion.reason {
        case .encryptedDataReset:
            turnOff(notice: "Your iCloud encrypted data was reset, so iCloud sync was turned off. Your data is still on this device. Turn sync on to upload it again.")
        default:
            iCloudDataWasDeleted()
        }
    }

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let modifications = changes.modifications.compactMap { CloudSyncRecords.incoming(from: $0.record) }
        let deletions = changes.deletions.compactMap { CloudSyncRecords.key(forDeleted: $0.recordID, recordType: $0.recordType) }
        merge(modifications: modifications, deletions: deletions)
    }

    /// Merges fetched (or conflicting) records into the store and queues what stays local.
    private func merge(modifications: [CloudSyncIncomingRecord], deletions: [CloudSyncKey]) {
        guard let userData, !modifications.isEmpty || !deletions.isEmpty else { return }
        let snapshot = CloudSyncSnapshot(userData.data)
        // Date any local edit not seen yet before comparing.
        metadata.observeLocalData(snapshot, now: .now)
        let result = CloudSyncMerge.merge(modifications: modifications, deletions: deletions, into: snapshot, metadata: &metadata)
        if result.changesLocalData {
            // Written to disk before this event returns, so the engine never records changes
            // as fetched that the app hasn't saved.
            userData.applyRemoteChanges(saves: result.saves, deletes: result.deletes)
        }
        if !result.skipped.isEmpty {
            logger.notice("Left \(result.skipped.count) records from a newer version of the app alone.")
        }
        saveMetadata(immediately: true)
        syncLocalChanges()
    }

    private func handleSentDatabaseChanges(_ sent: CKSyncEngine.Event.SentDatabaseChanges) {
        if sent.savedZones.contains(where: { $0.zoneID == CloudSyncRecords.zoneID }) {
            metadata.isZoneSaved = true
            saveMetadata()
        }
        for failure in sent.failedZoneSaves where failure.zone.zoneID == CloudSyncRecords.zoneID {
            note(failure.error, userInitiated: false)
        }
    }

    private func handleSentRecordZoneChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in sent.savedRecords {
            guard let incoming = CloudSyncRecords.incoming(from: record) else { continue }
            let fingerprint = CloudSyncRecords.fingerprint(of: incoming) ?? sentFingerprints[incoming.key]
            sentFingerprints[incoming.key] = nil
            metadata.recordSaved(incoming.key, fingerprint: fingerprint, systemFields: incoming.systemFields)
        }
        for recordID in sent.deletedRecordIDs {
            if let key = metadata.key(forRecordName: recordID.recordName) {
                metadata.recordDeletedFromICloud(key)
            }
        }

        var conflicts: [CloudSyncIncomingRecord] = []
        var retries: [CKSyncEngine.PendingRecordZoneChange] = []
        var failure: CKError?
        for failed in sent.failedRecordSaves {
            let recordID = failed.record.recordID
            switch failed.error.code {
            case .serverRecordChanged:
                // Someone else saved it first: merge their copy; if this one is newer it's sent again.
                if let serverRecord = failed.error.serverRecord, let incoming = CloudSyncRecords.incoming(from: serverRecord) {
                    conflicts.append(incoming)
                }
            case .zoneNotFound:
                metadata.isZoneSaved = false
                engine.state.add(pendingDatabaseChanges: [.saveZone(CloudSyncRecords.zone)])
                retries.append(.saveRecord(recordID))
            case .unknownItem:
                // Deleted in iCloud while it changed here: it's recreated.
                if let key = metadata.key(forRecordName: recordID.recordName) {
                    metadata.recordDeletedFromICloud(key)
                }
                retries.append(.saveRecord(recordID))
            case .batchRequestFailed:
                retries.append(.saveRecord(recordID))
            case .userDeletedZone:
                iCloudDataWasDeleted()
                return
            default:
                if !Self.retriedErrorCodes.contains(failed.error.code) { failure = failed.error }
            }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            switch error.code {
            case .unknownItem, .zoneNotFound:
                if let key = metadata.key(forRecordName: recordID.recordName) {
                    metadata.recordDeletedFromICloud(key)
                }
            case .batchRequestFailed:
                retries.append(.deleteRecord(recordID))
            default:
                if !Self.retriedErrorCodes.contains(error.code) { failure = error }
            }
        }

        if let failure {
            note(failure, userInitiated: false)
        } else {
            sendIssue = nil
        }
        if !retries.isEmpty { engine.state.add(pendingRecordZoneChanges: retries) }
        saveMetadata(immediately: true)
        if conflicts.isEmpty {
            syncLocalChanges()
        } else {
            merge(modifications: conflicts, deletions: [])
        }
    }

    /// The app's zone was deleted from iCloud (Settings › Apple Account › iCloud).
    private func iCloudDataWasDeleted() {
        turnOff(notice: "This app's data was deleted from iCloud, so iCloud sync was turned off. Your data is still on this device. Turn sync on to upload it again.")
    }

    // MARK: Sending

    private func nextBatch(
        for context: CKSyncEngine.SendChangesContext,
        from engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === self.engine, let userData else { return nil }
        let scope = context.options.scope
        let pending = engine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        let snapshot = CloudSyncSnapshot(userData.data)
        let records = metadata.records
        let preferenceChangedAt = metadata.preferenceChangedAt
        for change in pending {
            guard case .saveRecord(let recordID) = change,
                  let key = snapshot.key(forRecordName: recordID.recordName),
                  let item = snapshot[key] else { continue }
            sentFingerprints[key] = item.fingerprint
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let key = snapshot.key(forRecordName: recordID.recordName),
                  let item = snapshot[key],
                  let record = CloudSyncRecords.record(
                      for: key, entity: item.entity, state: records[key], preferenceChangedAt: preferenceChangedAt
                  ) else {
                // Deleted here since it was queued: nothing to save.
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            return record
        }
    }

    // MARK: Status

    private func markSynced() {
        metadata.lastSyncDate = .now
        saveMetadata()
    }

    /// Records an error for the status line (or stops, for errors that mean sync can't work).
    private func note(_ error: Error, userInitiated: Bool) {
        logger.error("Sync error: \(error.localizedDescription, privacy: .public)")
        guard let error = error as? CKError else {
            fetchIssue = "Couldn't sync with iCloud. Sync will try again later."
            return
        }
        switch error.code {
        case .badContainer, .missingEntitlement:
            unavailableReason = .notConfigured
            retireEngine()
            return
        case .managedAccountRestricted:
            unavailableReason = .restricted
            retireEngine()
            return
        case .notAuthenticated:
            requestEvaluation()
            return
        case .operationCancelled:
            return
        default:
            break
        }
        guard userInitiated || !Self.retriedErrorCodes.contains(error.code) else { return }
        let message: String = switch error.code {
        case .networkUnavailable, .networkFailure:
            "You're offline. Changes will sync when you're back online."
        case .quotaExceeded:
            "Your iCloud storage is full, so changes can't be uploaded."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            "iCloud is busy. Sync will try again shortly."
        case .accountTemporarilyUnavailable:
            "Check your Apple Account in Settings to sync."
        case .incompatibleVersion:
            "Update Term Organize to keep syncing."
        case .limitExceeded:
            "Some data is too large to sync."
        default:
            "Couldn't sync with iCloud. Sync will try again later."
        }
        if error.code == .quotaExceeded || error.code == .limitExceeded {
            sendIssue = message
        } else {
            fetchIssue = message
        }
    }

    private func refreshStatus() {
        status.erasesICloudData = status.isConfiguredInBuild && status.isEnabled && metadata.hasDataInICloud
        let state: CloudSyncStatus.State
        if !status.isConfiguredInBuild {
            state = .unavailable(.notConfigured)
        } else if !status.isEnabled {
            state = .off
        } else if let unavailableReason {
            state = .unavailable(unavailableReason)
        } else if isFetching || isSending || isSyncingManually || isAwaitingFirstFetch {
            state = .syncing
        } else if let issue = accountIssue ?? sendIssue ?? fetchIssue {
            state = .error(issue)
        } else if engine == nil {
            // Still checking the account.
            state = .syncing
        } else {
            state = .upToDate(lastSync: metadata.lastSyncDate)
        }
        if status.state != state { status.state = state }
    }

    // MARK: Persistence

    private func saveMetadata(immediately: Bool = false) {
        guard isPrepared else { return }
        metadataSaveTask?.cancel()
        metadataSaveTask = nil
        if immediately {
            files.save(metadata)
            return
        }
        metadataSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.metadataSaveTask = nil
            self.files.save(self.metadata)
        }
    }
}

// MARK: - CloudSyncActions

extension CloudSyncController: CloudSyncActions {
    func setCloudSyncEnabled(_ isEnabled: Bool) {
        guard isEnabled != status.isEnabled else { return }
        status.isEnabled = isEnabled
        status.notice = nil
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
        if isEnabled {
            // Turning sync on is consent to merge with whichever account is signed in.
            metadata.accountRecordName = nil
            accountIssue = nil
            if status.isConfiguredInBuild { Self.registerForRemoteNotifications() }
        } else {
            // Data stays on this device and in iCloud; this device just stops syncing. The
            // bookkeeping is forgotten, so turning sync on again merges instead of replaying
            // whatever was deleted here in the meantime.
            retireEngine()
            metadata.accountRecordName = nil
            forgetICloud()
            unavailableReason = nil
            accountIssue = nil
        }
        saveMetadata(immediately: true)
        refreshStatus()
        requestEvaluation()
    }

    func syncCloudNow() {
        guard isPrepared, status.isEnabled else { return }
        guard let engine else {
            requestEvaluation()
            return
        }
        guard !isSyncingManually, !isAwaitingFirstFetch else { return }
        isSyncingManually = true
        fetchIssue = nil
        sendIssue = nil
        refreshStatus()
        lastFetchRequest = .now
        Task { [weak self] in
            var failure: Error?
            do {
                try await engine.fetchChanges()
                self?.syncLocalChanges()
                try await engine.sendChanges()
            } catch {
                failure = error
            }
            guard let self, engine === self.engine else { return }
            self.isSyncingManually = false
            if let failure {
                self.note(failure, userInitiated: true)
            } else {
                self.markSynced()
            }
            self.refreshStatus()
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncController: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, from: syncEngine)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await nextBatch(for: context, from: syncEngine)
    }
}

private extension CKSyncEngine.PendingRecordZoneChange {
    var cloudSyncRecordID: CKRecord.ID? {
        switch self {
        case .saveRecord(let recordID): recordID
        case .deleteRecord(let recordID): recordID
        @unknown default: nil
        }
    }
}
