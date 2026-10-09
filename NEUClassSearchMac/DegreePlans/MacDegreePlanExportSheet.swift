//
//  MacDegreePlanExportSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import PDFKit
import SwiftUI

/// Exports a plan as a PDF in the degree audit's "View Plan" layout: a preview of the first
/// page, a switch for the student's name and ID (when the plan has them), Share, and Save.
struct MacDegreePlanExportSheet: View {
    var planID: UUID

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var includesStudent = false
    @State private var export: Export?
    @State private var failure: String?
    @State private var isSaving = false

    /// A rendered PDF, where it is on disk for sharing, and a thumbnail of its first page.
    private struct Export {
        var data: Data
        var url: URL
        var preview: NSImage?
        var pageCount: Int
    }

    private var plan: DegreePlan? { userData.degreePlan(id: planID) }

    var body: some View {
        Group {
            if let plan {
                content(plan)
            } else {
                ContentUnavailableView {
                    Label("Plan not found", systemImage: "list.bullet.clipboard")
                } description: {
                    Text("This plan may have been deleted.")
                }
                .frame(width: 460, height: 260)
            }
        }
        .task(id: includesStudent) { prepare() }
    }

    private func content(_ plan: DegreePlan) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Text("Export PDF")
                    .font(.headline)
                previewContent
                Text("The PDF uses the same layout as the degree audit’s View Plan, so you can send it to an advisor or import it again later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if plan.degreePlanHasStudentInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Include student name and ID", isOn: $includesStudent)
                        Text("Your name and ID stay on this device unless you share a PDF that includes them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Save PDF…", isConfirmDisabled: export == nil, cancelTitle: "Done") {
                isSaving = true
            } onCancel: {
                dismiss()
            } leading: {
                shareButton
            }
        }
        .frame(width: 460)
        .fileExporter(
            isPresented: $isSaving,
            document: MacDegreePlanPDFDocument(data: export?.data ?? Data()),
            contentType: .pdf,
            defaultFilename: plan.macExportFileName
        ) { result in
            if case .success = result { dismiss() }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let export {
            VStack(spacing: 8) {
                if let image = export.preview {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 340)
                        .clipShape(.rect(cornerRadius: 3))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .accessibilityLabel("Preview of the first page")
                }
                Text("\(export.url.lastPathComponent) · \(export.pageCount == 1 ? "1 page" : "\(export.pageCount) pages")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            ProgressView("Creating PDF…")
                .frame(height: 200)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let export {
            ShareLink(item: export.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Renders the PDF (a few pages at most) and its first-page thumbnail.
    private func prepare() {
        guard let plan else { return }
        do {
            let url = try DegreePlanPDFRenderer.temporaryFile(for: plan, includeStudent: includesStudent && plan.degreePlanHasStudentInfo)
            let data = try Data(contentsOf: url)
            let document = PDFDocument(data: data)
            let preview = document?.page(at: 0)?.thumbnail(of: CGSize(width: 480, height: 679), for: .mediaBox)
            export = Export(data: data, url: url, preview: preview, pageCount: max(1, document?.pageCount ?? 1))
            failure = nil
        } catch {
            export = nil
            failure = "Couldn’t create the PDF. \(error.localizedDescription)"
        }
    }
}
