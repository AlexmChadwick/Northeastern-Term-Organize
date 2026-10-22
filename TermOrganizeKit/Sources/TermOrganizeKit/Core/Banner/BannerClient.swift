//
//  BannerClient.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), packages/scraper/src/generate/endpoints.ts,
//  fetch.ts (retry policy), steps/sections.ts (search sessions and cookie pool),
//  steps/terms.ts and steps/campuses.ts, Copyright (C) Sandbox at Northeastern
//  University and the SearchNEU contributors, licensed under the GNU Affero General
//  Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift (URLSession, async/await,
//  Codable models) with a smaller session pool, plus per-course live refreshes,
//  attribute lookups and course-detail merging.
//
//  Talks directly to Northeastern's public Banner 9 class search. All requests are
//  read-only lookups of public course information.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BannerError: LocalizedError, Sendable {
    case http(Int)
    case invalidResponse
    case decoding(String)
    case noSession

    var errorDescription: String? {
        switch self {
        case .http(let code):
            code == 429 ? "Northeastern's registration system is busy. Please try again shortly."
                : "Northeastern's registration system returned an error (HTTP \(code))."
        case .invalidResponse: "Received an unexpected response from Northeastern's registration system."
        case .decoding(let detail): "Couldn't read the response from Northeastern's registration system. \(detail)"
        case .noSession: "Couldn't start a search session with Northeastern's registration system."
        }
    }
}

/// A Banner search session. Section searches require a cookie bound to a term.
struct BannerSearchSession: Sendable {
    let term: String
    let cookieHeader: String
}

final class BannerClient: Sendable {
    static let shared = BannerClient()

    static let baseURL = URL(string: "https://nubanner.neu.edu/StudentRegistrationSsb/ssb/")!

    private let session: URLSession
    private let maxAttempts: Int

    init(timeout: TimeInterval = 60, maxAttempts: Int = 4) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept": "application/json, text/html;q=0.9, */*;q=0.8"]
        self.session = URLSession(configuration: config)
        self.maxAttempts = maxAttempts
    }

    // MARK: - Reference data

    /// Most recent terms first.
    func fetchTerms(max: Int = 40, matching search: String = "") async throws -> [Term] {
        let url = endpoint("classSearch/getTerms", query: ["offset": "1", "max": String(max), "searchTerm": search])
        let terms: [BannerTerm] = try await decode(url: url)
        return terms.map { Term(code: $0.code, bannerDescription: HTMLText.decodeEntities($0.description)) }
    }

    func fetchSubjects(term: String) async throws -> [Subject] {
        let url = endpoint("classSearch/get_subject", query: ["searchTerm": "", "term": term, "offset": "1", "max": "900"])
        let items: [BannerCodeDescription] = try await decode(url: url)
        return items.map { Subject(code: $0.code, name: HTMLText.decodeEntities($0.description).trimmingCharacters(in: .whitespaces)) }
    }

    func fetchCampuses(term: String) async throws -> [Campus] {
        let url = endpoint("classSearch/get_campus", query: ["searchTerm": "", "term": term, "offset": "1", "max": "200"])
        let items: [BannerCodeDescription] = try await decode(url: url)
        return items.map { Campus(code: $0.code, name: HTMLText.decodeEntities($0.description).trimmingCharacters(in: .whitespaces)) }
    }

    func fetchAttributes(term: String) async throws -> [AttributeInfo] {
        let url = endpoint("classSearch/get_attribute", query: ["searchTerm": "", "term": term, "offset": "1", "max": "500"])
        let items: [BannerCodeDescription] = try await decode(url: url)
        return items.map { AttributeInfo(code: $0.code, name: HTMLText.decodeEntities($0.description).trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Section search

    /// Starts a search session for a term (POST `term/search`), returning its cookie.
    func openSearchSession(term: String) async throws -> BannerSearchSession {
        var request = URLRequest(url: endpoint("term/search", query: ["mode": "search"]))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["term": term, "studyPath": "", "studyPathText": "", "startDatepicker": "", "endDatepicker": ""])
        let (_, response) = try await perform(request)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
            if let k = pair.key as? String, let v = pair.value as? String { dict[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: Self.baseURL)
        guard !cookies.isEmpty else { throw BannerError.noSession }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return BannerSearchSession(term: term, cookieHeader: header)
    }

    /// Clears the search criteria of a session so it can be reused.
    func resetSearch(_ session: BannerSearchSession) async throws {
        var request = URLRequest(url: endpoint("classSearch/resetDataForm"))
        request.httpMethod = "POST"
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        _ = try await perform(request)
    }

    /// One page of section search results.
    func searchSections(
        _ session: BannerSearchSession,
        subject: String? = nil,
        courseNumber: String? = nil,
        offset: Int = 0,
        pageSize: Int = 500
    ) async throws -> BannerSectionPage {
        var query: [String: String] = [
            "txt_term": session.term,
            "pageOffset": String(offset),
            "pageMaxSize": String(pageSize),
            "sortColumn": "subjectDescription",
            "sortDirection": "asc",
        ]
        if let subject { query["txt_subject"] = subject }
        if let courseNumber { query["txt_courseNumber"] = courseNumber }
        var request = URLRequest(url: endpoint("searchResults/searchResults", query: query))
        request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
        return try await decode(request: request)
    }

    /// Every section in a term. Pages are fetched with `parallelism` independent
    /// sessions (SearchNEU uses a pool of cookies the same way).
    func fetchAllSections(
        term: String,
        parallelism: Int = 4,
        progress: (@Sendable (_ fetched: Int, _ total: Int) -> Void)? = nil
    ) async throws -> [BannerSection] {
        let pageSize = 500
        let first = try await openSearchSession(term: term)
        let probe = try await searchSections(first, offset: 0, pageSize: 1)
        let total = probe.totalCount
        guard total > 0 else { return [] }
        let pageCount = Int((Double(total) / Double(pageSize)).rounded(.up))
        progress?(0, total)

        var sessions = [first]
        for _ in 1..<max(1, min(parallelism, pageCount)) {
            sessions.append(try await openSearchSession(term: term))
        }

        let counter = ProgressCounter()
        let pages = try await withThrowingTaskGroup(of: (Int, [BannerSection]).self) { group in
            var results: [Int: [BannerSection]] = [:]
            var nextPage = 0
            func addTask(_ page: Int) {
                let session = sessions[page % sessions.count]
                group.addTask {
                    let result = try await self.searchSections(session, offset: page * pageSize, pageSize: pageSize)
                    let data = result.data ?? []
                    let fetched = await counter.add(data.count)
                    progress?(min(fetched, total), total)
                    return (page, data)
                }
            }
            // One in-flight request per session keeps each cookie's state consistent.
            while nextPage < min(sessions.count, pageCount) { addTask(nextPage); nextPage += 1 }
            while let (page, data) = try await group.next() {
                results[page] = data
                if nextPage < pageCount { addTask(nextPage); nextPage += 1 }
            }
            return results
        }

        var all: [BannerSection] = []
        all.reserveCapacity(total)
        var seen = Set<String>()
        for page in pages.keys.sorted() {
            for s in pages[page] ?? [] where seen.insert(s.courseReferenceNumber).inserted {
                all.append(s)
            }
        }
        return all
    }

    /// Live sections for specific courses, using one session and resetting the
    /// search between courses.
    func fetchSections(term: String, courses: [CourseKey]) async throws -> [CourseKey: [BannerSection]] {
        guard !courses.isEmpty else { return [:] }
        let session = try await openSearchSession(term: term)
        var out: [CourseKey: [BannerSection]] = [:]
        for (i, key) in courses.enumerated() {
            try Task.checkCancellation()
            if i > 0 { try await resetSearch(session) }
            let page = try await searchSections(session, subject: key.subject, courseNumber: key.number, pageSize: 500)
            // Banner treats the course number as a prefix; keep exact matches only.
            out[key] = (page.data ?? []).filter { $0.subject == key.subject && $0.courseNumber == key.number }
        }
        return out
    }

    // MARK: - Per-section details

    func fetchInstructors(term: String, crn: String) async throws -> [Instructor] {
        let url = endpoint("searchResults/getFacultyMeetingTimes", query: ["term": term, "courseReferenceNumber": crn])
        let result: BannerFacultyMeetingTimes = try await decode(url: url)
        var seen = Set<String>()
        var instructors: [Instructor] = []
        for meeting in result.fmt ?? [] {
            for faculty in meeting.faculty ?? [] {
                guard let instructor = faculty.toInstructor(), seen.insert(instructor.name).inserted else { continue }
                instructors.append(instructor)
            }
        }
        return instructors.sorted { $0.primary && !$1.primary }
    }

    func fetchDescriptionHTML(term: String, crn: String) async throws -> String {
        try await postForm("searchResults/getCourseDescription", term: term, crn: crn)
    }

    func fetchPrerequisitesHTML(term: String, crn: String) async throws -> String {
        try await postForm("searchResults/getSectionPrerequisites", term: term, crn: crn)
    }

    func fetchCorequisitesHTML(term: String, crn: String) async throws -> String {
        try await postForm("searchResults/getCorequisites", term: term, crn: crn)
    }

    func fetchCatalogDetailsHTML(term: String, crn: String) async throws -> String {
        try await postForm("searchResults/getSectionCatalogDetails", term: term, crn: crn)
    }

    func fetchRestrictionsHTML(term: String, crn: String) async throws -> String {
        try await postForm("searchResults/getRestrictions", term: term, crn: crn)
    }

    /// Must and cannot lists for one section. An empty array means Banner returned
    /// a fragment with no lists. Throws when the request fails, so the caller can
    /// leave a cached value in place.
    func fetchRestrictions(term: String, crn: String) async throws -> [SectionRestriction] {
        RestrictionParser.parse(try await fetchRestrictionsHTML(term: term, crn: crn))
    }

    /// Fetches description, requisites and catalog details for a course using one
    /// of its sections, merging them into `course`.
    func fetchCourseDetails(term: String, crn: String, course: Course, subjects: BannerParsers.SubjectLookup) async throws -> Course {
        async let descriptionHTML = fetchDescriptionHTML(term: term, crn: crn)
        async let prereqHTML = fetchPrerequisitesHTML(term: term, crn: crn)
        async let coreqHTML = fetchCorequisitesHTML(term: term, crn: crn)
        async let detailsHTML = fetchCatalogDetailsHTML(term: term, crn: crn)

        var updated = course
        updated.description = BannerParsers.description(fromHTML: try await descriptionHTML)
        updated.prereqs = BannerParsers.prerequisites(fromHTML: try await prereqHTML, subjects: subjects)
        updated.coreqs = BannerParsers.corequisites(fromHTML: try await coreqHTML, subjects: subjects)
        let details = BannerParsers.catalogDetails(fromHTML: try await detailsHTML)
        if let title = details.title?.nilIfBlank, !course.specialTopics { updated.title = title }
        updated.college = details.college ?? updated.college
        updated.department = details.department ?? updated.department
        updated.detailsLoaded = true
        return updated
    }

    // MARK: - Course catalog by course and term (no CRN needed)
    //
    // The class search only knows courses that have sections in a term. Banner 9 also has a
    // "Browse Course Catalog" that answers for any course in a term's catalog, taught or not.
    // What follows was found with read-only requests to nubanner.neu.edu in October 2026. The
    // endpoints are listed (`data-endpoint` attributes) in the HTML of `courseSearch/courseSearch`:
    // `courseSearch/get_subjectcoursecombo` and `courseSearchResults/{courseSearchResults,
    // getCourseDescription, getCourseCatalogDetails, getPrerequisites, getCorequisites,
    // getCourseMutuallyExclusions, getCourseAttributes, getRestrictions, getFees}`, next to the
    // `searchResults/…` ones the section pages use (among them `getXlstSections`, spelled
    // without the "i", and another `getCourseMutuallyExclusions`).
    //
    // Does a term's catalog list the course? `GET courseSearch/get_subjectcoursecombo?
    // searchTerm=CS 4050&term=202630&offset=1&max=10` needs no cookie and answers
    // `[{"code":"CS4050","description":"CS4050 Computer Science"}]`, or `[]`. It is a typeahead,
    // so `catalogLists` compares the code exactly in case it ever returns near matches. The
    // catalog is effective-dated (its JSON entries carry `termStart` and `termEnd`): a term lists
    // the courses that are active in it, whether or not they have sections.
    //   - CS 3386 (Game Programming 2) is listed in Fall 2026 (202710) although it has no
    //     sections then: its entry has termStart 202610 and termEnd 999999.
    //   - CS 4050 (AI and Society) is listed in Spring 2026 (202630), but not in Fall 2026.
    //   - CS 2510 is listed in Fall 2024 and Spring 2025 (202510, 202530), not from Fall 2025
    //     (202610) on: the renumbering retired it. (CS 2500 and CS 3500 have no sections in
    //     Fall 2026 either, where CS 2000, CS 2100 and CS 3100 do; their catalog entries weren't
    //     checked.)
    //   - CS 2963 is not listed in Fall 2026 (earlier terms weren't checked).
    // "The catalog doesn't list it" differs from "it has no prerequisites": the detail endpoints
    // answer "No prerequisite information available." for a course that doesn't exist too, and
    // `getCourseCatalogDetails` answers HTTP 500 (a null catalog object) for it. So existence is
    // checked first, with the typeahead, which answers an ordinary 200 either way.
    //
    // Details. `POST courseSearchResults/…` with the form fields `term`, `subjectCode` and
    // `courseNumber`. Like their `searchResults/…` counterparts they are stateless (no
    // `term/search` session, no cookie) and return the same HTML fragments, so `BannerParsers`
    // reads them: `getPrerequisites` is the same table as `getSectionPrerequisites`,
    // `getCourseCatalogDetails` has the title, college, department and credit hours
    // (`1 TO 4` for variable credit).
    //
    // Not used: the JSON course search `courseSearchResults/courseSearchResults`. It needs
    // `POST term/search?mode=courseSearch` first and keeps its criteria in the session: a second
    // search with other criteria returns the first one's results again, and
    // `courseSearch/resetDataForm` drops the term (the next search fails with a null
    // `enrollmentDisplaySettings`). The typeahead and the detail endpoints cover everything.
    //
    // Equivalent courses. The only course-level link between courses Banner offers is the mutual
    // exclusion list ("credit can't be earned for both"). Its answer was "No Mutual Exclusion
    // information available." for CS 2100 (Fall 2026), CS 2510 (Spring 2025) and MATH 1341, so
    // Banner does not link the renumbered computer science courses, and no sample has shown the
    // shape of a populated list (`BannerParsers.mutualExclusions` is written to tolerate it). The
    // other link is the cross-list (`searchResults/getXlstSections`, per CRN, listing the other
    // sections: CRN, subject, number, title and section). Banner also cross-lists combined
    // undergraduate and graduate sections and special-topics shells, which aren't
    // interchangeable, so `CourseEquivalences(crossListedIn:)` only counts same-number,
    // same-title courses.

    /// Whether `term`'s course catalog lists `course`.
    func catalogLists(_ course: CourseKey, term: String) async throws -> Bool {
        let url = endpoint("courseSearch/get_subjectcoursecombo", query: [
            "searchTerm": "\(course.subject) \(course.number)",
            "term": term,
            "offset": "1",
            "max": "10",
        ])
        let items: [BannerCodeDescription] = try await decode(url: url)
        return BannerParsers.catalogCodes(items, contain: course)
    }

    func fetchCourseCatalogDetailsHTML(term: String, course: CourseKey) async throws -> String {
        try await postCourseForm("courseSearchResults/getCourseCatalogDetails", term: term, course: course)
    }

    func fetchCoursePrerequisitesHTML(term: String, course: CourseKey) async throws -> String {
        try await postCourseForm("courseSearchResults/getPrerequisites", term: term, course: course)
    }

    func fetchCourseCorequisitesHTML(term: String, course: CourseKey) async throws -> String {
        try await postCourseForm("courseSearchResults/getCorequisites", term: term, course: course)
    }

    func fetchCourseMutualExclusionsHTML(term: String, course: CourseKey) async throws -> String {
        try await postCourseForm("courseSearchResults/getCourseMutuallyExclusions", term: term, course: course)
    }

    /// Sections cross-listed with a section (`searchResults/getXlstSections`).
    func fetchCrossListedSectionsHTML(term: String, crn: String) async throws -> String {
        try await postForm("searchResults/getXlstSections", term: term, crn: crn)
    }

    func fetchCrossListedSections(term: String, crn: String, subjects: BannerParsers.SubjectLookup) async throws -> [BannerParsers.CrossListedSection] {
        BannerParsers.crossListedSections(fromHTML: try await fetchCrossListedSectionsHTML(term: term, crn: crn), subjects: subjects)
    }

    /// A course's catalog entry as of `term`: title, credits, prerequisites, corequisites and
    /// mutual exclusions. Nil when the term's catalog doesn't list the course. One request to
    /// check, then four (in parallel) when it does.
    ///
    /// - Parameter subjects: the subject names of the term, to turn the requisite tables'
    ///   "Computer Science" into `CS`. Only called once the course is known to exist.
    func fetchCourseInfo(
        _ course: CourseKey,
        term: String,
        now: Date = .now,
        subjects: () async throws -> BannerParsers.SubjectLookup
    ) async throws -> CourseInfo? {
        guard try await catalogLists(course, term: term) else { return nil }
        async let detailsHTML = fetchCourseCatalogDetailsHTML(term: term, course: course)
        async let prerequisitesHTML = fetchCoursePrerequisitesHTML(term: term, course: course)
        async let corequisitesHTML = fetchCourseCorequisitesHTML(term: term, course: course)
        async let exclusionsHTML = fetchCourseMutualExclusionsHTML(term: term, course: course)

        let lookup = try await subjects()
        let details = BannerParsers.catalogDetails(fromHTML: try await detailsHTML)
        return CourseInfo(
            key: course,
            title: details.title ?? "",
            minCredits: details.minCredits,
            maxCredits: details.maxCredits,
            prerequisites: BannerParsers.prerequisites(fromHTML: try await prerequisitesHTML, subjects: lookup),
            corequisites: BannerParsers.corequisites(fromHTML: try await corequisitesHTML, subjects: lookup),
            equivalents: BannerParsers.mutualExclusions(fromHTML: try await exclusionsHTML, subjects: lookup),
            sourceTerm: term,
            fetchedAt: now
        )
    }

    // MARK: - Offering history

    /// Which of `courses` had at least one section in `term`: the answer to "was it taught that
    /// semester?".
    ///
    /// One search session for the term, then a reset and a search per course, as `fetchSections`
    /// does, but asking for a small page: only whether a section exists matters. (The section
    /// search also takes several subjects at once, `txt_subject=CS,MATH` found 866 sections in
    /// Fall 2026, the 637 of CS and the 229 of MATH; but a section is 3.4 KB of JSON, so asking
    /// for whole subjects would mean megabytes per term to learn about a few courses.)
    func fetchOfferedCourses(term: String, courses: [CourseKey]) async throws -> Set<CourseKey> {
        guard !courses.isEmpty else { return [] }
        let session = try await openSearchSession(term: term)
        var offered = Set<CourseKey>()
        for (position, key) in courses.enumerated() {
            try Task.checkCancellation()
            if position > 0 { try await resetSearch(session) }
            let page = try await searchSections(session, subject: key.subject, courseNumber: key.number, pageSize: 20)
            // Banner treats the course number as a prefix; only an exact match counts.
            if (page.data ?? []).contains(where: { $0.subject == key.subject && $0.courseNumber == key.number }) {
                offered.insert(key)
            }
        }
        return offered
    }

    /// Public catalog page for a course on Northeastern's website.
    static func catalogPageURL(term: String, course: CourseKey) -> URL? {
        var c = URLComponents(string: "https://bnrordsp.neu.edu/ssb-prod/bwckctlg.p_disp_course_detail")
        c?.queryItems = [
            URLQueryItem(name: "cat_term_in", value: term),
            URLQueryItem(name: "subj_code_in", value: course.subject),
            URLQueryItem(name: "crse_numb_in", value: course.number),
        ]
        return c?.url
    }

    // MARK: - Plumbing

    private func endpoint(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        return components.url!
    }

    private func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.keys.sorted().map { key in
            let value = fields[key]?.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func postForm(_ path: String, term: String, crn: String) async throws -> String {
        try await postForm(path, fields: ["term": term, "courseReferenceNumber": crn])
    }

    /// The course catalog endpoints take a course by subject and number instead of a CRN.
    private func postCourseForm(_ path: String, term: String, course: CourseKey) async throws -> String {
        try await postForm(path, fields: ["term": term, "subjectCode": course.subject, "courseNumber": course.number])
    }

    private func postForm(_ path: String, fields: [String: String]) async throws -> String {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let (data, _) = try await perform(request)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(url: URL) async throws -> T {
        try await decode(request: URLRequest(url: url))
    }

    private func decode<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, _) = try await perform(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BannerError.decoding(String(describing: error).prefix(200).description)
        }
    }

    /// Performs a request, retrying 429/5xx responses and transient network
    /// errors with exponential backoff and jitter.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var delay: Double = 1
        var lastError: Error = BannerError.invalidResponse
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw BannerError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                lastError = BannerError.http(http.statusCode)
                guard http.statusCode == 429 || http.statusCode >= 500 else { throw lastError }
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BannerError {
                if case .http(let code) = error, code == 429 || code >= 500 {
                    lastError = error
                } else {
                    throw error
                }
            }
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64((delay + Double.random(in: 0...0.5)) * 1_000_000_000))
                delay = min(delay * 2, 20)
            }
        }
        throw lastError
    }
}

/// Thread-safe counter for progress reporting.
actor ProgressCounter {
    private(set) var value = 0
    func add(_ n: Int) -> Int {
        value += n
        return value
    }
}

/// Runs `body` for each element with at most `limit` tasks in flight.
func forEachConcurrently<T: Sendable>(
    _ items: [T],
    limit: Int,
    _ body: @escaping @Sendable (T) async -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        var iterator = items.makeIterator()
        for _ in 0..<max(1, limit) {
            guard let item = iterator.next() else { break }
            group.addTask { await body(item) }
        }
        while await group.next() != nil {
            if Task.isCancelled { group.cancelAll(); break }
            if let item = iterator.next() {
                group.addTask { await body(item) }
            }
        }
    }
}
