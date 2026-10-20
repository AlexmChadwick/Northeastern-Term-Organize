//
//  DegreeRequirementsEntrySection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The plan screen's degree requirements card: a small invitation to set them up, a loading
/// or error state, or a summary (progress, when the plan finishes, what's still open) that
/// opens the full requirements.
struct DegreeRequirementsEntrySection: View {
    var context: DegreeRequirementsContext
    /// Replaces “On track to finish…” when a semester at or before the finish can't be taken.
    var blockedFinish: String? = nil
    var onSetUp: () -> Void
    var onRetry: () -> Void

    var body: some View {
        if context.isSetUp {
            Section {
                if let audit = context.audit {
                    NavigationLink(value: AppRoute.degreeRequirements(planID: context.plan.id)) {
                        DegreeRequirementsSummary(context: context, audit: audit, openItemLimit: 3, blockedFinish: blockedFinish)
                    }
                    .accessibilityHint("Shows every requirement")
                } else if let failure = context.failure {
                    failureRow(failure)
                } else {
                    loadingRow
                }
            } header: {
                Text("Degree requirements")
            }
        } else {
            Section {
                invitation
            }
        }
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check your degree requirements")
                        .font(.headline)
                    Text("Requirements come from Northeastern’s academic catalog for the year you started. Set them up to see when you’ll finish.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Button(action: onSetUp) {
                Text("Set up")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var loadingRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(context.programTitle)
                    .font(.headline)
                Text("Loading requirements…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.programTitle)
                    .font(.headline)
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Theme.Spacing.l) {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderless)
                Button("Change program or year", action: onSetUp)
                    .buttonStyle(.borderless)
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
