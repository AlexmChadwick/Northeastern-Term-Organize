//
//  main.swift — catalog-snapshot
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu), packages/scraper/src/generate/main.ts,
//  Copyright (C) Sandbox at Northeastern University and the SearchNEU contributors,
//  licensed under the GNU Affero General Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift. The scrape flow (sections,
//  subjects, campuses, instructors, course details, special-topics sections,
//  postrequisites) is kept, but requests run at a lower concurrency and the result
//  is written in this app's .catalog format.
//
//  Builds the offline course catalog bundled with the app by reading
//  Northeastern's public Banner class search.
//
//  Usage: catalog-snapshot <term-code> [--out DIR] [--concurrency N] [--sample N]
//

import Foundation

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

guard let termCode = arguments.first(where: { $0.count == 6 && $0.allSatisfy(\.isNumber) }) else {
    FileHandle.standardError.write(Data("usage: catalog-snapshot <term-code> [--out DIR] [--concurrency N]\n".utf8))
    exit(2)
}
let outDirectory = URL(fileURLWithPath: option("--out") ?? FileManager.default.currentDirectoryPath)
let concurrency = max(1, min(12, Int(option("--concurrency") ?? "6") ?? 6))
/// Limits detail fetching to the first N courses (for quick validation runs).
let sampleLimit = option("--sample").flatMap { Int($0) }

@Sendable func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

// MARK: - Accumulator

actor Accumulator {
    var instructors: [String: [Instructor]] = [:]
    var courses: [CourseKey: Course] = [:]
    var sectionDetails: [String: (description: String, prereqs: Requisite?, coreqs: Requisite?)] = [:]
    var failures: [String] = []
    var completed = 0

    func setInstructors(_ crn: String, _ value: [Instructor]) { instructors[crn] = value; completed += 1 }
    func setCourse(_ course: Course) { courses[course.key] = course; completed += 1 }
    func setSectionDetails(_ crn: String, _ d: String, _ p: Requisite?, _ c: Requisite?) {
        sectionDetails[crn] = (d, p, c); completed += 1
    }
    func fail(_ what: String) { failures.append(what); completed += 1 }
    func resetProgress() { completed = 0; failures = [] }
}

// MARK: - Main

let client = BannerClient(timeout: 60, maxAttempts: 5)
let started = Date.now

log("Looking up term \(termCode)…")
let terms = try await client.fetchTerms(max: 10, matching: termCode)
guard let term = terms.first(where: { $0.code == termCode }) else {
    log("Term \(termCode) was not found in Banner.")
    exit(1)
}
log("Term: \(term.bannerDescription)")

log("Fetching sections…")
let rawSections = try await client.fetchAllSections(term: termCode, parallelism: 4) { fetched, total in
    if fetched == total || fetched % 1000 < 500 { log("  sections \(fetched)/\(total)") }
}
log("Fetched \(rawSections.count) sections")

async let subjectsTask = client.fetchSubjects(term: termCode)
async let campusesTask = client.fetchCampuses(term: termCode)
async let attributesTask = client.fetchAttributes(term: termCode)
let subjects = try await subjectsTask
let campuses = try await campusesTask
let attributes = try await attributesTask
log("\(subjects.count) subjects, \(campuses.count) campuses, \(attributes.count) attributes")

var catalog = CatalogBuilder.merge(
    existing: nil, fresh: rawSections, term: term,
    subjects: subjects, campuses: campuses, attributes: attributes
)
// Requisite tables name subjects by description, sometimes for subjects that are
// no longer offered; include subject names from recent terms when resolving them.
var lookupSubjects = subjects
let recentTerms = (try? await client.fetchTerms(max: 12)) ?? []
for other in recentTerms where other.code != termCode {
    if let more = try? await client.fetchSubjects(term: other.code) {
        let known = Set(lookupSubjects.map(\.name))
        lookupSubjects += more.filter { !known.contains($0.name) }
    }
}
log("Resolving requisite subjects with \(lookupSubjects.count) known subject names")
let lookup = BannerParsers.SubjectLookup(lookupSubjects)
let accumulator = Accumulator()

func reportProgress(label: String, total: Int, while work: () async -> Void) async {
    let reporter = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            let done = await accumulator.completed
            log("  \(label): \(done)/\(total)")
        }
    }
    await work()
    reporter.cancel()
}

// Instructors (Banner's search results hide faculty, so this is per section).
if let sampleLimit {
    let keep = Set(catalog.courses.prefix(sampleLimit).map(\.key)).union(catalog.courses.filter(\.specialTopics).prefix(2).map(\.key))
    catalog.courses.removeAll { !keep.contains($0.key) }
    catalog.sections.removeAll { !keep.contains($0.courseKey) }
    log("Sample mode: limited to \(catalog.courses.count) courses, \(catalog.sections.count) sections")
}
let crns = catalog.sections.map(\.crn)
log("Fetching instructors for \(crns.count) sections (concurrency \(concurrency))…")
await reportProgress(label: "instructors", total: crns.count) {
    await forEachConcurrently(crns, limit: concurrency) { crn in
        do {
            await accumulator.setInstructors(crn, try await client.fetchInstructors(term: termCode, crn: crn))
        } catch {
            await accumulator.fail("instructors \(crn): \(error.localizedDescription)")
        }
    }
}
var failures = await accumulator.failures
log("Instructors done (\(failures.count) failures)")

// Course details: description, prereqs, coreqs and catalog title via the first section.
let firstCRN = Dictionary(catalog.sections.map { ($0.courseKey, $0.crn) }, uniquingKeysWith: { a, _ in a })
let courseJobs: [(Course, String)] = catalog.courses.compactMap { c in firstCRN[c.key].map { (c, $0) } }
await accumulator.resetProgress()
let courseConcurrency = max(1, concurrency / 3 + 1)
log("Fetching details for \(courseJobs.count) courses (concurrency \(courseConcurrency)×4)…")
await reportProgress(label: "courses", total: courseJobs.count) {
    await forEachConcurrently(courseJobs, limit: courseConcurrency) { job in
        do {
            await accumulator.setCourse(try await client.fetchCourseDetails(term: termCode, crn: job.1, course: job.0, subjects: lookup))
        } catch {
            await accumulator.fail("course \(job.0.code): \(error.localizedDescription)")
        }
    }
}
failures += await accumulator.failures
log("Course details done")

// Special topics: details live on each section.
let specialKeys = Set(catalog.courses.filter(\.specialTopics).map(\.key))
let specialCRNs = catalog.sections.filter { specialKeys.contains($0.courseKey) }.map(\.crn)
await accumulator.resetProgress()
log("Fetching details for \(specialCRNs.count) special topics sections…")
await reportProgress(label: "special topics", total: specialCRNs.count) {
    await forEachConcurrently(specialCRNs, limit: courseConcurrency) { crn in
        do {
            async let d = client.fetchDescriptionHTML(term: termCode, crn: crn)
            async let p = client.fetchPrerequisitesHTML(term: termCode, crn: crn)
            async let c = client.fetchCorequisitesHTML(term: termCode, crn: crn)
            await accumulator.setSectionDetails(
                crn,
                BannerParsers.description(fromHTML: try await d),
                BannerParsers.prerequisites(fromHTML: try await p, subjects: lookup),
                BannerParsers.corequisites(fromHTML: try await c, subjects: lookup)
            )
        } catch {
            await accumulator.fail("section \(crn): \(error.localizedDescription)")
        }
    }
}
failures += await accumulator.failures

// MARK: - Assemble

let instructorMap = await accumulator.instructors
let courseMap = await accumulator.courses
let sectionDetailMap = await accumulator.sectionDetails

for i in catalog.sections.indices {
    let crn = catalog.sections[i].crn
    if let instructors = instructorMap[crn] { catalog.sections[i].instructors = instructors }
    if let details = sectionDetailMap[crn] {
        catalog.sections[i].description = details.description.nilIfBlank
        catalog.sections[i].prereqs = details.prereqs
        catalog.sections[i].coreqs = details.coreqs
    }
}
for i in catalog.courses.indices {
    if let detailed = courseMap[catalog.courses[i].key] { catalog.courses[i] = detailed }
}
catalog.generatedAt = .now
catalog.sectionsUpdatedAt = .now
catalog.recomputePostreqs()

let outURL = outDirectory.appendingPathComponent(CatalogArchive.fileName(forTerm: termCode))
try CatalogArchive.write(catalog, to: outURL)
let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0

let detailed = catalog.courses.filter(\.detailsLoaded).count
log("Wrote \(outURL.path) (\(size / 1024) KB)")
log("\(catalog.courses.count) courses (\(detailed) with details), \(catalog.sections.count) sections")
log("Instructor emails: kept northeastern.edu and neu.edu only; dropped \(InstructorEmail.droppedCount) other addresses (\(InstructorEmail.droppedUniqueCount) unique)")
let droppedDomains = InstructorEmail.droppedDomains.sorted { lhs, rhs in
    if lhs.value != rhs.value { return lhs.value > rhs.value }
    return lhs.key < rhs.key
}
if !droppedDomains.isEmpty {
    log("Dropped email domains: \(droppedDomains.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
}
log("\(failures.count) failed requests; elapsed \(Int(Date.now.timeIntervalSince(started)))s")
for f in failures.prefix(25) { log("  ! \(f)") }
