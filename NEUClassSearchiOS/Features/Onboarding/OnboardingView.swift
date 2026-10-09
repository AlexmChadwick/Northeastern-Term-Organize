//
//  OnboardingView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The first-launch welcome sheet: what the app does, a privacy note and, when
/// campus data is available, an optional choice of preferred campus.
struct OnboardingView: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step {
        case welcome
        case campus
    }

    @State private var step: Step = .welcome
    @State private var selectedCampus: String?

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                welcomeStep
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            case .campus:
                campusStep
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: step)
    }

    // MARK: Welcome

    private var welcomeStep: some View {
        ScrollView {
            VStack(spacing: 36) {
                VStack(spacing: Theme.Spacing.m) {
                    Text("Welcome to\n\(Text("Term Organize").foregroundStyle(.tint))")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Northeastern courses, in your pocket.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 26) {
                    OnboardingFeatureRow(
                        symbol: "magnifyingglass",
                        tint: .red,
                        title: "Search every class",
                        message: "Find courses by code, title, professor or CRN, with live seats."
                    )
                    OnboardingFeatureRow(
                        symbol: "calendar.badge.plus",
                        tint: .blue,
                        title: "Build your schedule",
                        message: "Generate conflict-free schedules and export them to Calendar."
                    )
                    OnboardingFeatureRow(
                        symbol: "bell.badge.fill",
                        tint: .orange,
                        title: "Get seat alerts",
                        message: "Watch full sections and get notified when seats open."
                    )
                    OnboardingFeatureRow(
                        symbol: "door.left.hand.open",
                        tint: .green,
                        title: "Find a free room",
                        message: "See which classrooms are empty right now."
                    )
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: Theme.Spacing.m) {
                privacyFootnote
                Button(action: advanceFromWelcome) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.bottom, Theme.Spacing.s)
            .frame(maxWidth: .infinity)
        }
    }

    private var privacyFootnote: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Everything stays on your device. Unofficial — not affiliated with Northeastern University.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Campus

    private var campusStep: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .symbolRenderingMode(.hierarchical)
                        .accessibilityHidden(true)
                    Text("Where do you take classes?")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Searches start with this campus selected. You can change it any time in Settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                VStack(spacing: 0) {
                    ForEach(campusOptions, id: \.self) { name in
                        campusRow(name)
                        if name != campusOptions.last {
                            Divider().padding(.leading, Theme.Spacing.l)
                        }
                    }
                }
                .cardBackground(cornerRadius: 18)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: Theme.Spacing.s) {
                Button(action: finish) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button("Skip") {
                    selectedCampus = nil
                    finish()
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.bottom, Theme.Spacing.s)
            .frame(maxWidth: .infinity)
        }
    }

    private func campusRow(_ name: String) -> some View {
        let isSelected = selectedCampus == name
        return Button {
            selectedCampus = isSelected ? nil : name
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    /// Campuses that have classes this term, most common first, without the "no campus" placeholder.
    private var campusOptions: [String] {
        Array(catalog.campusPickerOptions(including: nil).prefix(10))
    }

    // MARK: Actions

    private func advanceFromWelcome() {
        // Skip the campus question while the catalog is still loading or has a single campus.
        if campusOptions.count > 1 {
            step = .campus
        } else {
            finish()
        }
    }

    private func finish() {
        var preferences = userData.preferences
        preferences.hasCompletedOnboarding = true
        if let selectedCampus { preferences.preferredCampus = selectedCampus }
        userData.preferences = preferences
        router.isOnboardingPresented = false
    }
}

/// One line of the welcome list: a tinted symbol, a title and a sentence.
private struct OnboardingFeatureRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.l) {
            Image(systemName: symbol)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
