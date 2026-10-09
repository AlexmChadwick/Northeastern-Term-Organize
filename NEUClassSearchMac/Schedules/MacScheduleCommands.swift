//
//  MacScheduleCommands.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The "Schedule" menu: what can be done with the schedule in the focused window. Add
//  `MacScheduleCommands()` next to `MacCommands(navigator:)` in the app's `.commands { }`.
//

import SwiftUI

/// What the schedule in the focused window offers to the menu bar.
struct MacScheduleCommandActions {
    var planName: String
    var isPrimary: Bool
    var isShowingGenerator: Bool
    var hasCourses: Bool
    var canGenerate: Bool
    var hasSelection: Bool
    /// The one course selected in the list, for "Choose Section…".
    var selectedCourse: CourseKey?
    var addCourse: () -> Void
    var showSchedule: () -> Void
    var showGenerator: () -> Void
    var showFilters: () -> Void
    var editPreferences: () -> Void
    var chooseSection: (CourseKey) -> Void
    var copyCRNs: () -> Void
    var setPrimary: () -> Void
    var rename: () -> Void
    var duplicate: () -> Void
    var delete: () -> Void
}

extension FocusedValues {
    /// The Schedule menu's actions for the schedule on screen.
    @Entry var macScheduleActions: MacScheduleCommandActions?
}

/// The Schedule menu. Its items are disabled while no schedule is on screen.
struct MacScheduleCommands: Commands {
    @FocusedValue(\.macScheduleActions) private var actions

    var body: some Commands {
        CommandMenu("Schedule") {
            Button("Add Course…") { actions?.addCourse() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Choose Section…") {
                if let key = actions?.selectedCourse { actions?.chooseSection(key) }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(actions?.selectedCourse == nil)

            Divider()

            Button("Show Schedule") { actions?.showSchedule() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(actions == nil || actions?.isShowingGenerator == false)
            Button("Generate Schedules") { actions?.showGenerator() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(actions?.canGenerate != true || actions?.isShowingGenerator == true)
            Button("Filters…") { actions?.showFilters() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Your Ideal Week…") { actions?.editPreferences() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions?.hasCourses != true)

            Divider()

            Button("Copy CRNs") { actions?.copyCRNs() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.hasSelection != true)

            Divider()

            Button(actions?.isPrimary == true ? "My Schedule" : "Set as My Schedule") { actions?.setPrimary() }
                .disabled(actions == nil || actions?.isPrimary == true)
            Button("Rename…") { actions?.rename() }
                .disabled(actions == nil)
            Button("Duplicate") { actions?.duplicate() }
                .disabled(actions == nil)
            Button("Delete…") { actions?.delete() }
                .disabled(actions == nil)
        }
    }
}
