//
//  CatalogIndex.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Aggregated section information for a course (seat availability, campuses,
/// instructors...). Used by result rows and filters.
struct CourseStats: Hashable, Sendable {
    var sectionCount = 0
    var openSectionCount = 0
    var seatsRemaining = 0
    var seatCapacity = 0
    var waitlistOpenCount = 0
    var campuses: Set<String> = []
    var classTypes: Set<String> = []
    var hasHonors = false
    var hasOnline = false
    var hasInPerson = false
    /// Display names, primary instructors first, de-duplicated.
    var instructorNames: [String] = []
    var meetingDays = DaySet()

    var isFull: Bool { sectionCount > 0 && openSectionCount == 0 }

    /// `3 of 5 sections open`.
    var availabilityLabel: String {
        guard sectionCount > 0 else { return "No sections" }
        if sectionCount == 1 { return openSectionCount == 1 ? "1 section · open" : "1 section · full" }
        return "\(openSectionCount) of \(sectionCount) sections open"
    }
}

/// An instructor teaching in a term along with their sections.
struct InstructorSummary: Hashable, Identifiable, Sendable {
    /// Banner name (`Last, First`), used as the identifier.
    var name: String
    var displayName: String
    var email: String?
    var crns: [String]
    var courseKeys: [CourseKey]
    var id: String { name }
}

/// A room and the weekly meetings held in it.
struct RoomSchedule: Hashable, Identifiable, Sendable {
    struct Booking: Hashable, Sendable {
        var crn: String
        var course: CourseKey
        var days: DaySet
        var start: Int
        var end: Int
        /// ISO dates (yyyy-MM-dd) bounding when the meeting happens, if known.
        var startDate: String? = nil
        var endDate: String? = nil

        /// Whether the booking meets on the given calendar day (date window and weekday).
        func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
            let weekday = calendar.component(.weekday, from: date) - 1
            guard days.contains(day: weekday) else { return false }
            return isActive(on: date, calendar: calendar)
        }

        /// Whether `date` falls inside the booking's date window (ignores weekday).
        func isActive(on date: Date, calendar: Calendar = .current) -> Bool {
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let iso = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
            if let startDate, iso < startDate { return false }
            if let endDate, iso > endDate { return false }
            return true
        }

        /// Meetings shorter than three weeks (one-day sessions, short workshops).
        var isShortSession: Bool {
            guard let startDate, let endDate,
                  let a = BookingDates.parse(startDate), let b = BookingDates.parse(endDate) else { return false }
            return b.timeIntervalSince(a) < 21 * 24 * 3600
        }
    }
    var buildingCode: String
    var buildingName: String
    var room: String
    var bookings: [Booking]
    var id: String { "\(buildingCode)|\(room)" }
    var label: String { "\(buildingCode) \(room)" }
}

/// Parses the ISO dates stored on meetings.
enum BookingDates {
    static func parse(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

struct BuildingSummary: Hashable, Identifiable, Sendable {
    var code: String
    var name: String
    var campusCode: String?
    var rooms: [RoomSchedule]
    var id: String { code }
}

/// Read-only lookup structures for a term's catalog. Building an index is
/// relatively expensive, so do it off the main actor via `CatalogIndex.build`.
struct CatalogIndex: Sendable {
    let catalog: TermCatalog
    let coursesByKey: [CourseKey: Course]
    let sectionsByCourse: [CourseKey: [CourseSection]]
    let sectionsByCRN: [String: CourseSection]
    let stats: [CourseKey: CourseStats]
    let subjectsByCode: [String: Subject]
    let attributeNames: [String: String]
    /// Campus names used by sections, most common first.
    let campusNames: [String]
    /// Schedule types used by sections (Lecture, Lab...), most common first.
    let classTypes: [String]
    /// Subjects that have at least one course this term, sorted by code.
    let activeSubjects: [Subject]
    let courseCountBySubject: [String: Int]
    let instructors: [InstructorSummary]
    let instructorsByName: [String: InstructorSummary]
    let buildings: [BuildingSummary]
    let searchDocuments: [SearchDocument]

    var term: Term { catalog.term }
    var courses: [Course] { catalog.courses }

    func course(_ key: CourseKey) -> Course? { coursesByKey[key] }
    func sections(for key: CourseKey) -> [CourseSection] { sectionsByCourse[key] ?? [] }
    func section(crn: String) -> CourseSection? { sectionsByCRN[crn] }
    func stats(for key: CourseKey) -> CourseStats { stats[key] ?? CourseStats() }
    func subjectName(_ code: String) -> String? { subjectsByCode[code]?.name }
    func instructor(named name: String) -> InstructorSummary? { instructorsByName[name] }

    /// Human readable attribute name (e.g. `NUpath Ethical Reasoning`).
    func attributeName(_ code: String) -> String { attributeNames[code] ?? code }

    /// Courses in a subject, ordered by number.
    func courses(inSubject code: String) -> [Course] {
        catalog.courses.filter { $0.subject == code }.sorted { $0.key < $1.key }
    }

    /// Courses carrying a NUpath attribute.
    func courses(with nupath: NUPath) -> [Course] {
        catalog.courses.filter { $0.attributes.contains(nupath.attributeCode) }.sorted { $0.key < $1.key }
    }

    /// Catalogs built before the subject lookup understood campus suffixes name some requisite
    /// subjects in full ("Computer Science - MMC 201M"). Uses the subject code (CS 201M)
    /// everywhere, including the "prerequisite for" lists.
    static func normalizedRequisites(_ catalog: TermCatalog) -> TermCatalog {
        guard catalog.courses.contains(where: needsSubjectFix) else { return catalog }
        let lookup = BannerParsers.SubjectLookup(catalog.subjects)
        var fixed = catalog
        for i in fixed.courses.indices {
            fixed.courses[i] = normalizedRequisites(of: fixed.courses[i], lookup: lookup)
        }
        fixed.recomputePostreqs()
        return fixed
    }

    /// One course's requisites with full subject names replaced by codes.
    static func normalizedRequisites(of course: Course, lookup: BannerParsers.SubjectLookup) -> Course {
        guard needsSubjectFix(course) else { return course }
        func normalized(_ key: CourseKey) -> CourseKey {
            guard key.subject.contains(" ") else { return key }
            return CourseKey(subject: lookup.code(for: key.subject), number: key.number)
        }
        var fixed = course
        fixed.prereqs = course.prereqs?.mapCourses(normalized)
        fixed.coreqs = course.coreqs?.mapCourses(normalized)
        return fixed
    }

    private static func needsSubjectFix(_ course: Course) -> Bool {
        func check(_ requisite: Requisite?) -> Bool {
            requisite?.referencedCourses.contains { $0.subject.contains(" ") } ?? false
        }
        return check(course.prereqs) || check(course.coreqs)
    }

    static func build(_ input: TermCatalog) -> CatalogIndex {
        let catalog = normalizedRequisites(input)
        var coursesByKey: [CourseKey: Course] = [:]
        coursesByKey.reserveCapacity(catalog.courses.count)
        for c in catalog.courses { coursesByKey[c.key] = c }

        var sectionsByCourse: [CourseKey: [CourseSection]] = [:]
        var sectionsByCRN: [String: CourseSection] = [:]
        sectionsByCRN.reserveCapacity(catalog.sections.count)
        var campusCounts: [String: Int] = [:]
        var typeCounts: [String: Int] = [:]
        var rooms: [String: RoomSchedule] = [:]
        var buildingNames: [String: (name: String, campus: String?)] = [:]

        for s in catalog.sections {
            sectionsByCourse[s.courseKey, default: []].append(s)
            sectionsByCRN[s.crn] = s
            if !s.campus.isEmpty { campusCounts[s.campus, default: 0] += 1 }
            typeCounts[s.classType, default: 0] += 1
            for m in s.weeklyMeetings {
                guard let code = m.buildingCode, let room = m.room, let start = m.start, let end = m.end, !m.isOnline else { continue }
                let id = "\(code)|\(room)"
                var schedule = rooms[id] ?? RoomSchedule(buildingCode: code, buildingName: m.building ?? code, room: room, bookings: [])
                schedule.bookings.append(.init(crn: s.crn, course: s.courseKey, days: m.days, start: start, end: end,
                                               startDate: m.startDate, endDate: m.endDate))
                rooms[id] = schedule
                if buildingNames[code] == nil { buildingNames[code] = (m.building ?? code, m.campusCode) }
            }
        }

        for (key, list) in sectionsByCourse {
            sectionsByCourse[key] = sortedSections(list)
        }

        var stats: [CourseKey: CourseStats] = [:]
        for (key, list) in sectionsByCourse {
            stats[key] = makeStats(list)
        }

        let subjectsByCode = Dictionary(catalog.subjects.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        var courseCountBySubject: [String: Int] = [:]
        for c in catalog.courses { courseCountBySubject[c.subject, default: 0] += 1 }
        let activeSubjects = courseCountBySubject.keys.sorted().map { code in
            subjectsByCode[code] ?? Subject(code: code, name: code)
        }

        let (instructors, instructorsByName) = makeInstructorDirectory(catalog.sections)

        var buildingRooms: [String: [RoomSchedule]] = [:]
        for room in rooms.values { buildingRooms[room.buildingCode, default: []].append(room) }
        let buildings = buildingRooms.map { code, list in
            BuildingSummary(
                code: code,
                name: buildingNames[code]?.name ?? code,
                campusCode: buildingNames[code]?.campus,
                rooms: list.sorted { $0.room.localizedStandardCompare($1.room) == .orderedAscending }
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let attributeNames = Dictionary(catalog.attributes.map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a })

        let documents = catalog.courses.map { course in
            makeDocument(course, subjectName: subjectsByCode[course.subject]?.name ?? "", stats: stats[course.key], sections: sectionsByCourse[course.key] ?? [])
        }

        return CatalogIndex(
            catalog: catalog,
            coursesByKey: coursesByKey,
            sectionsByCourse: sectionsByCourse,
            sectionsByCRN: sectionsByCRN,
            stats: stats,
            subjectsByCode: subjectsByCode,
            attributeNames: attributeNames,
            // Banner files co-ops and independent study under a pseudo-campus
            // ("No campus, no room needed"); it isn't useful as a filter choice.
            campusNames: campusCounts.sorted { $0.value > $1.value }.map(\.key)
                .filter { !$0.localizedCaseInsensitiveContains("no campus") },
            classTypes: typeCounts.sorted { $0.value > $1.value }.map(\.key),
            activeSubjects: activeSubjects,
            courseCountBySubject: courseCountBySubject,
            instructors: instructors,
            instructorsByName: instructorsByName,
            buildings: buildings,
            searchDocuments: documents
        )
    }

    // MARK: - Helpers

    /// Every instructor with their sections and courses, sorted by display name.
    static func makeInstructorDirectory(_ sections: [CourseSection]) -> ([InstructorSummary], [String: InstructorSummary]) {
        var entries: [String: (display: String, email: String?, crns: [String], keys: [CourseKey])] = [:]
        for s in sections {
            for i in s.instructors ?? [] {
                var entry = entries[i.name] ?? (i.displayName, i.email, [], [])
                entry.crns.append(s.crn)
                if !entry.keys.contains(s.courseKey) { entry.keys.append(s.courseKey) }
                if entry.email == nil { entry.email = i.email }
                entries[i.name] = entry
            }
        }
        let list = entries.map { name, entry in
            InstructorSummary(name: name, displayName: entry.display, email: entry.email, crns: entry.crns, courseKeys: entry.keys.sorted())
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return (list, Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Lectures first, then labs, recitations…, then by section number.
    static func sortedSections(_ list: [CourseSection]) -> [CourseSection] {
        let typeOrder: [String: Int] = ["Lecture": 0, "Lab": 1, "Recitation/Discussion": 2, "Seminar": 3]
        return list.sorted {
            let a = typeOrder[$0.classType] ?? 9, b = typeOrder[$1.classType] ?? 9
            if a != b { return a < b }
            if $0.classType != $1.classType { return $0.classType < $1.classType }
            return $0.sectionNumber.localizedStandardCompare($1.sectionNumber) == .orderedAscending
        }
    }

    static func makeStats(_ list: [CourseSection]) -> CourseStats {
        var st = CourseStats()
        var names: [String] = []
        for s in list {
            st.sectionCount += 1
            if s.isOpen { st.openSectionCount += 1 }
            st.seatsRemaining += max(0, s.seatsRemaining)
            st.seatCapacity += s.seatCapacity
            if s.waitlistRemaining > 0 { st.waitlistOpenCount += 1 }
            if !s.campus.isEmpty { st.campuses.insert(s.campus) }
            st.classTypes.insert(s.classType)
            st.hasHonors = st.hasHonors || s.honors
            if s.isOnline { st.hasOnline = true } else { st.hasInPerson = true }
            st.meetingDays.formUnion(s.meetingDays)
            for i in (s.instructors ?? []).sorted(by: { $0.primary && !$1.primary }) where !names.contains(i.displayName) {
                names.append(i.displayName)
            }
        }
        st.instructorNames = names
        return st
    }

    static func makeDocument(_ course: Course, subjectName: String, stats: CourseStats?, sections: [CourseSection]) -> SearchDocument {
        SearchDocument(
            course: course,
            subjectName: subjectName,
            instructorNames: stats?.instructorNames ?? [],
            sectionTitles: course.specialTopics ? Array(Set(sections.map(\.title))) : []
        )
    }

    /// A copy with one course's details and sections replaced — much cheaper
    /// than rebuilding the whole index after a live refresh. The instructor
    /// directory is rebuilt (cheap); room schedules are left as they were.
    func replacingCourse(_ key: CourseKey, course incoming: Course?, sections newSections: [CourseSection]) -> CatalogIndex {
        // Live details can arrive with full subject names in their requisites; use codes.
        let course = incoming.map { CatalogIndex.normalizedRequisites(of: $0, lookup: BannerParsers.SubjectLookup(self.catalog.subjects)) }
        var catalog = self.catalog
        catalog.sections.removeAll { $0.courseKey == key }
        catalog.sections.append(contentsOf: newSections)
        var coursesByKey = self.coursesByKey
        var documents = self.searchDocuments
        let sorted = CatalogIndex.sortedSections(newSections)
        var stats = self.stats
        stats[key] = CatalogIndex.makeStats(sorted)

        if let course {
            if let i = catalog.courses.firstIndex(where: { $0.key == key }) {
                catalog.courses[i] = course
            } else {
                catalog.courses.append(course)
                catalog.courses.sort { $0.key < $1.key }
            }
            coursesByKey[key] = course
        }
        if let current = coursesByKey[key] {
            let document = CatalogIndex.makeDocument(current, subjectName: subjectsByCode[key.subject]?.name ?? "", stats: stats[key], sections: sorted)
            if let i = documents.firstIndex(where: { $0.key == key }) {
                documents[i] = document
            } else {
                documents.append(document)
            }
        }

        var sectionsByCourse = self.sectionsByCourse
        var sectionsByCRN = self.sectionsByCRN
        for old in self.sectionsByCourse[key] ?? [] { sectionsByCRN[old.crn] = nil }
        for s in sorted { sectionsByCRN[s.crn] = s }
        sectionsByCourse[key] = sorted

        let (instructors, instructorsByName) = CatalogIndex.makeInstructorDirectory(catalog.sections)

        return CatalogIndex(
            catalog: catalog,
            coursesByKey: coursesByKey,
            sectionsByCourse: sectionsByCourse,
            sectionsByCRN: sectionsByCRN,
            stats: stats,
            subjectsByCode: subjectsByCode,
            attributeNames: attributeNames,
            campusNames: campusNames,
            classTypes: classTypes,
            activeSubjects: activeSubjects,
            courseCountBySubject: courseCountBySubject,
            instructors: instructors,
            instructorsByName: instructorsByName,
            buildings: buildings,
            searchDocuments: documents
        )
    }
}
