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
    /// A click in this table or list makes it the first responder, the way a normal macOS table does.
    /// Up and Down then move its selection. A click outside it, including the sidebar and the search
    /// field, leaves focus where it is. This watches mouse clicks in this window only. It does not
    /// monitor keys, and it does not consume the click, so the table's own selection still runs.
    func macFocusesOnClick() -> some View {
        modifier(MacClickFocusModifier())
    }

    /// Asks the AppKit table under this view to scroll its selected row into view when `token` changes.
    /// Arrow keys move the selection natively; this keeps that row on screen after the binding updates.
    func macScrollsTableSelectionIntoView(when token: some Hashable) -> some View {
        background { MacTableSelectionScroll(token: AnyHashable(token)) }
    }

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

/// Scrolls the selected row of the table that contains this view into view.
private struct MacTableSelectionScroll: NSViewRepresentable {
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
            try? await Task.sleep(for: .milliseconds(40))
            guard let view, let table = MacTableFit.table(containing: view) else { return }
            guard let row = table.selectedRowIndexes.last, row >= 0 else { return }
            table.scrollRowToVisible(row)
        }
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
        guard let table = table(containing: view), let scroll = table.enclosingScrollView else { return }
        let shown = scroll.contentView.bounds.width - scroll.contentInsets.left - scroll.contentInsets.right
        guard table.frame.width > shown + 2 else { return }
        table.sizeToFit()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MacShellDebugTable") {
            print("MacTableFit: fitted a table of \(Int(shown)) points to \(Int(table.frame.width))")
        }
        #endif
    }

    /// The table whose visible frame holds the middle of `view`.
    @MainActor
    static func table(containing view: NSView) -> NSTableView? {
        guard let root = view.window?.contentView else { return nil }
        let middle = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return tables(in: root).first { table in
            table.convert(table.visibleRect, to: nil).contains(middle)
        }
    }

    @MainActor
    private static func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView { found.append(table) }
        for subview in view.subviews { found += tables(in: subview) }
        return found
    }
}

/// Binds SwiftUI focus to the table and turns it on when a click lands in that table.
/// A row that is already selected does not change the selection binding, so focus follows the click.
private struct MacClickFocusModifier: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .background { MacTableClickFocus { isFocused = true } }
    }
}

/// Reports a mouse click whose hit view is the table that contains this anchor.
/// Local to this process. Key events are not observed, and the click is passed on.
private struct MacTableClickFocus: NSViewRepresentable {
    var onClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    func makeNSView(context: Context) -> NSView {
        let view = MacTableClickPassThrough()
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.onClick = onClick
        context.coordinator.start()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onClick: () -> Void
        weak var anchor: NSView?
        var monitor: Any?

        init(onClick: @escaping () -> Void) { self.onClick = onClick }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.focusIfClick(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func focusIfClick(_ event: NSEvent) {
            guard let anchor, let window = event.window, anchor.window === window else { return }
            guard let table = Self.table(near: anchor) else { return }
            guard let hit = window.contentView?.hitTest(event.locationInWindow) else { return }
            guard hit === table || hit.isDescendant(of: table) else { return }
            if window.firstResponder === table { return }
            if let view = window.firstResponder as? NSView, view.isDescendant(of: table) { return }
            window.makeFirstResponder(table)
            let focus = onClick
            DispatchQueue.main.async {
                focus()
                DispatchQueue.main.async {
                    guard anchor.window === window, window.firstResponder !== table else { return }
                    window.makeFirstResponder(table)
                }
            }
        }

        static func table(near view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let node = current {
                if let table = node as? NSTableView { return table }
                current = node.superview
            }
            return MacTableFit.table(containing: view)
        }
    }
}

/// Sits behind the table and never takes the click or keyboard focus.
private final class MacTableClickPassThrough: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
