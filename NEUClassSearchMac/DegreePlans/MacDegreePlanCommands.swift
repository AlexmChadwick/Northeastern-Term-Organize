//
//  MacDegreePlanCommands.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the Degree Plan menu can do for the plan or requirements on screen. The window publishes
/// it with `.focusedSceneValue(\.macDegreePlan, …)`; items whose action is nil are disabled.
struct MacDegreePlanMenuActions {
    var planName: String
    var isPrimary = false
    /// The semesters Add Semester offers (the plan's next ones).
    var nextSemesters: [DegreePlanTerm] = []
    /// The plan's semesters, for Move to.
    var semesters: [DegreePlanTerm] = []
    /// Planned courses are selected, so Move to and Mark as Completed apply.
    var hasPlannedSelection = false
    var addSemester: ((DegreePlanTerm) -> Void)?
    var moveSelection: ((UUID) -> Void)?
    var markSelectionCompleted: (() -> Void)?
    /// Goes back to the plan from the requirements' full page.
    var showPlan: (() -> Void)?
    /// Opens the requirements as a full page (they are beside the plan otherwise; View › Show
    /// Requirements shows or hides that pane).
    var showRequirements: (() -> Void)?
    /// Shows or hides the pane with the selected requirement's details, on the requirements page.
    var toggleDetails: (() -> Void)?
    var detailsAreShown = false
    var setPrimary: (() -> Void)?
    var editDetails: (() -> Void)?
    var addEquivalence: (() -> Void)?
    var duplicate: (() -> Void)?
}

extension FocusedValues {
    /// The Degree Plan menu's actions for the focused window's plan.
    @Entry var macDegreePlan: MacDegreePlanMenuActions?
}

/// The Degree Plan menu: semesters, the selected courses, the plan's settings and its
/// requirements (`MacDegreePlanCommands()` sits beside `MacCommands` in the app's `.commands`).
struct MacDegreePlanCommands: Commands {
    @FocusedValue(\.macDegreePlan) private var plan

    var body: some Commands {
        CommandMenu("Degree Plan") {
            Menu("Add Semester") {
                ForEach(plan?.nextSemesters ?? [], id: \.name) { semester in
                    Button(semester.name) { plan?.addSemester?(semester) }
                }
            }
            .disabled(plan?.addSemester == nil || (plan?.nextSemesters.isEmpty ?? true))

            Divider()

            Menu("Move Selected Courses to") {
                ForEach(plan?.semesters ?? []) { semester in
                    Button(semester.name) { plan?.moveSelection?(semester.id) }
                }
            }
            .disabled(plan?.moveSelection == nil || !(plan?.hasPlannedSelection ?? false))
            Button("Mark Selected Courses as Completed") { plan?.markSelectionCompleted?() }
                .disabled(plan?.markSelectionCompleted == nil || !(plan?.hasPlannedSelection ?? false))

            Divider()

            Button("Show Degree Plan") { plan?.showPlan?() }
                .disabled(plan?.showPlan == nil)
            Button("Open Requirements as Full Page") { plan?.showRequirements?() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(plan?.showRequirements == nil)
            Button(plan?.detailsAreShown == true ? "Hide Requirement Details" : "Show Requirement Details") { plan?.toggleDetails?() }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(plan?.toggleDetails == nil)

            Divider()

            Button("Add Course Equivalence…") { plan?.addEquivalence?() }
                .disabled(plan?.addEquivalence == nil)
            Button("Rename or Edit Program…") { plan?.editDetails?() }
                .disabled(plan?.editDetails == nil)
            Button(plan?.isPrimary == true ? "Used for Prerequisite Checks" : "Use for Prerequisite Checks") { plan?.setPrimary?() }
                .disabled(plan?.setPrimary == nil || plan?.isPrimary == true)
            Button("Duplicate Plan") { plan?.duplicate?() }
                .disabled(plan?.duplicate == nil)
        }
    }
}
