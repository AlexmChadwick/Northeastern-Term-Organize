//
//  DegreePlanPDF.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import CoreGraphics
import CoreText
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Imports degree audit plans from PDF (or plain-text) files.
enum DegreePlanImporter {
    /// File types offered in the importer.
    static let contentTypes: [UTType] = [.pdf, .plainText, .text]

    /// Reads and parses a plan. Handles security-scoped URLs from the document picker.
    static func importPlan(from url: URL) throws -> DegreePlanFormat.ParseResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let text: String
        if url.pathExtension.lowercased() == "pdf" || isPDF(url) {
            guard let extracted = textFromPDF(at: url) else { throw DegreePlanFormat.ImportError.unreadable }
            text = extracted
        } else {
            guard let data = try? Data(contentsOf: url) else { throw DegreePlanFormat.ImportError.unreadable }
            text = String(decoding: data, as: UTF8.self)
        }
        return try DegreePlanFormat.parse(text: text, fileName: url.lastPathComponent)
    }

    /// Text of every page, in order.
    static func textFromPDF(at url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return textFromPDF(document)
    }

    static func textFromPDF(data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        return textFromPDF(document)
    }

    private static func textFromPDF(_ document: PDFDocument) -> String? {
        guard document.pageCount > 0 else { return nil }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pages.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func isPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 5)) == Data("%PDF-".utf8)
    }
}

/// Renders a plan as a PDF with the same layout as the degree audit's "View Plan"
/// export: A4 pages, Helvetica 12 pt on 18 pt lines, a bold-oblique header, and
/// dash bullets. Drawn with Core Graphics and Core Text, so iOS and macOS produce the
/// same file.
enum DegreePlanPDFRenderer {
    private static let pageSize = CGSize(width: 595, height: 842)
    private static let lineHeight: CGFloat = 18
    /// Baselines run from 54 pt (top) to 774 pt, like the original export.
    private static let firstBaseline: CGFloat = 54
    private static let lastBaseline: CGFloat = 774
    private static let leftMargin: CGFloat = 36
    /// Text x positions for indent levels 0 (header), 1 (sections), 2 (courses).
    private static let indentX: [CGFloat] = [36, 96, 126]

    static func render(_ plan: DegreePlan, printedAt: Date = .now, includeStudent: Bool) -> Data {
        let regular = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let header = CTFontCreateWithName("Helvetica-BoldOblique" as CFString, 12, nil)

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info = [
            kCGPDFContextCreator as String: "Term Organize",
            kCGPDFContextTitle as String: "Degree Audit Plan – \(plan.name)",
        ] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else { return Data() }

        // Two blank lines, the header, the body, then two more blank lines — exactly like the export.
        let blank: (indent: Int, text: String, font: CTFont) = (0, " ", regular)
        var lines: [(indent: Int, text: String, font: CTFont)] = [blank, blank]
        lines += DegreePlanFormat.headerLines(for: plan, printedAt: printedAt, includeStudent: includeStudent).map { (0, $0, header) }
        lines += DegreePlanFormat.bodyLines(for: plan).map { ($0.indent, $0.text, regular) }
        lines += [blank, blank]
        let lastVisible = lines.lastIndex { $0.text != " " } ?? 0

        var baseline = lastBaseline + 1 // forces a new page first
        var pageIsOpen = false
        for (index, line) in lines.enumerated() {
            if baseline > lastBaseline {
                // Trailing blank lines never start a page of their own.
                if index > lastVisible { break }
                if pageIsOpen { context.endPDFPage() }
                context.beginPDFPage(nil)
                pageIsOpen = true
                baseline = firstBaseline
            }
            draw(line.text, font: line.font, x: indentX[line.indent], baseline: baseline, in: context)
            if line.indent > 0 {
                // The audit draws a dash bullet 30 pt to the left of section and course lines.
                draw("-", font: regular, x: indentX[line.indent] - 30, baseline: baseline, in: context)
            }
            baseline += lineHeight
        }
        if pageIsOpen { context.endPDFPage() }
        context.closePDF()
        return data as Data
    }

    /// Writes the PDF to a temporary file named after the plan, for sharing.
    static func temporaryFile(for plan: DegreePlan, includeStudent: Bool) throws -> URL {
        let safeName = plan.name.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "-")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DegreePlanExport", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(safeName.isEmpty ? "Degree Plan" : safeName) – view-plan.pdf")
        try render(plan, includeStudent: includeStudent).write(to: url, options: .atomic)
        return url
    }

    /// Draws one line with its baseline `baseline` points below the top of the page.
    private static func draw(_ text: String, font: CTFont, x: CGFloat, baseline: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }
        // The audit's PDF shows each header tab as a single space-wide gap, not a tab stop.
        let shown = text.replacingOccurrences(of: "\t", with: " ")
        // No kerning or ligatures, like the audit's PDF library; black text.
        let attributes = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: 0 as CFNumber,
            kCTLigatureAttributeName: 0 as CFNumber,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ] as CFDictionary
        guard let string = CFAttributedStringCreate(nil, shown as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(string)
        context.saveGState()
        // PDF space has its origin at the bottom left.
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: pageSize.height - baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
