//
//  CourseCatalogEntryView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The page of a course the loaded term's catalog doesn't list: one that isn't offered this term,
/// or that has been retired (CS 2510 after the renumbering).
///
/// A term's schedule only lists the courses that have sections, so there is nothing to show about
/// seats or meetings. Banner's course catalog still knows the course, though, so the page reads it
/// through `CourseInfoStore`: title, credits, prerequisites and corequisites, drawn like any
/// course's, and a note saying why it isn't in the term.
struct CourseCatalogEntryView: View {
    var key: CourseKey
    var termCode: String
    /// The loaded term, e.g. `Fall 2026`.
    var termName: String
    var index: CatalogIndex

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    /// The term's courses that mention this one in their prerequisites ("Leads to"). Nil until
    /// worked out, which is before the lookup starts, so the page never shows an empty list that
    /// then fills in.
    @State private var dependents: [CourseKey]?
    @State private var isRetrying = false
    @State private var stillFailing = false

    private struct LoadID: Hashable {
        var key: CourseKey
        var indexVersion: Int
    }

    var body: some View {
        content
            .task(id: LoadID(key: key, indexVersion: catalog.indexVersion)) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch CourseInfoStore.shared.state(for: key) {
        case .found(let info):
            if let dependents {
                details(info, dependents: dependents)
            } else {
                checking
            }
        case .unknown, .loading:
            checking
        case .notFound:
            notListed
        case .failed:
            unreachable
        }
    }

    private var checking: some View {
        ProgressView("Checking Banner's catalog…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Details

    private func details(_ info: CourseInfo, dependents: [CourseKey]) -> some View {
        let note = availability(of: info)
        let named = (info.prerequisites?.referencedCourses ?? []) + (info.corequisites?.referencedCourses ?? [])
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CourseCatalogHeader(
                    code: key.description,
                    title: info.title,
                    credits: info.creditsLabel,
                    availability: note.text,
                    availabilitySymbol: note.symbol,
                    degreeTag: userData.courseDegreePlanTag(for: key)
                )
                .padding(.horizontal, Theme.Spacing.l)

                CourseRequirementsSection(
                    key: key,
                    prereqs: info.prerequisites,
                    coreqs: info.corequisites,
                    postreqs: dependents,
                    index: index,
                    termCode: termCode,
                    status: .ready,
                    onRetry: {}
                )
            }
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xl)
            .courseReadableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .courseLoadsEquivalents(for: [key] + named)
    }

    /// Why there are no sections: the course has been retired (the catalog that lists it is an
    /// older term's), or it just isn't taught in the loaded term.
    private func availability(of info: CourseInfo) -> (text: String, symbol: String) {
        if info.isRetired == true {
            return ("No longer offered; last listed \(OfferingHistory.label(ofTerm: info.sourceTerm))", "archivebox")
        }
        return ("Not offered in \(termName)", "calendar.badge.minus")
    }

    // MARK: Other states

    /// No catalog Banner was asked about lists the course.
    private var notListed: some View {
        ContentUnavailableView {
            Label("\(key.description) isn't offered in \(termName)", systemImage: "magnifyingglass")
        } description: {
            Text("Banner's recent course catalogs don't list it either, so the course code may have changed.")
        } actions: {
            Button("Search for \(key.description)") {
                router.search(for: key.description)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Banner didn't answer. Quiet: the course may well be fine, only unchecked.
    private var unreachable: some View {
        ContentUnavailableView {
            Label("\(key.description) isn't offered in \(termName)", systemImage: "magnifyingglass")
        } description: {
            Text(stillFailing
                 ? "Banner's course catalog still isn't answering. Try again in a minute."
                 : "Banner's course catalog didn't answer, so the course's details couldn't be checked.")
        } actions: {
            Button("Try Again") {
                Task { await retry() }
            }
            .buttonStyle(.bordered)
            .disabled(isRetrying)
        }
    }

    // MARK: Loading

    /// Reads the catalog entry. The lookup runs in an unstructured task so leaving the page doesn't
    /// cancel it: the answer is cached for next time.
    private func load() async {
        dependents = Self.courses(mentioning: key, in: index)
        let store = CourseInfoStore.shared
        let key = self.key
        let indexes = catalog.loadedIndexes
        await Task { await store.load([key], indexes: indexes) }.value
    }

    private func retry() async {
        isRetrying = true
        stillFailing = false
        let store = CourseInfoStore.shared
        let key = self.key
        let indexes = catalog.loadedIndexes
        await Task { await store.load([key], indexes: indexes) }.value
        isRetrying = false
        // After a failure the store waits a minute before asking Banner again, so an immediate
        // retry can change nothing; say so rather than look dead.
        if case .failed = store.state(for: key) {
            stillFailing = true
        }
    }

    /// The courses of the term whose prerequisites mention `key`: what `Course.postreqs` is for a
    /// course the term lists.
    private static func courses(mentioning key: CourseKey, in index: CatalogIndex) -> [CourseKey] {
        index.courses
            .filter { $0.prereqs?.referencedCourses.contains(key) == true }
            .map(\.key)
            .sorted()
    }
}
