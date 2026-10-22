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

    /// Every address stored in the bundled Spring 2027 snapshot is on
    /// `northeastern.edu` or `neu.edu`. A field that listed a personal address
    /// beside an institutional one must not keep the personal one.
    @Test func bundledSpring2027EmailsAreInstitutional() throws {
        let url = try #require(
            AppPaths.bundledCatalogURLs.first { $0.lastPathComponent == "term-202730.catalog" },
            "Bundled Spring 2027 catalog missing"
        )
        let catalog = try CatalogArchive.read(from: url)
        let address = #/[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})/#
        var checked = 0
        func check(_ text: String, crn: String) {
            let matches = text.matches(of: address)
            for match in matches {
                checked += 1
                let domain = String(match.output.1).lowercased()
                #expect(domain == "northeastern.edu" || domain == "neu.edu", "CRN \(crn) has \(domain)")
            }
        }
        for section in catalog.sections {
            for instructor in section.instructors ?? [] {
                guard let email = instructor.email else { continue }
                let matches = email.matches(of: address)
                #expect(!matches.isEmpty, "Unparsed instructor email on CRN \(section.crn)")
                let leftover = email.replacing(address, with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(leftover.isEmpty, "Instructor email on CRN \(section.crn) is not only institutional addresses")
                check(email, crn: section.crn)
            }
            if let description = section.description { check(description, crn: section.crn) }
        }
        for course in catalog.courses {
            check(course.description, crn: course.code)
        }
        #expect(checked > 0)
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
}
