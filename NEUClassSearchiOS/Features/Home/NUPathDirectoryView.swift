//
//  NUPathDirectoryView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The NUpath attributes with how many courses carry each this term.
struct NUPathDirectoryView: View {
    var termCode: String

    var body: some View {
        BrowseIndexReader(termCode: termCode) { index in
            Group {
                if let index {
                    NUPathDirectoryList(index: index)
                } else {
                    BrowseIndexUnavailable(termCode: termCode)
                }
            }
            .navigationTitle("NUpath")
            .navigationSubtitle(index?.term.name ?? "")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct NUPathDirectoryList: View {
    var index: CatalogIndex

    /// Courses per NUpath, counted in a single pass over the catalog (the same
    /// rule `CatalogIndex.courses(with:)` uses for the lists behind each row).
    private var counts: [NUPath: Int] {
        var result: [NUPath: Int] = [:]
        for course in index.courses {
            for nupath in NUPath.allCases where course.attributes.contains(nupath.attributeCode) {
                result[nupath, default: 0] += 1
            }
        }
        return result
    }

    var body: some View {
        let counts = counts
        List {
            Section {
                Text("NUpath is Northeastern’s general education framework. A course can satisfy one or more NUpath attributes. Pick one to see which courses count toward it this term.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.xs, bottom: 0, trailing: Theme.Spacing.xs))
            }
            Section {
                ForEach(NUPath.allCases) { nupath in
                    NavigationLink(value: AppRoute.nupath(termCode: index.term.code, nupath: nupath)) {
                        NUPathDirectoryRow(nupath: nupath, count: counts[nupath] ?? 0)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct NUPathDirectoryRow: View {
    var nupath: NUPath
    var count: Int

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 34

    private var tint: Color {
        CourseColor.at(NUPath.allCases.firstIndex(of: nupath) ?? 0).base
    }

    private var tile: some View {
        Image(systemName: nupath.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: tileSize, height: tileSize)
            .background(tint.gradient, in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var countText: some View {
        Text(count.formatted())
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // The count moves under the name instead of squeezing it.
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    tile
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nupath.name)
                            .foregroundStyle(.primary)
                        Text(nupath.short)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        countText
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: Theme.Spacing.m) {
                    tile
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nupath.name)
                            .foregroundStyle(.primary)
                        Text(nupath.short)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    countText
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nupath.name), \(nupath.short)")
        .accessibilityValue(count == 1 ? "1 course" : "\(count) courses")
    }
}
