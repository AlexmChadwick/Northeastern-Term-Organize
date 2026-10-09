//
//  WidgetBridge.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import WidgetKit

/// Writes the active "My Schedule" to the shared app group for the widgets.
///
/// The plan comes from `UserDataStore.activePrimaryPlan()` (the term in session,
/// else the next to start), not from the term being browsed, so planning next
/// semester never hides today's classes. Called at launch, whenever plans change
/// and whenever an index changes, so it does as little as it can: nothing is
/// written (and no timelines are reloaded) unless the schedule actually differs
/// from what was last saved, and a missing app group is tolerated silently.
@MainActor
enum WidgetBridge {
    /// Hash of the last data written (ignoring its timestamp), or `clearedMarker`.
    private static var lastSignature: Int?
    private static let clearedMarker = Int.min
    /// Terms whose index is being loaded on the widgets' behalf.
    private static var loading: Set<String> = []
    /// `indexVersion` at which loading a term's index last came back empty (don't retry until it changes).
    private static var failedAt: [String: Int] = [:]

    static func update(catalog: CatalogStore, userData: UserDataStore) {
        guard let plan = userData.activePrimaryPlan() else {
            guard lastSignature != clearedMarker else { return }
            WidgetScheduleData.clear()
            lastSignature = clearedMarker
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        // The plan's term may not be the one on screen: use whatever is loaded, or load it.
        guard let index = catalog.cachedIndex(for: plan.termCode) else {
            loadIndex(for: plan.termCode, catalog: catalog, userData: userData)
            return
        }

        var data = ScheduleWidgetBuilder.make(plan: plan, index: index)
        let signature = Self.signature(of: data)
        guard signature != lastSignature else { return }

        // Without an app group container there is nowhere to write; try again next time.
        guard WidgetScheduleData.fileURL != nil else { return }
        data.generatedAt = .now
        do {
            try data.save()
            lastSignature = signature
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Never crash over widget data; the next change retries.
        }
    }

    /// Loads a term's index in the background, then updates again. Until it arrives
    /// the widgets keep what they have.
    private static func loadIndex(for termCode: String, catalog: CatalogStore, userData: UserDataStore) {
        guard !loading.contains(termCode), failedAt[termCode] != catalog.indexVersion else { return }
        loading.insert(termCode)
        Task { @MainActor in
            let loaded = await catalog.index(for: termCode)
            loading.remove(termCode)
            guard loaded != nil else {
                failedAt[termCode] = catalog.indexVersion
                return
            }
            failedAt[termCode] = nil
            update(catalog: catalog, userData: userData)
        }
    }

    private static func signature(of data: WidgetScheduleData) -> Int {
        var copy = data
        copy.generatedAt = .distantPast
        return copy.hashValue
    }
}
