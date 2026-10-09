//
//  MacScheduleEditing.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Edits to one schedule that Edit › Undo (⌘Z) and Redo can take back. An undo puts back only the
/// parts of the schedule the edit changed, so it never undoes a rename or another change made in the
/// meantime.
@MainActor
struct MacSchedulePlanEditor {
    /// The parts of a schedule an edit can change.
    struct Parts: OptionSet {
        let rawValue: Int
        /// The courses, the chosen sections and the favorite combinations.
        static let courses = Parts(rawValue: 1 << 0)
        /// The generator's filters.
        static let filters = Parts(rawValue: 1 << 1)
        /// "Your ideal week".
        static let preferences = Parts(rawValue: 1 << 2)
    }

    var userData: UserDataStore
    var planID: UUID
    var undoManager: UndoManager?

    /// Runs `edit` and registers its undo.
    func record(_ actionName: String, touching parts: Parts = .courses, _ edit: () -> Void) {
        guard let before = userData.plan(id: planID) else {
            edit()
            return
        }
        edit()
        register(actionName, parts: parts, restore: Self.restorer(for: before, parts: parts))
    }

    /// Edits the schedule and registers the undo.
    func perform(_ actionName: String, touching parts: Parts = .courses, _ change: (inout SchedulePlan) -> Void) {
        record(actionName, touching: parts) { userData.updatePlan(id: planID, change) }
    }

    /// The edit that puts a schedule's parts back as they are now.
    private static func restorer(for plan: SchedulePlan, parts: Parts) -> (inout SchedulePlan) -> Void {
        let courses = plan.courses
        let selected = plan.selectedCRNs
        let favorites = plan.favoriteCombinations
        let filters = plan.filters
        let preferences = plan.preferences
        return { plan in
            if parts.contains(.courses) {
                plan.courses = courses
                plan.selectedCRNs = selected
                plan.favoriteCombinations = favorites
            }
            if parts.contains(.filters) { plan.filters = filters }
            if parts.contains(.preferences) { plan.preferences = preferences }
        }
    }

    private func register(_ actionName: String, parts: Parts, restore: @escaping (inout SchedulePlan) -> Void) {
        guard let undoManager else { return }
        let planID = planID
        undoManager.registerUndo(withTarget: userData) { [weak undoManager] store in
            MainActor.assumeIsolated {
                guard let current = store.plan(id: planID) else { return }
                let redo = Self.restorer(for: current, parts: parts)
                store.updatePlan(id: planID) { restore(&$0) }
                // Registered while undoing, so the undo manager keeps it as the redo.
                MacSchedulePlanEditor(userData: store, planID: planID, undoManager: undoManager)
                    .register(actionName, parts: parts, restore: redo)
            }
        }
        undoManager.setActionName(actionName)
    }
}

extension PlanToast {
    /// A confirmation with an "Undo" that takes back the last edit, when there is an undo manager to
    /// ask. ⌘Z does the same.
    static func undoable(_ text: String, systemImage: String, undoManager: UndoManager?) -> PlanToast {
        guard let undoManager else { return PlanToast(text: text, systemImage: systemImage) }
        return PlanToast(text: text, systemImage: systemImage, actionTitle: "Undo", action: { undoManager.undo() })
    }
}
