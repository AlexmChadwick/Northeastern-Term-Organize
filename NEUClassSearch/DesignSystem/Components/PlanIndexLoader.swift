//
//  PlanIndexLoader.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

private struct PlanIndexLoader: ViewModifier {
    var termCode: String?
    @Binding var loaded: CatalogIndex?
    var finished: Binding<Bool>?
    @Environment(CatalogStore.self) private var catalog

    func body(content: Content) -> some View {
        content.task(id: termCode) {
            guard let termCode else { return }
            finished?.wrappedValue = false
            loaded = await catalog.index(for: termCode)
            finished?.wrappedValue = true
        }
    }
}

extension View {
    /// Loads the catalog index for a plan's term (when it is not the selected
    /// term, which `CatalogStore` already keeps current). `finished` flips to
    /// true once the attempt is over, so "data unavailable" isn't shown while loading.
    func loadPlanIndex(termCode: String?, into loaded: Binding<CatalogIndex?>, finished: Binding<Bool>? = nil) -> some View {
        modifier(PlanIndexLoader(termCode: termCode, loaded: loaded, finished: finished))
    }
}
