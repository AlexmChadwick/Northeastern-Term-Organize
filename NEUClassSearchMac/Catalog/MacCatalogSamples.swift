//
//  MacCatalogSamples.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

#if DEBUG
import SwiftUI

extension MacSampleData {
    /// Sample data for snapshots: saved and recently viewed courses, and recent searches.
    @MainActor
    static func seedCatalog(userData: UserDataStore, catalog: CatalogStore) {
        guard let index = catalog.readyIndex else { return }
        let termCode = index.term.code
        let keys = MacCatalogSampleCourses.keys(in: index)

        // Saved: the first few, newest last so the list reads in the order of `keys`. (Plus a course the
        // term no longer lists, which the saved list keeps so that it can be cleaned out.)
        let retired = CourseKey(subject: "CS", number: "2510")
        if index.course(retired) == nil {
            userData.toggleSaved(retired, termCode: termCode)
        }
        for key in keys.prefix(5).reversed() {
            userData.toggleSaved(key, termCode: termCode)
        }
        // Viewed lately: the next few, the most recent first.
        for key in keys.dropFirst(3).prefix(6).reversed() {
            userData.recordView(key, termCode: termCode)
        }
        for term in ["Khoury", "machine learning", "12345", "calculus", "CS 3000"].reversed() {
            userData.recordSearch(term)
        }
    }

    /// Views of this area outside the main window, for `-MacSnapshotView <name>`; nil for names
    /// it doesn't know.
    ///
    /// - `course:CS2500`: the course window.
    /// - `professor:<Last, First>`, `professor:top` or `professor:of:CS2500`: the professor window.
    /// - `compare:CS2500`: the "Compare Times" popover of a course.
    /// - `sectiondetails:CS2500`: the details under the sections table, for the first section.
    /// - `filters` / `subjectpicker`: the popovers of the search filters.
    @MainActor
    static func catalogSnapshotView(named name: String, catalog: CatalogStore, userData: UserDataStore) -> AnyView? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let termCode = catalog.selectedTermCode ?? ""
        let state = MacCatalogState.shared
        // Views drawn on their own have no window toolbar to host the items of a window's toolbar.
        MacCatalogSnapshotArguments.drawsWithoutToolbar = true
        switch parts[0] {
        case "course":
            guard let key = CourseKey(string: argument) else { return nil }
            return AnyView(MacCourseWindow(value: CourseWindowValue(termCode: termCode, key: key)).frame(idealWidth: 760, idealHeight: 820))
        case "professor":
            guard let index = catalog.readyIndex, let instructor = MacCatalogSampleCourses.instructor(argument, in: index) else { return nil }
            return AnyView(MacProfessorWindow(value: ProfessorWindowValue(termCode: termCode, name: instructor.name)).frame(idealWidth: 760, idealHeight: 700))
        case "overview":
            guard let index = catalog.readyIndex, let key = CourseKey(string: argument), let course = index.course(key) else { return nil }
            return AnyView(
                ScrollView {
                    MacCourseOverviewSample(course: course, index: index, termCode: termCode)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(idealWidth: 760, idealHeight: 560)
            )
        case "sections":
            guard let index = catalog.readyIndex, let key = CourseKey(string: argument), let course = index.course(key) else { return nil }
            return AnyView(MacCourseSectionsSample(course: course, index: index, termCode: termCode).frame(idealWidth: 760, idealHeight: 460))
        case "compare":
            guard let index = catalog.readyIndex, let key = CourseKey(string: argument) else { return nil }
            return AnyView(MacCourseSectionCompareView(sections: index.sections(for: key)) { _ in })
        case "sectiondetails":
            guard let index = catalog.readyIndex, let key = CourseKey(string: argument),
                  let course = index.course(key), let section = index.sections(for: key).first else { return nil }
            return AnyView(MacCourseSectionDetails(section: section, course: course, termCode: termCode, isLoadingDetails: false).frame(idealWidth: 760))
        case "filters":
            guard let index = catalog.readyIndex else { return nil }
            return AnyView(MacSearchFiltersForm(state: state, index: index))
        case "subjectpicker":
            guard let index = catalog.readyIndex else { return nil }
            return AnyView(MacSubjectPicker(state: state, index: index))
        default:
            return nil
        }
    }
}

/// The overview half of the course window on its own, for `-MacSnapshotView overview:CS3000`.
private struct MacCourseOverviewSample: View {
    var course: Course
    var index: CatalogIndex
    var termCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            MacCourseHeader(course: course, term: index.term, hasHonorsSections: index.stats(for: course.key).hasHonors)
            MacCourseDescription(course: course, status: course.detailsLoaded ? .ready : .unavailable, onRetry: {})
            MacCourseRequirements(
                key: course.key,
                prereqs: course.prereqs,
                coreqs: course.coreqs,
                postreqs: course.postreqs,
                index: index,
                termCode: termCode,
                status: course.detailsLoaded ? .ready : .unavailable,
                onRetry: {}
            )
        }
    }
}

/// The sections half of the course window on its own, for `-MacSnapshotView sections:CS3000`.
private struct MacCourseSectionsSample: View {
    var course: Course
    var index: CatalogIndex
    var termCode: String

    @State private var selection: Set<String> = []
    @State private var newSchedule: MacCatalogNewScheduleRequest?

    var body: some View {
        MacCourseSectionsPane(
            course: course,
            sections: index.sections(for: course.key),
            termCode: termCode,
            isLoadingDetails: false,
            lastUpdated: index.catalog.sectionsUpdatedAt,
            isRefreshing: false,
            refreshFailed: false,
            onRefresh: {},
            selection: $selection,
            newSchedule: $newSchedule
        )
        .onAppear {
            if let first = index.sections(for: course.key).first { selection = [first.crn] }
        }
    }
}

/// Choosing real courses and instructors from the loaded catalog for the sample data and snapshot views.
enum MacCatalogSampleCourses {
    /// Well-known courses that have sections, topped up with whatever the catalog lists first.
    @MainActor
    static func keys(in index: CatalogIndex) -> [CourseKey] {
        let preferred = ["CS 2500", "CS 3000", "MATH 1341", "ENGW 1111", "PHYS 1151", "CS 4100", "DS 2000", "CS 1800", "BIOL 1111"]
            .compactMap { CourseKey(string: $0) }
            .filter { index.course($0) != nil && index.stats(for: $0).sectionCount > 0 }
        let rest = index.courses
            .filter { index.stats(for: $0.key).sectionCount > 0 && !preferred.contains($0.key) }
            .prefix(12)
            .map(\.key)
        return preferred + rest
    }

    /// `top` (who teaches the most courses), `of:CS2500` (that course's first instructor) or a Banner
    /// name (`Last, First`).
    @MainActor
    static func instructor(_ argument: String, in index: CatalogIndex) -> InstructorSummary? {
        if argument == "top" || argument.isEmpty {
            return index.instructors.max { $0.courseKeys.count < $1.courseKeys.count }
        }
        if argument.hasPrefix("of:"), let key = CourseKey(string: String(argument.dropFirst(3))) {
            return index.macCatalogInstructors(key).first.flatMap { index.instructor(named: $0.name) }
        }
        return index.instructor(named: argument)
    }
}

/// Launch arguments of the main-window screens, so a snapshot can show results and selections:
///
///     -MacSnapshotSearch "cs 3000"
///     -MacSnapshotFilters "openSeats,nupath:FQ,subject:CS,level:2,campus:Boston,days:noFridays,minCredits:4"
///     -MacSnapshotSubject CS    -MacSnapshotNUPath FQ    -MacSnapshotProfessorQuery smith
///     -MacSnapshotSelectFirst YES (search, saved)    -mac.catalog.previewChoice 1 or 2 (the preview pane shown or hidden; 0 follows the window)
///
/// Only read when the run is a snapshot (`MacSnapshot.isRequested`).
enum MacCatalogSnapshotArguments {
    /// Set by the standalone snapshot views (`course:`, `professor:`), which are drawn outside a window.
    @MainActor static var drawsWithoutToolbar = false

    @MainActor
    static func applyToSearch(navigator: MacNavigator, state: MacCatalogState, selectFirst: () -> Void) {
        guard MacSnapshot.isRequested else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "MacSnapshotSelectFirst") { selectFirst() }
        if let text = defaults.string(forKey: "MacSnapshotSearch") {
            navigator.searchText = text
            state.userBroughtOwnSearch = true
        }
        if let spec = defaults.string(forKey: "MacSnapshotFilters") {
            state.filters = filters(from: spec)
            state.userBroughtOwnSearch = true
        }
    }

    /// `-MacSnapshotCourseWindow CS3000` or `-MacSnapshotProfessorWindow "Last, First"` show that window's
    /// content in the main window, where its toolbar is drawn (a standalone hosting view has none).
    @MainActor
    static func windowInMainWindow(termCode: String?) -> AnyView? {
        guard MacSnapshot.isRequested, let termCode else { return nil }
        let defaults = UserDefaults.standard
        if let spec = defaults.string(forKey: "MacSnapshotCourseWindow"), let key = CourseKey(string: spec) {
            return AnyView(MacCourseWindow(value: CourseWindowValue(termCode: termCode, key: key)))
        }
        if let name = defaults.string(forKey: "MacSnapshotProfessorWindow") {
            return AnyView(MacProfessorWindow(value: ProfessorWindowValue(termCode: termCode, name: name)))
        }
        return nil
    }

    /// `-MacSnapshotSelectFirst YES` selects the first saved course; `-MacSnapshotSelectKey CS2510` that one.
    @MainActor
    static func applyToSaved(select: (CourseKey) -> Void, termCode: String, userData: UserDataStore) {
        guard MacSnapshot.isRequested else { return }
        let defaults = UserDefaults.standard
        if let spec = defaults.string(forKey: "MacSnapshotSelectKey"), let key = CourseKey(string: spec) {
            select(key)
        } else if defaults.bool(forKey: "MacSnapshotSelectFirst"), let first = userData.savedCourses(in: termCode).first {
            select(first.key)
        }
    }

    @MainActor
    static func applyToSubjects(state: MacCatalogState) {
        guard MacSnapshot.isRequested else { return }
        let defaults = UserDefaults.standard
        if let code = defaults.string(forKey: "MacSnapshotSubject") {
            state.subjectsMode = .subjects
            state.selectedSubject = code
        }
        if let short = defaults.string(forKey: "MacSnapshotNUPath"), let nupath = NUPath.from(short: short) {
            state.subjectsMode = .nupath
            state.selectedNUPath = nupath
        }
    }

    @MainActor
    static func applyToProfessors(query: Binding<String>) {
        guard MacSnapshot.isRequested, let text = UserDefaults.standard.string(forKey: "MacSnapshotProfessorQuery") else { return }
        query.wrappedValue = text
    }

    /// Parses `openSeats,honors,noPrerequisites,noCorequisites,online,nupath:FQ,subject:CS,level:2,campus:Boston,days:noFridays,minCredits:4`.
    static func filters(from spec: String) -> SearchFilters {
        var filters = SearchFilters()
        for token in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let pair = token.split(separator: ":", maxSplits: 1).map(String.init)
            let value = pair.count > 1 ? pair[1] : ""
            switch pair[0] {
            case "openSeats": filters.openSeatsOnly = true
            case "honors": filters.honorsOnly = true
            case "noPrerequisites": filters.noPrerequisites = true
            case "noCorequisites": filters.noCorequisites = true
            case "online": filters.instruction = .online
            case "inPerson": filters.instruction = .inPerson
            case "nupath": if let nupath = NUPath.from(short: value) { filters.nupaths.insert(nupath) }
            case "subject": filters.subjects.insert(value.uppercased())
            case "level": if let level = Int(value) { filters.levels.insert(level) }
            case "campus": filters.campuses.insert(value)
            case "days": filters.allowedDays = SearchDayPreset(rawValue: value)?.days
            case "minCredits": filters.minCredits = Double(value)
            case "maxCredits": filters.maxCredits = Double(value)
            default: break
            }
        }
        return filters
    }
}
#endif
