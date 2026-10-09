//
//  HomeQuickSearch.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The preset searches the catalog home screens offer (iPhone, iPad and Mac).
//

import Foundation

/// Preset searches offered on the catalog home screen.
enum HomeQuickSearch: CaseIterable, Identifiable {
    case openSeats
    case honors
    case online
    case noFridays
    case firstYear

    var id: Self { self }

    var title: String {
        switch self {
        case .openSeats: "Open seats"
        case .honors: "Honors"
        case .online: "Online"
        case .noFridays: "No Friday classes"
        case .firstYear: "1000-level"
        }
    }

    var symbol: String {
        switch self {
        case .openSeats: "chair"
        case .honors: "star"
        case .online: "laptopcomputer"
        case .noFridays: "calendar.badge.minus"
        case .firstYear: "1.circle"
        }
    }

    var filters: SearchFilters {
        var filters = SearchFilters()
        switch self {
        case .openSeats: filters.openSeatsOnly = true
        case .honors: filters.honorsOnly = true
        case .online: filters.instruction = .online
        case .noFridays: filters.allowedDays = [.monday, .tuesday, .wednesday, .thursday]
        case .firstYear: filters.levels = [1]
        }
        return filters
    }
}
