//
//  MacShellSamples.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

#if DEBUG
import SwiftUI
import UserNotifications

extension MacSampleData {
    /// Sample data for snapshots: watched sections in every state (open, nearly full, on the
    /// waitlist, full), made of real sections of the term's catalog.
    @MainActor
    static func seedShell(userData: UserDataStore, catalog: CatalogStore) {
        guard let index = catalog.readyIndex else { return }
        // `-MacSnapshotEmptyWatchlist YES` leaves the watchlist empty, for its empty state in the main window.
        if !UserDefaults.standard.bool(forKey: "MacSnapshotEmptyWatchlist") {
            MacShellSamples.seedWatchlist(userData: userData, index: index)
        }
    }

    /// Views of this area outside the main window, for `-MacSnapshotView <name>`; nil for names
    /// it doesn't know.
    ///
    /// - `upNext`: the menu bar extra on a Tuesday morning, in class (`upNext-morning`: before the
    ///   first class, `upNext-weekend`: on a Sunday, `upNext-empty`: without a schedule,
    ///   `upNext-ended`: after the term, `upNext-live`: from the primary schedule of the sample
    ///   data at the time given by `-MacSnapshotNow`)
    /// - `settings-general`, `settings-data`, `settings-icloud`, `settings-notifications`,
    ///   `settings-notifications-denied`, `settings-about`, `settings-licenses`
    /// - `welcome`
    /// - `watchlist-empty`, `watchlist-permission`
    /// - `watchlist-print`: the first page of File › Print… (the whole printout is also written to
    ///   `WatchlistPrint.pdf` next to the snapshots, for Quick Look)
    @MainActor
    static func shellSnapshotView(named name: String, catalog: CatalogStore, userData: UserDataStore) -> AnyView? {
        switch name {
        case "upNext", "upNext-morning", "upNext-weekend", "upNext-empty", "upNext-ended", "upNext-live":
            return MacShellSamples.upNext(named: name, catalog: catalog)
        case "settings-general":
            return AnyView(MacGeneralSettingsPane().frame(width: MacSettingsPaneLayout.width))
        case "settings-data":
            return AnyView(MacDataSettingsPane().frame(width: MacSettingsPaneLayout.width))
        case "settings-icloud":
            return AnyView(MacCloudSettingsPane().frame(width: MacSettingsPaneLayout.width))
        case "settings-notifications":
            return AnyView(MacNotificationSettingsPane(previewStatus: .authorized).frame(width: MacSettingsPaneLayout.width))
        case "settings-notifications-denied":
            return AnyView(MacNotificationSettingsPane(previewStatus: .denied).frame(width: MacSettingsPaneLayout.width))
        case "settings-about":
            return AnyView(MacAboutSettingsPane().frame(width: MacSettingsPaneLayout.width))
        case "settings-licenses":
            return AnyView(MacLicensesView())
        case "welcome":
            return AnyView(MacWelcomeView())
        case "watchlist-empty":
            // An empty store of its own: the sample data has watched sections.
            let empty = UserDataStore(fileURL: MacSnapshot.directory.appendingPathComponent("EmptyShell.json"))
            return AnyView(MacWatchlistView().environment(empty).frame(width: 980, height: 560))
        case "watchlist-permission":
            return AnyView(MacWatchlistView(previewStatus: .notDetermined).frame(width: 980, height: 560))
        case "watchlist-print":
            return MacShellSamples.watchlistPrint(userData: userData, catalog: catalog)
        default:
            return nil
        }
    }
}

/// Sample content of the shell's screens.
enum MacShellSamples {
    // MARK: Watchlist

    /// Six real lectures of popular courses, in the states a watchlist shows.
    @MainActor
    static func seedWatchlist(userData: UserDataStore, index: CatalogIndex) {
        let termCode = index.term.code
        let wanted = ["CS 2500", "CS 3000", "MATH 1341", "PHYS 1151", "CS 2510", "ENGW 1111", "BIOL 1111", "CHEM 1211", "DS 2000", "EECE 2322", "CS 3200", "CS 4500"]
        var lectures: [CourseSection] = []
        var seen = Set<CourseKey>()
        for text in wanted {
            guard let key = CourseKey(string: text),
                  let section = index.sections(for: key).first(where: { $0.classType == "Lecture" && !$0.isOnline }),
                  seen.insert(key).inserted else { continue }
            lectures.append(section)
        }
        // Fall back to any lectures when the popular ones aren't in the term.
        if lectures.count < 6 {
            for section in index.catalog.sections where section.classType == "Lecture" && seen.insert(section.courseKey).inserted {
                lectures.append(section)
                if lectures.count == 6 { break }
            }
        }

        let now = MacShellClock.now
        // (seats, capacity, waitlist spots, waitlist alerts, minutes since the last opening)
        let states: [(seats: Int, capacity: Int, waitlist: Int, alerts: Bool, opened: Int?)] = [
            (14, 40, 0, false, 125),
            (2, 35, 0, false, 1_500),
            (0, 30, 3, true, nil),
            (0, 25, 0, false, nil),
            (0, 60, 0, true, nil),
            (9, 24, 0, false, nil),
        ]
        for (section, state) in zip(lectures.prefix(states.count), states).reversed() {
            let title = index.course(section.courseKey)?.title ?? section.title
            userData.watch(section, courseTitle: title, termCode: termCode)
            guard var item = userData.watchlist.first(where: { $0.crn == section.crn && $0.termCode == termCode }) else { continue }
            item.lastSeatsRemaining = state.seats
            item.seatCapacity = section.seatCapacity > 0 ? section.seatCapacity : state.capacity
            item.lastWaitlistRemaining = state.waitlist
            item.notifyOnWaitlist = state.alerts
            item.addedAt = now.addingTimeInterval(-3 * 86_400)
            item.lastCheckedAt = now.addingTimeInterval(-4 * 60)
            item.lastNotifiedAt = state.opened.map { now.addingTimeInterval(-TimeInterval($0) * 60) }
            userData.updateWatchItem(item)
        }
    }

    // MARK: Printing

    /// The sample watchlist as File › Print… draws it: the first page as a view, and the whole
    /// printout as a PDF in the snapshot folder.
    @MainActor
    static func watchlistPrint(userData: UserDataStore, catalog: CatalogStore) -> AnyView? {
        let sections = userData.watchlist
            .map { item in
                MacWatchRow(
                    item: item,
                    section: catalog.cachedIndex(for: item.termCode)?.section(crn: item.crn),
                    status: WatchlistStatus(item: item, isMissing: false),
                    termName: catalog.selectedTerm?.shortName ?? ""
                )
            }
            .sorted { $0.courseKey < $1.courseKey }
        guard !sections.isEmpty else { return nil }
        // `-MacSnapshotPrintRepeat 7` repeats the sections to see a printout of several pages.
        let copies = max(1, UserDefaults.standard.integer(forKey: "MacSnapshotPrintRepeat"))
        let rows = (0..<copies).flatMap { copy in
            sections.map { row -> MacWatchRow in
                var repeated = row
                repeated.item.crn = "\(row.item.crn)\(copy)"
                return repeated
            }
        }
        let termName = catalog.selectedTerm?.name ?? "Watchlist"
        let pdf = MacWatchlistPrinter.pdf(rows: rows, termName: termName, checked: "checked 4 min ago", printedAt: MacShellClock.now)
        let url = MacSnapshot.directory.appendingPathComponent("WatchlistPrint.pdf")
        try? pdf.write(to: url)
        print("MacShell print: \(url.path) (\(pdf.count) bytes)")
        let pages = MacWatchlistPrinter.pages(rows: rows, termName: termName, checked: "checked 4 min ago", printedAt: MacShellClock.now)
        guard let first = pages.first else { return nil }
        return AnyView(
            first
                .frame(width: MacShellPrinting.pageSize.width, height: MacShellPrinting.pageSize.height)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
    }

    // MARK: Up Next

    private static var calendar: Calendar { .current }

    /// A moment on a weekday of the current term: `hour:minute` on the given date (month 10, 2026).
    private static func date(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .now
    }

    /// The menu bar extra in one of its states, over the term's real sections.
    @MainActor
    static func upNext(named name: String, catalog: CatalogStore) -> AnyView? {
        guard let index = catalog.readyIndex else { return nil }
        let content: MacUpNextMenu
        switch name {
        case "upNext-live":
            content = MacUpNextMenu(now: MacShellClock.now)
        case "upNext-empty":
            content = MacUpNextMenu(now: date(day: 6, hour: 10, minute: 15), source: .fixed(nil))
        case "upNext-ended":
            let plan = samplePlan(in: index)
            let after = calendar.date(from: DateComponents(year: 2026, month: 12, day: 28, hour: 10)) ?? .now
            content = MacUpNextMenu(now: after, source: .fixed(plan))
        case "upNext-weekend":
            content = MacUpNextMenu(now: date(day: 4, hour: 17, minute: 5), source: .fixed(samplePlan(in: index)))
        case "upNext-morning":
            content = MacUpNextMenu(now: date(day: 6, hour: 8, minute: 20), source: .fixed(samplePlan(in: index)))
        default:
            content = MacUpNextMenu(now: date(day: 6, hour: 10, minute: 15), source: .fixed(samplePlan(in: index)))
        }
        return AnyView(content)
    }

    /// A schedule of four real lectures with classes on Tuesday: one before 9:30, one running at
    /// 10:15, and two in the afternoon, for a day that shows every state of the list.
    @MainActor
    static func samplePlan(in index: CatalogIndex) -> SchedulePlan? {
        let tuesday = 2
        func meeting(_ section: CourseSection) -> Meeting? {
            section.weeklyMeetings.first { $0.days.contains(day: tuesday) && !$0.isOnline }
        }
        let lectures = index.catalog.sections
            .filter { $0.classType == "Lecture" && meeting($0) != nil }
            .sorted { ($0.courseKey, $0.sectionNumber) < ($1.courseKey, $1.sectionNumber) }

        var chosen: [CourseSection] = []
        func add(where matches: (Meeting) -> Bool) {
            for section in lectures {
                guard let m = meeting(section), matches(m),
                      !chosen.contains(where: { $0.courseKey == section.courseKey || $0.conflicts(with: section) }) else { continue }
                chosen.append(section)
                return
            }
        }
        add { ($0.start ?? 0) >= 8 * 60 && ($0.end ?? 0) <= 9 * 60 + 30 }
        add { ($0.start ?? 0) <= 10 * 60 + 15 && ($0.end ?? 0) > 10 * 60 + 15 && ($0.start ?? 0) >= 9 * 60 + 30 }
        add { ($0.start ?? 0) >= 12 * 60 + 30 && ($0.start ?? 0) <= 14 * 60 }
        add { ($0.start ?? 0) >= 15 * 60 && ($0.start ?? 0) <= 17 * 60 }
        guard !chosen.isEmpty else { return nil }

        var plan = SchedulePlan(name: "Fall Classes", termCode: index.term.code)
        plan.isPrimary = true
        for (position, section) in chosen.enumerated() {
            plan.courses.append(PlanCourse(key: section.courseKey, colorIndex: position))
            plan.selectedCRNs.append(section.crn)
        }
        return plan
    }
}
#endif
