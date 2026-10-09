//
//  MacWelcomeView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The first-launch welcome sheet: what the app does, a privacy note, where it comes from and,
/// when campus data is available, an optional choice of preferred campus.
struct MacWelcomeView: View {
    /// `@AppStorage` key: set once the welcome has been shown (or dismissed).
    static let seenKey = "mac.hasSeenWelcome"

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var campus: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 36)
                .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                MacWelcomeFeature(
                    symbol: "magnifyingglass",
                    tint: .red,
                    title: "Search every class",
                    message: "Find courses by code, title, professor or CRN, with live seats."
                )
                MacWelcomeFeature(
                    symbol: "calendar.badge.plus",
                    tint: .blue,
                    title: "Build your schedule",
                    message: "Generate conflict-free schedules and export them to Calendar."
                )
                MacWelcomeFeature(
                    symbol: "graduationcap.fill",
                    tint: .purple,
                    title: "Plan your degree",
                    message: "Import your degree audit plan and check it against the requirements."
                )
                MacWelcomeFeature(
                    symbol: "bell.badge.fill",
                    tint: .orange,
                    title: "Get seat alerts",
                    message: "Watch full sections and get notified when seats open."
                )
                MacWelcomeFeature(
                    symbol: "door.left.hand.open",
                    tint: .green,
                    title: "Find a free room",
                    message: "See which classrooms are empty right now."
                )
            }
            .padding(.horizontal, 44)

            if campusOptions.count > 1 {
                campusPicker
                    .padding(.horizontal, 44)
                    .padding(.top, 22)
            }

            privacyNote
                .padding(.horizontal, 44)
                .padding(.top, 22)

            HStack {
                Button("About & Licenses…") {
                    UserDefaults.standard.set(MacSettingsTab.about.rawValue, forKey: MacSettingsTab.storageKey)
                    openSettings()
                }
                .buttonStyle(.link)
                Spacer()
                Button("Continue", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 44)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
        .frame(width: 540)
        .onAppear { campus = userData.preferences.preferredCampus }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AppIconArtwork(size: 76)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            Text("Welcome to Term Organize")
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Northeastern courses, on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var campusPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Where do you take classes?", selection: $campus) {
                Text("No preference").tag(String?.none)
                Divider()
                ForEach(campusOptions, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            Text("Searches start with this campus selected. You can change it any time in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Everything stays on your Mac. No accounts, no analytics, no tracking.")
                    .font(.callout)
                Text("Unofficial: not affiliated with Northeastern University or Sandbox. Based on SearchNEU by Sandbox at Northeastern University, free software under the \(LegalText.licenseName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Campuses that have classes this term, most common first (the same list as Settings).
    private var campusOptions: [String] {
        Array(catalog.campusPickerOptions(including: nil).prefix(10))
    }

    private func finish() {
        var preferences = userData.preferences
        preferences.hasCompletedOnboarding = true
        if let campus { preferences.preferredCampus = campus }
        userData.preferences = preferences
        dismiss()
    }
}

/// One line of the welcome list: a tinted symbol, a title and a sentence.
private struct MacWelcomeFeature: View {
    var symbol: String
    var tint: Color
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 40)
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
