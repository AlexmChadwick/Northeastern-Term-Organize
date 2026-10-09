//
//  MacScheduleExport.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file the student saves from the export sheet: the calendar (`.ics`) or the picture (`.png`).
struct MacScheduleExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, MacScheduleExportDocument.calendarType] }
    static var writableContentTypes: [UTType] { [.png, MacScheduleExportDocument.calendarType] }

    /// The `.ics` calendar file type.
    static let calendarType = UTType(filenameExtension: "ics") ?? .calendarEvent

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// "Export Schedule": adds the schedule to the Calendar app (with write-only access: the app never
/// reads the calendars), saves it as a calendar file or a picture, or copies the CRNs for registration.
struct MacScheduleExportSheet: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var isAdding = false
    @State private var alert: ExportAlert?
    /// The file the student is saving (one save panel at a time): the calendar or the picture.
    @State private var exportFile: MacScheduleExportDocument?
    @State private var exportType = MacScheduleExportDocument.calendarType
    @State private var exportName = ""
    @State private var isExporting = false
    @State private var shareURL: URL?
    @State private var toast: PlanToast?

    private struct ExportAlert: Identifiable {
        var id = UUID()
        var title: String
        var message: String
        var offersSettings = false
        var closesAfter = false
    }

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    var body: some View {
        Group {
            if let plan, let index {
                content(plan: plan, index: index)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 560)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex)
        .planToast($toast)
        .alert(
            alert?.title ?? "",
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
            presenting: alert
        ) { alert in
            if alert.offersSettings {
                Button("Open Privacy Settings") { openCalendarPrivacySettings() }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {
                    if alert.closesAfter { dismiss() }
                }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(plan: SchedulePlan, index: CatalogIndex) -> some View {
        let export = ScheduleExporter.events(for: plan, index: index)
        VStack(spacing: 0) {
            if export.events.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to export", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("Choose a section for at least one course, then export your schedule.")
                }
            } else {
                Form {
                    summarySection(plan: plan, summary: export.summary)
                    calendarSection(plan: plan, index: index, events: export.events)
                    copySection(plan: plan, index: index)
                }
                .formStyle(.grouped)
                .task(id: "\(plan.updatedAt.timeIntervalSince1970)-\(catalog.indexVersion)") {
                    shareURL = try? ScheduleExporter.writeICS(for: plan, index: index)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .fileExporter(isPresented: $isExporting, document: exportFile, contentType: exportType, defaultFilename: exportName) { result in
            if case .failure(let error) = result {
                alert = ExportAlert(title: "Couldn’t save the file", message: error.localizedDescription)
            }
        }
    }

    private func summarySection(plan: SchedulePlan, summary: ScheduleExportSummary) -> some View {
        Section {
            LabeledContent("Schedule", value: plan.name)
            LabeledContent("Classes", value: summary.finalExams > 0
                ? "\(summary.classCount) · \(summary.weeklyMeetings) weekly meetings · \(summary.finalExams) final exams"
                : "\(summary.classCount) · \(summary.weeklyMeetings) weekly meetings")
            if let last = summary.lastClassDay {
                // The date is New York's: formatting it in the Mac's zone would read a day early on the West Coast.
                LabeledContent("Repeats until", value: last.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: ScheduleDates.newYork)))
            }
        } header: {
            Text("Export Schedule")
        } footer: {
            if summary.skippedMeetings > 0 {
                Text("\(summary.skippedMeetings) meeting(s) without dates were left out.")
            }
        }
    }

    private func calendarSection(plan: SchedulePlan, index: CatalogIndex, events: [ScheduleExportEvent]) -> some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    Task { await add(events) }
                } label: {
                    HStack(spacing: 8) {
                        if isAdding { ProgressView().controlSize(.small) } else { Image(systemName: "calendar.badge.plus") }
                        Text("Add to Calendar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdding)
                Button("Save Calendar File…", systemImage: "square.and.arrow.down") {
                    guard let data = try? Data(contentsOf: ScheduleExporter.writeICS(for: plan, index: index)) else {
                        alert = ExportAlert(title: "Couldn’t create the calendar file", message: "Choose a section for at least one course and try again.")
                        return
                    }
                    exportFile = MacScheduleExportDocument(data: data)
                    exportType = MacScheduleExportDocument.calendarType
                    exportName = Self.baseName("\(plan.name) – \(index.term.name)", extension: "ics")
                    isExporting = true
                }
                if let shareURL {
                    ShareLink(item: shareURL, preview: SharePreview("\(plan.name).ics", image: Image(systemName: "calendar"))) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer(minLength: 0)
            }
        } header: {
            Text("Calendar")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Label("Events repeat every week in Eastern Time, following Banner’s class dates. They don’t skip holidays or breaks, so delete those days in Calendar if you need to.", systemImage: "calendar.badge.clock")
                Label("Term Organize only adds events; it never reads your calendars. Adding the same schedule twice creates duplicates.", systemImage: "info.circle")
            }
            .labelStyle(.titleAndIcon)
            .padding(.top, 4)
        }
    }

    private func copySection(plan: SchedulePlan, index: CatalogIndex) -> some View {
        let resolved = ResolvedPlan(plan: plan, index: index)
        return Section {
            HStack(spacing: 10) {
                Button("Save as Image…", systemImage: "photo") {
                    guard let data = pictureData(plan: plan, index: index) else {
                        alert = ExportAlert(title: "Couldn’t render the image", message: "Choose a section for at least one course and try again.")
                        return
                    }
                    exportFile = MacScheduleExportDocument(data: data)
                    exportType = .png
                    exportName = Self.baseName("\(plan.name) – \(index.term.shortName)", extension: "png")
                    isExporting = true
                }
                Button("Copy Image", systemImage: "doc.on.doc") {
                    guard let data = pictureData(plan: plan, index: index), let image = NSImage(data: data) else {
                        alert = ExportAlert(title: "Couldn’t render the image", message: "Choose a section for at least one course and try again.")
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    toast = PlanToast(text: "Copied the picture", systemImage: "doc.on.doc.fill")
                }
                Button("Copy CRNs", systemImage: "number") {
                    let crns = resolved.crnsForRegistration
                    MacPasteboard.copy(crns.joined(separator: "\n"))
                    toast = PlanToast(text: crns.count == 1 ? "Copied 1 CRN" : "Copied \(crns.count) CRNs", systemImage: "doc.on.doc.fill")
                }
                .disabled(!resolved.hasSelection)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Picture and CRNs")
        } footer: {
            Text("The picture shows the week and every section with its CRN. The CRNs are ready to paste into registration.")
        }
    }

    // MARK: Actions

    /// The file name without its extension (the save panel adds it), cleaned of characters files can't have.
    private static func baseName(_ name: String, extension ext: String) -> String {
        let file = ScheduleExporter.fileName(name, extension: ext)
        return file.hasSuffix(".\(ext)") ? String(file.dropLast(ext.count + 1)) : file
    }

    private func pictureData(plan: SchedulePlan, index: CatalogIndex) -> Data? {
        guard let image = ScheduleExporter.renderCGImage(plan: plan, index: index) else { return nil }
        return ScheduleExporter.pngData(from: image)
    }

    private func add(_ events: [ScheduleExportEvent]) async {
        isAdding = true
        let outcome = await ScheduleExporter.addToCalendar(events)
        isAdding = false
        switch outcome {
        case .added(let count):
            alert = ExportAlert(
                title: "Added to Calendar",
                message: count == 1 ? "1 event was added to your calendar." : "\(count) events were added to your calendar.",
                closesAfter: true
            )
        case .nothingToAdd:
            alert = ExportAlert(title: "Nothing to add", message: "Choose a section for at least one course first.")
        case .denied:
            alert = ExportAlert(
                title: "Calendar access is off",
                message: "Allow Term Organize to add events in System Settings › Privacy & Security › Calendars, then try again.",
                offersSettings: true
            )
        case .failed(let message):
            alert = ExportAlert(title: "Couldn’t add events", message: message)
        }
    }

    private func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}
