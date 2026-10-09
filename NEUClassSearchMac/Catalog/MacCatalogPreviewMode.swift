//
//  MacCatalogPreviewMode.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Whether the preview pane beside a table is shown, and the toolbar button for it. The pane itself
//  is a `MacSplitPane` in each screen; this is the part they share.
//

import SwiftUI

/// Whether the screens with a table (Search, Subjects, Saved, Professors) show their preview pane.
/// Until the user chooses, the pane follows the window: shown when the window is wide enough for a
/// table and a pane side by side, hidden when it isn't. After that the choice is remembered, and it
/// holds for all four screens.
///
///     private let preview = MacCatalogPreviewMode()
///     … .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { preview.measure($0) }
@MainActor
struct MacCatalogPreviewMode: DynamicProperty {
    /// The detail area's width from which the pane is shown unasked.
    static let roomyWidth: CGFloat = 1100

    /// 0 follows the window, 1 is shown, 2 is hidden.
    @AppStorage("mac.catalog.previewChoice") private var choice = 0
    @State private var width = MacCatalogState.shared.detailWidth

    /// Whether the pane is wanted now (it still needs something to show it for).
    var isShown: Bool {
        switch choice {
        case 1: true
        case 2: false
        default: width >= Self.roomyWidth
        }
    }

    func setShown(_ shown: Bool) {
        choice = shown ? 1 : 2
    }

    func toggle() {
        setShown(!isShown)
    }

    /// Tells the mode how wide the screen is; call it from `.onGeometryChange`. The pane that opens or
    /// closes because the window got wider or narrower does so at once, without the slide a click on the
    /// toolbar button gets.
    func measure(_ newWidth: CGFloat) {
        guard abs(newWidth - width) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { width = newWidth }
        MacCatalogState.shared.detailWidth = newWidth
    }

    /// The pane's shown state for a `MacSplitPane`: on only while `available` (something to show it for).
    /// Closing the pane (the button, the menu, dragging the divider over) is the user's choice.
    func binding(available: Bool = true) -> Binding<Bool> {
        Binding(get: { isShown && available }, set: { setShown($0) })
    }

    /// What View › Show/Hide Preview (⌥⌘0) works with, while `available`.
    func sidePane(available: Bool = true) -> MacPaneToggle? {
        guard available else { return nil }
        return MacPaneToggle(title: "Preview", isShown: isShown, toggle: { toggle() })
    }
}

/// The toolbar button that shows or hides the preview pane.
struct MacCatalogPreviewToggle: View {
    @Binding var isShown: Bool
    /// What the pane previews: `course`, `professor`.
    var subject = "course"

    var body: some View {
        Toggle(isOn: $isShown) {
            Label("Preview", systemImage: "sidebar.trailing")
        }
        .toggleStyle(.button)
        .help(isShown ? "Hide the preview" : "Show the selected \(subject) beside the list")
    }
}
