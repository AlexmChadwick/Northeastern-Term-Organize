//
//  DegreePlanSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

// MARK: - Haptics

/// A value views bump to play a haptic: `haptic.fire(.success)` plus `.degreePlanHaptic(haptic)`.
struct DegreePlanHaptic: Equatable {
    enum Kind: Equatable {
        case success, warning, selection, impact
    }

    private(set) var kind: Kind = .selection
    private(set) var count = 0

    mutating func fire(_ kind: Kind) {
        self.kind = kind
        count += 1
    }
}

extension View {
    /// Plays the haptic whenever `haptic` changes.
    func degreePlanHaptic(_ haptic: DegreePlanHaptic) -> some View {
        sensoryFeedback(trigger: haptic) { _, new -> SensoryFeedback? in
            guard new.count > 0 else { return nil }
            switch new.kind {
            case .success: return .success
            case .warning: return .warning
            case .selection: return .selection
            case .impact: return .impact
            }
        }
    }
}

/// Haptics for flows that dismiss their own view straight away (a state-driven
/// `sensoryFeedback` could be torn down before it plays).
enum DegreePlanFeedback {
    @MainActor
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Toast

/// A brief confirmation such as "Copied plan as text", optionally with an action (Undo).
struct DegreePlanToast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var systemImage = "checkmark.circle.fill"
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (lhs: DegreePlanToast, rhs: DegreePlanToast) -> Bool { lhs.id == rhs.id }
}

private struct DegreePlanToastModifier: ViewModifier {
    @Binding var toast: DegreePlanToast?
    var edge: VerticalEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if let toast {
                    HStack(spacing: 14) {
                        Label(toast.text, systemImage: toast.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        if let title = toast.actionTitle, let action = toast.action {
                            Button(title) {
                                action()
                                withAnimation { self.toast = nil }
                            }
                            .font(.subheadline.weight(.bold))
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(edge == .top ? .top : .bottom, 8)
                    .padding(.horizontal, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        let seconds: UInt64 = toast.action == nil ? 2_200_000_000 : 5_000_000_000
                        try? await Task.sleep(nanoseconds: seconds)
                        guard !Task.isCancelled else { return }
                        withAnimation { self.toast = nil }
                    }
                    .onTapGesture { if toast.action == nil { withAnimation { self.toast = nil } } }
                }
            }
            .animation(.snappy, value: toast)
            .onChange(of: toast) { _, new in
                if let new { AccessibilityNotification.Announcement(new.text).post() }
            }
    }
}

extension View {
    /// Shows `toast` as a glass capsule at the top of the view (or its bottom, where the top has a
    /// header of its own) for a few seconds.
    func degreePlanToast(_ toast: Binding<DegreePlanToast?>, edge: VerticalEdge = .top) -> some View {
        modifier(DegreePlanToastModifier(toast: toast, edge: edge))
    }
}

// MARK: - Flow layout

/// Lays children out left to right, wrapping onto new lines.
struct DegreePlanFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: min(maxX, width.isFinite ? width : maxX), height: y + lineHeight), origins)
    }
}
