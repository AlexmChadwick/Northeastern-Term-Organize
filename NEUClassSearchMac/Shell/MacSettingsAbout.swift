//
//  MacSettingsAbout.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Settings › About: what the app is, who it is (not) from, where it comes from and how it
/// treats data, with the version, the AGPL notices and a link to the source. Together with the
/// About panel this is where the app shows its "Appropriate Legal Notices" (AGPL v3 §5d).
struct MacAboutSettingsPane: View {
    @State private var showsLicenses = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 22)
                .padding(.bottom, 4)

            Form {
                Section {
                    Text("A fast, offline-friendly way to explore Northeastern's courses. Search every class, build conflict-free schedules, watch full sections for open seats and find free classrooms, all on your Mac.")
                }

                Section {
                    Label {
                        Text(LegalText.unofficialNotice)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Unofficial")
                }

                Section {
                    Text(LegalText.searchNEUSummary)
                    HStack {
                        Link("SearchNEU on GitHub", destination: LegalText.searchNEURepositoryURL)
                        Spacer()
                        Link("searchneu.com", destination: LegalText.searchNEUWebsiteURL)
                    }
                } header: {
                    Text("Based on SearchNEU")
                }

                Section {
                    Label {
                        Text(LegalText.privacyNotice)
                    } icon: {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.blue)
                    }
                } header: {
                    Text("Privacy")
                }

                Section {
                    Text(LegalText.dataNotice)
                } header: {
                    Text("Course Data")
                }

                Section {
                    Text(LegalText.sourceOffer)
                    HStack {
                        if let url = LegalText.sourceCodeURL {
                            Link(destination: url) {
                                Label("View Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                            }
                        }
                        Spacer()
                        Button("Acknowledgements & Licenses…") {
                            showsLicenses = true
                        }
                    }
                } header: {
                    Text("Source Code")
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 600)
        .sheet(isPresented: $showsLicenses) {
            MacLicensesView()
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            AppIconArtwork(size: 72)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
            VStack(spacing: 2) {
                Text(LegalText.appName)
                    .font(.title2.weight(.bold))
                Text("Version \(LegalText.versionDescription)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(LegalText.appCopyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }
}
