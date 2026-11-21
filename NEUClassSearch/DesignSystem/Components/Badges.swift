//
//  Badges.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Seat availability, e.g. a green "12 / 40" capsule or red "Full".
struct SeatsBadge: View {
    var remaining: Int
    var capacity: Int
    var waitlistRemaining: Int = 0
    var waitlistCapacity: Int = 0
    var waitlistCount: Int = 0
    var style: Style = .compact

    enum Style { case compact, detailed }

    init(section: CourseSection, style: Style = .compact) {
        remaining = section.seatsRemaining
        capacity = section.seatCapacity
        waitlistRemaining = section.waitlistRemaining
        waitlistCapacity = section.waitlistCapacity
        waitlistCount = section.waitlistCount
        self.style = style
    }

    init(remaining: Int, capacity: Int, style: Style = .compact) {
        self.remaining = remaining
        self.capacity = capacity
        self.style = style
    }

    private var isWaitlistHold: Bool { remaining > 0 && waitlistCount > 0 }
    private var waitlistLabel: String? {
        if waitlistCapacity > 0 { return "Waitlist \(waitlistCount)/\(waitlistCapacity)" }
        return waitlistCount > 0 ? "Waitlist \(waitlistCount)" : nil
    }

    /// The compact badge text; `Waitlist` alone, since the size is only in the detailed style.
    var compactText: String {
        if capacity == 0 && remaining <= 0 { return "No limit listed" }
        if isWaitlistHold { return "Waitlist" }
        return remaining > 0 ? "\(remaining)/\(capacity)" : "Full"
    }

    /// The detailed badge text. The word Waitlist appears once: in the size, never also as a status.
    var detailedText: String {
        if capacity == 0 && remaining <= 0 { return "No seat limit listed" }
        if isWaitlistHold { return "\(remaining) of \(capacity) · \(waitlistLabel ?? "Waitlist")" }
        if remaining > 0 { return "\(remaining) of \(capacity) open" }
        if let waitlistLabel { return "Full · \(waitlistLabel)" }
        return "Full"
    }

    private var color: Color {
        if isWaitlistHold { return .orange }
        return capacity == 0 && remaining <= 0 ? .secondary : Theme.seatColor(remaining: remaining, capacity: capacity)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: remaining > 0 ? "chair.fill" : "chair")
                .imageScale(.small)
            Text(style == .compact ? compactText : detailedText)
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if capacity == 0 && remaining <= 0 { return "No seat limit listed" }
        if isWaitlistHold { return "Waitlist, \(remaining) of \(capacity) seats held for the waitlist" }
        if remaining > 0 { return "\(remaining) of \(capacity) seats open" }
        if let waitlistLabel { return "Full, \(waitlistLabel)" }
        return "Full"
    }
}

/// A NUpath attribute capsule, e.g. "FQ".
struct NUPathChip: View {
    var nupath: NUPath
    var showsName = false

    var body: some View {
        HStack(spacing: 4) {
            Text(nupath.short).fontWeight(.bold)
            if showsName { Text(nupath.name) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .accessibilityLabel("NUpath \(nupath.name)")
    }
}

/// A row of NUpath chips.
struct NUPathChipRow: View {
    var nupaths: [NUPath]
    var limit = 4

    var body: some View {
        if !nupaths.isEmpty {
            HStack(spacing: 4) {
                ForEach(nupaths.prefix(limit)) { NUPathChip(nupath: $0) }
                if nupaths.count > limit {
                    Text("+\(nupaths.count - limit)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A small neutral or tinted capsule label.
struct TagLabel: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: .capsule)
    }
}

/// A thin capacity bar showing how full a section is.
struct SeatMeter: View {
    var remaining: Int
    var capacity: Int

    var body: some View {
        let fraction = capacity > 0 ? Double(capacity - max(0, remaining)) / Double(capacity) : 1
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.seatColor(remaining: remaining, capacity: capacity).gradient)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
