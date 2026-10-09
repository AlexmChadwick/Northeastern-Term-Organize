//
//  SearchToggleChip.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The toggle chip used in the iPhone and iPad filter forms. (Day presets, chip titles and the time
//  conversion are in Logic/Search/SearchFilterSupport.swift, shared with the Mac app.)
//

import SwiftUI

/// A rounded toggle used for grids of options (levels, days) inside forms.
/// A plain control on a content surface, so no Liquid Glass here.
struct SearchToggleChip: View {
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.s)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
                    in: .rect(cornerRadius: Theme.Radius.chip)
                )
                .contentShape(.rect(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
