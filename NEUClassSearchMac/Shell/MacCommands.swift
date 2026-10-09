//
//  MacCommands.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI

/// Menu bar commands: the File items for schedules and degree plans, the actions the focused
/// window offers (Export, Print, Delete, Reload), a Go menu for the sidebar areas, and Help.
struct MacCommands: Commands {
    var navigator: MacNavigator

    @FocusedValue(\.macExport) private var exportAction
    @FocusedValue(\.macPrint) private var printAction
    @FocusedValue(\.macDelete) private var deleteAction
    @FocusedValue(\.macReload) private var reloadAction
    @FocusedValue(\.macSidePane) private var sidePane
    @FocusedValue(\.macListPane) private var listPane

    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        SidebarCommands()
        appCommands
        fileCommands
        editCommands
        viewCommands
        goCommands
        windowCommands
        helpCommands
    }

    // MARK: App

    /// The About panel, with the notices the AGPL asks an app to show.
    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(LegalText.appName)") { MacAboutPanel.show() }
        }
    }

    // MARK: File

    @CommandsBuilder
    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Schedule") { navigator.isNewSchedulePresented = true }
                .keyboardShortcut("n")
            Button("New Degree Plan") { navigator.isNewDegreePlanPresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Degree Plan…") { navigator.isDegreePlanImporterPresented = true }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .importExport) {
            Button(exportAction?.title ?? "Export…") { exportAction?.perform() }
                .keyboardShortcut("e")
                .disabled(exportAction == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button(printAction?.title ?? "Print…") { printAction?.perform() }
                .keyboardShortcut("p")
                .disabled(printAction == nil)
        }
    }

    // MARK: Edit

    /// The action the focused window offers for what is selected (a course of a schedule, a watched
    /// section…), under its own name, next to the system's Delete (which the Delete key and each
    /// table's `.onDeleteCommand` answer). Like Finder's Move to Trash it uses ⌘⌫, and while text is
    /// being edited ⌘⌫ keeps its usual meaning there (delete to the start of the line), so typing in
    /// a search field is never interrupted. Without such an action the item isn't shown.
    @CommandsBuilder
    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            if let deleteAction {
                Button(deleteAction.title) {
                    if let text = NSApp.keyWindow?.firstResponder as? NSText, text.isEditable {
                        text.deleteToBeginningOfLine(nil)
                    } else {
                        deleteAction.perform()
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }

    // MARK: View

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(before: .toolbar) {
            Button(reloadAction?.title ?? "Reload") { reloadAction?.perform() }
                .keyboardShortcut("r")
                .disabled(reloadAction == nil)
        }
        // The side pane of the area on screen: the requirements beside a degree plan, a room's classes…
        // (and, for an area with a list pane as well, that one too: the buildings of Free Rooms).
        CommandGroup(after: .sidebar) {
            Button(sidePane.map { ($0.isShown ? "Hide " : "Show ") + $0.title } ?? "Show Side Pane") { sidePane?.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(sidePane == nil)
            if let listPane {
                Button((listPane.isShown ? "Hide " : "Show ") + listPane.title) { listPane.toggle() }
            }
        }
    }

    // MARK: Go

    /// The sidebar's areas, in the order of their ⌘1…⌘8 shortcuts.
    private static let destinations: [(title: String, item: MacSidebarItem)] = [
        ("Search", .search),
        ("Subjects", .subjects),
        ("Saved", .saved),
        ("Professors", .professors),
        ("Free Rooms", .rooms),
        ("Schedules", .schedules),
        ("Degree Plans", .degreePlans),
        ("Watchlist", .watchlist),
    ]

    @CommandsBuilder
    private var goCommands: some Commands {
        CommandMenu("Go") {
            ForEach(Array(Self.destinations.enumerated()), id: \.offset) { position, destination in
                Button(destination.title) {
                    navigator.selection = destination.item
                    MacShellWindows.showMain(openWindow: openWindow)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(position + 1))), modifiers: .command)
            }
        }
    }

    // MARK: Window

    @CommandsBuilder
    private var windowCommands: some Commands {
        CommandGroup(before: .windowList) {
            Button("Term Organize") { MacShellWindows.showMain(openWindow: openWindow) }
                .keyboardShortcut("0")
            Divider()
        }
    }

    // MARK: Help

    @CommandsBuilder
    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            if let sourceURL = LegalText.sourceCodeURL {
                Button("\(LegalText.appName) Source Code") { openURL(sourceURL) }
            }
            Button("SearchNEU on GitHub") { openURL(LegalText.searchNEURepositoryURL) }
            Button("searchneu.com") { openURL(LegalText.searchNEUWebsiteURL) }
            Divider()
            Button("GNU Affero General Public License") { openURL(LegalText.licenseURL) }
            Button("Acknowledgements & Licenses…") {
                UserDefaults.standard.set(MacSettingsTab.about.rawValue, forKey: MacSettingsTab.storageKey)
                openSettings()
            }
        }
    }
}

/// The standard About panel with this app's credits: what it is, who it is not from, where it
/// comes from and how to get its source.
@MainActor
enum MacAboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): LegalText.appCopyright,
        ])
        NSApp.activate()
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString()
        func add(_ string: String) {
            text.append(NSAttributedString(string: string, attributes: base))
        }
        func addLink(_ title: String, _ url: URL) {
            var attributes = base
            attributes[.link] = url
            text.append(NSAttributedString(string: title, attributes: attributes))
        }
        add(LegalText.unofficialNotice + "\n")
        add("Based on SearchNEU by Sandbox at Northeastern University. Free software under the \(LegalText.licenseName), without any warranty.\n")
        addLink("SearchNEU", LegalText.searchNEURepositoryURL)
        add("  ·  ")
        addLink("License", LegalText.licenseURL)
        if let sourceURL = LegalText.sourceCodeURL {
            add("  ·  ")
            addLink("Source Code", sourceURL)
        }
        return text
    }
}

extension FocusedValues {
    /// View › Show/Hide <list> (no shortcut): the second pane of an area that has two, for instance
    /// the buildings beside the rooms of Free Rooms. The area's side pane is `macSidePane` (⌥⌘0).
    @Entry var macListPane: MacPaneToggle?
}
