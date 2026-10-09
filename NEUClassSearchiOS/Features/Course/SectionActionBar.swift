//
//  SectionActionBar.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// Add to Schedule, Watch, Share and a "more" menu for the section page.
struct SectionActionBar: View {
    var section: CourseSection
    var course: Course?
    var term: Term
    /// Pushes a destination chosen from the menu.
    var onNavigate: (AppRoute) -> Void

    @Environment(\.openURL) private var openURL
    @State private var copyCount = 0

    private var courseTitle: String { course?.title ?? section.title }

    private var shareTitle: String {
        "\(section.courseKey.description) – \(courseTitle) · Section \(section.sectionNumber) (\(term.name))"
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: Theme.Spacing.m) {
                CourseAddButton(
                    termCode: term.code,
                    key: section.courseKey,
                    crn: section.crn,
                    sectionNumber: section.sectionNumber,
                    style: .bar
                )
                HStack(spacing: Theme.Spacing.m) {
                    CourseWatchButton(section: section, courseTitle: courseTitle, termCode: term.code, style: .bar)
                    shareButton
                    moreMenu
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyCount)
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = CourseLinks.section(termCode: term.code, crn: section.crn) {
            ShareLink(
                item: url,
                subject: Text(shareTitle),
                message: Text("\(shareTitle), CRN \(section.crn)"),
                preview: SharePreview(shareTitle, image: Image(systemName: "calendar.badge.clock"))
            ) {
                CourseIconLabel("square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Share section")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = section.crn
                copyCount += 1
            } label: {
                Label("Copy CRN", systemImage: "doc.on.doc")
            }
            Button {
                onNavigate(.course(termCode: term.code, key: section.courseKey))
            } label: {
                Label("View Course", systemImage: "book.closed")
            }
            if let url = BannerClient.catalogPageURL(term: term.code, course: section.courseKey) {
                Button {
                    openURL(url)
                } label: {
                    Label("View on Northeastern Website", systemImage: "safari")
                }
            }
            if let instructors = section.courseSortedInstructors, !instructors.isEmpty {
                Divider()
                ForEach(instructors, id: \.name) { instructor in
                    Button {
                        onNavigate(.professor(termCode: term.code, name: instructor.name))
                    } label: {
                        Label("View \(instructor.displayName)", systemImage: "person")
                    }
                }
            }
        } label: {
            CourseIconLabel("ellipsis")
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("More actions")
    }
}
