//
//  MacSchedulesSamples.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Sample data and snapshot views of the schedules area. `-MacSnapshotSchedules none` seeds no
//  schedules (the empty overview); `-MacSnapshotSchedules empty` puts an empty "Plan A" first (the empty
//  schedule with its suggestions); `-MacSnapshotSchedules second` puts "Plan B", with its conflict and
//  full section, first; `-MacSnapshotSchedules many` adds four more schedules (a light load, a morning
//  person's, one without sections chosen, an empty one) for the overview's grid. Views for
//  `-MacSnapshotView <name>`:
//
//    scheduleNew                     the New Schedule sheet
//    scheduleNewWithCourses          the sheet with another schedule's courses chosen as the start
//    schedulePreferences             "Your ideal week" survey, Apple Intelligence available
//    schedulePreferencesFilled       the survey right after Apple Intelligence filled it in
//    schedulePreferencesUnavailable  the survey when Apple Intelligence is turned off
//    scheduleRename                  the Rename Schedule sheet
//    scheduleBlockedTime             the blocked time editor
//    scheduleInstructors             the instructors to prefer or avoid
//    scheduleFilters                 the generator's filters popover
//    scheduleSectionPicker           the section table and preview for the first schedule's first course
//    scheduleSectionDetails          the popover of a class on the calendar
//    scheduleAddCourse               the Add Course popover
//    scheduleExport                  the export sheet
//    scheduleGenerator               the first schedule's generator (use `-MacSnapshotSize`)
//    scheduleNoResults               the "no schedules fit" help with a degree plan suggestion
//    scheduleOverviewPreview         the overview's preview of the first schedule
//    scheduleMinSize                 prints the smallest width and height each screen allows
//    scheduleCalendar                the week calendar of the first schedule
//

#if DEBUG
import AppKit
import SwiftUI

extension MacSampleData {
    // MARK: Seeding

    /// Sample data for snapshots: two schedules for the selected term, "Plan A" (My Schedule, with
    /// an ideal week and favorites) and "Plan B" (one conflict and one full section).
    @MainActor
    static func seedSchedules(userData: UserDataStore, catalog: CatalogStore) {
        guard let index = catalog.readyIndex else { return }
        let termCode = index.term.code
        // `-MacSnapshotSchedules none` seeds no schedules, `empty` puts an empty one first (the two
        // below it become Plan B and Plan C), and `second` puts Plan B (the one with the conflict) first.
        let variant = UserDefaults.standard.string(forKey: "MacSnapshotSchedules")
        if variant == "none" { return }
        if variant == "empty" { userData.createPlan(name: "Plan A", termCode: termCode) }
        let names = variant == "empty" ? ["Plan B", "Plan C"] : ["Plan A", "Plan B"]

        /// A second-year computer science term, with an ideal week and favorites.
        func secondYear() -> UUID {
            let planA = userData.createPlan(name: names[0], termCode: termCode)
            let keysA = sampleCourses(preferred: ["CS 3000", "MATH 2331", "CS 3650", "ENGW 1111"], count: 4, in: index)
            for key in keysA { userData.addCourse(key, toPlan: planA.id) }
            if let optional = sampleCourses(preferred: ["PHIL 1145", "COMM 1112", "PSYC 1101"], count: 1, in: index, excluding: keysA).first {
                userData.addCourse(optional, toPlan: planA.id, required: false)
            }
            var preferences = SchedulePreferences()
            preferences[.earlyMorning] = .avoid
            preferences[.afternoon] = .prefer
            preferences.daysOff = .friday
            preferences.blockedTimes = [
                BlockedTime(label: "Robotics club", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60),
            ]
            userData.updatePlan(id: planA.id) { $0.preferences = preferences }
            if let plan = userData.plan(id: planA.id) {
                let result = ScheduleGenerator.generate(
                    courses: ScheduleCourseInput.inputs(for: plan, index: index),
                    filters: plan.filters, preferences: preferences, sort: .best
                )
                if let best = result.schedules.first {
                    userData.updatePlan(id: planA.id) { $0.selectedCRNs = best.crns }
                }
                for schedule in result.schedules.prefix(3).dropFirst() {
                    userData.updatePlan(id: planA.id) { PlanEditing.setFavorite(true, sortedCRNs: schedule.sortedCRNs, in: &$0) }
                }
            }
            return planA.id
        }

        /// A first-year term with a lab, a conflict and a full section.
        func firstYear() {
            let planB = userData.createPlan(name: names[1], termCode: termCode)
            let keysB = sampleCourses(preferred: ["CS 2100", "CS 2101", "MATH 1341", "ENGW 1111", "CS 1800"], count: 5, in: index, excluding: [])
            for key in keysB { userData.addCourse(key, toPlan: planB.id) }
            guard let plan = userData.plan(id: planB.id) else { return }
            let result = ScheduleGenerator.generate(
                courses: ScheduleCourseInput.inputs(for: plan, index: index),
                filters: plan.filters, preferences: SchedulePreferences(), sort: .best
            )
            var crns = result.schedules.first?.crns ?? []
            // Swap one section for one that overlaps another, and one for a full section.
            if let overlapping = overlappingSwap(of: crns, in: index) {
                crns = overlapping
            }
            if let full = fullSwap(of: crns, in: index) {
                crns = full
            }
            userData.updatePlan(id: planB.id) { $0.selectedCRNs = crns }
        }

        /// Another schedule: `preferred` courses, with the best combination chosen when `choosing`.
        func extra(_ name: String, preferred: [String], count: Int, choosing: Bool, preferences: SchedulePreferences = SchedulePreferences()) {
            let created = userData.createPlan(name: name, termCode: termCode)
            let keys = sampleCourses(preferred: preferred, count: count, in: index, excluding: [])
            for key in keys { userData.addCourse(key, toPlan: created.id) }
            guard choosing, let plan = userData.plan(id: created.id) else { return }
            let result = ScheduleGenerator.generate(
                courses: ScheduleCourseInput.inputs(for: plan, index: index),
                filters: plan.filters, preferences: preferences, sort: .best
            )
            if let best = result.schedules.first {
                userData.updatePlan(id: created.id) { $0.selectedCRNs = best.crns }
            }
        }

        let planA: UUID
        if variant == "second" {
            firstYear()
            planA = secondYear()
        } else {
            planA = secondYear()
            firstYear()
        }
        if variant == "many" {
            var mornings = SchedulePreferences()
            mornings[.earlyMorning] = .prefer
            extra("Light load", preferred: ["CS 2100", "ENGW 1111", "PHIL 1145"], count: 3, choosing: true)
            extra("Mornings only", preferred: ["MATH 1341", "CS 1800", "COMM 1112", "PSYC 1101"], count: 4, choosing: true, preferences: mornings)
            extra("Ideas for spring", preferred: ["CS 3500", "CS 3800"], count: 2, choosing: false)
            _ = userData.createPlan(name: "Backup", termCode: termCode)
        }
        userData.setPrimary(id: planA)
        if variant == "empty", let first = userData.plans.first { userData.setPrimary(id: first.id) }
    }

    /// Courses for a sample schedule: the preferred ones the term offers (with weekly meeting times),
    /// then whichever other courses have the most sections.
    @MainActor
    private static func sampleCourses(preferred: [String], count: Int, in index: CatalogIndex, excluding: [CourseKey] = []) -> [CourseKey] {
        func isUsable(_ key: CourseKey) -> Bool {
            !excluding.contains(key) && index.sections(for: key).contains { !$0.weeklyMeetings.isEmpty && $0.campus == "Boston" }
        }
        var result = preferred.compactMap { CourseKey(string: $0) }.filter(isUsable)
        if result.count < count {
            let fallback = index.courses
                .filter { isUsable($0.key) && !result.contains($0.key) && $0.key.level == 2 }
                .sorted { index.sections(for: $0.key).count > index.sections(for: $1.key).count }
                .map(\.key)
            result.append(contentsOf: fallback.prefix(count - result.count))
        }
        return Array(result.prefix(count))
    }

    /// `crns` with one section replaced by another section of its course that overlaps a section of
    /// another course, if there is one.
    @MainActor
    private static func overlappingSwap(of crns: [String], in index: CatalogIndex) -> [String]? {
        let sections = crns.compactMap { index.section(crn: $0) }
        for section in sections {
            let others = sections.filter { $0.crn != section.crn }
            for alternative in index.sections(for: section.courseKey) where alternative.crn != section.crn {
                if !ScheduleConflicts.sections(overlapping: alternative, in: others.filter { $0.courseKey != section.courseKey }).isEmpty {
                    return crns.map { $0 == section.crn ? alternative.crn : $0 }
                }
            }
        }
        return nil
    }

    /// `crns` with one section replaced by a full section of its course, if there is one.
    @MainActor
    private static func fullSwap(of crns: [String], in index: CatalogIndex) -> [String]? {
        let sections = crns.compactMap { index.section(crn: $0) }
        for section in sections.reversed() {
            if let full = index.sections(for: section.courseKey).first(where: { $0.isFull && !$0.weeklyMeetings.isEmpty }) {
                return crns.map { $0 == section.crn ? full.crn : $0 }
            }
        }
        return nil
    }

    // MARK: Views

    /// Views of this area outside the main window, for `-MacSnapshotView <name>`; nil for names it
    /// doesn't know.
    @MainActor
    static func schedulesSnapshotView(named name: String, catalog: CatalogStore, userData: UserDataStore) -> AnyView? {
        let planA = userData.plans.first
        let index = catalog.readyIndex
        switch name {
        case "scheduleNew":
            return AnyView(MacNewScheduleSheet())
        case "scheduleNewWithCourses":
            return AnyView(MacNewScheduleSheet(startsWithFirstSuggestion: true))
        case "schedulePreferences", "schedulePreferencesFilled", "schedulePreferencesUnavailable":
            guard let plan = planA else { return nil }
            let context = SchedulePreferencesContext(plan: plan, index: index)
            let initial = plan.preferences ?? SchedulePreferences()
            switch name {
            case "schedulePreferencesFilled":
                var filled = initial
                filled.timeOfDay[.morning] = .avoid
                filled.lunch = LunchBreak()
                let assistant = ScheduleAssistantModel(state: .filled(count: 3))
                return AnyView(
                    MacSchedulePreferencesSheet(
                        planID: plan.id, initial: filled, context: context,
                        description: "No classes before 10, I have robotics club Tuesdays and Thursdays 6–8pm and I want a lunch break",
                        filledIn: [.timeOfDay(.morning), .lunch], assistant: assistant
                    )
                    .environment(\.scheduleAssistantAvailability, .available)
                )
            case "schedulePreferencesUnavailable":
                return AnyView(
                    MacSchedulePreferencesSheet(planID: plan.id, initial: initial, context: context)
                        .environment(\.scheduleAssistantAvailability, .notEnabled)
                )
            default:
                return AnyView(
                    MacSchedulePreferencesSheet(planID: plan.id, initial: initial, context: context)
                        .environment(\.scheduleAssistantAvailability, .available)
                )
            }
        case "scheduleRename":
            guard let plan = planA else { return nil }
            return AnyView(MacRenameScheduleSheet(plan: plan) { _ in })
        case "scheduleBlockedTime":
            guard let block = planA?.preferences?.blockedTimes.first else { return nil }
            return AnyView(BlockedTimeEditorPreview(block: block))
        case "scheduleInstructors":
            guard let plan = planA else { return nil }
            return AnyView(InstructorsPreview(context: SchedulePreferencesContext(plan: plan, index: index)))
        case "scheduleFilters":
            guard let plan = planA else { return nil }
            return AnyView(MacScheduleFiltersView(planID: plan.id, campusNames: index?.campusNames ?? [], courseCount: plan.courses.count))
        case "scheduleSectionPicker":
            guard let plan = planA, let key = plan.courses.first?.key else { return nil }
            return AnyView(MacSectionPickerSheet(planID: plan.id, courseKey: key))
        case "scheduleSectionDetails":
            guard let plan = planA, let crn = plan.selectedCRNs.first else { return nil }
            return AnyView(MacSectionDetailsView(planID: plan.id, crn: crn, undoManager: nil) { _ in })
        case "scheduleAddCourse":
            guard let plan = planA else { return nil }
            return AnyView(MacAddCourseView(planID: plan.id))
        case "scheduleExport":
            guard let plan = planA else { return nil }
            return AnyView(MacScheduleExportSheet(planID: plan.id))
        case "scheduleGenerator":
            guard let plan = planA else { return nil }
            return AnyView(MacScheduleView(planID: plan.id, initialMode: .generator).frame(minWidth: 1000, minHeight: 700))
        case "scheduleMinSize":
            guard let plan = planA else { return nil }
            return AnyView(MinSizeProbe(planID: plan.id))
        case "scheduleOverviewPreview":
            guard let plan = planA else { return nil }
            return AnyView(MacSchedulePreview(plan: plan, index: index).frame(width: 380, height: 760))
        case "scheduleCalendar":
            guard let plan = planA, let index else { return nil }
            return AnyView(CalendarPreview(plan: plan, index: index).frame(width: 760, height: 620))
        case "scheduleNoResults":
            guard let plan = planA, let index else { return nil }
            return AnyView(NoResultsPreview(plan: plan, index: index).frame(width: 760, height: 900))
        default:
            return nil
        }
    }
}

// MARK: - Window sizes

/// Measures the smallest size each screen of this area asks the window for: hosts it in a window of
/// its own off screen, waits for it to load, and prints the window's `contentMinSize` (without the
/// sidebar's 230 points). A screen whose minimum is too big for a half-width window shows up here.
private struct MinSizeProbe: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(MacNavigator.self) private var navigator
    @State private var report = "Measuring…"

    var body: some View {
        Text(report)
            .font(.system(.body, design: .monospaced))
            .padding()
            .frame(width: 560, alignment: .leading)
            .task { await measure() }
    }

    @MainActor
    private func measure() async {
        let screens: [(name: String, view: AnyView)] = [
            ("schedule", AnyView(MacScheduleView(planID: planID))),
            ("generator", AnyView(MacScheduleView(planID: planID, initialMode: .generator))),
            ("overview", AnyView(MacSchedulesOverview())),
        ]
        var lines: [String] = []
        for screen in screens {
            let content = screen.view.macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1400, height: 900))
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.ignoresMouseEvents = true
            window.orderFront(nil)
            try? await Task.sleep(for: .seconds(6))
            let size = window.contentMinSize
            lines.append("\(screen.name): \(Int(size.width)) x \(Int(size.height))")
            window.orderOut(nil)
        }
        report = lines.joined(separator: "\n")
        print("MinSizeProbe (detail only, add 230 for the sidebar):\n" + report)
    }
}

// MARK: - Previews of single views

/// The blocked time editor with a binding of its own.
private struct BlockedTimeEditorPreview: View {
    @State var block: BlockedTime

    var body: some View {
        MacBlockedTimeEditor(block: $block, days: [1, 2, 3, 4, 5]) {}
    }
}

private struct InstructorsPreview: View {
    var context: SchedulePreferencesContext
    @State private var preferred: [String] = []
    @State private var avoided: [String] = []

    var body: some View {
        MacInstructorPreferences(
            preferred: $preferred, avoided: $avoided,
            instructors: context.instructors
        )
        .onAppear {
            preferred = context.instructors.first.map { [$0.name] } ?? []
            avoided = context.instructors.dropFirst().first.map { [$0.name] } ?? []
        }
    }
}

private struct CalendarPreview: View {
    var plan: SchedulePlan
    var index: CatalogIndex

    var body: some View {
        let resolved = ResolvedPlan(plan: plan, index: index)
        MacWeekCalendar(
            events: resolved.events,
            days: [1, 2, 3, 4, 5],
            hours: MacCalendarRange.hours(for: resolved.events, preferences: AppPreferences())
        )
    }
}

/// The "no schedules fit" help for a schedule whose courses can't be combined, with a degree plan
/// suggestion to move one of them.
private struct NoResultsPreview: View {
    var plan: SchedulePlan
    var index: CatalogIndex

    @State private var noResults: ScheduleNoResults?
    @State private var diagnostics: ScheduleDiagnostics?

    var body: some View {
        Group {
            if let diagnostics {
                MacScheduleNoResultsView(
                    diagnostics: diagnostics,
                    noResults: noResults,
                    termName: index.term.name,
                    reorder: .ready(ScheduleReorderResult(options: [
                        ScheduleReorderOption(
                            id: "move",
                            title: "Move \(plan.courses.first?.key.description ?? "CS 3000") to Spring 2027",
                            reasons: ["Offered every spring", "Prerequisites still met"],
                            addsSemester: false,
                            movedAway: plan.courses.first.map { [$0.key] } ?? [],
                            movedIn: [],
                            apply: { _ in }
                        ),
                    ])),
                    onApply: { _ in },
                    onMakeOptional: { _ in },
                    onApplyReorder: { _ in }
                )
            } else {
                ProgressView()
            }
        }
        .task {
            // Nothing meets this early, so every section is ruled out.
            var filters = ScheduleFilters()
            filters.earliestStart = 20 * 60
            let courses = ScheduleCourseInput.inputs(for: plan, index: index)
            let result = ScheduleGenerator.generate(courses: courses, filters: filters, preferences: SchedulePreferences(), sort: .best)
            diagnostics = result.diagnostics
            noResults = ScheduleGenerator.analyzeEmptyResult(
                courses: courses, filters: filters, preferences: SchedulePreferences(),
                diagnostics: result.diagnostics, includeBlockers: true
            )
        }
    }
}
#endif
