//
//  MacCatalogCommands.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Nothing any more: the View menu's Show/Hide Preview is the shared one (`\.macSidePane`, ⌥⌘0) that
/// `MacCommands` shows for every screen with a side pane. Kept empty so the app's `.commands { }`
/// still compiles; delete this file together with its `MacCatalogCommands()` line.
struct MacCatalogCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {}
    }
}
