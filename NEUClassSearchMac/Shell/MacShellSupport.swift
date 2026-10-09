//
//  MacShellSupport.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Small helpers the shell's screens share: the clock, windows and System Settings.
//

import AppKit
import SwiftUI

/// The time the shell's screens read. It is the real clock, except in debug snapshot runs, which
/// can pin it (`-MacSnapshotNow 2026-10-06T10:15`) so a Tuesday morning can be shown on a Sunday.
enum MacShellClock {
    static var now: Date {
        #if DEBUG
        if let pinned { return pinned }
        #endif
        return .now
    }

    /// Calls `update` with the time at the start of every minute until the task is cancelled: for the
    /// clocks on screen ("4 min ago", the line on a timeline), which need no finer tick. Use it from
    /// a `.task` that updates `@State`, never from a `TimelineView` (they must not nest).
    static func everyMinute(_ update: @MainActor (Date) -> Void) async {
        while !Task.isCancelled {
            let moment = Date.now
            let next = Calendar.current.nextDate(after: moment, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
                ?? moment.addingTimeInterval(60)
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(moment))))
            guard !Task.isCancelled else { return }
            await update(now)
        }
    }

    #if DEBUG
    private static let pinned: Date? = {
        guard MacSnapshot.isRequested, let text = UserDefaults.standard.string(forKey: "MacSnapshotNow") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: text)
    }()
    #endif
}

/// Whether this run is a debug snapshot, which must never prompt, notify or touch the network.
enum MacShellRun {
    static var isSnapshot: Bool {
        #if DEBUG
        MacSnapshot.isRequested
        #else
        false
        #endif
    }
}

#if DEBUG
extension MacShellRun {
    /// `-MacShellDebugWindow YES` in a snapshot run prints the main window's size and the smallest
    /// size its content allows, two seconds in: a screen whose minimum width is too big for the
    /// default window shows up here.
    @MainActor
    static func printWindowSizesIfRequested() {
        guard isSnapshot else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "MacShellDebugTable") {
            // After the snapshot has resized the window (it does so once the delay is over).
            Task { @MainActor in
                let delay = max(defaults.double(forKey: "MacSnapshotDelay"), 2)
                var elapsed = 0.0
                for offset in [-0.5, 0.3, 0.7, 0.95] {
                    try? await Task.sleep(for: .seconds(delay + offset - elapsed))
                    elapsed = delay + offset
                    print("MacShell tables at +\(offset) s:")
                    for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(MacWindowID.main) == true {
                        if let content = window.contentView { printTables(in: content) }
                    }
                }
            }
        }
        guard defaults.bool(forKey: "MacShellDebugWindow") || defaults.bool(forKey: "MacShellDebugMenu") else { return }
        Task { @MainActor in
            // The selection a snapshot asks for is made once the catalog is ready, and the window's
            // minimum follows it: the last of these readings is the one to go by.
            for second in [2, 3, 4, 5] {
                try? await Task.sleep(for: .seconds(second == 2 ? 2 : 1))
                if defaults.bool(forKey: "MacShellDebugWindow") {
                    for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(MacWindowID.main) == true {
                        print("MacShell window: frame \(window.frame.size) content minimum \(window.contentMinSize)")
                    }
                }
            }
            if defaults.bool(forKey: "MacShellDebugMenu"), let menu = NSApp.mainMenu {
                menu.update()
                print("MacShell menu bar:")
                printMenu(menu, indent: "  ")
            }
        }
    }

    /// `-MacShellDebugTable YES` prints every table of the main window: its frame, the width of the
    /// view that clips it, and its columns' widths (what a `Table` made of them, and why).
    @MainActor
    private static func printTables(in view: NSView) {
        if let table = view as? NSTableView {
            let clip = table.enclosingScrollView?.contentView.bounds.width ?? -1
            print("MacShell table: frame \(table.frame.size) visible width \(clip) autoresizing \(table.columnAutoresizingStyle.rawValue)")
            if let scroll = table.enclosingScrollView {
                let insets = scroll.contentInsets
                print("  scroll frame \(scroll.frame) insets l\(insets.left) r\(insets.right) clip bounds \(scroll.contentView.bounds) table visible \(table.visibleRect) spacing \(table.intercellSpacing.width)")
            }
            var chain: [String] = []
            var parent = table.superview
            while let view = parent, chain.count < 7 {
                chain.append("\(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height))@\(Int(view.frame.minX))")
                parent = view.superview
            }
            print("  inside: " + chain.joined(separator: " < "))
            for column in table.tableColumns {
                let maximum = column.maxWidth > 100_000 ? "unbounded" : "\(Int(column.maxWidth))"
                print("  \(column.identifier.rawValue) width \(Int(column.width)) min \(Int(column.minWidth)) max \(maximum) hidden \(column.isHidden)")
            }
        }
        for subview in view.subviews { printTables(in: subview) }
    }

    /// `-MacShellDebugMenu YES` lists the menu bar: titles, shortcuts and what is disabled.
    @MainActor
    private static func printMenu(_ menu: NSMenu, indent: String) {
        for item in menu.items {
            if item.isSeparatorItem {
                print("\(indent)-")
                continue
            }
            var shortcut = ""
            if !item.keyEquivalent.isEmpty {
                let mask = item.keyEquivalentModifierMask
                shortcut = " [" + (mask.contains(.control) ? "^" : "") + (mask.contains(.option) ? "~" : "")
                    + (mask.contains(.shift) ? "$" : "") + (mask.contains(.command) ? "@" : "") + item.keyEquivalent + "]"
            }
            print("\(indent)\(item.title)\(shortcut)\(item.isEnabled ? "" : " (disabled)")")
            if let submenu = item.submenu { printMenu(submenu, indent: indent + "    ") }
        }
    }
}
#endif

/// Windows of the Mac app that more than one screen needs to bring forward.
@MainActor
enum MacShellWindows {
    /// Brings the main window to the front, opening a new one when the last was closed.
    static func showMain(openWindow: OpenWindowAction) {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MacWindowID.main)
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            !(window is NSPanel) && (window.identifier?.rawValue.hasPrefix(MacWindowID.main) ?? false)
        }
    }
}

/// Where the Settings window remembers its selected tab, and the tabs themselves.
enum MacSettingsTab: String, CaseIterable, Identifiable {
    case general, data, iCloud, notifications, about

    static let storageKey = "mac.settings.tab"

    var id: String { rawValue }
}

enum MacSystemSettings {
    /// Opens System Settings › Notifications, where the user can allow this app's alerts.
    static func openNotifications() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum MacShellPasteboard {
    /// Replaces the clipboard with plain text.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
