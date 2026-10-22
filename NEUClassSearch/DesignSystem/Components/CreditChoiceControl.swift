//
//  CreditChoiceControl.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Whole-credit stepper for a variable-credit row. Fixed-credit rows do not use it.
struct CreditChoiceControl: View {
    var span: CreditSpan
    var credits: Double
    var onChange: (Double) -> Void

    var body: some View {
        if let bounds = span.integerBounds, span.isVariable {
            Stepper(
                value: Binding(
                    get: { Int(span.clamp(credits).rounded()) },
                    set: { onChange(span.clamp(Double($0))) }
                ),
                in: bounds
            ) {
                Text(span.choiceLabel(credits))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .controlSize(.small)
            .accessibilityLabel(span.choiceLabel(credits))
        }
    }
}

/// Muted secondary line. Used for the CPS restriction note.
struct CatalogCaption: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// All / Undergrad / Grad. Undergrad is a course number below 5000.
struct DegreeLevelFilterPicker: View {
    @Binding var filters: SearchFilters

    var body: some View {
        Picker("Undergrad or graduate", selection: Binding(
            get: { filters.degreeLevel ?? .all },
            set: { filters.degreeLevel = $0 == .all ? nil : $0 }
        )) {
            ForEach(DegreeLevelFilter.allCases) { level in
                Text(level.label).tag(level)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Undergrad or graduate")
        .help("Undergrad is a course number below 5000. Grad is 5000 and above.")
    }
}
