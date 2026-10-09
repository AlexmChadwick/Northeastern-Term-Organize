//
//  CourseCatalogHeader.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The top of the page of a course the loaded term's catalog doesn't list: code, credits, title,
/// and a note saying why there are no sections ("Not offered in Fall 2026", "No longer offered;
/// last listed Spring 2025"). Laid out like `CourseHeaderView`, from what Banner's catalog says.
struct CourseCatalogHeader: View {
    var code: String
    var title: String
    /// `4 credits`; nil when the catalog entry doesn't say.
    var credits: String?
    var availability: String
    var availabilitySymbol: String
    /// "Completed" / "Planned", when the primary degree plan has the course.
    var degreeTag: CourseDegreePlanTag?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            codeAndCredits
            if !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Label {
                Text(availability)
            } icon: {
                Image(systemName: availabilitySymbol)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .labelStyle(CourseInfoLabelStyle())
            if let degreeTag {
                degreeTag
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var codeAndCredits: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Spacing.m))
        return layout {
            Text(code)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
            if !stacked {
                Spacer(minLength: 0)
            }
            if let credits {
                Text(credits)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
        }
    }
}
