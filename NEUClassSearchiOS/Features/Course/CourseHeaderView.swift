//
//  CourseHeaderView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The top of the course page: code, title, credits, college and tags.
struct CourseHeaderView: View {
    var course: Course
    var term: Term
    var hasHonorsSections: Bool
    var caption: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(UserDataStore.self) private var userData

    /// `Khoury College of Computer Sciences · Computer Science`
    private var affiliation: String? {
        let parts = [course.college, course.department]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            codeAndCredits
            Text(course.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let affiliation {
                Text(affiliation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let caption {
                CatalogCaption(text: caption)
            }
            chips
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var codeAndCredits: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Spacing.m))
        return layout {
            Text(course.code)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
            if dynamicTypeSize.isAccessibilitySize == false {
                Spacer(minLength: 0)
            }
            Text(course.creditsLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: .capsule)
        }
    }

    @ViewBuilder
    private var chips: some View {
        let nupaths = course.nupaths
        let degreeTag = userData.courseDegreePlanTag(for: course.key)
        let hasTags = hasHonorsSections || course.specialTopics || term.isViewOnly || degreeTag != nil
        if !nupaths.isEmpty || hasTags {
            CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(nupaths) { nupath in
                    NUPathChip(nupath: nupath, showsName: true)
                }
                if hasHonorsSections {
                    TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
                }
                if course.specialTopics {
                    TagLabel(text: "Special topics", systemImage: "sparkles", tint: .orange)
                }
                if term.isViewOnly {
                    TagLabel(text: "View only term", systemImage: "lock.fill")
                }
                if let degreeTag {
                    degreeTag
                }
            }
        }
    }
}
