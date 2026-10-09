//
//  ScheduleExportViews.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

// MARK: - Calendar export

/// "Export to Calendar": add the schedule to the Calendar app (write-only
/// access) or share it as an `.ics` file.
struct ScheduleCalendarExportSheet: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var loadedIndex: CatalogIndex?
    @State private var icsURL: URL?
    @State private var isAdding = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showsAlert = false
    @State private var offersSettings = false
    @State private var closesAfterAlert = false
    @State private var haptic = PlanHaptic()

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan, let index {
                    content(plan: plan, index: index)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Export to Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex)
        .planHaptic(haptic)
        .alert(alertTitle, isPresented: $showsAlert) {
            if offersSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {
                    if closesAfterAlert { dismiss() }
                }
            }
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private func content(plan: SchedulePlan, index: CatalogIndex) -> some View {
        let export = ScheduleExporter.events(for: plan, index: index)
        if export.events.isEmpty {
            ContentUnavailableView {
                Label("Nothing to export", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Choose a section for at least one course, then export your schedule.")
            }
        } else {
            Form {
                Section {
                    LabeledContent("Schedule", value: plan.name)
                    LabeledContent("Classes", value: "\(export.summary.classCount)")
                    LabeledContent("Weekly meetings", value: "\(export.summary.weeklyMeetings)")
                    if export.summary.finalExams > 0 {
                        LabeledContent("Final exams", value: "\(export.summary.finalExams)")
                    }
                    if let last = export.summary.lastClassDay {
                        // The date is New York's: formatting it in the device's zone would read a day early on the West Coast.
                        LabeledContent("Repeats until", value: last.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: ScheduleDates.newYork)))
                    }
                } footer: {
                    if export.summary.skippedMeetings > 0 {
                        Text("\(export.summary.skippedMeetings) meeting(s) without dates were left out.")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Events repeat every week in Eastern Time, following Banner’s class dates. They don’t skip holidays or breaks, so delete those days in Calendar if you need to.", systemImage: "calendar.badge.clock")
                        Label("Term Organize only adds events; it never reads your calendars. Adding the same schedule twice creates duplicates.", systemImage: "info.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
            }
            .safeAreaBar(edge: .bottom) {
                actionBar(plan: plan, events: export.events)
            }
            .task(id: "\(plan.updatedAt.timeIntervalSince1970)-\(catalog.indexVersion)") {
                icsURL = try? ScheduleExporter.writeICS(for: plan, index: index)
            }
        }
    }

    private func actionBar(plan: SchedulePlan, events: [ScheduleExportEvent]) -> some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                Button {
                    Task { await add(events) }
                } label: {
                    HStack(spacing: 8) {
                        if isAdding {
                            ProgressView()
                        } else {
                            Image(systemName: "calendar.badge.plus")
                        }
                        Text("Add to Calendar")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(isAdding)

                if let icsURL {
                    ShareLink(item: icsURL, preview: SharePreview("\(plan.name).ics", image: Image(systemName: "calendar"))) {
                        Label("Share Calendar File", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                } else {
                    Label("Share Calendar File", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func add(_ events: [ScheduleExportEvent]) async {
        isAdding = true
        let outcome = await ScheduleExporter.addToCalendar(events)
        isAdding = false
        offersSettings = false
        closesAfterAlert = false
        switch outcome {
        case .added(let count):
            haptic.fire(.success)
            alertTitle = "Added to Calendar"
            alertMessage = count == 1 ? "1 event was added to your calendar." : "\(count) events were added to your calendar."
            closesAfterAlert = true
        case .nothingToAdd:
            haptic.fire(.warning)
            alertTitle = "Nothing to add"
            alertMessage = "Choose a section for at least one course first."
        case .denied:
            haptic.fire(.warning)
            alertTitle = "Calendar access is off"
            alertMessage = "Allow Term Organize to add events in Settings, then try again."
            offersSettings = true
        case .failed(let message):
            haptic.fire(.warning)
            alertTitle = "Couldn’t add events"
            alertMessage = message
        }
        showsAlert = true
    }
}

// MARK: - Image share

/// "Share as Image": previews the rendered schedule and shares it as a PNG.
struct ScheduleImageShareSheet: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var loadedIndex: CatalogIndex?
    @State private var image: UIImage?
    @State private var fileURL: URL?
    @State private var failed = false

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image, let plan {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(.rect(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                            .padding(Theme.Spacing.l)
                            .accessibilityLabel("Preview of \(plan.name)")
                    }
                } else if failed {
                    ContentUnavailableView {
                        Label("Couldn’t render the image", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("Choose a section for at least one course and try again.")
                    }
                } else {
                    ProgressView("Rendering…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Share as Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaBar(edge: .bottom) {
                if let image, let fileURL, let plan {
                    ShareLink(item: fileURL, preview: SharePreview(plan.name, image: Image(uiImage: image))) {
                        Label("Share Image", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.s)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex)
        .task(id: renderKey) {
            guard let plan, let index else { return }
            // Let the sheet finish presenting first. `ImageRenderer` is bound to the main
            // actor, so the render itself stays there; encoding and writing the PNG don't.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let name = "\(plan.name) – \(index.term.shortName)"
            guard let rendered = await ScheduleExporter.renderImageFile(plan: plan, index: index, name: name) else {
                if !Task.isCancelled { failed = true }
                return
            }
            guard !Task.isCancelled else { return }
            image = rendered.image
            fileURL = rendered.url
            failed = false
        }
    }

    /// Re-render when the plan or any index changes (a sync or live refresh can change times and seats).
    private var renderKey: String {
        "\(plan?.updatedAt.timeIntervalSince1970 ?? 0)-\(catalog.indexVersion)-\(index == nil ? "none" : "ready")"
    }
}
