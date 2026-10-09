//
//  LicensesView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The app's license, its upstream attribution and what it is built with. This
/// screen is how the app displays its "Appropriate Legal Notices" (GNU AGPL v3,
/// sections 0 and 5d): copyright notice, no warranty, the right to convey the
/// app under the license, and how to read the license.
struct LicensesView: View {
    @State private var showsFullText = false

    var body: some View {
        List {
            Section {
                Text(LegalText.appCopyright)
                    .fontWeight(.medium)
                Text(LegalText.licenseGrant)
                Button {
                    showsFullText = true
                } label: {
                    Label("Read the full GNU AGPL v3 text", systemImage: "doc.text")
                }
            } header: {
                Text(LegalText.appName)
            } footer: {
                Text(LegalText.licenseNotice)
            }

            Section {
                Text(LegalText.noWarranty)
            } header: {
                Text("No warranty")
            }

            Section {
                Text(LegalText.upstreamCopyright)
                    .fontWeight(.medium)
                Text("Licensed under the \(LegalText.licenseName).")
                Text("Portions of this app are derived from SearchNEU's source code and modified for iOS. Changes are marked in the headers of the affected source files.")
                    .foregroundStyle(.secondary)
                Link(destination: LegalText.searchNEURepositoryURL) {
                    HStack {
                        Label("SearchNEU source code", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer(minLength: Theme.Spacing.s)
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            } header: {
                Text("SearchNEU")
            }

            Section {
                Text("Apart from the SearchNEU-derived code above, Term Organize uses only Apple's system frameworks (such as SwiftUI, WidgetKit, App Intents, Core Spotlight, CloudKit, Foundation Models, Natural Language, PDFKit, EventKit, UserNotifications and BackgroundTasks). It includes no third-party libraries, analytics or advertising.")
                Text("SF Symbols are Apple's and are used in accordance with Apple's terms.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apple frameworks")
            }

            Section {
                Text(LegalText.sourceOffer)
            } header: {
                Text("Source code")
            }
        }
        .navigationTitle("Acknowledgements & Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsFullText) {
            LicensesFullTextView()
        }
    }
}

/// The complete GNU AGPL v3, loaded from the bundled `LICENSE.txt`.
struct LicensesFullTextView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var didFail = false

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView {
                        Text(text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else if didFail {
                    ContentUnavailableView {
                        Label("License text unavailable", systemImage: "doc.questionmark")
                    } description: {
                        Text("The full license should be bundled with this app, but it couldn't be read. It is published at https://www.gnu.org/licenses/agpl-3.0.html.")
                            .textSelection(.enabled)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("GNU AGPL v3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let url = LegalText.licenseFileURL() {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: url) {
                            Label("Share License", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                text = await LegalText.loadLicenseText()
                didFail = text == nil
            }
        }
    }
}
