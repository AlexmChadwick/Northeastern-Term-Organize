//
//  BrowseCourseRow.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// How the save action reads on a row: a toggle everywhere except the saved
/// list, where it removes the course.
enum BrowseSaveStyle {
    case toggle
    case remove
}

/// A `CourseRow` that pushes the course screen, with a context menu (save,
/// schedule, copy, share) and swipe actions. Use inside a `List`.
///
/// The saved state is read here, per visible row, instead of being passed down
/// from the list: a list of ~3,000 search results then does not have to
/// rebuild when the user's data changes while a course screen is pushed.
struct BrowseCourseRow: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    var termCode: String
    var course: Course
    var stats: CourseStats?
    var note: String?
    var saveStyle: BrowseSaveStyle = .toggle

    var body: some View {
        let isSaved = userData.isSaved(course.key, termCode: termCode)
        NavigationLink(value: AppRoute.course(termCode: termCode, key: course.key)) {
            HStack(spacing: Theme.Spacing.s) {
                CourseRow(course: course, stats: stats, note: note)
                // Everywhere except the saved list itself, mark bookmarked courses.
                if isSaved && saveStyle == .toggle {
                    Image(systemName: "bookmark.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Saved")
                }
            }
        }
        .contextMenu {
            BrowseCourseMenu(termCode: termCode, course: course, isSaved: isSaved, saveStyle: saveStyle)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            switch saveStyle {
            case .toggle:
                Button {
                    userData.toggleSaved(course.key, termCode: termCode)
                } label: {
                    Label(isSaved ? "Unsave" : "Save", systemImage: isSaved ? "bookmark.slash" : "bookmark")
                }
                .tint(.orange)
            case .remove:
                Button(role: .destructive) {
                    userData.toggleSaved(course.key, termCode: termCode)
                } label: {
                    Label("Remove", systemImage: "bookmark.slash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                router.addToSchedule(termCode: termCode, key: course.key)
            } label: {
                Label("Schedule", systemImage: "calendar.badge.plus")
            }
            .tint(.blue)
        }
        .sensoryFeedback(trigger: isSaved) { _, saved in
            saved ? .success : .impact(weight: .light)
        }
    }
}

/// Context menu actions for a course. A separate view so its body is only
/// evaluated when the menu is actually shown.
struct BrowseCourseMenu: View {
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    var termCode: String
    var course: Course
    var isSaved: Bool
    var saveStyle: BrowseSaveStyle = .toggle

    private var saveTitle: String {
        switch saveStyle {
        case .toggle: isSaved ? "Unsave" : "Save"
        case .remove: "Remove from saved"
        }
    }

    var body: some View {
        Button {
            userData.toggleSaved(course.key, termCode: termCode)
        } label: {
            Label(saveTitle, systemImage: isSaved ? "bookmark.slash" : "bookmark")
        }
        Button {
            router.addToSchedule(termCode: termCode, key: course.key)
        } label: {
            Label("Add to schedule", systemImage: "calendar.badge.plus")
        }
        Button {
            UIPasteboard.general.string = course.code
        } label: {
            Label("Copy course code", systemImage: "doc.on.doc")
        }
        ShareLink(item: "\(course.code) – \(course.title)") {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

/// A saved course that is not part of the term's catalog (or whose catalog is
/// not on the device). Still removable.
struct BrowseMissingCourseRow: View {
    @Environment(UserDataStore.self) private var userData

    var termCode: String
    var key: CourseKey
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.description)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                userData.toggleSaved(key, termCode: termCode)
            } label: {
                Label("Remove", systemImage: "bookmark.slash")
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = key.description
            } label: {
                Label("Copy course code", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                userData.toggleSaved(key, termCode: termCode)
            } label: {
                Label("Remove from saved", systemImage: "bookmark.slash")
            }
        }
    }
}
