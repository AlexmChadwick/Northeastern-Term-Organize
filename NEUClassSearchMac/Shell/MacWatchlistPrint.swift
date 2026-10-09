//
//  MacWatchlistPrint.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// File › Print… for the Watchlist: the watched sections as lettered pages (course, CRN,
/// times, instructor and how the seats looked at the last check), handy to have next to the
/// registration page.
@MainActor
enum MacWatchlistPrinter {
    /// One watched section as a line of the printout.
    struct Line: Identifiable {
        var id: String
        var course: String
        var title: String
        /// `Lecture 02 · MWR 9:15 – 10:20 AM · Jane Doe`.
        var details: String
        var crn: String
        var seats: String
        var status: WatchlistStatus

        init(_ row: MacWatchRow) {
            id = row.id
            course = row.courseKey.description
            title = row.item.courseTitle
            details = [row.sectionName, row.times, row.instructor].filter { $0 != "—" }.joined(separator: " · ")
            crn = row.crn
            seats = row.status.detail(for: row.item)
            status = row.status
        }
    }

    // Layout, in points: Letter with three-quarter-inch margins.
    private static let margin: CGFloat = 54
    private static let lineHeight: CGFloat = 44
    private static let firstHeaderHeight: CGFloat = 78
    private static let laterHeaderHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 28

    /// The pages of the printout, one view each.
    static func pages(rows: [MacWatchRow], termName: String, checked: String, printedAt: Date) -> [AnyView] {
        let lines = rows.map(Line.init)
        let open = rows.filter { $0.status == .open }.count
        let summary = [
            termName,
            "\(rows.count) \(rows.count == 1 ? "section" : "sections")",
            open > 0 ? "\(open) open" : nil,
        ].compactMap { $0 }.joined(separator: " · ")

        let contentHeight = MacShellPrinting.pageSize.height - 2 * margin
        let firstCapacity = max(1, Int((contentHeight - firstHeaderHeight - footerHeight) / lineHeight))
        let laterCapacity = max(1, Int((contentHeight - laterHeaderHeight - footerHeight) / lineHeight))

        var chunks: [[Line]] = [Array(lines.prefix(firstCapacity))]
        var rest = Array(lines.dropFirst(firstCapacity))
        while !rest.isEmpty {
            chunks.append(Array(rest.prefix(laterCapacity)))
            rest = Array(rest.dropFirst(laterCapacity))
        }
        return chunks.enumerated().map { position, chunk in
            AnyView(MacWatchlistPrintPage(
                lines: chunk,
                isFirst: position == 0,
                summary: summary,
                printedAt: printedAt,
                checked: checked,
                pageNumber: position + 1,
                pageCount: chunks.count
            ))
        }
    }

    /// The printout as a PDF.
    static func pdf(rows: [MacWatchRow], termName: String, checked: String, printedAt: Date = .now) -> Data {
        MacShellPrinting.pdf(pages: pages(rows: rows, termName: termName, checked: checked, printedAt: printedAt))
    }

    /// Opens the print panel for the watched sections.
    static func printRows(_ rows: [MacWatchRow], termName: String, checked: String) {
        guard !rows.isEmpty else { return }
        let data = pdf(rows: rows, termName: termName, checked: checked)
        MacShellPrinting.printPDF(data, jobTitle: "\(termName) Watchlist")
    }

    fileprivate static var geometry: (margin: CGFloat, lineHeight: CGFloat, firstHeader: CGFloat, laterHeader: CGFloat, footer: CGFloat) {
        (margin, lineHeight, firstHeaderHeight, laterHeaderHeight, footerHeight)
    }
}

/// One lettered page: black on white whatever the app's appearance, with fixed line heights so a
/// page holds a known number of sections.
private struct MacWatchlistPrintPage: View {
    var lines: [MacWatchlistPrinter.Line]
    var isFirst: Bool
    var summary: String
    var printedAt: Date
    var checked: String
    var pageNumber: Int
    var pageCount: Int

    private let ink = Color.black
    private let softInk = Color(white: 0.38)

    var body: some View {
        let layout = MacWatchlistPrinter.geometry
        VStack(alignment: .leading, spacing: 0) {
            header(height: isFirst ? layout.firstHeader : layout.laterHeader)
            ForEach(lines) { line in
                row(line)
                    .frame(height: layout.lineHeight)
            }
            Spacer(minLength: 0)
            footer
                .frame(height: layout.footer, alignment: .bottom)
        }
        .padding(layout.margin)
        .frame(width: MacShellPrinting.pageSize.width, height: MacShellPrinting.pageSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func header(height: CGFloat) -> some View {
        if isFirst {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watchlist")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(ink)
                HStack(alignment: .firstTextBaseline) {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(softInk)
                    Spacer()
                    Text("Printed \(printedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(softInk)
                }
                Rectangle()
                    .fill(ink)
                    .frame(height: 1)
                    .padding(.top, 6)
            }
            .frame(height: height, alignment: .top)
        } else {
            Text("Watchlist · \(summary)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(softInk)
                .frame(height: height, alignment: .top)
        }
    }

    private func row(_ line: MacWatchlistPrinter.Line) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(line.course)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ink)
                        Text(line.title)
                            .font(.system(size: 12))
                            .foregroundStyle(softInk)
                            .lineLimit(1)
                    }
                    Text(line.details)
                        .font(.system(size: 10.5))
                        .foregroundStyle(softInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("CRN \(line.crn)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(ink)
                    Text(line.seats)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(line.status.color)
                        .lineLimit(1)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color(white: 0.82))
                .frame(height: 0.5)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            Text("\(LegalText.appName) · seats as of the last check (\(checked)) · unofficial")
                .font(.system(size: 9))
                .foregroundStyle(softInk)
            Spacer()
            Text("Page \(pageNumber) of \(pageCount)")
                .font(.system(size: 9))
                .foregroundStyle(softInk)
        }
    }
}
