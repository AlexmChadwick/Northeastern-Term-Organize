//
//  DegreePlanExportSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import PDFKit
import SwiftUI
import UIKit

/// Exports a plan as a PDF in the degree audit's "View Plan" layout: a preview of the
/// first page, a switch for the student's name and ID (when the plan has them), and a
/// share button.
struct DegreePlanExportSheet: View {
    var planID: UUID

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var includesStudent = false
    @State private var export: Export?
    @State private var failure: String?

    /// A rendered PDF on disk and a thumbnail of its first page.
    private struct Export {
        var url: URL
        var preview: UIImage?
        var pageCount: Int
    }

    private var plan: DegreePlan? { userData.degreePlan(id: planID) }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    form(plan)
                } else {
                    ContentUnavailableView {
                        Label("Plan not found", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("This plan may have been deleted.")
                    }
                }
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: includesStudent) { prepare() }
    }

    // MARK: Form

    private func form(_ plan: DegreePlan) -> some View {
        Form {
            Section {
                previewContent
            } footer: {
                Text("The PDF uses the same layout as the degree audit’s View Plan, so you can send it to an advisor or import it again later.")
            }

            if plan.degreePlanHasStudentInfo {
                Section {
                    Toggle("Include student name and ID", isOn: $includesStudent)
                } footer: {
                    Text("Your name and ID stay on this device unless you share a PDF that includes them.")
                }
            }
        }
        .safeAreaBar(edge: .bottom) { shareBar }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let export {
            VStack(spacing: Theme.Spacing.s) {
                if let image = export.preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 340)
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        .accessibilityLabel("Preview of the first page")
                }
                Text("\(export.url.lastPathComponent) · \(export.pageCount == 1 ? "1 page" : "\(export.pageCount) pages")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            .listRowBackground(Color.clear)
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            ProgressView("Creating PDF…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.l)
        }
    }

    /// Text-only labels: a Label's icon can pick up the accent tint and vanish against
    /// prominent (tinted) glass.
    private var shareBar: some View {
        Group {
            if let export, let image = export.preview {
                ShareLink(item: export.url, preview: SharePreview(export.url.lastPathComponent, image: Image(uiImage: image))) {
                    Text("Share PDF")
                        .frame(maxWidth: .infinity)
                }
            } else if let export {
                ShareLink(item: export.url) {
                    Text("Share PDF")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {} label: {
                    Text("Share PDF")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            }
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    // MARK: Rendering

    /// Renders the PDF (a few pages at most) and its first-page thumbnail.
    private func prepare() {
        guard let plan else { return }
        do {
            let url = try DegreePlanPDFRenderer.temporaryFile(for: plan, includeStudent: includesStudent && plan.degreePlanHasStudentInfo)
            let document = PDFDocument(url: url)
            let preview = document?.page(at: 0)?.thumbnail(of: CGSize(width: 480, height: 679), for: .mediaBox)
            export = Export(url: url, preview: preview, pageCount: max(1, document?.pageCount ?? 1))
            failure = nil
        } catch {
            export = nil
            failure = "Couldn’t create the PDF. \(error.localizedDescription)"
        }
    }
}
