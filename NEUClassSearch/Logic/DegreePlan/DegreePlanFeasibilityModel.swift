//
//  DegreePlanFeasibilityModel.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation

/// Offering history for the plan screen, loaded once per set of planned courses. Starts empty,
/// so a semester is never called unoffered before the history arrives. A term whose catalog is
/// already on the device is judged from that catalog immediately.
@MainActor
@Observable
final class DegreePlanFeasibilityModel {
    private(set) var history = OfferingHistory.empty
    private(set) var isLoadingHistory = false
    private var loadedSignature = ""

    func report(for plan: DegreePlan, snapshot: DegreePlanCatalogSnapshot, now: Date = .now) -> DegreePlanFeasibility.Report {
        let keys = plan.degreePlanPlannedKeys
        return DegreePlanFeasibility.assess(plan: plan, history: history, sections: { term in
            DegreePlanFeasibility.sectionMap(in: snapshot, for: term, keys: keys)
        }, now: now)
    }

    func loadIfNeeded(plan: DegreePlan, indexes: [CatalogIndex]) async {
        let signature = plan.degreePlanPlannedKeys.map(\.description).sorted().joined(separator: "|")
            + "#" + indexes.map(\.term.code).sorted().joined(separator: ",")
        guard signature != loadedSignature else { return }
        isLoadingHistory = true
        history = await CourseInfoStore.shared.offeringHistory(for: plan.degreePlanPlannedKeys, indexes: indexes)
        loadedSignature = signature
        isLoadingHistory = false
    }
}
