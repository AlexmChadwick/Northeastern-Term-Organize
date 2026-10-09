//
//  AppRouter.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import Observation

/// Every pushable destination in the app. Push with
/// `NavigationLink(value: AppRoute.course(...))` or `router.navigate(to:)`.
enum AppRoute: Hashable {
    case course(termCode: String, key: CourseKey)
    case section(termCode: String, crn: String)
    case professor(termCode: String, name: String)
    case professorsDirectory(termCode: String)
    case subject(termCode: String, code: String)
    case subjectsDirectory(termCode: String)
    case nupath(termCode: String, nupath: NUPath)
    case nupathDirectory(termCode: String)
    case savedCourses(termCode: String)
    case building(termCode: String, code: String)
    case room(termCode: String, buildingCode: String, room: String)
    case plan(id: UUID)
    /// The schedule generator for a plan.
    case planGenerator(id: UUID)
    /// A multi-semester degree plan.
    case degreePlan(id: UUID)
    /// A degree plan checked against its program's catalog requirements.
    case degreeRequirements(planID: UUID)
}

/// A degree audit plan file that was picked or opened and is ready to review.
struct DegreePlanImportRequest: Identifiable {
    let id = UUID()
    var fileName: String
    var result: Result<DegreePlanFormat.ParseResult, Error>
}

/// A request to add a course (optionally a specific section) to a schedule plan.
struct AddToPlanRequest: Identifiable, Hashable {
    var termCode: String
    var key: CourseKey
    var crn: String?
    var id: String { "\(termCode)|\(key)|\(crn ?? "")" }
}

@MainActor
@Observable
final class AppRouter {
    enum Tab: String, Hashable, CaseIterable {
        case catalog, schedule, watchlist, rooms, search
    }

    var selectedTab: Tab = .catalog
    var catalogPath: [AppRoute] = []
    var schedulePath: [AppRoute] = []
    var watchlistPath: [AppRoute] = []
    var roomsPath: [AppRoute] = []
    var searchPath: [AppRoute] = []

    /// Presents the "Add to Schedule" sheet.
    var addToPlanRequest: AddToPlanRequest?
    var isSettingsPresented = false
    var isOnboardingPresented = false
    /// Text to pre-fill in search when switching to the search tab.
    var pendingSearchText: String?
    /// Shows the file picker for importing a degree audit plan (PDF).
    var isDegreePlanImporterPresented = false
    /// A parsed (or failed) import awaiting review in `DegreePlanImportSheet`.
    var degreePlanImport: DegreePlanImportRequest?
    /// Shows the "New Degree Plan" sheet.
    var isNewDegreePlanPresented = false

    func path(for tab: Tab) -> [AppRoute] {
        switch tab {
        case .catalog: catalogPath
        case .schedule: schedulePath
        case .watchlist: watchlistPath
        case .rooms: roomsPath
        case .search: searchPath
        }
    }

    func setPath(_ path: [AppRoute], for tab: Tab) {
        switch tab {
        case .catalog: catalogPath = path
        case .schedule: schedulePath = path
        case .watchlist: watchlistPath = path
        case .rooms: roomsPath = path
        case .search: searchPath = path
        }
    }

    /// Pushes a route onto the current tab's stack.
    func navigate(to route: AppRoute) {
        setPath(path(for: selectedTab) + [route], for: selectedTab)
    }

    /// Switches tabs and pushes a route there.
    func show(_ route: AppRoute, in tab: Tab) {
        selectedTab = tab
        setPath(path(for: tab) + [route], for: tab)
    }

    func popToRoot(_ tab: Tab? = nil) {
        setPath([], for: tab ?? selectedTab)
    }

    func addToSchedule(termCode: String, key: CourseKey, crn: String? = nil) {
        addToPlanRequest = AddToPlanRequest(termCode: termCode, key: key, crn: crn)
    }

    func search(for text: String) {
        pendingSearchText = text
        selectedTab = .search
    }

    /// Reads a degree audit plan file (off the main actor) and presents the review sheet.
    func importDegreePlan(from url: URL) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<DegreePlanFormat.ParseResult, Error> in
                defer {
                    // Files opened from other apps are copied into Documents/Inbox; don't keep them.
                    if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                }
                return Result { try DegreePlanImporter.importPlan(from: url) }
            }.value
            degreePlanImport = DegreePlanImportRequest(fileName: url.lastPathComponent, result: result)
        }
    }

    /// Handles `termorganize://course/202710/CS/3000`, `termorganize://section/202710/12345`,
    /// `termorganize://plan/<uuid>`, `termorganize://degree-plan/<uuid>[/requirements]`,
    /// `termorganize://schedule` (and the same under the old `neuclasssearch://`), and files
    /// opened with the app (degree audit plan PDFs).
    func handle(url: URL) {
        if url.isFileURL {
            importDegreePlan(from: url)
            return
        }
        guard AppLink.isAppLink(url) else { return }
        let parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "course" where parts.count >= 4:
            show(.course(termCode: parts[1], key: CourseKey(subject: parts[2].uppercased(), number: parts[3].uppercased())), in: .catalog)
        case "section" where parts.count >= 3:
            show(.section(termCode: parts[1], crn: parts[2]), in: .catalog)
        case "plan" where parts.count >= 2:
            if let id = UUID(uuidString: parts[1]) { show(.plan(id: id), in: .schedule) }
        case "degree-plan" where parts.count >= 2:
            if let id = UUID(uuidString: parts[1]) {
                show(parts.count >= 3 && parts[2] == "requirements" ? .degreeRequirements(planID: id) : .degreePlan(id: id), in: .schedule)
            }
        case "schedule":
            selectedTab = .schedule
        case "watchlist":
            selectedTab = .watchlist
        case "search":
            search(for: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? "")
        default:
            break
        }
    }
}

extension View {
    /// Registers destinations for `AppRoute` values. Apply inside each NavigationStack.
    func appDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppDestination(route: route)
        }
    }
}

/// Maps routes to feature screens.
struct AppDestination: View {
    var route: AppRoute

    var body: some View {
        switch route {
        case .course(let termCode, let key):
            CourseDetailView(termCode: termCode, key: key)
        case .section(let termCode, let crn):
            SectionDetailView(termCode: termCode, crn: crn)
        case .professor(let termCode, let name):
            ProfessorView(termCode: termCode, name: name)
        case .professorsDirectory(let termCode):
            ProfessorsDirectoryView(termCode: termCode)
        case .subject(let termCode, let code):
            SubjectCoursesView(termCode: termCode, subjectCode: code)
        case .subjectsDirectory(let termCode):
            SubjectsDirectoryView(termCode: termCode)
        case .nupath(let termCode, let nupath):
            NUPathCoursesView(termCode: termCode, nupath: nupath)
        case .nupathDirectory(let termCode):
            NUPathDirectoryView(termCode: termCode)
        case .savedCourses(let termCode):
            SavedCoursesView(termCode: termCode)
        case .building(let termCode, let code):
            BuildingView(termCode: termCode, buildingCode: code)
        case .room(let termCode, let buildingCode, let room):
            RoomView(termCode: termCode, buildingCode: buildingCode, room: room)
        case .plan(let id):
            PlanDetailView(planID: id)
        case .planGenerator(let id):
            ScheduleGeneratorRouteView(planID: id)
        case .degreePlan(let id):
            DegreePlanView(planID: id)
        case .degreeRequirements(let planID):
            DegreeRequirementsView(planID: planID)
        }
    }
}
