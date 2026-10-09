//
//  PlanComponents.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Haptics

/// A value views bump to play a haptic: `haptic.fire(.success)` plus `.planHaptic(haptic)`.
struct PlanHaptic: Equatable {
    enum Kind: Equatable {
        case success, warning, impact, selection, increase, decrease
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
    func planHaptic(_ haptic: PlanHaptic) -> some View {
        sensoryFeedback(trigger: haptic) { _, new in
            guard new.count > 0 else { return nil }
            switch new.kind {
            case .success: return .success
            case .warning: return .warning
            case .impact: return .impact
            case .selection: return .selection
            case .increase: return .increase
            case .decrease: return .decrease
            }
        }
    }
}

// MARK: - Toast

/// A brief confirmation such as "Copied 5 CRNs", optionally with an action (Undo).
struct PlanToast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var systemImage = "checkmark.circle.fill"
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (lhs: PlanToast, rhs: PlanToast) -> Bool { lhs.id == rhs.id }
}

private struct PlanToastModifier: ViewModifier {
    @Binding var toast: PlanToast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
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
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
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
    /// Shows `toast` as a glass capsule at the top of the view for a few seconds.
    func planToast(_ toast: Binding<PlanToast?>) -> some View {
        modifier(PlanToastModifier(toast: toast))
    }
}

// MARK: - Flow layout

/// Lays children out left to right, wrapping onto new lines. Children wider than the
/// available width are given exactly that width (so a long label can truncate).
struct PlanFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            let size = result.sizes[index]
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        let limit: CGFloat? = width.isFinite ? width : nil
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: min(maxX, width.isFinite ? width : maxX), height: y + lineHeight), origins, sizes)
    }
}

// MARK: - Day dots

/// A row of weekday letters, filled for the days that have classes.
struct ScheduleDayDots: View {
    var days: DaySet
    var showsWeekend = false
    var tint: Color = .accentColor
    /// The dots' diameter; by default 20 points, scaled with the text size.
    var diameter: CGFloat?
    @ScaledMetric(relativeTo: .caption2) private var scaledSize: CGFloat = 20

    private var size: CGFloat { diameter ?? scaledSize }

    private var visible: [Int] {
        var result = [1, 2, 3, 4, 5]
        if showsWeekend || days.contains(day: 6) { result.append(6) }
        if showsWeekend || days.contains(day: 0) { result.insert(0, at: 0) }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(visible, id: \.self) { day in
                let isOn = days.contains(day: day)
                Text(DaySet.letters[day])
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: size, height: size)
                    .background(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .circle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days.isEmpty ? "No class days" : "Classes on \(days.indices.map { DaySet.fullNames[$0] }.joined(separator: ", "))")
    }
}

// MARK: - Chips

/// A capsule with a course's plan color and code. Optional courses get a dashed outline.
struct PlanCourseChip: View {
    var key: CourseKey
    var colorIndex: Int
    var isRequired = true
    var hasSection = true

    var body: some View {
        let color = CourseColor.at(colorIndex)
        HStack(spacing: 5) {
            Circle().fill(color.stroke).frame(width: 7, height: 7)
            Text(key.description)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.fill, in: .capsule)
        .overlay {
            if !isRequired {
                Capsule().strokeBorder(color.stroke.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .opacity(hasSection ? 1 : 0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.description)\(isRequired ? "" : ", optional")\(hasSection ? "" : ", no section chosen")")
    }
}

/// A small colored dot used as a course's identity marker.
struct PlanColorDot: View {
    var colorIndex: Int
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(CourseColor.at(colorIndex).stroke)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Banners

/// A tinted notice shown at the top of a plan: conflicts, full sections, credit load…
struct PlanBanner: View {
    enum Style {
        case error, warning, info

        var color: Color {
            switch self {
            case .error: .red
            case .warning: .orange
            case .info: .secondary
            }
        }

        var symbol: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .warning: "exclamationmark.circle.fill"
            case .info: "info.circle.fill"
            }
        }
    }

    var style: Style
    var title: String
    var lines: [String] = []
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.title3)
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        // Keep the action reachable as its own element when there is one.
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }
}

// MARK: - Freshness

/// "Seats as of 5 minutes ago. Pull down to refresh." — and it keeps itself current.
struct PlanSeatsFreshness: View {
    var date: Date?
    /// How to refresh, as the platform does it: "Pull down to refresh." on iPhone and iPad.
    var refreshHint = "Pull down to refresh."

    var body: some View {
        if let date {
            TimelineView(.everyMinute) { _ in
                Text("Seats as of \(date.formatted(.relative(presentation: .named))). \(refreshHint)")
            }
        } else {
            Text("Seats can change quickly. \(refreshHint)")
        }
    }
}

// MARK: - Misc

/// A tiny capsule showing that a section overlaps another course.
struct ScheduleConflictTag: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.12), in: .capsule)
            .lineLimit(1)
    }
}
