//
//  MacSettingsView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The Settings window (⌘,): one pane per tab, like the settings of Apple's own apps. Each pane
/// sizes the window to its content. The selected tab is remembered, and Help › Acknowledgements
/// & Licenses opens the window on the About tab.
struct MacSettingsView: View {
    @AppStorage(MacSettingsTab.storageKey) private var tab = MacSettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: MacSettingsTab.general) {
                MacGeneralSettingsPane()
            }
            Tab("Data", systemImage: "externaldrive", value: MacSettingsTab.data) {
                MacDataSettingsPane()
            }
            Tab("iCloud", systemImage: "icloud", value: MacSettingsTab.iCloud) {
                MacCloudSettingsPane()
            }
            Tab("Notifications", systemImage: "bell.badge", value: MacSettingsTab.notifications) {
                MacNotificationSettingsPane()
            }
            Tab("About", systemImage: "info.circle", value: MacSettingsTab.about) {
                MacAboutSettingsPane()
            }
        }
        .frame(width: MacSettingsPaneLayout.width)
    }
}

enum MacSettingsPaneLayout {
    static let width: CGFloat = 560
}

extension UserDataStore {
    /// A binding to one of the preferences, for the Settings panes.
    func macPreferenceBinding<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { self.preferences[keyPath: keyPath] = $0 }
        )
    }
}
