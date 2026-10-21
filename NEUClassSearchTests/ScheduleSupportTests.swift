//
//  ScheduleSupportTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  The schedule helpers both apps share: what a schedule warns about, how a plan is edited, the
//  wording of "no schedules fit", favorites, and undoing a removed course.
//

import Foundation
import Testing
@testable import NEUClassSearch

private enum Support {
    static func section(
        _ crn: String, _ subject: String, _ number: String, days: [Int], start: Double, end: Double,
        seats: Int = 10, waitlist: Int = 0
    ) -> CourseSection {
        let meeting = Meeting(
            days: DaySet(indices: days), start: Int(start * 60), end: Int(end * 60),
            buildingCode: "WVH", building: "West Village H", room: "210", campusCode: "BOS",
            kind: "Class", startDate: "2026-09-09", endDate: "2026-12-13"
        )
        return CourseSection(
            crn: crn, subject: subject, number: number, title: "\(subject) \(number)", sectionNumber: "01",
            partOfTerm: "1", seatCapacity: 40, seatsRemaining: seats, enrollment: 40 - seats,
            waitlistCapacity: waitlist, waitlistCount: 0, waitlistRemaining: waitlist, classType: "Lecture",
            honors: false, campus: "Boston", instructionMethod: "Traditional", meetings: [meeting],
            instructors: [], crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil
        )
    }

    static func course(_ subject: String, _ number: String, credits: Double = 4) -> Course {
        Course(
            subject: subject, number: number, title: "\(subject) \(number)", description: "",
            minCredits: credits, maxCredits: credits, attributes: [], prereqs: nil, coreqs: nil, postreqs: [],
            specialTopics: false, college: nil, department: nil, detailsLoaded: true
        )
    }

    static func banner(_ crn: String, _ subject: String, _ number: String, title: String) -> BannerSection {
        let json = """
        {"courseReferenceNumber":"\(crn)","courseNumber":"\(number)","subject":"\(subject)",\
        "sequenceNumber":"01","campusDescription":"Boston","scheduleTypeDescription":"Lecture",\
        "courseTitle":"\(title)","creditHours":4,"maximumEnrollment":40,"enrollment":10,"seatsAvailable":30}
        """
        return try! JSONDecoder().decode(BannerSection.self, from: Data(json.utf8))
    }

    static func index(courses: [Course], sections: [CourseSection]) -> CatalogIndex {
        CatalogIndex.build(TermCatalog(
            term: Term(code: "202710", bannerDescription: "Fall 2026 Semester"),
            courses: courses, sections: sections, subjects: [], attributes: [], campuses: []
        ))
    }

    static func plan(_ codes: [String], selected: [String] = []) -> SchedulePlan {
        var plan = SchedulePlan(name: "Plan A", termCode: "202710")
        for (offset, code) in codes.enumerated() {
            if let key = CourseKey(string: code) { plan.courses.append(PlanCourse(key: key, colorIndex: offset)) }
        }
        plan.selectedCRNs = selected
        return plan
    }

    /// Two courses whose only sections overlap, and a third that fits anywhere.
    static var clashingIndex: CatalogIndex {
        index(
            courses: [course("CS", "3000"), course("MATH", "2331"), course("ENGW", "1111")],
            sections: [
                section("A1", "CS", "3000", days: [1, 3], start: 10, end: 11.5),
                section("B1", "MATH", "2331", days: [1], start: 11, end: 12, seats: 0, waitlist: 5),
                section("C1", "ENGW", "1111", days: [2, 4], start: 13, end: 14.5),
            ]
        )
    }
}

struct ScheduleSupportTests {
    @Test func warningsListWhatNeedsAttention() {
        let index = Support.clashingIndex
        // CS and MATH overlap, MATH is full, ENGW has no section chosen.
        let resolved = ResolvedPlan(plan: Support.plan(["CS 3000", "MATH 2331", "ENGW 1111"], selected: ["A1", "B1"]), index: index)
        let texts = resolved.warnings.map(\.text)
        #expect(texts == ["1 conflict", "1 full section", "1 course needs a section"])
        #expect(resolved.warnings.first?.severity == .error)
        #expect(resolved.warnings.last?.severity == .neutral)
        // Without a catalog nothing can be said.
        #expect(ResolvedPlan(plan: Support.plan(["CS 3000"]), index: nil).warnings.isEmpty)
    }

    @Test func noticesExplainConflictsAndFullSections() {
        let index = Support.clashingIndex
        let resolved = ResolvedPlan(plan: Support.plan(["CS 3000", "MATH 2331"], selected: ["A1", "B1"]), index: index)
        let notices = ScheduleNotices.make(for: resolved, termName: "Fall 2026", catalogUnavailable: false)
        #expect(notices.map(\.id) == ["conflicts", "full"])
        #expect(notices[0].severity == .error)
        #expect(notices[0].title == "1 time conflict")
        #expect(notices[0].lines.first?.contains("CS 3000 overlaps MATH 2331") == true)
        #expect(notices[1].lines == ["MATH 2331 Lecture 01 is full · 5 waitlist spots left"])
        #expect(notices.allSatisfy { $0.fix == nil })
    }

    @Test func noticesOfferToForgetSectionsTheCatalogDoesNotList() {
        let index = Support.clashingIndex
        // 99999 isn't in the catalog; C1 is, but ENGW isn't in the plan any more.
        let resolved = ResolvedPlan(plan: Support.plan(["CS 3000"], selected: ["A1", "99999", "C1"]), index: index)
        let notices = ScheduleNotices.make(for: resolved, termName: "Fall 2026", catalogUnavailable: false)
        let ids = notices.map(\.id)
        #expect(ids.contains("unlisted"))
        #expect(ids.contains("orphaned"))
        #expect(notices.first { $0.id == "unlisted" }?.fix == .removeSections(["99999"]))
        #expect(notices.first { $0.id == "orphaned" }?.fix == .removeSections(["C1"]))
        #expect(notices.first { $0.id == "orphaned" }?.fixTitle == "Remove")
    }

    @Test func aMissingCatalogIsReportedOnceItIsKnownToBeMissing() {
        let resolved = ResolvedPlan(plan: Support.plan(["CS 3000"]), index: nil)
        #expect(ScheduleNotices.make(for: resolved, termName: "Spring 2027", catalogUnavailable: false).isEmpty)
        let notices = ScheduleNotices.make(for: resolved, termName: "Spring 2027", catalogUnavailable: true)
        #expect(notices.map(\.id) == ["catalog"])
        #expect(notices[0].title == "Course data for Spring 2027 isn’t on this device")
        // An empty schedule has nothing to miss.
        #expect(ScheduleNotices.make(for: ResolvedPlan(plan: Support.plan([]), index: nil), termName: "Spring 2027", catalogUnavailable: true).isEmpty)
    }

    @Test func favoritesAreMeasuredAndSkipWhenTheyCanNoLongerBeApplied() {
        let index = Support.clashingIndex
        var plan = Support.plan(["CS 3000", "ENGW 1111"])
        plan.favoriteCombinations = [
            ["A1", "C1"],            // fine
            ["A1", "GONE"],          // a section the catalog doesn't list
            ["B1", "C1"],            // MATH isn't in the plan
        ]
        let favorites = GeneratedSchedule.favorites(of: plan, index: index, preferences: SchedulePreferences())
        #expect(favorites.map(\.crns) == [["A1", "C1"]])
        #expect(favorites.first?.sortedCRNs == ["A1", "C1"])
    }

    @Test func favoritesComeNewestFirstInPlanOrder() {
        let index = Support.clashingIndex
        var plan = Support.plan(["ENGW 1111", "CS 3000"])
        plan.favoriteCombinations = [["A1"], ["C1", "A1"]]
        let favorites = GeneratedSchedule.favorites(of: plan, index: index, preferences: SchedulePreferences())
        #expect(favorites.map { Set($0.crns) } == [["A1", "C1"], ["A1"]])
        // The sections follow the order of the plan's courses.
        #expect(favorites.first?.crns == ["C1", "A1"])
    }

    @Test func courseInputsRoundCreditsUpAndKeepExclusions() {
        let index = Support.index(
            courses: [Support.course("CS", "3000", credits: 3.5), Support.course("MATH", "2331")],
            sections: [Support.section("A1", "CS", "3000", days: [1], start: 9, end: 10), Support.section("A2", "CS", "3000", days: [2], start: 9, end: 10)]
        )
        var plan = Support.plan(["CS 3000", "MATH 2331"])
        plan.courses[0].excludedCRNs = ["A2"]
        plan.courses[1].isRequired = false
        let inputs = ScheduleCourseInput.inputs(for: plan, index: index)
        #expect(inputs.map(\.key.description) == ["CS 3000", "MATH 2331"])
        #expect(inputs[0].minCredits == 4)
        #expect(inputs[0].sections.count == 2)
        #expect(inputs[0].excludedCRNs == ["A2"])
        #expect(inputs[1].isRequired == false)
        #expect(inputs[1].sections.isEmpty)
    }

    @Test func looseningARuleEditsThePlanOrItsPreferences() {
        var plan = Support.plan(["CS 3000", "MATH 2331"])
        plan.filters.earliestStart = 10 * 60
        plan.filters.freeDays = [.friday]
        var preferences = SchedulePreferences()
        preferences.daysOff = [.friday]
        preferences.daysOffStrength = .required
        plan.preferences = preferences

        PlanEditing.apply(.clearEarliestStart, to: &plan)
        #expect(plan.filters.earliestStart == nil)
        #expect(plan.filters.freeDays == [.friday])

        PlanEditing.apply(.makeOptional(CourseKey(subject: "CS", number: "3000")), to: &plan)
        #expect(plan.courses[0].isRequired == false)
        #expect(plan.courses[1].isRequired)

        PlanEditing.apply(.preference(.softenDaysOff), to: &plan)
        #expect(plan.preferences?.daysOffStrength == .preferred)

        // Loosening the last rule leaves nothing to store.
        var onlyBlock = Support.plan(["CS 3000"])
        var blockPreferences = SchedulePreferences()
        blockPreferences.maxClassesPerDay = 2
        onlyBlock.preferences = blockPreferences
        PlanEditing.apply(.preference(.clearMaxClassesPerDay), to: &onlyBlock)
        #expect(onlyBlock.preferences == nil)

        PlanEditing.makeOptional([CourseKey(subject: "CS", number: "3000"), CourseKey(subject: "MATH", number: "2331")], in: &plan)
        #expect(plan.courses.allSatisfy { !$0.isRequired })
    }

    @Test func noResultsWordingNamesWhatBlocksAndWhatWouldWork() {
        // CS 3000 and MATH 2331 each have one section, and the two overlap.
        let index = Support.clashingIndex
        let plan = Support.plan(["CS 3000", "MATH 2331"])
        let courses = ScheduleCourseInput.inputs(for: plan, index: index)
        let result = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        #expect(result.schedules.isEmpty)
        #expect(ScheduleNoResultsText.title(for: result.diagnostics) == "No schedule fits all 2 courses")

        let analysis = ScheduleGenerator.analyzeEmptyResult(
            courses: courses, filters: ScheduleFilters(), preferences: SchedulePreferences(), diagnostics: result.diagnostics
        )
        #expect(ScheduleNoResultsText.headline(for: result.diagnostics, blockers: analysis.blockers) == "Here’s what would work.")
        let reasons = ScheduleNoResultsText.reasons(for: result.diagnostics, termName: "Fall 2026")
        #expect(reasons.map(\.title) == ["CS 3000 and MATH 2331 always overlap"])
        let option = analysis.blockers.options.first
        #expect(option != nil)
        if let option {
            #expect(ScheduleNoResultsText.detail(of: option, blockers: analysis.blockers, termName: "Fall 2026").hasPrefix("1 schedule"))
        }
        #expect(ScheduleNoResultsText.list([CourseKey(subject: "CS", number: "3000"), CourseKey(subject: "MATH", number: "2331"), CourseKey(subject: "PHYS", number: "1151")]) == "CS 3000, MATH 2331 and PHYS 1151")
    }

    @Test func noResultsWordingSaysWhyEverySectionWasRuledOut() {
        let index = Support.clashingIndex
        let plan = Support.plan(["CS 3000"])
        var filters = ScheduleFilters()
        filters.earliestStart = 20 * 60
        let result = ScheduleGenerator.generate(courses: ScheduleCourseInput.inputs(for: plan, index: index), filters: filters)
        let reasons = ScheduleNoResultsText.reasons(for: result.diagnostics, termName: "Fall 2026")
        #expect(reasons.map(\.title) == ["No CS 3000 sections left"])
        #expect(reasons.first?.detail == "Its only section starts before 8:00 PM.")
    }

    @Test func uncertainReorderReasonsAreNotGoodNews() {
        #expect(ScheduleNoResultsText.isUncertain("Offering history unknown"))
        #expect(ScheduleNoResultsText.isUncertain("Couldn’t check the catalog"))
        #expect(!ScheduleNoResultsText.isUncertain("Offered every spring"))
    }

    @Test func blockedTimesReadAsTheyAreConfigured() {
        var block = BlockedTime(label: "Club", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60)
        #expect(block.listDetail == "Tue, Thu 6:00 – 8:00 PM")
        block.strength = .preferred
        #expect(block.listDetail == "Tue, Thu 6:00 – 8:00 PM · If I must")
        block.isEnabled = false
        #expect(block.listDetail == "Tue, Thu 6:00 – 8:00 PM · Off")
        #expect(BlockedTime(label: "", days: DaySet(), start: 600, end: 660).listDetail == "Choose the days")
        #expect(BlockedTime(label: "", days: [.monday], start: 700, end: 660).listDetail == "Check the times")
    }

    @Test func calendarLayoutFitsEverySchedule() {
        let early = GeneratedSchedule(sections: [Support.section("A", "CS", "1", days: [1], start: 8, end: 9)])
        let late = GeneratedSchedule(sections: [Support.section("B", "CS", "2", days: [6], start: 17, end: 20)])
        let layout = ScheduleCarouselLayout(schedules: [early, late], preferences: AppPreferences())
        #expect(layout.hours == 8...20)
        #expect(layout.days == [1, 2, 3, 4, 5, 6])
        #expect(ScheduleCarouselLayout(schedules: [], preferences: AppPreferences()).days == [1, 2, 3, 4, 5])
    }

    @Test func autofillSuggestionsComeFromTheDegreePlanAndOtherSchedules() {
        let index = Support.clashingIndex
        let target = Support.plan([])
        var sibling = Support.plan(["CS 3000", "ENGW 1111"])
        sibling.name = "Plan B"
        let suggestions = ScheduleAutofillSupport.suggestions(
            for: target, terms: [], degreePlans: [], schedulePlans: [sibling, target], index: index
        )
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.courses.map(\.description) == ["CS 3000", "ENGW 1111"])
        #expect(ScheduleAutofillSupport.sourceName(of: suggestions[0]) == "Copy “Plan B”")
        // Nothing to suggest from.
        #expect(ScheduleAutofillSupport.suggestions(for: target, terms: [], degreePlans: [], schedulePlans: [target], index: index).isEmpty)
        #expect(ScheduleAutofillSupport.courseCountLabel(1) == "1 course")
        #expect(ScheduleAutofillSupport.courseCountLabel(3) == "3 courses")
        let key = ScheduleAutofillSupport.dismissalKey(planID: target.id, suggestion: suggestions[0])
        let stored = ScheduleAutofillSupport.adding(key, to: "")
        #expect(ScheduleAutofillSupport.isDismissed(key, in: stored))
        #expect(!ScheduleAutofillSupport.isDismissed("other", in: stored))
    }

    @Test func draggedTextNamesCoursesAndSections() {
        let parsed = ScheduleDroppedCourse.parse(["CS 3000", "math 2331 12345\nPHYS 1151 99\nCS 3000", "Dr. Smith", "John Smith"])
        #expect(parsed.map(\.key.description) == ["CS 3000", "MATH 2331", "PHYS 1151"])
        #expect(parsed.map(\.crn) == [nil, "12345", nil])
        #expect(ScheduleDroppedCourse.parse([]).isEmpty)
        #expect(ScheduleDroppedCourse.parse(["hello"]).isEmpty)
    }

    /// Each pinned topic is its own prerequisite row. A later course that needs the number
    /// is satisfied by either one, and the two topics are not flagged as a repeat.
    @Test func twoTopicsEachKeepAPrerequisiteStatus() {
        let topics = CourseKey(subject: "CS", number: "4973")
        let laterKey = CourseKey(subject: "CS", number: "3500")
        var seminar = Support.course("CS", "4973")
        seminar.specialTopics = true
        seminar.title = "Seminar"
        var later = Support.course("CS", "3500")
        later.prereqs = .course(topics)
        later.title = "Object-Oriented Design"
        let index = Support.index(courses: [seminar, later], sections: [])
        let first = DegreePlanCourse(key: topics, title: "Seminar", credits: 4, crn: "11111")
        let second = DegreePlanCourse(key: topics, title: "Seminar", credits: 4, crn: "22222")
        let follow = DegreePlanCourse(key: laterKey, title: "Object-Oriented Design", credits: 4)
        var plan = DegreePlan(name: "Topics")
        plan.terms = [
            DegreePlanTerm(season: .fall, year: 2026, courses: [first, second]),
            DegreePlanTerm(season: .spring, year: 2027, courses: [follow]),
        ]
        let review = DegreePlanReview(
            plan: plan,
            catalog: DegreePlanCatalogSnapshot(indexes: [index], terms: [index.term])
        )
        #expect(review.duplicateCount == 0)
        #expect(review.status(for: first) == .met)
        #expect(review.status(for: second) == .met)
        #expect(review.status(for: follow) == .met)
        #expect(DegreePlanAnalysis.duplicateKeys(in: plan).isEmpty)
    }

    @Test func clockConvertsMinutesAndPickerDates() {
        for minutes in [0, 9 * 60 + 15, 23 * 60 + 59] {
            #expect(ScheduleClock.minutes(from: ScheduleClock.date(forMinutes: minutes)) == minutes)
        }
        // Out-of-range values are clamped to the day.
        #expect(ScheduleClock.minutes(from: ScheduleClock.date(forMinutes: 24 * 60)) == 24 * 60 - 1)
        #expect(ScheduleClock.minutes(from: ScheduleClock.date(forMinutes: -5)) == 0)
    }
}

// MARK: - Editing the course list

@MainActor
struct SchedulePlanActionsTests {
    private func store() -> (UserDataStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UserData-\(UUID().uuidString).json")
        return (UserDataStore(fileURL: url), url)
    }

    @Test func removingACourseTakesItsSectionsAndFavoritesAndUndoPutsThemBack() {
        let (userData, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let index = Support.clashingIndex
        let plan = userData.createPlan(name: "Plan A", termCode: "202710")
        for code in ["CS 3000", "MATH 2331", "ENGW 1111"] { userData.addCourse(CourseKey(string: code)!, toPlan: plan.id) }
        userData.updatePlan(id: plan.id) {
            $0.selectedCRNs = ["A1", "C1"]
            $0.favoriteCombinations = [["A1", "C1"], ["B1", "C1"]]
        }
        let current = userData.plan(id: plan.id)!
        let resolved = ResolvedPlan(plan: current, index: index)
        let entry = resolved.entry(for: CourseKey(string: "CS 3000")!)!

        let removal = SchedulePlanActions.removeCourse(entry, from: current, index: index, userData: userData)
        let after = userData.plan(id: plan.id)!
        #expect(after.courses.map(\.key.description) == ["MATH 2331", "ENGW 1111"])
        #expect(after.selectedCRNs == ["C1"])
        #expect(after.favoriteCombinations == [["B1", "C1"]])
        #expect(removal.index == 0)
        #expect(removal.selectedCRNs == ["A1"])

        userData.updatePlan(id: plan.id) { PlanEditing.restore(removal, in: &$0) }
        let restored = userData.plan(id: plan.id)!
        #expect(restored.courses.map(\.key.description) == ["CS 3000", "MATH 2331", "ENGW 1111"])
        #expect(Set(restored.selectedCRNs) == ["A1", "C1"])
        #expect(restored.favoriteCombinations.contains(["A1", "C1"]))
    }

    @Test func autofillAddsRequiredCoursesOnceAndUndoTakesThemOut() {
        let (userData, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = userData.createPlan(name: "Plan A", termCode: "202710")
        userData.addCourse(CourseKey(string: "CS 3000")!, toPlan: plan.id)
        let suggestion = ScheduleAutofillSuggestion(
            source: .schedulePlan(id: UUID()), planName: "Plan B", semester: nil, title: "Copy “Plan B”", detail: "",
            isExactTerm: false, courses: [CourseKey(string: "CS 3000")!, CourseKey(string: "ENGW 1111")!], unavailable: []
        )
        let added = SchedulePlanActions.addAutofill(suggestion, toPlan: plan.id, userData: userData)
        #expect(added.map(\.description) == ["ENGW 1111"])
        #expect(userData.plan(id: plan.id)?.courses.count == 2)
        #expect(userData.plan(id: plan.id)?.course(CourseKey(string: "ENGW 1111")!)?.isRequired == true)

        SchedulePlanActions.undoAutofill(added, planID: plan.id, index: Support.clashingIndex, userData: userData)
        #expect(userData.plan(id: plan.id)?.courses.map(\.key.description) == ["CS 3000"])
    }

    @Test func reorderingTheDegreePlanNeedsASemesterThatMatchesTheTerm() {
        let plan = Support.plan(["CS 3000"])
        var degreePlan = DegreePlan(name: "Plan")
        degreePlan.terms = [DegreePlanTerm(season: .fall, year: 2026, courses: [DegreePlanCourse(key: CourseKey(string: "CS 3000"), title: "Algorithms", credits: 4)])]
        let terms = [Term(code: "202710", bannerDescription: "Fall 2026 Semester")]
        let found = ScheduleReorderSuggestions.semester(for: plan, degreePlan: degreePlan, terms: terms, index: nil)
        #expect(found?.term.code == "202710")
        #expect(found?.plan.id == degreePlan.id)
        // A schedule for a term the degree plan has no semester for, or no degree plan at all.
        var spring = plan
        spring.termCode = "202730"
        #expect(ScheduleReorderSuggestions.semester(for: spring, degreePlan: degreePlan, terms: terms, index: nil) == nil)
        #expect(ScheduleReorderSuggestions.semester(for: plan, degreePlan: nil, terms: terms, index: nil) == nil)
    }

    /// CS 4973 is offered as two topics. Pinning one CRN, adopting a generated schedule,
    /// refreshing the catalog, and detaching the course for a reorganize must not switch topics.
    /// `setSection` is the edit that may change the pin.
    @Test func specialTopicsPinStaysOnItsCRN() {
        let topicA = Support.section("11111", "CS", "4973", days: [1], start: 9, end: 10)
        let topicB = Support.section("22222", "CS", "4973", days: [2], start: 9, end: 10)
        let math = Support.section("33333", "MATH", "2331", days: [3], start: 9, end: 10)
        let courses = [
            Course(subject: "CS", number: "4973", title: "Special Topics", description: "", minCredits: 4, maxCredits: 4,
                   attributes: [], prereqs: nil, coreqs: nil, postreqs: [], specialTopics: true, college: nil, department: nil, detailsLoaded: true),
            Support.course("MATH", "2331"),
        ]
        let index = Support.index(courses: courses, sections: [topicA, topicB, math])
        var plan = Support.plan(["CS 4973", "MATH 2331"], selected: ["11111"])

        PlanEditing.adoptGeneratedSchedule(["22222", "33333"], into: &plan, index: index)
        #expect(plan.selectedCRNs == ["11111", "33333"])

        let resolved = ResolvedPlan(plan: plan, index: index)
        #expect(resolved.entry(for: CourseKey(subject: "CS", number: "4973"))?.chosen?.crn == "11111")

        var catalog = TermCatalog(
            term: Term(code: "202710", bannerDescription: "Fall 2026 Semester"),
            courses: courses, sections: [topicA, topicB, math], subjects: [], attributes: [], campuses: []
        )
        CatalogBuilder.applyCourseRefresh(&catalog, course: CourseKey(subject: "CS", number: "4973"), banner: [
            Support.banner("22222", "CS", "4973", title: "Topic B"),
            Support.banner("11111", "CS", "4973", title: "Topic A"),
        ])
        let refreshed = CatalogIndex.build(catalog)
        let afterRefresh = ResolvedPlan(plan: plan, index: refreshed)
        #expect(afterRefresh.entry(for: CourseKey(subject: "CS", number: "4973"))?.chosen?.crn == "11111")
        #expect(!afterRefresh.selectedSections.map(\.crn).contains("22222"))

        CatalogBuilder.applyCourseRefresh(&catalog, course: CourseKey(subject: "CS", number: "4973"), banner: [
            Support.banner("22222", "CS", "4973", title: "Topic B"),
        ])
        let dropped = ResolvedPlan(plan: plan, index: CatalogIndex.build(catalog))
        #expect(dropped.unlistedCRNs == ["11111"])
        #expect(dropped.entry(for: CourseKey(subject: "CS", number: "4973"))?.chosen == nil)

        let detached = PlanEditing.selectedCRNs(plan.selectedCRNs, for: CourseKey(subject: "CS", number: "4973"), index: index)
        #expect(detached == ["11111"])
        var remaining = plan.selectedCRNs
        remaining.removeAll { detached.contains($0) }
        #expect(remaining == ["33333"])

        PlanEditing.setSection("22222", courseCRNs: Set(["11111", "22222"]), in: &plan)
        #expect(plan.selectedCRNs.contains("22222"))
        #expect(!plan.selectedCRNs.contains("11111"))
    }

    /// A second row of a number is allowed only when every row already has a different CRN.
    @Test func duplicateCourseNumbersNeedDistinctCRNs() {
        let key = CourseKey(subject: "CS", number: "4973")
        let sections: Set<String> = ["11111", "22222", "33333"]
        var plan = SchedulePlan(name: "Topics", termCode: "202710")

        #expect(plan.include(key: key, crn: nil) == .added)
        #expect(plan.include(key: key, crn: nil) == .alreadyPresent)
        #expect(plan.courses.count == 1)

        #expect(plan.include(key: key, crn: "22222", courseCRNs: sections) == .pinnedExisting)
        #expect(plan.courses.count == 1)
        #expect(plan.courses[0].pinnedCRN == "22222")
        #expect(plan.include(key: key, crn: "22222", courseCRNs: sections) == .alreadyPresent)
        #expect(plan.courses.count == 1)

        #expect(plan.include(key: key, crn: "11111", courseCRNs: sections) == .added)
        #expect(plan.courses.map(\.pinnedCRN) == ["22222", "11111"])

        let second = plan.courses[1].id
        PlanEditing.setSection("33333", courseCRNs: sections, entryID: second, in: &plan)
        #expect(plan.courses[0].pinnedCRN == "22222")
        #expect(plan.courses[1].pinnedCRN == "33333")
        #expect(plan.selectedCRNs.contains("22222"))
        #expect(plan.selectedCRNs.contains("33333"))
        #expect(!plan.selectedCRNs.contains("11111"))

        PlanEditing.setSection("22222", courseCRNs: sections, entryID: second, in: &plan)
        #expect(plan.courses[1].pinnedCRN == "33333")
        PlanEditing.setSection(nil, courseCRNs: sections, entryID: second, in: &plan)
        #expect(plan.courses[1].pinnedCRN == "33333")
    }

    /// Removing one topic leaves the other topic and its CRN.
    @Test func removingOneTopicLeavesItsSibling() {
        let (userData, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let key = CourseKey(subject: "CS", number: "4973")!
        let plan = userData.createPlan(name: "Topics", termCode: "202710")
        userData.includeCourse(key, crn: "11111", toPlan: plan.id)
        userData.includeCourse(key, crn: "22222", toPlan: plan.id)
        let current = userData.plan(id: plan.id)!
        let resolved = ResolvedPlan(plan: current, index: nil)
        let entry = resolved.entries.first { $0.planCourse.pinnedCRN == "11111" }!
        _ = SchedulePlanActions.removeCourse(entry, from: current, index: nil, userData: userData)
        let after = userData.plan(id: plan.id)!
        #expect(after.courses.map(\.pinnedCRN) == ["22222"])
        #expect(after.selectedCRNs == ["22222"])
    }

    /// A degree-plan draft keeps both pinned topics, and still keeps one row when neither has a CRN.
    @Test func degreePlanDraftKeepsDistinctTopics() {
        let key = CourseKey(subject: "CS", number: "4973")
        var schedule = SchedulePlan(name: "Plan A", termCode: "202730")
        schedule.isPrimary = true
        schedule.courses = [
            PlanCourse(key: key, colorIndex: 0, pinnedCRN: "11111"),
            PlanCourse(key: key, colorIndex: 1, pinnedCRN: "22222"),
        ]
        let draft = DegreePlanAutofill.newDegreePlanDraft(
            name: "Draft", basedOn: nil, schedulePlans: [schedule], catalogIndex: { _ in nil }
        )
        let copied = draft.terms.flatMap(\.courses)
        #expect(copied.map(\.crn).sorted() == ["11111", "22222"])
        #expect(copied.allSatisfy { $0.key == key })

        schedule.courses = [
            PlanCourse(key: key, colorIndex: 0),
            PlanCourse(key: key, colorIndex: 1),
        ]
        let merged = DegreePlanAutofill.newDegreePlanDraft(
            name: "Draft", basedOn: nil, schedulePlans: [schedule], catalogIndex: { _ in nil }
        )
        #expect(merged.terms.flatMap(\.courses).count == 1)
    }
}
