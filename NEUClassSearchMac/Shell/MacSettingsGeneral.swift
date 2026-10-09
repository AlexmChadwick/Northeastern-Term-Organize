//
//  MacSettingsGeneral.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Settings › General: the term, search and calendar defaults, and the menu bar extra.
struct MacGeneralSettingsPane: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    /// "Show Up Next in the menu bar" (this Mac only); `NEUClassSearchMacApp` reads the same key.
    @AppStorage("mac.showsMenuBarExtra") private var showsMenuBarExtra = true

    var body: some View {
        Form {
            termSection
            searchSection
            calendarSection
            menuBarSection
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Term

    private var termSection: some View {
        Section {
            termPicker
        } header: {
            Text("Term")
        } footer: {
            Text("The term the main window shows. The term menu above the sidebar changes it too.")
        }
    }

    @ViewBuilder
    private var termPicker: some View {
        if catalog.termPickerOptions.isEmpty {
            LabeledContent("Current term") {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Current term", selection: termBinding) {
                ForEach(catalog.termPickerGroups, id: \.college) { group in
                    Section(group.college.displayName) {
                        ForEach(group.terms) { term in
                            Text(term.name).tag(term.code)
                        }
                    }
                }
            }
        }
    }

    private var termBinding: Binding<String> {
        Binding(
            get: { catalog.selectedTermCode ?? catalog.termPickerOptions.first?.code ?? "" },
            set: { code in
                guard !code.isEmpty, code != catalog.selectedTermCode else { return }
                Task {
                    await catalog.select(termCode: code)
                    userData.preferences.selectedTermCode = code
                }
            }
        )
    }

    // MARK: Search and course windows

    private var searchSection: some View {
        Section {
            Picker("Preferred campus", selection: userData.macPreferenceBinding(\.preferredCampus)) {
                Text("None").tag(String?.none)
                Divider()
                ForEach(catalog.campusPickerOptions(including: userData.preferences.preferredCampus), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            Toggle("Auto-refresh seats", isOn: userData.macPreferenceBinding(\.autoRefreshSeats))
        } header: {
            Text("Search and Courses")
        } footer: {
            Text("Searches start with the preferred campus selected, and Free Rooms shows only its buildings until you pick another campus. Auto-refresh fetches live seat counts from Northeastern each time you open a course.")
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section {
            Toggle("Show weekends", isOn: userData.macPreferenceBinding(\.showWeekends))
            Picker("Day starts at", selection: userData.macPreferenceBinding(\.calendarStartHour)) {
                ForEach(0..<max(1, userData.preferences.calendarEndHour), id: \.self) { hour in
                    Text(SettingsFormat.hourLabel(hour)).tag(hour)
                }
            }
            Picker("Day ends at", selection: userData.macPreferenceBinding(\.calendarEndHour)) {
                ForEach(min(24, userData.preferences.calendarStartHour + 1)...24, id: \.self) { hour in
                    Text(SettingsFormat.hourLabel(hour)).tag(hour)
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Calendars show your classes between these hours.")
        }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        Section {
            Toggle("Show Up Next in the menu bar", isOn: $showsMenuBarExtra)
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("Today's classes and the next one from My Schedule, one click away from anywhere on your Mac.")
        }
    }
}
