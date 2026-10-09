//
//  AboutView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the app is, who it is (not) from, where it comes from and how it treats data.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                Text("A fast, offline-friendly way to explore Northeastern's courses. Search every class, build conflict-free schedules, watch full sections for open seats and find free classrooms, all on your iPhone or iPad.")
            }

            Section {
                Label {
                    Text(LegalText.unofficialNotice)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Unofficial")
            }

            Section {
                Text(LegalText.searchNEUSummary)
                Link(destination: LegalText.searchNEURepositoryURL) {
                    linkLabel("SearchNEU on GitHub", detail: "github.com/sandboxnu/searchneu")
                }
                Link(destination: LegalText.searchNEUWebsiteURL) {
                    linkLabel("searchneu.com", detail: "The original course search")
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
                Text("Course data")
            }

            Section {
                Text(LegalText.sourceOffer)
                if let url = LegalText.sourceCodeURL {
                    Link(destination: url) {
                        Label("View source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Acknowledgements & Licenses", systemImage: "doc.text")
                }
            } header: {
                Text("Source code")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.m) {
            AppIconArtwork(size: 96)

            VStack(spacing: 2) {
                Text(LegalText.appName)
                    .font(.title2.weight(.bold))
                Text("Version \(LegalText.versionDescription)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.l)
    }

    private func linkLabel(_ title: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.s)
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(.isLink)
    }
}
