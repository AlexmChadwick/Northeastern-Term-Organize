//
//  MacDegreePlanCards.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The degree plans as cards in as many columns as the width allows: each says where the plan
/// stands (credits done and planned, against what the program requires when its requirements are
/// known) and what comes next. Click to select (the preview beside them shows it in full),
/// double-click to open, and right-click for the rest.
struct MacDegreePlanCards: View {
    var plans: [DegreePlan]
    /// By plan, the semester hours its program requires, once its requirements have loaded.
    var requiredHours: [UUID: Double]
    @Binding var selection: Set<UUID>
    var open: (UUID) -> Void
    var menu: (UUID) -> AnyView

    var body: some View {
        ScrollView {
            // (A card needs 260 points, so one fits the narrowest window beside the sidebar.)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 480), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(plans) { plan in
                    MacDegreePlanCard(
                        plan: plan,
                        requiredHours: requiredHours[plan.id],
                        isSelected: selection.contains(plan.id),
                        onOpen: { open(plan.id) }
                    )
                    .onTapGesture(count: 2) { open(plan.id) }
                    .onTapGesture { selection = [plan.id] }
                    .contextMenu { menu(plan.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection.contains(plan.id) ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction(named: "Open Plan") { open(plan.id) }
                }
            }
            .padding(16)
        }
        // The arrow keys move the selection through the plans, Return opens the selected one.
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in move(direction) }
        .onKeyPress(.return) {
            guard let id = plans.first(where: { selection.contains($0.id) })?.id else { return .ignored }
            open(id)
            return .handled
        }
    }

    /// Selects the plan before or after the selected one (left and up go back, right and down on).
    private func move(_ direction: MoveCommandDirection) {
        let step: Int
        switch direction {
        case .left, .up: step = -1
        case .right, .down: step = 1
        @unknown default: return
        }
        guard !plans.isEmpty else { return }
        let current = plans.firstIndex { selection.contains($0.id) }
        let next = min(max((current ?? (step > 0 ? -1 : plans.count)) + step, 0), plans.count - 1)
        selection = [plans[next].id]
    }
}

/// One degree plan in the cards: its name and program, a bar of credits done and planned, and the
/// semesters coming up.
struct MacDegreePlanCard: View {
    var plan: DegreePlan
    var requiredHours: Double?
    var isSelected: Bool
    var onOpen: () -> Void

    var body: some View {
        let upcoming = plan.degreePlanUpcomingTerms()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: plan.isPrimary ? "star.fill" : "graduationcap")
                    .foregroundStyle(plan.isPrimary ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(plan.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onOpen) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open this plan")
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(programLine)
                    .font(.callout)
                    .foregroundStyle(plan.catalogProgramPath == nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
                if plan.isPrimary {
                    TagLabel(text: "Used for prerequisite checks", systemImage: "star.fill", tint: .orange)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                // Without what the program requires there's nothing to measure the bar against.
                if requiredHours != nil {
                    DegreeCreditsBar(done: plan.completedCredits, planned: plan.plannedCredits, total: requiredHours)
                }
                Text(creditsLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(plan.degreePlanNextLine(), systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !upcoming.isEmpty {
                    // As many semesters as the card has room for.
                    ViewThatFits(in: .horizontal) {
                        chips(of: upcoming, limit: 3)
                        chips(of: upcoming, limit: 2)
                        chips(of: upcoming, limit: 1)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 0.5)
        }
        .contentShape(.rect(cornerRadius: 12))
    }

    /// The upcoming semesters as chips (`Sp ’27 · 16`), the first few, and how many more there are.
    private func chips(of upcoming: [DegreePlanTerm], limit: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(upcoming.prefix(limit)) { term in
                Text("\(term.degreePlanChipName) · \(DegreePlanText.number(term.credits))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: .capsule)
                    .opacity(term.courses.isEmpty ? 0.55 : 1)
                    .help("\(term.name): \(term.degreePlanSummaryLine)")
            }
            if upcoming.count > limit {
                Text("+\(upcoming.count - limit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// `Computer Science, BSCS · 2024–2025 catalog`, or that its requirements aren't set up.
    private var programLine: String {
        guard plan.catalogProgramPath != nil else { return "Degree requirements not set up" }
        let title = plan.catalogProgramTitle ?? plan.program ?? "Program"
        return plan.requirementsYear.map { "\(title) · \($0) catalog" } ?? title
    }

    /// `50 done · 80 planned · 134 required`.
    private var creditsLine: String {
        var parts = ["\(DegreePlanText.number(plan.completedCredits)) done", "\(DegreePlanText.number(plan.plannedCredits)) planned"]
        if let requiredHours { parts.append("\(DegreePlanText.number(requiredHours)) required") }
        return parts.joined(separator: " · ")
    }
}
