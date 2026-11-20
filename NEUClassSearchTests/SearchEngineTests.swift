//
//  SearchEngineTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

/// Runs the search engine against the bundled Fall 2026 snapshot.
@Suite(.serialized)
struct SearchEngineTests {
    static let index: CatalogIndex? = {
        guard let url = AppPaths.bundledCatalogURLs.first(where: { $0.lastPathComponent == "term-202710.catalog" }),
              let catalog = try? CatalogArchive.read(from: url) else { return nil }
        return CatalogIndex.build(catalog)
    }()

    private func top(_ text: String, filters: SearchFilters = .init()) throws -> [String] {
        let index = try #require(Self.index, "Bundled catalog missing")
        return SearchEngine.search(SearchQuery(text: text, filters: filters), in: index).results.prefix(5).map(\.course.code)
    }

    /// Reads each bundled file as raw JSON, without the runtime sanitizer in `CatalogArchive.decode`,
    /// so an address that shipped in the file cannot be hidden by the loader.
    @Test func bundledCatalogEmailsAreInstitutional() throws {
        let urls = AppPaths.bundledCatalogURLs
        let names = urls.map(\.lastPathComponent)
        #expect(names.contains("term-202710.catalog"))
        #expect(names.contains("term-202730.catalog"))
        for url in urls {
            let json = try CatalogArchive.jsonData(Data(contentsOf: url))
            let root = try JSONSerialization.jsonObject(with: json)
            var scan = RawEmailScan()
            scan.visit(root, key: nil)
            #expect(scan.kept > 0, "\(url.lastPathComponent): no instructor emails found")
            #expect(scan.violations.isEmpty, "\(url.lastPathComponent): \(scan.violations.prefix(5))")
        }
    }

    @Test func rawEmailScanFlagsUnsafeFixtures() {
        func violations(_ object: Any) -> [String] {
            var scan = RawEmailScan()
            scan.visit(object, key: nil)
            return scan.violations
        }
        func catalog(email: String? = nil, description: String? = nil) -> [String: Any] {
            var instructor: [String: Any] = ["name": "Lovelace, Ada"]
            if let email { instructor["email"] = email }
            var section: [String: Any] = ["instructors": [instructor]]
            if let description { section["description"] = description }
            return ["sections": [section]]
        }
        // Clean data passes, including an institutional address with sentence punctuation in prose.
        #expect(violations(catalog(email: "ada@northeastern.edu Ada@NEU.EDU")).isEmpty)
        #expect(violations(catalog(email: "ada!x@neu.edu", description: "Write to advising@northeastern.edu.")).isEmpty)
        // Student, subdomain and external domains.
        #expect(!violations(catalog(email: "synthetic@husky.neu.edu")).isEmpty)
        #expect(!violations(catalog(email: "synthetic@coe.neu.edu")).isEmpty)
        #expect(!violations(catalog(email: "synthetic@example.com")).isEmpty)
        #expect(!violations(catalog(email: "synthetic@example.com ada@neu.edu")).isEmpty)
        // An allowed prefix of a longer domain, in the email field.
        #expect(!violations(catalog(email: "synthetic@northeastern.edu.")).isEmpty)
        #expect(!violations(catalog(email: "synthetic@neu.eduX")).isEmpty)
        #expect(!violations(catalog(email: "synthetic@neu.edu\u{00E9}")).isEmpty)
        // Escaped addresses, in the email field and in any other string.
        #expect(!violations(catalog(email: "synthetic[at]example[dot]com")).isEmpty)
        #expect(!violations(catalog(description: "mail synthetic (at) example (dot) com")).isEmpty)
        #expect(!violations(catalog(description: "mail synthetic%40example.com")).isEmpty)
        #expect(!violations(catalog(description: "mail synthetic&#64;example.com")).isEmpty)
        // Literal addresses outside the email field.
        #expect(!violations(catalog(description: "mail synthetic@husky.neu.edu today")).isEmpty)
        #expect(!violations(catalog(description: "mail <synthetic@example.com>")).isEmpty)
        #expect(!violations(catalog(description: "mail synthetic@example.com.")).isEmpty)
    }

    @Test func bundledCatalogIsComplete() throws {
        let index = try #require(Self.index)
        #expect(index.courses.count > 2_500)
        #expect(index.catalog.sections.count > 7_000)
        #expect(index.courses.allSatisfy { $0.detailsLoaded })
        #expect(!index.instructors.isEmpty)
        #expect(!index.buildings.isEmpty)
    }

    @Test func exactCourseCodes() throws {
        #expect(try top("CS 3000").first == "CS 3000")
        #expect(try top("cs3000").first == "CS 3000")
        #expect(try top("cs 30").first == "CS 3000")
    }

    @Test func titlesAndShorthand() throws {
        #expect(try top("algorithms and data").first == "CS 3000")
        #expect(try top("linear algebra").first == "MATH 2331")
        #expect(try top("orgo").allSatisfy { $0.hasPrefix("CHM") || $0.hasPrefix("CHEM") })
        #expect(try top("linalg").first == "MATH 2331")
        // Typo tolerance.
        #expect(try top("algoritms").contains("CS 3000"))
    }

    @Test func crnLookup() throws {
        let index = try #require(Self.index)
        let section = try #require(index.catalog.sections.first)
        let response = SearchEngine.search(SearchQuery(text: section.crn), in: index)
        #expect(response.crnMatch?.crn == section.crn)
    }

    @Test func subjectAndProfessorMatches() throws {
        let index = try #require(Self.index)
        #expect(SearchEngine.search(SearchQuery(text: "cs"), in: index).subjects.map(\.code) == ["CS"])
        let instructor = try #require(index.instructors.first { $0.displayName.split(separator: " ").count == 2 })
        let lastName = String(instructor.displayName.split(separator: " ").last!)
        let response = SearchEngine.search(SearchQuery(text: instructor.displayName), in: index)
        #expect(response.instructors.contains { $0.name == instructor.name }, "Expected \(instructor.displayName) (\(lastName))")
    }

    @Test func filtersRequireAMatchingSection() throws {
        let index = try #require(Self.index)
        var filters = SearchFilters()
        filters.subjects = ["CS"]
        filters.openSeatsOnly = true
        filters.allowedDays = [.monday, .wednesday, .thursday]
        let results = SearchEngine.search(SearchQuery(text: "", filters: filters), in: index).results
        #expect(!results.isEmpty)
        for result in results {
            #expect(result.course.subject == "CS")
            #expect(index.sections(for: result.course.key).contains { filters.matches(section: $0) })
        }
    }

    /// `prereqs == nil` on a stub is unknown. The filters keep a course only when
    /// details were loaded and that table is empty. A placement test still counts.
    @Test func noRequisiteFiltersKeepOnlyLoadedEmptyTables() {
        let none = sample("1800", prereqs: nil, coreqs: nil, detailsLoaded: true)
        let prereq = sample("3000", prereqs: .course(CourseKey(subject: "CS", number: "1800")), coreqs: nil, detailsLoaded: true)
        let coreq = sample("1802", prereqs: nil, coreqs: .course(CourseKey(subject: "CS", number: "1800")), detailsLoaded: true)
        let placement = sample("1101", prereqs: .test(name: "Math Placement", score: 30), coreqs: nil, detailsLoaded: true)
        let unknown = sample("9999", prereqs: nil, coreqs: nil, detailsLoaded: false)
        let index = CatalogIndex.build(TermCatalog(
            term: Term(code: "202730", bannerDescription: "Spring 2027 Semester"),
            courses: [none, prereq, coreq, placement, unknown],
            sections: [],
            subjects: [Subject(code: "CS", name: "Computer Science")],
            attributes: [],
            campuses: []
        ))

        var noPrereqs = SearchFilters()
        noPrereqs.noPrerequisites = true
        let prereqCodes = SearchEngine.search(SearchQuery(text: "", filters: noPrereqs), in: index).results.map(\.course.code).sorted()
        #expect(prereqCodes == ["CS 1800", "CS 1802"])
        #expect(noPrereqs.activeCount == 1)

        var noCoreqs = SearchFilters()
        noCoreqs.noCorequisites = true
        let coreqCodes = SearchEngine.search(SearchQuery(text: "", filters: noCoreqs), in: index).results.map(\.course.code).sorted()
        #expect(coreqCodes == ["CS 1101", "CS 1800", "CS 3000"])

        var both = SearchFilters()
        both.noPrerequisites = true
        both.noCorequisites = true
        let bothCodes = SearchEngine.search(SearchQuery(text: "", filters: both), in: index).results.map(\.course.code)
        #expect(bothCodes == ["CS 1800"])
        #expect(both.activeCount == 2)
    }

    private func sample(_ number: String, prereqs: Requisite?, coreqs: Requisite?, detailsLoaded: Bool) -> Course {
        Course(
            subject: "CS", number: number, title: "Sample", description: "",
            minCredits: 4, maxCredits: 4, attributes: [],
            prereqs: prereqs, coreqs: coreqs, postreqs: [],
            specialTopics: false, college: nil, department: nil, detailsLoaded: detailsLoaded
        )
    }
}

/// Walks decoded catalog JSON and collects addresses that are not complete
/// `northeastern.edu` or `neu.edu` mailboxes. It does not share code with the
/// runtime sanitizer, so a bug there cannot hide a bad file.
private struct RawEmailScan {
    var violations: [String] = []
    /// Complete institutional mailboxes seen in `email` fields.
    var kept = 0

    private static let allowed: Set<String> = ["northeastern.edu", "neu.edu"]
    private static let punctuation = CharacterSet(charactersIn: "<>()[]{}\"'.,;:!?")

    mutating func visit(_ node: Any, key: String?) {
        if let dictionary = node as? [String: Any] {
            for (childKey, value) in dictionary { visit(value, key: childKey) }
        } else if let array = node as? [Any] {
            for value in array { visit(value, key: key) }
        } else if let text = node as? String {
            visit(string: text, isEmailField: key == "email")
        }
    }

    private mutating func visit(string text: String, isEmailField: Bool) {
        if hasEscapedAddress(text) { violations.append("escaped address in \(text.prefix(60))") }
        // Whitespace, comma or semicolon separated tokens. Every token with an @ is a candidate.
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
        for piece in tokens where piece.contains("@") {
            // In the email field the token must be a whole mailbox as written. In prose, wrapping
            // brackets and sentence punctuation around an address are ignored.
            var token = String(piece)
            if !isEmailField { token = token.trimmingCharacters(in: Self.punctuation) }
            if Self.isAllowedMailbox(token) {
                if isEmailField { kept += 1 }
            } else {
                violations.append("address with a domain that is not allowed: \(domain(of: token))")
            }
        }
        if isEmailField, !text.contains("@"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append("email field without an address")
        }
    }

    private func domain(of token: String) -> String {
        token.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    private static func isAllowedMailbox(_ token: String) -> Bool {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let localSymbols = Set("!#$%&'*+/=?^_`{|}~-.".unicodeScalars)
        for scalar in parts[0].unicodeScalars {
            let isAlphanumeric = (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            if !isAlphanumeric && !localSymbols.contains(scalar) { return false }
        }
        let domain = String(parts[1])
        guard domain.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        return allowed.contains(domain.lowercased())
    }

    /// `[at]`, `(dot)` and similar bracketed words, plus percent and HTML escapes of the at sign.
    private func hasEscapedAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("%40") || lower.contains("&#64;") || lower.contains("&#x40;") || lower.contains("&commat;") {
            return true
        }
        return lower.firstMatch(of: #/[\[({<]\s*(at|dot)\s*[\])}>]/#) != nil
    }
}
