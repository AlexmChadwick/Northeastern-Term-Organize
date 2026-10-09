//
//  MacLicensesView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The app's license, its upstream attribution and what it is built with, in a sheet over
/// Settings › About. Like its iOS counterpart it shows the "Appropriate Legal Notices" of the GNU
/// AGPL v3 (sections 0 and 5d): copyright notice, no warranty, the right to convey the app under
/// the license, and a way to read the license itself.
struct MacLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Destination] = []

    private enum Destination: Hashable {
        case fullText
    }

    var body: some View {
        NavigationStack(path: $path) {
            overview
                .navigationTitle("Acknowledgements & Licenses")
                .navigationDestination(for: Destination.self) { _ in
                    MacLicenseTextView()
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(width: 540, height: 620)
    }

    private var overview: some View {
        Form {
            Section {
                Text(LegalText.appCopyright)
                    .fontWeight(.medium)
                Text(LegalText.licenseGrant)
                Button("Read the Full GNU AGPL v3 Text") {
                    path.append(.fullText)
                }
            } header: {
                Text(LegalText.appName)
            } footer: {
                Text(LegalText.licenseNotice)
            }

            Section {
                Text(LegalText.noWarranty)
            } header: {
                Text("No Warranty")
            }

            Section {
                Text(LegalText.upstreamCopyright)
                    .fontWeight(.medium)
                Text("Licensed under the \(LegalText.licenseName).")
                Text("Portions of this app are derived from SearchNEU's source code and modified for iOS and macOS. Changes are marked in the headers of the affected source files.")
                    .foregroundStyle(.secondary)
                Link(destination: LegalText.searchNEURepositoryURL) {
                    Label("SearchNEU Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } header: {
                Text("SearchNEU")
            }

            Section {
                Text("Apart from the SearchNEU-derived code above, \(LegalText.appName) uses only Apple's system frameworks (such as SwiftUI, AppKit, Core Spotlight, CloudKit, Foundation Models, Natural Language, PDFKit, EventKit and UserNotifications). It includes no third-party libraries, analytics or advertising.")
                Text("SF Symbols are Apple's and are used in accordance with Apple's terms.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apple Frameworks")
            }

            Section {
                Text(LegalText.sourceOffer)
                if let url = LegalText.sourceCodeURL {
                    Link(destination: url) {
                        Label("View Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            } header: {
                Text("Source Code")
            }
        }
        .formStyle(.grouped)
    }
}

/// The complete GNU AGPL v3, loaded from the bundled `LICENSE.txt`.
struct MacLicenseTextView: View {
    @State private var text: String?
    @State private var didFail = false

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if didFail {
                ContentUnavailableView {
                    Label("License Text Unavailable", systemImage: "doc.questionmark")
                } description: {
                    Text("The full license should be bundled with this app, but it couldn't be read. It is published at \(LegalText.licenseURL.absoluteString).")
                        .textSelection(.enabled)
                } actions: {
                    Link("Open on gnu.org", destination: LegalText.licenseURL)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("GNU AGPL v3")
        .toolbar {
            if let url = LegalText.licenseFileURL() {
                ToolbarItem {
                    ShareLink(item: url) {
                        Label("Share License", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            text = await LegalText.loadLicenseText()
            didFail = text == nil
        }
    }
}
