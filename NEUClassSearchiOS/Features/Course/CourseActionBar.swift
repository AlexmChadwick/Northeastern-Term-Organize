//
//  CourseActionBar.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// Save, Add to Schedule, Share and a "more" menu, as a row of Liquid Glass controls.
struct CourseActionBar: View {
    var course: Course
    var termCode: String
    var termName: String

    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var copyCount = 0

    private var key: CourseKey { course.key }
    private var isSaved: Bool { userData.isSaved(key, termCode: termCode) }
    private var shareTitle: String { "\(course.code) – \(course.title) (\(termName))" }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            // Widest first: icons everywhere, then a text-only primary button, then stacked.
            ViewThatFits(in: .horizontal) {
                row(showsAddIcon: true)
                row(showsAddIcon: false)
                VStack(spacing: Theme.Spacing.m) {
                    addButton(showsIcon: true)
                    HStack(spacing: Theme.Spacing.m) {
                        saveButton
                        shareButton
                        moreMenu
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyCount)
    }

    private func row(showsAddIcon: Bool) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            saveButton
            addButton(showsIcon: showsAddIcon)
            shareButton
            moreMenu
        }
    }

    // MARK: Controls

    private var saveButton: some View {
        Button {
            withAnimation(.snappy) {
                userData.toggleSaved(key, termCode: termCode)
            }
        } label: {
            CourseIconLabel(isSaved ? "bookmark.fill" : "bookmark", tint: isSaved ? Color.accentColor : nil)
                .symbolEffect(.bounce, value: isSaved)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .sensoryFeedback(trigger: isSaved) { _, saved in
            saved ? .success : .impact(weight: .light)
        }
        .accessibilityLabel(isSaved ? "Remove from saved courses" : "Save course")
        .accessibilityAddTraits(isSaved ? .isSelected : [])
    }

    private func addButton(showsIcon: Bool) -> some View {
        CourseAddButton(termCode: termCode, key: key, crn: nil, sectionNumber: nil, style: .bar, showsIcon: showsIcon)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = CourseLinks.course(termCode: termCode, key: key) {
            ShareLink(
                item: url,
                subject: Text(shareTitle),
                message: Text(shareTitle),
                preview: SharePreview(shareTitle, image: Image(systemName: "graduationcap"))
            ) {
                CourseIconLabel("square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Share course")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = course.code
                copyCount += 1
            } label: {
                Label("Copy Course Code", systemImage: "doc.on.doc")
            }
            if let url = BannerClient.catalogPageURL(term: termCode, course: key) {
                Button {
                    openURL(url)
                } label: {
                    Label("View on Northeastern Website", systemImage: "safari")
                }
            }
            Button {
                router.search(for: key.subject)
            } label: {
                Label("Search Similar Courses", systemImage: "magnifyingglass")
            }
        } label: {
            CourseIconLabel("ellipsis")
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("More actions")
    }
}
