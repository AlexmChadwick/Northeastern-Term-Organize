//
//  SettingsSupport.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  What the Settings screens offer to choose from, shared by the iPhone/iPad and the Mac
//  interfaces.
//

import Foundation

enum SettingsFormat {
    /// `8 AM`, `12 PM`, `9 PM`; 24 is midnight.
    static func hourLabel(_ hour: Int) -> String {
        let hour24 = ((hour % 24) + 24) % 24
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return "\(hour12) \(hour24 < 12 ? "AM" : "PM")"
    }
}

extension CatalogStore {
    /// Terms to offer in a picker, always including the selected one so the picker has a matching tag.
    var termPickerOptions: [Term] {
        var options = terms
        if let selected = selectedTerm, !options.contains(where: { $0.code == selected.code }) {
            options.insert(selected, at: 0)
        }
        return options
    }

    /// `termPickerOptions` by college, in the order Northeastern, Professional Studies, Law.
    var termPickerGroups: [(college: Term.College, terms: [Term])] {
        let options = termPickerOptions
        return Term.College.allCases.compactMap { college in
            let terms = options.filter { $0.college == college }
            return terms.isEmpty ? nil : (college, terms)
        }
    }

    /// Campuses with sections this term, plus the saved choice so a picker always has a matching tag.
    func campusPickerOptions(including saved: String?) -> [String] {
        var names = (index?.campusNames ?? []).filter { !$0.localizedCaseInsensitiveContains("no campus") }
        if let saved, !names.contains(saved) {
            names.insert(saved, at: 0)
        }
        return names
    }
}
