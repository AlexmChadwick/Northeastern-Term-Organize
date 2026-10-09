//
//  MacCatalogAdaptiveTable.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  A table that has the columns its width has room for. A table with more columns than fit would
//  have its last ones run off the edge of the window, and a wide one would waste its room on three.
//

import SwiftUI

/// Makes a table once its width is measured, with the columns that width has room for (`tier`), and
/// makes a new one when the room changes enough to change them, once the width has held still: a
/// table made while its window is still being resized comes out with its columns sized for the wrong
/// width, and one that only gains or loses columns keeps the widths it had.
///
///     MacCatalogAdaptiveTable(tierForWidth: { $0 >= 900 ? .wide : .narrow }) { tier in
///         Table(…) { columns(for: tier) }
///     }
struct MacCatalogAdaptiveTable<Tier: Hashable, Content: View>: View {
    var tierForWidth: (CGFloat) -> Tier
    @ViewBuilder var content: (Tier) -> Content

    /// The width the table has, nil until it is measured.
    @State private var width: CGFloat?
    /// The columns the table was made with.
    @State private var settled: Tier?

    var body: some View {
        ZStack {
            Color.clear
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { measured($0) }
            if let settled {
                content(settled)
                    .id(settled)
                    .macFitsTableColumns(when: settled)
            }
        }
        .task(id: measuredTier) { await settleTier() }
    }

    private var measuredTier: Tier? {
        width.map(tierForWidth)
    }

    private func measured(_ newWidth: CGFloat) {
        width = newWidth
        // The first table is made right away; later changes of columns wait for the width to settle.
        if settled == nil { settled = tierForWidth(newWidth) }
    }

    private func settleTier() async {
        guard let measuredTier, measuredTier != settled else { return }
        // A snapshot has no window being dragged, and takes its picture a moment after resizing.
        if !MacShellRun.isSnapshot {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        settled = measuredTier
    }
}

/// What a table of a narrow window leaves out.
enum MacCatalogTableColumns {
    /// A table's columns as the user left them, except that those in `dropped` are hidden: the columns a
    /// narrow table has no room for. What is remembered doesn't change, so they come back with the room.
    static func binding<Row: Identifiable>(
        _ base: Binding<TableColumnCustomization<Row>>,
        dropping dropped: [String]
    ) -> Binding<TableColumnCustomization<Row>> {
        Binding(
            get: {
                var columns = base.wrappedValue
                for id in dropped { columns[visibility: id] = .hidden }
                return columns
            },
            set: { newValue in
                var columns = newValue
                for id in dropped { columns[visibility: id] = base.wrappedValue[visibility: id] }
                base.wrappedValue = columns
            }
        )
    }
}
