//
//  MacCatalogStackedSplit.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Two views one above the other that share the height, with a divider the user drags to change the
/// share and double-clicks to put it back: `MacSplitPane` turned on its side, for a page that is too
/// narrow for its two halves to sit side by side. Built by hand rather than with `VSplitView`, whose
/// AppKit panes don't follow the window's toolbar and size like the rest of the page does. The bottom
/// view's share is remembered per `storageKey`.
struct MacCatalogStackedSplit<Top: View, Bottom: View>: View {
    var defaultBottomShare: Double
    var topMinHeight: CGFloat
    var bottomMinHeight: CGFloat
    private let top: Top
    private let bottom: Bottom

    @AppStorage private var bottomShare: Double
    /// The share while the divider is dragged; stored when the drag ends.
    @State private var liveShare: Double?
    @State private var shareAtDragStart: Double?
    @State private var height: CGFloat = 0

    init(
        storageKey: String,
        defaultBottomShare: Double = 0.45,
        topMinHeight: CGFloat = 200,
        bottomMinHeight: CGFloat = 230,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.defaultBottomShare = defaultBottomShare
        self.topMinHeight = topMinHeight
        self.bottomMinHeight = bottomMinHeight
        self.top = top()
        self.bottom = bottom()
        _bottomShare = AppStorage(wrappedValue: defaultBottomShare, storageKey)
    }

    private var available: CGFloat { max(1, height - MacCatalogStackedDivider.grip) }

    /// The bottom view's height for a share: at least its minimum, leaving the top view its own.
    private func bottomHeight(for share: Double) -> CGFloat {
        let upper = max(bottomMinHeight, available - topMinHeight)
        return min(max(available * share, bottomMinHeight), upper)
    }

    var body: some View {
        MacCatalogStackedLayout(bottomHeight: bottomHeight(for: liveShare ?? bottomShare)) {
            top
            MacCatalogStackedDivider(
                onDrag: { translation in
                    let start = shareAtDragStart ?? (liveShare ?? bottomShare)
                    shareAtDragStart = start
                    liveShare = min(max(start - translation / available, 0), 0.85)
                },
                onDragEnd: {
                    if let liveShare {
                        bottomShare = bottomHeight(for: liveShare) / available
                    }
                    liveShare = nil
                    shareAtDragStart = nil
                },
                onReset: { withAnimation(.snappy) { bottomShare = defaultBottomShare } },
                onAdjust: { step in
                    let current = bottomHeight(for: bottomShare) / available
                    bottomShare = min(max(current - step, 0), 0.85)
                }
            )
            bottom
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
    }
}

/// Places the top view, the divider and the bottom view, the bottom one with the height it is given.
private struct MacCatalogStackedLayout: Layout {
    var bottomHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 400))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let grip = MacCatalogStackedDivider.grip
        let bottom = min(bottomHeight, max(0, bounds.height - grip))
        let top = max(0, bounds.height - grip - bottom)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: top))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), proposal: ProposedViewSize(width: bounds.width, height: grip))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + top + grip), proposal: ProposedViewSize(width: bounds.width, height: bottom))
    }
}

/// The divider of a `MacCatalogStackedSplit`: a hairline with room above and below to grab, the
/// row-resize pointer, a double-click to reset, and adjustments for VoiceOver.
private struct MacCatalogStackedDivider: View {
    static let grip: CGFloat = 9

    /// The vertical distance dragged since the drag began, in points.
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    var onReset: () -> Void
    /// A share step (+0.05 makes the top view taller).
    var onAdjust: (Double) -> Void

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: Self.grip)
            .frame(maxWidth: .infinity)
            .overlay {
                Rectangle()
                    .fill(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
                    .frame(height: isHovering ? 2 : 1)
            }
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.height) }
                    .onEnded { _ in onDragEnd() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            .help("Drag to resize. Double-click to reset.")
            .accessibilityElement()
            .accessibilityLabel("Divider")
            .accessibilityHint("Adjust to make the upper part taller or shorter")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(0.05)
                case .decrement: onAdjust(-0.05)
                @unknown default: break
                }
            }
    }
}
