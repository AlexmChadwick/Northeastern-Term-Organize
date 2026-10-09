//
//  MacSectionCells.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The cells and menus the section tables share, in the course window (a course's sections) and the
//  professor window (an instructor's sections).
//

import SwiftUI

extension CourseSection {
    // Sort keys for the section tables' columns.

    /// The earliest weekly start, so sections sort by when they begin; unscheduled ones last.
    var macCatalogSortStart: Int { weeklyMeetings.compactMap(\.start).min() ?? Int.max }
    var macCatalogSortInstructor: String { courseSortedInstructors?.first?.displayName ?? "" }
    var macCatalogSortLocation: String { macCatalogLocationLabel }
    var macCatalogSortSeats: Int { seatsRemaining }
    var macCatalogSortWaitlist: Int { hasWaitlist ? waitlistRemaining : -1 }
    var macCatalogSortCourse: CourseKey { courseKey }

    /// `WVH 210`, `WVH 210 · SN 110`, or `Online`: where the section's weekly meetings are held.
    var macCatalogLocationLabel: String {
        let patterns = courseMeetingPatterns
        guard !patterns.isEmpty else { return isOnline ? "Online" : "–" }
        var seen = Set<String>()
        var labels: [String] = []
        for pattern in patterns {
            let label = pattern.locationLabel(long: false)
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels.joined(separator: " · ")
    }
}

// MARK: - Watching

enum MacCatalogWatching {
    /// What to tell the student after they start watching `what` ("section 02", "3 sections"): that
    /// they will be notified, or, when the Mac won't show alerts, that they won't be.
    @MainActor
    static func announcement(of what: String) -> (message: String, symbol: String, tint: Color) {
        let service = WatchlistService.shared
        if service.hasLoadedAuthorization, service.authorizationStatus == .denied {
            return ("Watching \(what), but notifications are off. Turn them on in System Settings to hear when seats open.", "bell.slash.fill", .orange)
        }
        return ("Watching \(what). You'll be notified when seats open.", "bell.fill", .green)
    }
}

// MARK: - Cells

/// A CRN that copies itself when it is clicked, and says so for a moment.
struct MacSectionCRNButton: View {
    var crn: String

    @State private var copiedAt: Date?

    private var isCopied: Bool { copiedAt != nil }

    var body: some View {
        Button {
            MacCatalogClipboard.copy(crn)
            copiedAt = .now
        } label: {
            HStack(spacing: 4) {
                Text(crn)
                    .monospacedDigit()
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(isCopied ? Color.green : Color.secondary)
                    .opacity(isCopied ? 1 : 0.6)
                    .contentTransition(.symbolEffect(.replace))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isCopied ? "Copied" : "Copy CRN \(crn)")
        .accessibilityLabel("CRN \(crn)")
        .accessibilityHint("Copies the CRN")
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedAt = nil
        }
    }
}

/// A section's open seats out of its capacity, colored by how many are left.
struct MacSectionSeatsLabel: View {
    var section: CourseSection

    var body: some View {
        if section.seatCapacity <= 0 && section.seatsRemaining <= 0 {
            Text("No limit")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 3) {
                Text("\(max(0, section.seatsRemaining))")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.seatColor(for: section))
                Text("/ \(section.seatCapacity)")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .help("\(section.courseSeatsSpoken) · \(section.enrollment) enrolled")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.courseSeatsSpoken)
        }
    }
}

/// A section's waitlist: how many are on it out of its room; a dash when it has none.
struct MacSectionWaitlistLabel: View {
    var section: CourseSection

    var body: some View {
        if section.hasWaitlist {
            HStack(spacing: 3) {
                Text("\(section.waitlistCount)")
                    .fontWeight(.medium)
                    .foregroundStyle(section.isFull ? Theme.seatColor(remaining: section.waitlistRemaining, capacity: section.waitlistCapacity) : Color.secondary)
                Text("/ \(section.waitlistCapacity)")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .help("Waitlist: \(section.waitlistCount) of \(section.waitlistCapacity) spots filled")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Waitlist: \(section.waitlistCount) of \(section.waitlistCapacity) filled")
        } else {
            Text("–")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("No waitlist")
        }
    }
}

/// A section's instructors as links to their windows.
struct MacSectionInstructorLinks: View {
    var section: CourseSection
    var termCode: String
    var isLoadingDetails: Bool

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let instructors = section.courseSortedInstructors {
            if instructors.isEmpty {
                Text("TBA").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(instructors.enumerated()), id: \.element.name) { position, instructor in
                        if position > 0 {
                            Text(", ").foregroundStyle(.secondary)
                        }
                        Button {
                            openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: instructor.name))
                        } label: {
                            Text(instructor.displayName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .buttonStyle(.link)
                        .help("Open \(instructor.displayName)'s window")
                    }
                }
            }
        } else if isLoadingDetails {
            Text("Loading…").foregroundStyle(.tertiary)
        } else {
            Text("Unavailable").foregroundStyle(.tertiary)
        }
    }
}

/// The bell in a section row: watch the section for open seats, or stop.
struct MacSectionWatchButton: View {
    var section: CourseSection
    var courseTitle: String
    var termCode: String

    // Optional: a table builds a cell before it has handed it the window's environment, and a layout in
    // that gap (the window being resized) must not find a store missing.
    @Environment(UserDataStore.self) private var userData: UserDataStore?
    @Environment(MacNavigator.self) private var navigator: MacNavigator?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.catalogToast) private var toast

    private var isWatching: Bool { userData?.isWatching(crn: section.crn, termCode: termCode) ?? false }

    var body: some View {
        Button {
            guard let userData else { return }
            let wasWatching = isWatching
            userData.toggleWatch(section, courseTitle: courseTitle, termCode: termCode)
            if !wasWatching {
                let note = MacCatalogWatching.announcement(of: "\(section.courseKey.description) section \(section.sectionNumber)")
                toast(note.message, systemImage: note.symbol, tint: note.tint, actionTitle: "Show Watchlist") {
                    if let navigator {
                        MacCatalogNavigation.showWatchlist(navigator: navigator, openWindow: openWindow)
                    }
                }
            }
        } label: {
            Image(systemName: isWatching ? "bell.fill" : "bell")
                .foregroundStyle(isWatching ? Color.orange : Color.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isWatching ? "Stop watching section \(section.sectionNumber)" : "Watch section \(section.sectionNumber) for open seats")
        .accessibilityLabel(isWatching ? "Stop watching section \(section.sectionNumber)" : "Watch section \(section.sectionNumber) for open seats")
    }
}

// MARK: - Menu

/// The context menu of section rows, for the sections that are selected: watch, add to a schedule,
/// copy the CRN, open the instructors.
struct MacCourseSectionMenu: View {
    var termCode: String
    var sections: [CourseSection]
    var courseTitle: (CourseSection) -> String
    /// Whether to offer "Open Course in New Window" (the professor window lists several courses).
    var offersCourse = false
    @Binding var newSchedule: MacCatalogNewScheduleRequest?

    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.catalogToast) private var toast

    private var isSingle: Bool { sections.count == 1 }
    private var allWatched: Bool { sections.allSatisfy { userData.isWatching(crn: $0.crn, termCode: termCode) } }

    private var instructors: [Instructor] {
        var seen = Set<String>()
        return sections.flatMap { $0.courseSortedInstructors ?? [] }.filter { seen.insert($0.name).inserted }
    }

    var body: some View {
        if offersCourse {
            let keys = Array(Set(sections.map(\.courseKey))).sorted()
            Button(keys.count == 1 ? "Open Course in New Window" : "Open \(keys.count) Courses in New Windows", systemImage: "macwindow.badge.plus") {
                for key in keys {
                    openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: key))
                }
            }
            Divider()
        }
        Button(allWatched ? "Stop Watching" : "Watch for Open Seats", systemImage: allWatched ? "bell.slash" : "bell") {
            toggleWatch()
        }
        MacCatalogAddToScheduleMenu(
            termCode: termCode,
            additions: sections.map { MacCatalogScheduleAddition(key: $0.courseKey, crn: $0.crn) },
            newSchedule: $newSchedule
        )
        Divider()
        Button(isSingle ? "Copy CRN" : "Copy CRNs", systemImage: "doc.on.doc") {
            MacCatalogClipboard.copy(sections.map(\.crn).joined(separator: "\n"))
        }
        if let section = sections.first, isSingle, let link = CourseLinks.section(termCode: termCode, crn: section.crn) {
            Button("Copy Link", systemImage: "link") { MacCatalogClipboard.copy(link.absoluteString) }
        }
        if !instructors.isEmpty {
            Divider()
            Menu("Open Professor", systemImage: "person") {
                ForEach(instructors, id: \.name) { instructor in
                    Button(instructor.displayName) {
                        openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: instructor.name))
                    }
                }
            }
        }
    }

    private func toggleWatch() {
        let shouldWatch = !allWatched
        for section in sections where userData.isWatching(crn: section.crn, termCode: termCode) != shouldWatch {
            userData.toggleWatch(section, courseTitle: courseTitle(section), termCode: termCode)
        }
        if shouldWatch {
            let note = MacCatalogWatching.announcement(of: isSingle ? "section \(sections[0].sectionNumber)" : "\(sections.count) sections")
            toast(note.message, systemImage: note.symbol, tint: note.tint, actionTitle: "Show Watchlist") {
                MacCatalogNavigation.showWatchlist(navigator: navigator, openWindow: openWindow)
            }
        }
    }
}
