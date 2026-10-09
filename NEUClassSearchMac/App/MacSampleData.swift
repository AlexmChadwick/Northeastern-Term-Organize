//
//  MacSampleData.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

#if DEBUG
import SwiftUI

/// Throwaway data for `-MacSnapshotSampleData` runs (see `MacSnapshot`): a store that isn't the
/// user's and never syncs. Each area fills in its part in its own folder.
enum MacSampleData {
    @MainActor
    static func seed(userData: UserDataStore, catalog: CatalogStore) {
        seedCatalog(userData: userData, catalog: catalog)
        seedSchedules(userData: userData, catalog: catalog)
        seedDegreePlans(userData: userData, catalog: catalog)
        seedShell(userData: userData, catalog: catalog)
    }

    /// The view `-MacSnapshotView <name>` renders, from whichever area knows the name.
    @MainActor
    static func snapshotView(named name: String, catalog: CatalogStore, userData: UserDataStore) -> AnyView? {
        if name == "sidebar" {
            return AnyView(MacSidebar(selection: .constant(.search)).frame(width: 240, height: 560))
        }
        return catalogSnapshotView(named: name, catalog: catalog, userData: userData)
            ?? schedulesSnapshotView(named: name, catalog: catalog, userData: userData)
            ?? degreePlansSnapshotView(named: name, catalog: catalog, userData: userData)
            ?? shellSnapshotView(named: name, catalog: catalog, userData: userData)
    }
}
#endif
