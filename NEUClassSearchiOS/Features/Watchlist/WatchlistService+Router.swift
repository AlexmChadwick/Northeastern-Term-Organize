//
//  WatchlistService+Router.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

extension WatchlistService {
    /// Connects the service to the app's stores and router: tapping a seat alert opens its
    /// `termorganize://` link there. The engine itself is shared with the Mac app.
    func configure(catalog: CatalogStore, userData: UserDataStore, router: AppRouter) {
        configure(catalog: catalog, userData: userData) { [weak router] url in
            router?.handle(url: url)
        }
    }
}
