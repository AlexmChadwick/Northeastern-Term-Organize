//
//  CourseWatchButton.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit
import UserNotifications

/// Remembers, for this launch of the app, that the "notifications are off" hint was shown.
@MainActor
private enum CourseWatchHintSession {
    static var didWarnAboutNotifications = false
}

/// Toggles whether a section is on the watchlist.
///
/// Right after a section is watched a small popover says what happens next. It
/// never promises alerts the device will not deliver: when notifications are off
/// it points to Settings instead, and while the system permission prompt (raised
/// by the first watch) is still unanswered it waits for the answer.
struct CourseWatchButton: View {
    enum Style {
        /// A compact bordered button for use inside a content card.
        case card
        /// A larger glass button for action bars.
        case bar
    }

    private enum Hint {
        case willNotify
        case notificationsOff
    }

    var section: CourseSection
    var courseTitle: String
    var termCode: String
    var style: Style = .card

    @Environment(UserDataStore.self) private var userData
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("CourseWatchHintSeen") private var hintSeen = false
    @State private var showsHint = false
    @State private var hint = Hint.willNotify
    @State private var awaitsPermissionAnswer = false

    private var service: WatchlistService { WatchlistService.shared }

    private var isWatching: Bool {
        userData.isWatching(crn: section.crn, termCode: termCode)
    }

    var body: some View {
        Group {
            switch style {
            case .card:
                button
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
            case .bar:
                button
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
        .tint(isWatching ? Color.orange : nil)
        .popover(isPresented: $showsHint, arrowEdge: .bottom) {
            hintContent
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 270)
                .presentationCompactAdaptation(.popover)
        }
        .task(id: showsHint) {
            guard showsHint else { return }
            try? await Task.sleep(for: .seconds(hint == .notificationsOff ? 9 : 3.5))
            guard !Task.isCancelled else { return }
            showsHint = false
        }
        .onChange(of: service.authorizationStatus) { _, status in
            // The system prompt was answered: now the hint can say what is true.
            guard awaitsPermissionAnswer, status != .notDetermined else { return }
            awaitsPermissionAnswer = false
            presentHint()
        }
        .onChange(of: isWatching) { _, watching in
            if !watching { awaitsPermissionAnswer = false }
        }
        .sensoryFeedback(trigger: isWatching) { _, watching in
            watching ? .success : .impact(weight: .light)
        }
        .accessibilityLabel(isWatching ? "Stop watching section \(section.sectionNumber)" : "Watch section \(section.sectionNumber) for open seats")
    }

    private var button: some View {
        Button {
            let wasWatching = isWatching
            withAnimation(.snappy) {
                userData.toggleWatch(section, courseTitle: courseTitle, termCode: termCode)
            }
            if !wasWatching {
                Task { await offerHint() }
            }
        } label: {
            Label {
                // "Watch" and "Watching" are single words: shrink a little rather than
                // break them across lines. Only "Watch for Seats" may wrap, at its spaces.
                Text(title)
                    .lineLimit(style == .bar && !isWatching && dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.75)
            } icon: {
                Image(systemName: isWatching ? "bell.fill" : "bell")
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(maxWidth: style == .bar ? .infinity : nil)
        }
    }

    private var title: String {
        switch style {
        case .card: isWatching ? "Watching" : "Watch"
        case .bar: isWatching ? "Watching" : "Watch for Seats"
        }
    }

    // MARK: Hint

    @ViewBuilder
    private var hintContent: some View {
        switch hint {
        case .willNotify:
            Text("We'll notify you when seats open")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        case .notificationsOff:
            VStack(spacing: 10) {
                Text("Notifications are off")
                    .font(.subheadline.weight(.semibold))
                Text("Turn them on in Settings and we'll tell you when seats open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    showsHint = false
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .multilineTextAlignment(.center)
        }
    }

    /// Decides what, if anything, to say after a section was just watched.
    private func offerHint() async {
        await service.refreshAuthorizationStatus()
        if service.authorizationStatus == .notDetermined {
            // The first watch also raises the system permission prompt; speak once it is answered.
            awaitsPermissionAnswer = true
        } else {
            presentHint()
        }
    }

    private func presentHint() {
        if service.canNotify {
            // The reassurance is shown once, the first time a section is watched.
            guard !hintSeen else { return }
            hintSeen = true
            hint = .willNotify
        } else {
            // Never promise alerts that will not arrive; point to Settings, once per launch.
            guard !CourseWatchHintSession.didWarnAboutNotifications else { return }
            CourseWatchHintSession.didWarnAboutNotifications = true
            hint = .notificationsOff
        }
        showsHint = true
    }
}

/// Opens the "Add to Schedule" sheet for a course or a section. When a plan for
/// the term already holds it, the button says so ("In schedule" with a
/// checkmark); tapping still opens the sheet so it can be added to other plans.
struct CourseAddButton: View {
    enum Style {
        case card
        case bar
    }

    var termCode: String
    var key: CourseKey
    var crn: String?
    var sectionNumber: String?
    var style: Style = .card
    /// Whether the prominent bar button shows its calendar icon (dropped to save width).
    var showsIcon = true

    @Environment(AppRouter.self) private var router
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isInSchedule: Bool {
        userData.courseIsInSchedule(termCode: termCode, key: key, crn: crn)
    }

    var body: some View {
        Group {
            switch style {
            case .card:
                cardButton
            case .bar:
                barButton
            }
        }
        .sensoryFeedback(trigger: isInSchedule) { wasInSchedule, nowInSchedule in
            nowInSchedule && !wasInSchedule ? .success : nil
        }
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(isInSchedule ? "Opens Add to Schedule so you can add it to another plan" : "")
    }

    private func open() {
        router.addToSchedule(termCode: termCode, key: key, crn: crn)
    }

    private var cardButton: some View {
        Button(action: open) {
            Label {
                Text(isInSchedule ? "In schedule" : "Add")
                    // Two words may wrap at the space at accessibility sizes, never mid-word.
                    .lineLimit(isInSchedule && dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.75)
            } icon: {
                Image(systemName: isInSchedule ? "checkmark" : "plus")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(isInSchedule ? Color.green : nil)
        .animation(.snappy, value: isInSchedule)
    }

    @ViewBuilder
    private var barButton: some View {
        if isInSchedule {
            Button(action: open) {
                Label("In Schedule", systemImage: "checkmark")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .tint(.green)
        } else {
            Button(action: open) {
                Group {
                    if showsIcon {
                        Label("Add to Schedule", systemImage: "calendar.badge.plus")
                    } else {
                        Text("Add to Schedule")
                    }
                }
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    private var accessibilityTitle: String {
        if let sectionNumber {
            return isInSchedule ? "Section \(sectionNumber) is in your schedule" : "Add section \(sectionNumber) to schedule"
        }
        return isInSchedule ? "\(key.description) is in your schedule" : "Add \(key.description) to schedule"
    }
}
