//
//  MacTableFit.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI

extension View {
    /// Makes the columns of a `Table` (made when `token` last changed) fit the room it has.
    ///
    /// The detail column of the main window runs under the sidebar, so a table in it is a scroll view
    /// with the sidebar's width as an inset. A table made after its window changed size (or after the
    /// columns it shows changed) sizes its columns for the whole scroll view and forgets that inset, so
    /// the last columns end up beyond the window's edge. Fitting them once the table is there puts
    /// them where there is room. Use it on a table that gets a new `.id` when its columns change.
    func macFitsTableColumns(when token: some Hashable) -> some View {
        background { MacTableFit(token: AnyHashable(token)) }
    }
}

/// An invisible view behind a `Table` that, whenever its token changes, tells the AppKit table that
/// sits where it does to fit its columns to the room there is.
private struct MacTableFit: NSViewRepresentable {
    var token: AnyHashable

    final class Coordinator {
        var token: AnyHashable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.token != token else { return }
        context.coordinator.token = token
        Task { @MainActor [weak view] in
            // Once the table has been laid out, and again as its insets and the window settle.
            for delay in [40, 150, 400, 1_000, 2_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let view else { return }
                Self.fitTable(behind: view)
            }
        }
    }

    /// The table whose frame holds the middle of `view`: when it is wider than what shows of it, its
    /// columns are fitted to what shows.
    @MainActor
    private static func fitTable(behind view: NSView) {
        guard let root = view.window?.contentView else { return }
        let middle = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let table = tables(in: root).first(where: { table in
            table.convert(table.visibleRect, to: nil).contains(middle)
        }), let scroll = table.enclosingScrollView else { return }
        let shown = scroll.contentView.bounds.width - scroll.contentInsets.left - scroll.contentInsets.right
        guard table.frame.width > shown + 2 else { return }
        table.sizeToFit()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MacShellDebugTable") {
            print("MacTableFit: fitted a table of \(Int(shown)) points to \(Int(table.frame.width))")
        }
        #endif
    }

    @MainActor
    private static func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView { found.append(table) }
        for subview in view.subviews { found += tables(in: subview) }
        return found
    }
}
