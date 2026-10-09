//
//  SettingsView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// App settings, presented in a sheet (the presenter provides the navigation stack).
struct SettingsView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(CloudSyncStatus.self) private var cloudSync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private let alerts = WatchlistService.shared

    @State private var confirmsClearingData = false
    @State private var confirmsErasingUserData = false
    @State private var testNotificationCount = 0
    @State private var backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    var body: some View {
        Form {
            courseDataSection
            SettingsCloudSyncSection()
            searchSection
            coursePagesSection
            calendarSection
            seatAlertsSection
            aboutSection
            resetSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sensoryFeedback(.success, trigger: testNotificationCount)
        .task { await alerts.refreshAuthorizationStatus() }
        .onChange(of: scenePhase) { _, phase in
            // The user may have changed notification permission in the Settings app.
            if phase == .active {
                backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
                Task { await alerts.refreshAuthorizationStatus() }
            }
        }
    }

    // MARK: Course data

    private var courseDataSection: some View {
        Section {
            termPicker
            syncRows
            LabeledContent("Last updated") {
                if let date = catalog.sectionsUpdatedAt {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .wide))
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) {
                confirmsClearingData = true
            } label: {
                Text("Clear downloaded data")
            }
            .disabled(catalog.isSyncing)
            .confirmationDialog(
                "Clear downloaded data?",
                isPresented: $confirmsClearingData,
                titleVisibility: .visible
            ) {
                Button("Clear Downloaded Data", role: .destructive) {
                    Task { await catalog.clearDownloadedData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes course data and seat updates downloaded to this device. The snapshot that ships with the app stays, so everything keeps working offline.")
            }
        } header: {
            Text("Course data")
        } footer: {
            Text("Data is downloaded directly from Northeastern's public registration system (nubanner.neu.edu). A snapshot ships with the app so it works offline.")
        }
    }

    @ViewBuilder
    private var termPicker: some View {
        if termOptions.isEmpty {
            LabeledContent("Current term") {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Current term", selection: termBinding) {
                ForEach(termGroups, id: \.college) { group in
                    Section(group.college.displayName) {
                        ForEach(group.terms) { term in
                            Text(term.name).tag(term.code)
                        }
                    }
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    @ViewBuilder
    private var syncRows: some View {
        switch catalog.syncState {
        case .idle:
            Button {
                catalog.syncSelectedTerm()
            } label: {
                Label("Refresh \(termName) now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(catalog.selectedTermCode == nil)
        case .syncing(let progress):
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Refreshing \(termName)…")
                    .font(.subheadline.weight(.medium))
                ProgressView(value: progress.fraction)
                Text(progress.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
            Button("Cancel refresh") {
                catalog.cancelSync()
            }
        case .failed(let message):
            Label {
                Text(message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("Try again") {
                catalog.dismissSyncError()
                catalog.syncSelectedTerm()
            }
            Button("Dismiss") {
                catalog.dismissSyncError()
            }
        }
    }

    private var termName: String {
        catalog.selectedTerm?.name ?? "term"
    }

    /// Terms to offer, always including the selected one so the picker has a matching tag.
    private var termOptions: [Term] { catalog.termPickerOptions }

    private var termGroups: [(college: Term.College, terms: [Term])] { catalog.termPickerGroups }

    private var termBinding: Binding<String> {
        Binding(
            get: { catalog.selectedTermCode ?? termOptions.first?.code ?? "" },
            set: { code in
                guard !code.isEmpty, code != catalog.selectedTermCode else { return }
                Task {
                    await catalog.select(termCode: code)
                    userData.preferences.selectedTermCode = code
                }
            }
        )
    }

    // MARK: Search

    private var searchSection: some View {
        Section {
            Picker("Preferred campus", selection: preference(\.preferredCampus)) {
                Text("None").tag(String?.none)
                ForEach(campusOptions, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
        } header: {
            Text("Search")
        } footer: {
            Text("Searches start with this campus selected. Free Rooms shows only its buildings until you pick another campus.")
        }
    }

    /// Campuses with sections this term, plus the saved choice so the picker always has a matching tag.
    private var campusOptions: [String] {
        catalog.campusPickerOptions(including: userData.preferences.preferredCampus)
    }

    // MARK: Course pages & calendar

    private var coursePagesSection: some View {
        Section {
            Toggle("Auto-refresh seats", isOn: preference(\.autoRefreshSeats))
        } header: {
            Text("Course pages")
        } footer: {
            Text("Fetches live seat counts from Northeastern each time you open a course.")
        }
    }

    private var calendarSection: some View {
        Section {
            Toggle("Show weekends", isOn: preference(\.showWeekends))
            Stepper(
                value: preference(\.calendarStartHour),
                in: 0...max(0, userData.preferences.calendarEndHour - 1)
            ) {
                Text("Day starts at \(SettingsFormat.hourLabel(userData.preferences.calendarStartHour))")
                    .monospacedDigit()
            }
            Stepper(
                value: preference(\.calendarEndHour),
                in: min(24, userData.preferences.calendarStartHour + 1)...24
            ) {
                Text("Day ends at \(SettingsFormat.hourLabel(userData.preferences.calendarEndHour))")
                    .monospacedDigit()
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Calendars show your classes between these hours.")
        }
    }

    // MARK: Seat alerts

    private var seatAlertsSection: some View {
        Section {
            Toggle("Background refresh", isOn: backgroundRefreshBinding)
            backgroundRefreshWarning
            notificationStatusRow
            notificationActionRow
        } header: {
            Text("Seat alerts")
        } footer: {
            Text("iOS decides when background checks run, usually every 30 minutes or less often, and not at all if you rarely open the app or Low Power Mode is on. Open the Watchlist tab to check right away.")
        }
    }

    /// Explains why background checks can't run when iOS Settings (or a device policy) blocks them.
    @ViewBuilder
    private var backgroundRefreshWarning: some View {
        if backgroundRefreshStatus != .available {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background App Refresh is off")
                        .font(.subheadline.weight(.semibold))
                    Text(backgroundRefreshStatus == .denied
                         ? "Turn it on for Term Organize in iOS Settings so seats can be checked while the app is closed."
                         : "iOS has restricted background activity on this device, so seats are only checked while the app is open.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            if backgroundRefreshStatus == .denied {
                Button {
                    openSystemSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
            }
        }
    }

    private var backgroundRefreshBinding: Binding<Bool> {
        Binding(
            get: { userData.preferences.backgroundRefreshEnabled },
            set: { isOn in
                userData.preferences.backgroundRefreshEnabled = isOn
                WatchlistService.scheduleBackgroundRefresh(enabled: isOn && !userData.watchlist.isEmpty)
            }
        )
    }

    private var notificationStatusRow: some View {
        LabeledContent("Notifications") {
            switch alerts.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Label("On", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Off", systemImage: "bell.slash.fill")
                    .foregroundStyle(.red)
            default:
                Text("Not turned on")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notificationActionRow: some View {
        switch alerts.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Button {
                testNotificationCount += 1
                Task { await alerts.sendTestNotification() }
            } label: {
                Label("Send a test notification", systemImage: "bell.badge")
            }
        case .denied:
            Button {
                openSystemSettings()
            } label: {
                Label("Open Settings to allow notifications", systemImage: "gearshape")
            }
        default:
            Button {
                Task { await alerts.requestAuthorization() }
            } label: {
                Label("Turn on notifications", systemImage: "bell.badge")
            }
        }
    }

    // MARK: About & reset

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label("About Term Organize", systemImage: "info.circle")
            }
            NavigationLink {
                LicensesView()
            } label: {
                Label("Acknowledgements & Licenses", systemImage: "doc.text")
            }
            LabeledContent("Version", value: LegalText.versionDescription)
        } header: {
            Text("About")
        } footer: {
            Text(LegalText.unofficialNotice)
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                confirmsErasingUserData = true
            } label: {
                Text("Erase all schedules, watchlist & bookmarks")
            }
            .confirmationDialog(
                "Erase all schedules, watchlist & bookmarks?",
                isPresented: $confirmsErasingUserData,
                titleVisibility: .visible
            ) {
                Button("Erase Everything", role: .destructive, action: eraseUserData)
                Button("Cancel", role: .cancel) {}
            } message: {
                if cloudSync.erasesICloudData {
                    Text("This removes your schedules, degree plans, watchlist and bookmarks from this device and from iCloud, so they're also removed from your other devices. Recent courses and search history on this device are cleared too. Your settings are kept. This can't be undone.")
                } else {
                    Text("This removes your schedules, degree plans, watchlist, bookmarks, recent courses and search history from this device. Your settings are kept. This can't be undone.")
                }
            }
        } footer: {
            Text(cloudSync.erasesICloudData
                 ? "Removes everything you saved, on this device and in iCloud. Course data isn't affected."
                 : "Removes everything you saved on this device. Course data isn't affected.")
        }
    }

    private func eraseUserData() {
        userData.resetAll(keepingPreferences: true)
        // Save now; with iCloud sync on, this also queues the deletions for iCloud right away.
        userData.flushNow()
        WatchlistService.scheduleBackgroundRefresh(enabled: false)
        alerts.didEraseWatchlist()
    }

    // MARK: Helpers

    private func preference<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { userData.preferences[keyPath: keyPath] },
            set: { userData.preferences[keyPath: keyPath] = $0 }
        )
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}
