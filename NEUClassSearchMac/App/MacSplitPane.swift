//
//  MacSplitPane.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Built by hand rather than with `HSplitView` or `.inspector`: both make the window ask for the
//  width of every pane (the inspector even while hidden), so screens couldn't fit half a laptop
//  screen, and their widths don't follow the window.
//

import SwiftUI

/// Two views side by side that share the width, with a divider the user drags to change the
/// share, double-clicks to put it back, or drags all the way over to close the pane. The share is
/// remembered (per `storageKey`) as a fraction of the width rather than in points, so the pane
/// grows with the window: roomy on a wide display, never under its minimum on a narrow one.
/// When the window is too narrow for both views, the pane floats over the main view instead of
/// making the window wider; hide it, or widen the window, to see both again.
///
///     @AppStorage("mac.degreePlan.showsRequirements") private var showsRequirements = true
///
///     MacSplitPane(storageKey: "mac.split.degreePlan", defaultShare: 0.42,
///                  paneMinWidth: 320, primaryMinWidth: 380, isPaneShown: $showsRequirements) {
///         plan
///     } pane: {
///         requirements
///     }
struct MacSplitPane<Primary: View, Pane: View>: View {
    typealias PaneEdge = MacSplitPaneEdge

    var paneEdge: PaneEdge
    /// The pane's share of the width until the user changes it.
    var defaultShare: Double
    var paneMinWidth: CGFloat
    var primaryMinWidth: CGFloat
    /// The pane's share never goes above this.
    var maxShare: Double
    @Binding var isPaneShown: Bool
    private let primary: Primary
    private let pane: Pane

    @AppStorage private var share: Double
    /// The share while the divider is being dragged; stored when the drag ends.
    @State private var liveShare: Double?
    @State private var shareAtDragStart: Double?
    /// Whether letting go of the divider now closes the pane (it was dragged well past the
    /// pane's minimum width).
    @State private var closesOnRelease = false

    /// - Parameters:
    ///   - storageKey: Where the user's share is remembered (`UserDefaults`).
    ///   - isPaneShown: Whether the pane is shown. Dragging the divider all the way over sets
    ///     it to false; pass `.constant(true)` for a pane that can't be closed.
    init(
        storageKey: String,
        paneEdge: PaneEdge = .trailing,
        defaultShare: Double,
        paneMinWidth: CGFloat,
        primaryMinWidth: CGFloat,
        maxShare: Double = 0.7,
        isPaneShown: Binding<Bool> = .constant(true),
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder pane: () -> Pane
    ) {
        self.paneEdge = paneEdge
        self.defaultShare = defaultShare
        self.paneMinWidth = paneMinWidth
        self.primaryMinWidth = primaryMinWidth
        self.maxShare = maxShare
        _isPaneShown = isPaneShown
        self.primary = primary()
        self.pane = pane()
        _share = AppStorage(wrappedValue: defaultShare, storageKey)
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let floats = total < paneMinWidth + primaryMinWidth + MacSplitDivider.grip
            let paneWidth = width(for: liveShare ?? share, in: total, floats: floats)
            MacSplitLayout(paneEdge: paneEdge, paneWidth: paneWidth, floats: floats) {
                primary
                if isPaneShown {
                    divider(total: total, floats: floats)
                    pane
                        .background(.background)
                        .opacity(closesOnRelease ? 0.4 : 1)
                        .shadow(color: .black.opacity(floats ? 0.18 : 0), radius: 12)
                        .transition(.move(edge: paneEdge == .leading ? .leading : .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: primaryMinWidth)
        .animation(.snappy(duration: 0.25), value: isPaneShown)
    }

    /// The pane's width for a share: at least its minimum, and leaving the main view the room
    /// it needs (or, while the pane floats, a strip of the main view to click).
    private func width(for share: Double, in total: CGFloat, floats: Bool) -> CGFloat {
        let available = total - MacSplitDivider.grip
        if floats { return max(0, min(paneMinWidth, available - 44)) }
        let upper = max(paneMinWidth, min(available * maxShare, available - primaryMinWidth))
        return min(max(available * share, paneMinWidth), upper)
    }

    private func divider(total: CGFloat, floats: Bool) -> some View {
        let available = max(1, total - MacSplitDivider.grip)
        return MacSplitDivider(
            onDrag: { translation in
                guard !floats else { return }
                let start = shareAtDragStart ?? (liveShare ?? share)
                shareAtDragStart = start
                let change = (paneEdge == .leading ? translation : -translation) / available
                let proposed = start + change
                closesOnRelease = proposed * available < paneMinWidth * 0.5
                liveShare = min(max(proposed, 0), maxShare)
            },
            onDragEnd: {
                if closesOnRelease {
                    // Closed by dragging: it comes back at the width it had.
                    isPaneShown = false
                } else if let liveShare {
                    // Store what the pane shows, inside its limits.
                    share = width(for: liveShare, in: total, floats: false) / available
                }
                liveShare = nil
                shareAtDragStart = nil
                closesOnRelease = false
            },
            onReset: {
                withAnimation(.snappy) { share = defaultShare }
            },
            onAdjust: { step in
                let current = width(for: share, in: total, floats: false) / available
                share = min(max(current + (paneEdge == .leading ? step : -step), 0), maxShare)
            }
        )
    }
}

/// The side of a `MacSplitPane` its pane is on.
enum MacSplitPaneEdge: Sendable {
    case leading, trailing
}

/// Places the main view, the divider and the pane: side by side, or with the pane floating over
/// the main view's edge when there's no room for both.
private struct MacSplitLayout: Layout {
    var paneEdge: MacSplitPaneEdge
    var paneWidth: CGFloat
    var floats: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let primary = subviews.first else { return }
        let height = bounds.height
        guard subviews.count >= 3 else {
            primary.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let divider = subviews[1]
        let pane = subviews[2]
        let grip = MacSplitDivider.grip
        let primaryWidth = floats ? bounds.width : max(0, bounds.width - grip - paneWidth)
        switch paneEdge {
        case .trailing:
            let paneX = bounds.maxX - paneWidth
            primary.place(at: bounds.origin, proposal: ProposedViewSize(width: primaryWidth, height: height))
            divider.place(at: CGPoint(x: paneX - grip, y: bounds.minY), proposal: ProposedViewSize(width: grip, height: height))
            pane.place(at: CGPoint(x: paneX, y: bounds.minY), proposal: ProposedViewSize(width: paneWidth, height: height))
        case .leading:
            pane.place(at: bounds.origin, proposal: ProposedViewSize(width: paneWidth, height: height))
            divider.place(at: CGPoint(x: bounds.minX + paneWidth, y: bounds.minY), proposal: ProposedViewSize(width: grip, height: height))
            let primaryX = floats ? bounds.minX : bounds.minX + paneWidth + grip
            primary.place(at: CGPoint(x: primaryX, y: bounds.minY), proposal: ProposedViewSize(width: primaryWidth, height: height))
        }
    }
}

/// The divider of a `MacSplitPane`: a hairline with room either side to grab, the column-resize
/// pointer, a double-click to reset, and adjustments for VoiceOver.
struct MacSplitDivider: View {
    static let grip: CGFloat = 9

    /// The horizontal distance dragged since the drag began, in points.
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    var onReset: () -> Void
    /// A share step (+0.05 widens the leading view).
    var onAdjust: (Double) -> Void

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: Self.grip)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
                    .frame(width: isHovering ? 2 : 1)
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { isHovering = $0 }
            .gesture(
                // In window coordinates: the divider moves as it's dragged, so its own would drift.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onDragEnd() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            .help("Drag to resize. Double-click to reset.")
            .accessibilityElement()
            .accessibilityLabel("Pane divider")
            .accessibilityHint("Adjust to make the panes wider or narrower")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(0.05)
                case .decrement: onAdjust(-0.05)
                @unknown default: break
                }
            }
    }
}
