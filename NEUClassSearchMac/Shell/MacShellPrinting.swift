//
//  MacShellPrinting.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Printing for the Mac screens (File › Print…, ⌘P): what a screen shows is drawn into a PDF, one
//  SwiftUI view per page, and the PDF goes to the print panel as a sheet on the front window.
//  The app's sandbox needs `com.apple.security.print` for this.
//

import AppKit
import PDFKit
import SwiftUI

@MainActor
enum MacShellPrinting {
    /// US Letter in points, the paper the pages are laid out for. A4 and other papers get the
    /// pages scaled down to fit.
    static let pageSize = CGSize(width: 612, height: 792)

    /// Draws one page per view into a PDF. Each view is given the whole page and a light
    /// appearance, whatever the app is showing, because paper is white.
    ///
    /// Only plain views draw: text, stacks, shapes, images. Controls, lists and tables don't
    /// render outside a window.
    static func pdf(pages: [AnyView]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in pages {
            let content = page
                .frame(width: pageSize.width, height: pageSize.height)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(pageSize)
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// Opens the print panel for a PDF, as a sheet on the front window when there is one.
    static func printPDF(_ data: Data, jobTitle: String) {
        guard let document = PDFDocument(data: data) else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        // The pages carry their own margins.
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
