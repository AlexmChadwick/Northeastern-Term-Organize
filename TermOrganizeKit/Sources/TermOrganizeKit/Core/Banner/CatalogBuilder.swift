//
//  CatalogBuilder.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), packages/scraper/src/generate/marshall.ts,
//  Copyright (C) Sandbox at Northeastern University and the SearchNEU contributors,
//  licensed under the GNU Affero General Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift and extended with
//  merge logic used for on-device refreshes.
//

import Foundation

enum CatalogBuilder {
    /// Converts raw Banner sections into app sections, resolving cross-lists.
    /// Seat counts use cross-list totals when present, as SearchNEU does.
    static func makeSections(from banner: [BannerSection], previous: [String: CourseSection] = [:]) -> [CourseSection] {
        var crossLists: [String: [String]] = [:]
        for s in banner {
            if let x = s.crossList?.nilIfBlank { crossLists[x, default: []].append(s.courseReferenceNumber) }
        }

        return banner.map { s in
            let attributes = (s.sectionAttributes ?? []).map(\.code)
            let honors = (s.sectionAttributes ?? []).contains {
                $0.code == honorsAttributeCode || $0.description?.trimmingCharacters(in: .whitespaces) == "Honors"
            }
            let meetings = (s.meetingsFaculty ?? []).compactMap { $0.meetingTime?.toMeeting() }
            let bannerInstructors = (s.meetingsFaculty ?? []).flatMap { $0.faculty ?? [] }.compactMap { $0.toInstructor() }
            let prior = previous[s.courseReferenceNumber]
            let crossList = s.crossList?.nilIfBlank.flatMap { crossLists[$0] }?.filter { $0 != s.courseReferenceNumber } ?? []

            return CourseSection(
                crn: s.courseReferenceNumber,
                subject: s.subject,
                number: s.courseNumber,
                title: HTMLText.decodeEntities(HTMLText.decodeEntities(s.courseTitle ?? "")),
                sectionNumber: s.sequenceNumber ?? "",
                partOfTerm: s.partOfTerm ?? "1",
                seatCapacity: s.crossListCapacity ?? s.maximumEnrollment ?? 0,
                seatsRemaining: s.crossListAvailable ?? s.seatsAvailable ?? 0,
                enrollment: s.crossListCount ?? s.enrollment ?? 0,
                waitlistCapacity: s.waitCapacity ?? 0,
                waitlistCount: s.waitCount ?? 0,
                waitlistRemaining: s.waitAvailable ?? 0,
                classType: HTMLText.decodeEntities(s.scheduleTypeDescription ?? "Lecture"),
                honors: honors,
                campus: HTMLText.decodeEntities(s.campusDescription ?? ""),
                instructionMethod: s.instructionalMethodDescription.map(HTMLText.decodeEntities),
                meetings: meetings,
                // Banner's search results currently hide faculty; keep what we knew.
                instructors: bannerInstructors.isEmpty ? prior?.instructors : bannerInstructors,
                crossListCRNs: crossList,
                attributes: attributes,
                description: prior?.description,
                prereqs: prior?.prereqs,
                coreqs: prior?.coreqs
            )
        }
    }

    /// Builds course stubs from sections (port of SearchNEU's `arrangeCourses`).
    /// Courses whose title contains "Special Topics" or that carry the `TOPC`
    /// attribute are marked as special topics.
    static func stubCourses(from banner: [BannerSection]) -> (courses: [Course], attributes: [AttributeInfo]) {
        var courses: [CourseKey: Course] = [:]
        var order: [CourseKey] = []
        var attributes: [String: String] = [:]

        for s in banner {
            let key = CourseKey(subject: s.subject, number: s.courseNumber)
            let title = HTMLText.decodeEntities(HTMLText.decodeEntities(s.courseTitle ?? ""))
            let sectionAttributes = s.sectionAttributes ?? []
            for a in sectionAttributes {
                attributes[a.code] = HTMLText.decodeEntities(a.description ?? a.code).trimmingCharacters(in: .whitespaces)
            }
            let isTopics = sectionAttributes.contains { $0.code == "TOPC" }

            if var existing = courses[key] {
                let codes = Set(existing.attributes).union(sectionAttributes.map(\.code).filter { $0 != honorsAttributeCode })
                existing.attributes = codes.sorted()
                if !existing.specialTopics, isTopics {
                    existing.specialTopics = true
                    existing.title = "Special Topics"
                }
                courses[key] = existing
            } else {
                let special = title.localizedCaseInsensitiveContains("Special Topics") || isTopics
                let low = s.creditHourLow ?? s.creditHours ?? 0
                courses[key] = Course(
                    subject: s.subject,
                    number: s.courseNumber,
                    title: special ? "Special Topics" : title,
                    description: "",
                    minCredits: low,
                    maxCredits: s.creditHourHigh ?? low,
                    attributes: sectionAttributes.map(\.code).filter { $0 != honorsAttributeCode }.sorted(),
                    prereqs: nil,
                    coreqs: nil,
                    postreqs: [],
                    specialTopics: special,
                    college: nil,
                    department: nil,
                    detailsLoaded: false
                )
                order.append(key)
            }
        }

        let attributeList = attributes.map { AttributeInfo(code: $0.key, name: $0.value) }.sorted { $0.code < $1.code }
        return (order.compactMap { courses[$0] }, attributeList)
    }

    /// Merges a fresh section scrape into an existing catalog.
    ///
    /// - Seats, times and locations come from `fresh`.
    /// - Instructors and special-topics details are preserved by CRN.
    /// - Course descriptions/requisites are preserved, or borrowed from
    ///   `knowledge` (courses known from other terms), otherwise left as stubs.
    static func merge(
        existing: TermCatalog?,
        fresh: [BannerSection],
        term: Term,
        subjects: [Subject]?,
        campuses: [Campus]?,
        attributes: [AttributeInfo]?,
        knowledge: [CourseKey: Course] = [:],
        now: Date = .now
    ) -> TermCatalog {
        let previousSections = Dictionary((existing?.sections ?? []).map { ($0.crn, $0) }, uniquingKeysWith: { a, _ in a })
        let previousCourses = Dictionary((existing?.courses ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        let sections = makeSections(from: fresh, previous: previousSections)
        let (stubs, freshAttributes) = stubCourses(from: fresh)

        let courses: [Course] = stubs.map { stub in
            if var known = previousCourses[stub.key] {
                // Keep rich details, refresh credit hours and attributes.
                known.minCredits = stub.minCredits
                known.maxCredits = stub.maxCredits
                known.attributes = stub.attributes
                known.specialTopics = known.specialTopics || stub.specialTopics
                return known
            }
            if var borrowed = knowledge[stub.key] {
                borrowed.minCredits = stub.minCredits
                borrowed.maxCredits = stub.maxCredits
                borrowed.attributes = stub.attributes
                borrowed.specialTopics = borrowed.specialTopics || stub.specialTopics
                borrowed.postreqs = []
                return borrowed
            }
            return stub
        }

        var mergedAttributes = Dictionary((existing?.attributes ?? []).map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        for a in (attributes ?? []) + freshAttributes { mergedAttributes[a.code] = a }

        var catalog = TermCatalog(
            term: term,
            generatedAt: existing?.generatedAt ?? now,
            sectionsUpdatedAt: now,
            courses: courses.sorted { $0.key < $1.key },
            sections: sections.sorted { ($0.courseKey, $0.sectionNumber) < ($1.courseKey, $1.sectionNumber) },
            subjects: subjects ?? existing?.subjects ?? [],
            attributes: mergedAttributes.values.sorted { $0.code < $1.code },
            campuses: campuses ?? existing?.campuses ?? []
        )
        catalog.recomputePostreqs()
        return catalog
    }

    /// Replaces the sections of specific courses (after a per-course live refresh).
    static func applyCourseRefresh(_ catalog: inout TermCatalog, course: CourseKey, banner: [BannerSection], now: Date = .now) {
        let previous = Dictionary(catalog.sections.filter { $0.courseKey == course }.map { ($0.crn, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = makeSections(from: banner, previous: previous)
        catalog.sections.removeAll { $0.courseKey == course }
        catalog.sections.append(contentsOf: fresh)
        catalog.sections.sort { ($0.courseKey, $0.sectionNumber) < ($1.courseKey, $1.sectionNumber) }
        if !catalog.courses.contains(where: { $0.key == course }), !banner.isEmpty {
            let (stubs, _) = stubCourses(from: banner)
            catalog.courses.append(contentsOf: stubs)
            catalog.courses.sort { $0.key < $1.key }
        }
    }
}
