//
//  DegreePlanCatalog.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Catalog snapshot

/// What the degree plan screens read from the catalog: every Northeastern semester
/// index that is loaded (newest first), plus Banner's list of terms. Built from the
/// observable `CatalogStore`, so views that create one update as catalogs load.
struct DegreePlanCatalogSnapshot {
    /// Loaded indexes of Northeastern semester terms, newest first.
    var indexes: [CatalogIndex] = []
    /// Banner's terms, newest first.
    var terms: [Term] = []
    var selectedTermCode: String?

    /// The newest index on hand — used for titles and prerequisite checks.
    var reference: CatalogIndex? { indexes.first }

    var hasData: Bool { !indexes.isEmpty }

    func index(for termCode: String) -> CatalogIndex? {
        indexes.first { $0.term.code == termCode }
    }

    /// The newest loaded index that lists the course with its requisites (courses synced
    /// without details have none), else the newest that lists it at all.
    func index(containing key: CourseKey) -> CatalogIndex? {
        indexes.first { $0.course(key)?.detailsLoaded == true } ?? indexes.first { $0.course(key) != nil }
    }

    func course(_ key: CourseKey) -> Course? {
        for index in indexes {
            if let course = index.course(key) { return course }
        }
        return nil
    }

    /// The title to show for a plan entry: the catalog's, else the plan's own.
    func title(for course: DegreePlanCourse) -> String {
        if let key = course.key, let title = self.course(key)?.title, !title.isEmpty { return title }
        return course.title
    }

    /// The Northeastern term on Banner that is this semester, if it has been posted.
    func bannerTerm(for semester: DegreePlanTerm) -> Term? {
        let matches = terms.filter { $0.college == .neu && semester.matches($0) }
        // Summer sessions also match the combined summer term; prefer the exact one.
        return matches.first { PlanSeason(termSeason: $0.season) == semester.season } ?? matches.first
    }

    /// The term whose course page should open for a course: the semester's own term when
    /// its catalog is on the device, else the selected term, else the newest catalog that
    /// has the course.
    func routeTermCode(for key: CourseKey, in semester: DegreePlanTerm? = nil) -> String? {
        if let semester, let term = bannerTerm(for: semester), index(for: term.code)?.course(key) != nil {
            return term.code
        }
        if let selectedTermCode, index(for: selectedTermCode)?.course(key) != nil {
            return selectedTermCode
        }
        if let index = index(containing: key) {
            return index.term.code
        }
        return selectedTermCode ?? indexes.first?.term.code
    }

    /// Why a semester can't have a schedule built yet, or nil when it can.
    func scheduleUnavailableReason(for semester: DegreePlanTerm) -> String? {
        if terms.isEmpty { return "Banner’s term list hasn’t loaded yet" }
        if bannerTerm(for: semester) == nil {
            return semester.degreePlanHasEnded() ? "\(semester.name) is over" : "\(semester.name) isn’t on Banner yet"
        }
        return nil
    }
}

extension CatalogStore {
    /// The loaded catalogs the degree plan screens can read, newest first.
    func degreePlanSnapshot() -> DegreePlanCatalogSnapshot {
        var seen = Set<String>()
        var indexes: [CatalogIndex] = []
        func add(_ index: CatalogIndex?) {
            guard let index, index.term.college == .neu, seen.insert(index.term.code).inserted else { return }
            indexes.append(index)
        }
        add(readyIndex)
        for term in terms { add(cachedIndex(for: term.code)) }
        indexes.sort { $0.term.code > $1.term.code }
        return DegreePlanCatalogSnapshot(indexes: indexes, terms: terms, selectedTermCode: selectedTermCode)
    }

    /// Loads from disk the catalogs a degree plan reads, when they aren't loaded yet: the
    /// newest Northeastern term on the device (titles and prerequisites), and the terms
    /// of the plan's semesters that are on the device (course pages for those semesters).
    func degreePlanLoadLocalCatalogs(for plan: DegreePlan?) async {
        if degreePlanSnapshot().reference == nil, loadState != .loading {
            for term in terms where term.college == .neu {
                if await hasLocalCatalog(term.code) {
                    _ = await index(for: term.code)
                    break
                }
            }
        }
        guard let plan else { return }
        for semester in plan.terms.prefix(8) {
            guard let term = degreePlanSnapshot().bannerTerm(for: semester), cachedIndex(for: term.code) == nil else { continue }
            if await hasLocalCatalog(term.code) {
                _ = await index(for: term.code)
            }
        }
    }
}

// MARK: - Review

/// Why a planned course's prerequisites weren't checked.
enum DegreePlanUncheckedReason: Hashable, Sendable {
    /// Banner's course catalog is being searched for the course.
    case checking
    /// The search failed (offline, Banner busy); it can be tried again.
    case failed
    /// No recent catalog lists the course.
    case notFound
    /// Nothing was looked up.
    case notChecked
}

/// Prerequisite checks and duplicate flags for every course in a plan.
struct DegreePlanReview {
    private(set) var statuses: [UUID: DegreePlanAnalysis.PrerequisiteStatus] = [:]
    private(set) var notes: [UUID: String] = [:]
    /// Why each planned course whose status is `.unknown` wasn't checked.
    private(set) var uncheckedReasons: [UUID: DegreePlanUncheckedReason] = [:]
    /// Planned courses the catalog no longer lists: `No longer offered; last listed Spring 2025`.
    private(set) var offeringNotes: [UUID: String] = [:]
    /// Planned courses that are no longer offered.
    var retiredCount: Int { offeringNotes.count }
    /// Planned courses whose prerequisites aren't covered by earlier semesters.
    private(set) var missingCount = 0
    /// Planned courses whose prerequisites couldn't be checked; some of them may still be
    /// `checkingCount`, or have `failedCount`.
    private(set) var uncheckedCount = 0
    private(set) var checkingCount = 0
    private(set) var failedCount = 0
    /// Distinct courses that appear more than once in the plan (planned twice, or planned
    /// and already completed).
    private(set) var duplicateCount = 0
    private(set) var plannedCourseCount = 0
    /// Whether any catalog was available to check against: one on the device, or Banner's
    /// course catalog through `lookup`.
    let hasCatalog: Bool

    /// - Parameters:
    ///   - lookup: prerequisites of courses the loaded catalogs don't list
    ///     (`CourseInfoStore.requisiteLookup()`).
    ///   - equivalences: which courses count as which (`CourseInfoStore.equivalences(for:)`).
    ///   - lookupStates: where each course's lookup stands, to say why a course wasn't checked.
    init(
        plan: DegreePlan,
        catalog: DegreePlanCatalogSnapshot,
        lookup: ((CourseKey) -> Requisite??)? = nil,
        equivalences: CourseEquivalences = .none,
        lookupStates: [CourseKey: CourseInfoStore.LookupState] = [:]
    ) {
        hasCatalog = catalog.hasData || lookup != nil
        let duplicates = DegreePlanAnalysis.duplicateKeys(in: plan)
        let completed = plan.completedKeys
        var flagged = Set<CourseKey>()

        for (position, term) in plan.terms.enumerated() {
            for course in term.courses {
                plannedCourseCount += 1
                guard let key = course.key else { continue }
                // A course the loaded catalogs don't list, or list without its details, is
                // answered by `lookup`; without an answer the status is `.unknown`.
                let status = DegreePlanAnalysis.prerequisiteStatus(
                    of: key,
                    termIndex: position,
                    in: plan,
                    catalog: catalog.index(containing: key) ?? catalog.reference,
                    lookup: lookup,
                    equivalences: equivalences
                )
                statuses[course.id] = status
                if status.isMissing { missingCount += 1 }
                if status == .unknown {
                    let reason = Self.reason(for: lookupStates[key], hasLookup: lookup != nil)
                    uncheckedReasons[course.id] = reason
                    uncheckedCount += 1
                    if reason == .checking { checkingCount += 1 }
                    if reason == .failed { failedCount += 1 }
                }
                if let retired = lookupStates[key]?.degreeRetiredNote {
                    offeringNotes[course.id] = retired
                }

                guard duplicates.contains(key) else { continue }
                flagged.insert(key)
                if completed.contains(key) {
                    notes[course.id] = "Already in your completed courses. Each copy still counts."
                } else {
                    let others = plan.terms.filter { $0.id != term.id && $0.courses.contains { $0.key == key } }
                    notes[course.id] = others.isEmpty
                        ? "Listed more than once in \(term.name). Each copy still counts."
                        : "Also planned in \(others.map(\.name).joined(separator: ", ")). Each copy still counts."
                }
            }
        }

        duplicateCount = flagged.count

        for course in plan.completed {
            guard let key = course.key, duplicates.contains(key) else { continue }
            let planned = plan.terms.filter { $0.courses.contains { $0.key == key } }
            if !planned.isEmpty {
                notes[course.id] = "Also planned in \(planned.map(\.name).joined(separator: ", ")). Each copy still counts."
            }
        }
    }

    private static func reason(for state: CourseInfoStore.LookupState?, hasLookup: Bool) -> DegreePlanUncheckedReason {
        guard hasLookup else { return .notChecked }
        switch state {
        case .failed: return .failed
        case .notFound: return .notFound
        // Not asked yet (the screen asks as it appears), or the answer is on its way.
        case .unknown, .loading, .found, nil: return .checking
        }
    }

    func status(for course: DegreePlanCourse) -> DegreePlanAnalysis.PrerequisiteStatus? { statuses[course.id] }

    func note(for course: DegreePlanCourse) -> String? { notes[course.id] }

    func uncheckedReason(for course: DegreePlanCourse) -> DegreePlanUncheckedReason? { uncheckedReasons[course.id] }

    func offeringNote(for course: DegreePlanCourse) -> String? { offeringNotes[course.id] }
}

extension CourseInfoStore {
    /// A plan's review with everything Banner's course catalog has said so far: prerequisites
    /// of courses the loaded catalogs don't list, equivalences, and where lookups stand.
    func degreePlanReview(for plan: DegreePlan, catalog: DegreePlanCatalogSnapshot) -> DegreePlanReview {
        DegreePlanReview(
            plan: plan,
            catalog: catalog,
            lookup: requisiteLookup(),
            equivalences: equivalences(for: plan),
            lookupStates: degreeLookupStates(for: plan.degreePlanPlannedKeys)
        )
    }
}
