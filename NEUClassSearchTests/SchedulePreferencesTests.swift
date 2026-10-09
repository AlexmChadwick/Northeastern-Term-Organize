//
//  SchedulePreferencesTests.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Testing
@testable import NEUClassSearch

// MARK: - Fixtures

private enum Fixture {
    /// A section meeting on `days` (indices, 0 = Sunday) from `start` to `end` (hours).
    static func section(
        _ crn: String, _ subject: String, _ number: String, days: [Int], start: Double, end: Double,
        seats: Int = 10, capacity: Int = 40, waitlist: Int = 0, building: String = "WVH", campus: String = "Boston",
        method: String = "Traditional", instructors: [String] = [],
        startDate: String = "2026-09-09", endDate: String = "2026-12-13"
    ) -> CourseSection {
        let meeting = Meeting(
            days: DaySet(indices: days), start: Int(start * 60), end: Int(end * 60),
            buildingCode: building, building: "\(building) Hall", room: "210", campusCode: "BOS",
            kind: "Class", startDate: startDate, endDate: endDate
        )
        return CourseSection(
            crn: crn, subject: subject, number: number, title: "\(subject) \(number)", sectionNumber: "01",
            partOfTerm: "1", seatCapacity: capacity, seatsRemaining: seats, enrollment: capacity - seats,
            waitlistCapacity: waitlist, waitlistCount: 0, waitlistRemaining: waitlist, classType: "Lecture",
            honors: false, campus: campus, instructionMethod: method, meetings: [meeting],
            instructors: instructors.map { Instructor(name: $0, primary: true, email: nil) },
            crossListCRNs: [], attributes: [], description: nil, prereqs: nil, coreqs: nil
        )
    }

    static func course(
        _ subject: String, _ number: String, required: Bool = true, credits: Int = 4, _ sections: [CourseSection]
    ) -> ScheduleCourseInput {
        ScheduleCourseInput(
            key: CourseKey(subject: subject, number: number), isRequired: required, sections: sections,
            minCredits: credits, maxCredits: credits
        )
    }

    static func generate(
        _ courses: [ScheduleCourseInput], filters: ScheduleFilters = ScheduleFilters(),
        _ preferences: SchedulePreferences = SchedulePreferences(), sort: ScheduleSortOption = .best
    ) -> ScheduleGenerationResult {
        ScheduleGenerator.generate(courses: courses, filters: filters, preferences: preferences, sort: sort)
    }

    /// Every way the result's schedules combine sections, as sets of CRNs.
    static func crnSets(_ result: ScheduleGenerationResult) -> Set<Set<String>> {
        Set(result.schedules.map { Set($0.crns) })
    }

    static func hours(_ h: Double) -> Int { Int(h * 60) }
}

// MARK: - The model

struct SchedulePreferencesModelTests {
    @Test func defaultsHaveNoOpinions() {
        let p = SchedulePreferences()
        #expect(p.isDefault)
        #expect(p.activeCount == 0)
        #expect(p.summaryParts.isEmpty)
        #expect(p.summary() == "No preferences yet")
    }

    @Test func settingABandBackToOkayRestoresTheDefault() {
        var p = SchedulePreferences()
        p[.morning] = .prefer
        #expect(!p.isDefault)
        p[.morning] = .okay
        #expect(p.isDefault)
    }

    @Test func summaryReadsLikeTheBrief() {
        var p = SchedulePreferences()
        p[.earlyMorning] = .prefer
        p[.morning] = .prefer
        p.daysOff = [.friday]
        p.blockedTimes = [
            BlockedTime(label: "Club", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60),
            BlockedTime(label: "Work", days: [.monday], start: 13 * 60, end: 17 * 60),
        ]
        #expect(p.summaryParts == ["Mornings", "Fridays off", "2 blocked times"])
        #expect(p.summary() == "Mornings · Fridays off · 2 blocked times")
        p.dayLayout = .fewerDays
        #expect(p.summary(limit: 3) == "Mornings · Fridays off · Fewer days · +1")
    }

    @Test func summaryNamesTheDaysAndTimes() {
        var p = SchedulePreferences()
        p.daysOff = [.monday, .friday]
        p.earliestStart = TimeLimit(minutes: 10 * 60)
        p.latestEnd = TimeLimit(minutes: 17 * 60 + 30, strength: .preferred)
        #expect(p.summaryParts == ["Nothing before 10 AM", "Prefer done by 5:30 PM", "Mon & Fri off"])
        p[.evening] = .avoid
        p[.night] = .avoid
        #expect(p.summaryParts.first == "No evenings")
    }

    @Test func disabledBlocksDontCount() {
        var p = SchedulePreferences()
        p.blockedTimes = [BlockedTime(label: "Work", days: [.monday], start: 600, end: 700, isEnabled: false)]
        #expect(p.activeBlockedTimes.isEmpty)
        #expect(p.activeCount == 0)
        #expect(p.summaryParts.isEmpty)
        #expect(!p.isDefault, "A switched-off block is still the student's data")
    }

    @Test func everyWishShowsUpInTheSummary() {
        // `hasWishes` and the summary must agree, or a screen shows "no preferences" for a wish that is set.
        var wishes: [SchedulePreferences] = []
        func with(_ change: (inout SchedulePreferences) -> Void) {
            var p = SchedulePreferences()
            change(&p)
            wishes.append(p)
        }
        with { $0[.night] = .avoid }
        with { $0.earliestStart = TimeLimit(minutes: 600) }
        with { $0.latestEnd = TimeLimit(minutes: 1_020, strength: .preferred) }
        with { $0.daysOff = [.friday] }
        with { $0.dayLayout = .spreadOut }
        with { $0.maxClassesPerDay = 2 }
        with { $0.maxMinutesPerDay = 240 }
        with { $0.gaps = .fine }
        with { $0.gaps = .compact }
        with { $0.breaks = .avoidBackToBack }
        with { $0.breaks = .atLeast }
        with { $0.lunch = LunchBreak() }
        with { $0.blockedTimes = [BlockedTime(label: "Work", days: [.monday], start: 600, end: 700)] }
        with { $0.format = .online }
        with { $0.campus = "Boston" }
        with { $0.seats = .waitlistOK }
        with { $0.preferredInstructors = ["Smith, Alex"] }
        with { $0.avoidedInstructors = ["Jones, Sam"] }
        with { $0.creditTarget = CreditTarget(lower: 16, upper: 18) }
        for p in wishes {
            #expect(p.hasWishes)
            #expect(!p.summaryParts.isEmpty, "\(p) has a wish the summary doesn't mention")
            #expect(p.activeCount > 0)
        }
        #expect(!SchedulePreferences().hasWishes)
    }

    @Test func presetsToggleAndCombine() {
        var p = SchedulePreferences()
        p = SchedulePreset.morningPerson.toggled(in: p)
        #expect(SchedulePreset.morningPerson.isApplied(to: p))
        #expect(p[.morning] == .prefer && p[.night] == .avoid)

        p = SchedulePreset.longWeekends.toggled(in: p)
        #expect(SchedulePreset.longWeekends.isApplied(to: p))
        #expect(SchedulePreset.morningPerson.isApplied(to: p), "Presets only touch their own wishes")
        #expect(p.daysOff.contains(.friday))
        #expect(p.dayLayout == .fewerDays)

        p = SchedulePreset.nightOwl.toggled(in: p)
        #expect(SchedulePreset.nightOwl.isApplied(to: p))
        #expect(!SchedulePreset.morningPerson.isApplied(to: p))
        #expect(p[.morning] == .avoid && p[.evening] == .prefer)

        p = SchedulePreset.nightOwl.toggled(in: p)
        p = SchedulePreset.longWeekends.toggled(in: p)
        #expect(p.isDefault, "Switching every preset off leaves nothing behind")
    }

    @Test func compactDaysSetsLayoutAndGaps() {
        var p = SchedulePreferences()
        p = SchedulePreset.compactDays.toggled(in: p)
        #expect(p.dayLayout == .fewerDays && p.gaps == .compact)
        p = SchedulePreset.compactDays.toggled(in: p)
        #expect(p.isDefault)
    }

    @Test func normalizingDropsWhatCantBeApplied() {
        var p = SchedulePreferences()
        p.earliestStart = TimeLimit(minutes: 600)
        p.latestEnd = TimeLimit(minutes: 540)
        p.maxClassesPerDay = 0
        p.maxMinutesPerDay = 10
        p.minimumBreakMinutes = 1_000
        p.lunch = LunchBreak(start: 700, end: 705, minutes: 600)
        p.blockedTimes = [
            BlockedTime(label: "  ", days: [.monday], start: 600, end: 700),
            BlockedTime(label: "No days", days: DaySet(), start: 600, end: 700),
            BlockedTime(label: "Backwards", days: [.monday], start: 700, end: 600),
            BlockedTime(label: "Club", days: [.tuesday], start: 600, end: 700),
            BlockedTime(label: "club", days: [.tuesday], start: 600, end: 700),
        ]
        p.preferredInstructors = ["Smith, Alex", " smith, alex ", ""]
        p.avoidedInstructors = ["Smith, Alex", "Jones, Sam"]
        p.creditTarget = CreditTarget(lower: 40, upper: 50)

        let n = p.normalized()
        #expect(n.latestEnd == TimeLimit(minutes: 540), "A finish before the start is kept: the generator says no schedule fits")
        #expect(n.maxClassesPerDay == nil)
        #expect(n.maxMinutesPerDay == nil)
        #expect(n.minimumBreakMinutes == 90)
        #expect(n.lunch.map { $0.end - $0.start >= $0.minutes } == true)
        #expect(n.blockedTimes.map { $0.label } == ["Blocked time", "Club"])
        #expect(n.preferredInstructors == ["Smith, Alex"])
        #expect(n.avoidedInstructors == ["Jones, Sam"], "An instructor can't be both preferred and avoided")
        #expect(n.creditTarget?.upper == 30)
    }

    @Test func changedFieldsListWhatDiffers() {
        let old = SchedulePreferences()
        var new = old
        new[.morning] = .avoid
        new.earliestStart = TimeLimit(minutes: 600)
        new.daysOff = [.friday]
        let block = BlockedTime(label: "Club", days: [.tuesday], start: 1_080, end: 1_200)
        new.blockedTimes = [block]
        new.lunch = LunchBreak()
        let changed = new.changedFields(from: old)
        #expect(changed == [.timeOfDay(.morning), .earliestStart, .daysOff, .blockedTime(block.id), .lunch])
        #expect(new.changedFields(from: new).isEmpty)
    }
}

// MARK: - Saving

struct SchedulePreferencesCodingTests {
    private func fullyLoaded() -> SchedulePreferences {
        var p = SchedulePreferences()
        p[.earlyMorning] = .avoid
        p[.afternoon] = .prefer
        p.earliestStart = TimeLimit(minutes: 600, strength: .preferred)
        p.latestEnd = TimeLimit(minutes: 1_020)
        p.daysOff = [.friday, .monday]
        p.daysOffStrength = .required
        p.dayLayout = .spreadOut
        p.maxClassesPerDay = 3
        p.maxMinutesPerDay = 300
        p.gaps = .compact
        p.breaks = .atLeast
        p.minimumBreakMinutes = 20
        p.minimumBreakStrength = .required
        p.lunch = LunchBreak(start: 690, end: 840, minutes: 45)
        p.blockedTimes = [
            BlockedTime(label: "Robotics club", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60),
            BlockedTime(label: "Work", days: [.monday], start: 13 * 60, end: 17 * 60, strength: .preferred, isEnabled: false),
        ]
        p.format = .hybrid
        p.formatStrength = .required
        p.campus = "Boston"
        p.campusStrength = .required
        p.seats = .waitlistOK
        p.preferredInstructors = ["Smith, Alex"]
        p.avoidedInstructors = ["Jones, Sam"]
        p.creditTarget = CreditTarget(lower: 16, upper: 18)
        return p
    }

    @Test func roundTrips() throws {
        let original = fullyLoaded()
        let data = try JSONEncoder.userData.encode(original)
        let decoded = try JSONDecoder.userData.decode(SchedulePreferences.self, from: data)
        #expect(decoded == original)
    }

    @Test func anEmptyObjectDecodesToTheDefaults() throws {
        let decoded = try JSONDecoder.userData.decode(SchedulePreferences.self, from: Data("{}".utf8))
        #expect(decoded.isDefault)
    }

    @Test func unknownAndDamagedValuesFallBackInsteadOfFailing() throws {
        let json = """
        {
          "timeOfDay": {"morning": "prefer", "brunch": "prefer", "night": "sometimes"},
          "dayLayout": "teleport",
          "earliestStart": {"minutes": "soon"},
          "daysOff": 32,
          "maxClassesPerDay": 3,
          "blockedTimes": [
            {"label": "Club", "days": 20, "start": 1080, "end": 1200},
            "garbage",
            {"label": 7}
          ],
          "futureField": [1, 2, 3]
        }
        """
        let decoded = try JSONDecoder.userData.decode(SchedulePreferences.self, from: Data(json.utf8))
        #expect(decoded[.morning] == .prefer)
        #expect(decoded[.night] == .okay, "A value this version doesn't know is ignored")
        #expect(decoded.dayLayout == .noPreference)
        #expect(decoded.earliestStart == nil)
        #expect(decoded.daysOff == [.friday])
        #expect(decoded.maxClassesPerDay == 3)
        #expect(decoded.blockedTimes.first(where: { $0.label == "Club" })?.days == DaySet(rawValue: 20))
        #expect(decoded.activeBlockedTimes.map { $0.label } == ["Club"], "The damaged blocks never become active")
    }

    @Test func plansSavedBeforePreferencesExistStillLoad() throws {
        // A plan as an older version wrote it: no `preferences` key.
        var plan = SchedulePlan(name: "Plan A", termCode: "202730")
        plan.courses = [PlanCourse(key: CourseKey(subject: "CS", number: "3000"), colorIndex: 0)]
        let encoded = try JSONEncoder.userData.encode(plan)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["preferences"] == nil, "Plans without preferences don't write the key")
        object.removeValue(forKey: "preferences")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.userData.decode(SchedulePlan.self, from: old)
        #expect(decoded.name == "Plan A")
        #expect(decoded.preferences == nil)
        #expect(decoded.courses.count == 1)
    }

    @Test func planPreferencesSurviveASaveAndLoad() throws {
        let preferences = fullyLoaded()
        var plan = SchedulePlan(name: "Plan B", termCode: "202730")
        plan.preferences = preferences
        var data = UserData()
        data.plans = [plan]
        let decoded = try JSONDecoder.userData.decode(UserData.self, from: try JSONEncoder.userData.encode(data))
        #expect(decoded.plans.count == 1)
        #expect(decoded.plans.first?.preferences == preferences)
    }

    @MainActor
    @Test func theStoreSavesPreferencesWithThePlan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UserData-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = fullyLoaded()
        let store = UserDataStore(fileURL: url)
        let plan = store.createPlan(name: "Fall", termCode: "202710")
        let other = store.createPlan(name: "Other", termCode: "202710")
        store.updatePlan(id: plan.id) { $0.preferences = preferences }
        store.flushNow()

        let reloaded = UserDataStore(fileURL: url)
        #expect(reloaded.plan(id: plan.id)?.preferences == preferences)
        #expect(reloaded.plan(id: other.id)?.preferences == nil, "Preferences belong to one schedule")
        // Duplicating a schedule copies its preferences with it.
        let copy = try #require(reloaded.duplicatePlan(id: plan.id))
        #expect(reloaded.plan(id: copy.id)?.preferences == preferences)
    }

    @Test func preferencesOfAnyShapeNeverTakeTheScheduleDown() throws {
        let plan = SchedulePlan(name: "Plan D", termCode: "202730")
        let object = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder.userData.encode(plan)) as? [String: Any])
        for garbage: Any in [7, "text", [1, 2, 3], true] {
            var damaged = object
            damaged["preferences"] = garbage
            let data = try JSONSerialization.data(withJSONObject: damaged)
            let decoded = try JSONDecoder.userData.decode(SchedulePlan.self, from: data)
            #expect(decoded.name == "Plan D")
            #expect(decoded.preferences?.isDefault ?? true)
        }
        // And inside a whole save file: one odd schedule doesn't lose the others.
        var other = object
        other["preferences"] = "text"
        let file: [String: Any] = ["version": 1, "plans": [object, other]]
        let decoded = try JSONDecoder.userData.decode(UserData.self, from: try JSONSerialization.data(withJSONObject: file))
        #expect(decoded.plans.count == 2)
    }

    @Test func damagedPreferencesNeverTakeTheScheduleDown() throws {
        let plan = SchedulePlan(name: "Plan C", termCode: "202730")
        var object = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder.userData.encode(plan)) as? [String: Any])
        object["preferences"] = ["timeOfDay": 7, "blockedTimes": "nope", "campus": 3]
        let damaged = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder.userData.decode(SchedulePlan.self, from: damaged)
        #expect(decoded.name == "Plan C")
        #expect(decoded.preferences?.isDefault == true)
    }
}

// MARK: - Hard rules

struct SchedulePreferencesFilterTests {
    private typealias F = Fixture

    @Test func aBlockedTimeRemovesSectionsThatOverlapIt() {
        let course = F.course("CS", "3000", [
            F.section("EVE", "CS", "3000", days: [2, 4], start: 18, end: 19.5),
            F.section("DAY", "CS", "3000", days: [1, 3, 5], start: 10, end: 11),
            F.section("LATE", "CS", "3000", days: [2, 4], start: 20, end: 21),
        ])
        var p = SchedulePreferences()
        p.blockedTimes = [BlockedTime(label: "Club meeting", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60)]
        let result = F.generate([course], p)
        // LATE starts exactly when the club meeting ends, which is fine.
        #expect(F.crnSets(result) == [["DAY"], ["LATE"]])
        #expect(F.generate([course]).totalFound == 3)
    }

    @Test func blockedTimesOnlyApplyOnTheirDaysAndHours() {
        let course = F.course("CS", "3000", [
            F.section("MON", "CS", "3000", days: [1], start: 18, end: 19.5),
            F.section("TUE", "CS", "3000", days: [2], start: 18, end: 19.5),
            F.section("EARLY", "CS", "3000", days: [2], start: 16, end: 18),
            F.section("OVER", "CS", "3000", days: [2], start: 19.5, end: 21),
        ])
        var p = SchedulePreferences()
        p.blockedTimes = [BlockedTime(label: "Club", days: [.tuesday], start: 18 * 60, end: 20 * 60)]
        let result = F.generate([course], p)
        // Ending exactly when the block starts is fine; touching its far edge is not.
        #expect(F.crnSets(result) == [["MON"], ["EARLY"]])
    }

    @Test func aSwitchedOffBlockIsIgnored() {
        let course = F.course("CS", "3000", [F.section("A", "CS", "3000", days: [2], start: 18, end: 19)])
        var p = SchedulePreferences()
        p.blockedTimes = [BlockedTime(label: "Club", days: [.tuesday], start: 18 * 60, end: 20 * 60, isEnabled: false)]
        #expect(F.generate([course], p).totalFound == 1)
    }

    @Test func aPreferredBlockOnlyRanksLower() {
        let course = F.course("CS", "3000", [
            F.section("CLASH", "CS", "3000", days: [2], start: 18, end: 19),
            F.section("FREE", "CS", "3000", days: [3], start: 18, end: 19),
        ])
        var p = SchedulePreferences()
        p.blockedTimes = [BlockedTime(label: "Club", days: [.tuesday], start: 18 * 60, end: 20 * 60, strength: .preferred)]
        let result = F.generate([course], p)
        #expect(result.schedules.map { $0.crns } == [["FREE"], ["CLASH"]])
        #expect(result.schedules.last?.reasons.contains(where: { $0.isCaveat && $0.text == "Overlaps Club" }) == true)
    }

    @Test func daysOffAreHardOnlyWhenRequired() {
        let course = F.course("CS", "3000", [
            F.section("FRI", "CS", "3000", days: [5], start: 10, end: 11),
            F.section("TUE", "CS", "3000", days: [2], start: 10, end: 11),
        ])
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        p.daysOffStrength = .required
        #expect(F.generate([course], p).schedules.map { $0.crns } == [["TUE"]])
        p.daysOffStrength = .preferred
        #expect(F.generate([course], p).schedules.map { $0.crns } == [["TUE"], ["FRI"]])
    }

    @Test func earliestStartAndLatestEndFilterWhenRequired() {
        let course = F.course("CS", "3000", [
            F.section("EARLY", "CS", "3000", days: [1], start: 8, end: 9.5),
            F.section("MID", "CS", "3000", days: [2], start: 10, end: 11.5),
            F.section("LATE", "CS", "3000", days: [3], start: 16, end: 18.5),
        ])
        var p = SchedulePreferences()
        p.earliestStart = TimeLimit(minutes: 10 * 60)
        #expect(F.crnSets(F.generate([course], p)) == [["MID"], ["LATE"]])
        p.latestEnd = TimeLimit(minutes: 17 * 60)
        #expect(F.crnSets(F.generate([course], p)) == [["MID"]])
    }

    @Test func softLimitsRankByHowFarOutsideTheyAre() {
        let course = F.course("CS", "3000", [
            F.section("VERY", "CS", "3000", days: [1], start: 8, end: 9),
            F.section("SLIGHTLY", "CS", "3000", days: [2], start: 9.75, end: 11),
            F.section("OK", "CS", "3000", days: [3], start: 10, end: 11),
        ])
        var p = SchedulePreferences()
        p.earliestStart = TimeLimit(minutes: 10 * 60, strength: .preferred)
        #expect(F.generate([course], p).schedules.map { $0.crns } == [["OK"], ["SLIGHTLY"], ["VERY"]])
    }

    @Test func requiredFormatSeatsAndCampusFilter() {
        let course = F.course("CS", "3000", [
            F.section("INPERSON", "CS", "3000", days: [1], start: 9, end: 10),
            F.section("HYBRID", "CS", "3000", days: [2], start: 9, end: 10, method: "Hybrid"),
            F.section("ONLINE", "CS", "3000", days: [3], start: 9, end: 10, campus: "Online", method: "Online"),
            F.section("FULL", "CS", "3000", days: [4], start: 9, end: 10, seats: 0, waitlist: 5),
            F.section("FULLNOLIST", "CS", "3000", days: [5], start: 9, end: 10, seats: 0),
            F.section("OAKLAND", "CS", "3000", days: [1], start: 12, end: 13, campus: "Oakland, CA"),
        ])
        var p = SchedulePreferences()
        p.format = .inPerson
        p.formatStrength = .required
        #expect(F.crnSets(F.generate([course], p)) == [["INPERSON"], ["FULL"], ["FULLNOLIST"], ["OAKLAND"]])

        p.seats = .openOnly
        #expect(F.crnSets(F.generate([course], p)) == [["INPERSON"], ["OAKLAND"]])

        p.seats = .waitlistOK
        #expect(F.crnSets(F.generate([course], p)) == [["INPERSON"], ["FULL"], ["OAKLAND"]])

        p.campus = "Boston"
        p.campusStrength = .required
        #expect(F.crnSets(F.generate([course], p)) == [["INPERSON"], ["FULL"]])
    }

    @Test func sectionsWithoutASeatLimitAreNeverFull() {
        let course = F.course("CS", "3000", [F.section("OPEN", "CS", "3000", days: [1], start: 9, end: 10, seats: 0, capacity: 0)])
        var p = SchedulePreferences()
        p.seats = .openOnly
        #expect(F.generate([course], p).totalFound == 1)
    }

    @Test func maxClassesPerDayLimitsHowManySectionsShareADay() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 8, end: 9)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 10, end: 11), F.section("B2", "B", "1", days: [2], start: 10, end: 11)]),
            F.course("C", "1", [F.section("C1", "C", "1", days: [1], start: 12, end: 13), F.section("C2", "C", "1", days: [3], start: 12, end: 13)]),
        ]
        #expect(F.generate(courses).totalFound == 4)
        var p = SchedulePreferences()
        p.maxClassesPerDay = 2
        // A is always on Monday, so B and C can't both join it there.
        #expect(F.crnSets(F.generate(courses, p)) == [["A1", "B1", "C2"], ["A1", "B2", "C1"], ["A1", "B2", "C2"]])
        p.maxClassesPerDay = 1
        #expect(F.crnSets(F.generate(courses, p)) == [["A1", "B2", "C2"]])
    }

    @Test func maxMinutesPerDayLimitsClassTimeOnOneDay() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 11)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 13, end: 15), F.section("B2", "B", "1", days: [2], start: 13, end: 15)]),
        ]
        var p = SchedulePreferences()
        p.maxMinutesPerDay = 3 * 60
        #expect(F.crnSets(F.generate(courses, p)) == [["A1", "B2"]])
        p.maxMinutesPerDay = 90
        #expect(F.generate(courses, p).totalFound == 0, "A 2-hour class can never fit a 90 minute day")
        #expect(F.generate(courses, p).diagnostics.courses.first?.rejections[.prefWorkload] == 1)
    }

    @Test func requiredWalkingTimeOnlyMattersBetweenBuildings() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10, building: "RY")]),
            F.course("B", "1", [
                F.section("SAME", "B", "1", days: [1], start: 10.1, end: 11, building: "RY"),
                F.section("NEAR", "B", "1", days: [1], start: 10.1, end: 11, building: "SL"),
                F.section("FAR", "B", "1", days: [1], start: 10.5, end: 11.5, building: "SL"),
                F.section("OTHERDAY", "B", "1", days: [2], start: 10.1, end: 11, building: "SL"),
            ]),
        ]
        var p = SchedulePreferences()
        p.breaks = .atLeast
        p.minimumBreakMinutes = 15
        p.minimumBreakStrength = .required
        // A ends at 10:00. NEAR starts 6 minutes later in another building; SAME is in the same building.
        #expect(F.crnSets(F.generate(courses, p)) == [["A1", "SAME"], ["A1", "FAR"], ["A1", "OTHERDAY"]])
        let blocked = F.generate(courses, p)
        #expect(blocked.diagnostics.conflictingPairs.isEmpty)
    }

    @Test func aTightWalkIsReportedWhenItIsTheOnlyProblem() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10, building: "RY")]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 10.1, end: 11, building: "SL")]),
        ]
        var p = SchedulePreferences()
        p.breaks = .atLeast
        p.minimumBreakMinutes = 15
        p.minimumBreakStrength = .required
        let result = F.generate(courses, p)
        #expect(result.totalFound == 0)
        #expect(result.diagnostics.conflictingPairs.map { $0.reason } == [.travelTime])
        p.minimumBreakStrength = .preferred
        let relaxed = F.generate(courses, p)
        #expect(relaxed.totalFound == 1)
        #expect(relaxed.schedules.first?.reasons.contains(where: { $0.isCaveat && $0.text == "Tight between buildings" }) == true)
    }

    @Test func halfTermSectionsAtTheSameTimeStillDontConflictWithPreferences() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1, 3], start: 10, end: 11.5, startDate: "2026-09-09", endDate: "2026-10-23")]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1, 3], start: 10, end: 11.5, startDate: "2026-10-26", endDate: "2026-12-13")]),
        ]
        var p = SchedulePreferences()
        p[.morning] = .prefer
        p.maxClassesPerDay = 3
        p.breaks = .atLeast
        p.minimumBreakStrength = .required
        #expect(F.generate(courses, p).totalFound == 1)
        #expect(F.generate(courses).totalFound == 1)
    }

    @Test func requiredCoursesAreStillRequired() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 9, end: 10)]),
        ]
        var p = SchedulePreferences()
        p[.morning] = .prefer
        #expect(F.generate(courses, p).totalFound == 0)
    }

    @Test func creditTargetsReplaceTheMaximalRule() {
        // Required A is 4 credits; optional B and C are 4 each and always fit.
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", required: false, [F.section("B1", "B", "1", days: [2], start: 9, end: 10)]),
            F.course("C", "1", required: false, [F.section("C1", "C", "1", days: [3], start: 9, end: 10)]),
        ]
        #expect(F.crnSets(F.generate(courses)) == [["A1", "B1", "C1"]], "Without a target only maximal schedules count")

        var p = SchedulePreferences()
        p.creditTarget = CreditTarget(lower: 8, upper: 8)
        #expect(F.crnSets(F.generate(courses, p)) == [["A1", "B1"], ["A1", "C1"]])
        p.creditTarget = CreditTarget(lower: 4, upper: 8)
        #expect(F.crnSets(F.generate(courses, p)) == [["A1"], ["A1", "B1"], ["A1", "C1"]])
        p.creditTarget = CreditTarget(lower: 12, upper: 16)
        #expect(F.crnSets(F.generate(courses, p)) == [["A1", "B1", "C1"]])
    }

    @Test func impossibleCreditTargetsAreExplained() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", required: false, [F.section("B1", "B", "1", days: [2], start: 9, end: 10)]),
        ]
        var p = SchedulePreferences()
        p.creditTarget = CreditTarget(lower: 2, upper: 3)
        #expect(F.generate(courses, p).diagnostics.countProblem == .creditsOverTarget(required: 4, limit: 3))
        p.creditTarget = CreditTarget(lower: 12, upper: 14)
        #expect(F.generate(courses, p).diagnostics.countProblem == .creditsUnderTarget(available: 8, wanted: 12))
    }

    @Test func diagnosticsNameThePreferenceThatRemovedSections() {
        let course = F.course("CS", "3000", [
            F.section("A", "CS", "3000", days: [2], start: 18, end: 19),
            F.section("B", "CS", "3000", days: [4], start: 18.5, end: 19.5),
        ])
        var p = SchedulePreferences()
        p.blockedTimes = [BlockedTime(label: "Club", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60)]
        let result = F.generate([course], p)
        #expect(result.totalFound == 0)
        let report = result.diagnostics.courses.first
        #expect(report?.isBlocked == true)
        #expect(report?.rejections[.blockedTime] == 2)
    }

    @Test func relaxationsOfferToSoftenWhatIsInTheWay() {
        let course = F.course("CS", "3000", [F.section("A", "CS", "3000", days: [2], start: 18, end: 19)])
        var p = SchedulePreferences()
        let block = BlockedTime(label: "Club", days: [.tuesday], start: 18 * 60, end: 20 * 60)
        p.blockedTimes = [block]
        p.earliestStart = TimeLimit(minutes: 20 * 60)
        let suggestions = ScheduleGenerator.suggestRelaxations(courses: [course], filters: ScheduleFilters(), preferences: p)
        // Softening only one of the two rules isn't enough.
        #expect(suggestions.isEmpty)

        p.earliestStart = nil
        let single = ScheduleGenerator.suggestRelaxations(courses: [course], filters: ScheduleFilters(), preferences: p)
        #expect(single.map { $0.relaxation } == [.preference(.softenBlockedTime(id: block.id, label: "Club"))])

        var relaxed = p
        single[0].relaxation.apply(to: &relaxed)
        #expect(relaxed.blockedTimes.first?.strength == .preferred)
        #expect(F.generate([course], relaxed).totalFound == 1)
    }
}

// MARK: - Ranking

struct SchedulePreferencesRankingTests {
    private typealias F = Fixture

    private var morningOrNight: ScheduleCourseInput {
        F.course("CS", "3000", [
            F.section("NIGHT", "CS", "3000", days: [2, 4], start: 19, end: 20.5),
            F.section("MORNING", "CS", "3000", days: [2, 4], start: 9.5, end: 11),
            F.section("AFTERNOON", "CS", "3000", days: [2, 4], start: 14.5, end: 16),
        ])
    }

    @Test func withoutPreferencesTheDefaultOrderIsUnchanged() {
        let result = F.generate([morningOrNight])
        // Ending after 5 PM costs points in the default ranking.
        #expect(result.schedules.map { $0.crns.first ?? "" }.last == "NIGHT")
        #expect(result.schedules.allSatisfy { $0.reasons.isEmpty })
    }

    @Test func aMorningPersonSeesMorningsFirstAndANightOwlSeesNightsFirst() {
        var morning = SchedulePreferences()
        morning = SchedulePreset.morningPerson.toggled(in: morning)
        #expect(F.generate([morningOrNight], morning).schedules.map { $0.crns.first ?? "" } == ["MORNING", "AFTERNOON", "NIGHT"])

        var night = SchedulePreferences()
        night = SchedulePreset.nightOwl.toggled(in: night)
        let order = F.generate([morningOrNight], night).schedules.map { $0.crns.first ?? "" }
        #expect(order.first == "NIGHT")
        #expect(order.last == "MORNING")
    }

    @Test func avoidingEarlyMorningsPutsThemLast() {
        let course = F.course("CS", "3000", [
            F.section("EIGHT", "CS", "3000", days: [1, 3, 5], start: 8, end: 9),
            F.section("NOON", "CS", "3000", days: [1, 3, 5], start: 12, end: 13),
        ])
        var p = SchedulePreferences()
        p[.earlyMorning] = .avoid
        #expect(F.generate([course], p).schedules.map { $0.crns.first ?? "" } == ["NOON", "EIGHT"])
        // The default ranking dislikes 8 AMs too, so check the wish alone can overcome a nudge the other way.
        let eightOnly = F.course("CS", "3000", [
            F.section("EIGHT", "CS", "3000", days: [2], start: 8, end: 9),
            F.section("NINEFIFTEEN", "CS", "3000", days: [2, 4, 5], start: 9.25, end: 10.25),
        ])
        p = SchedulePreferences()
        p[.earlyMorning] = .prefer
        #expect(F.generate([eightOnly], p).schedules.first?.crns == ["EIGHT"])
    }

    @Test func aWishedForDayOffBeatsEverythingElseTheDefaultRankingLikes() {
        let course = F.course("CS", "3000", [
            F.section("ONEDAY", "CS", "3000", days: [5], start: 9, end: 10),
            F.section("TWODAYS", "CS", "3000", days: [2, 4], start: 9, end: 10),
        ])
        #expect(F.generate([course]).schedules.first?.crns == ["ONEDAY"], "The default ranking prefers fewer days")
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        #expect(F.generate([course], p).schedules.first?.crns == ["TWODAYS"])
    }

    @Test func fewerDaysAndSpreadOutPullInOppositeDirections() {
        let course = F.course("CS", "3000", [
            F.section("TWO", "CS", "3000", days: [2, 4], start: 9, end: 11),
            F.section("FIVE", "CS", "3000", days: [1, 2, 3, 4, 5], start: 9, end: 9.8),
        ])
        var few = SchedulePreferences()
        few.dayLayout = .fewerDays
        #expect(F.generate([course], few).schedules.first?.crns == ["TWO"])
        var spread = SchedulePreferences()
        spread.dayLayout = .spreadOut
        #expect(F.generate([course], spread).schedules.first?.crns == ["FIVE"])
    }

    @Test func protectingLunchRanksFreeLunchesFirst() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1, 3], start: 9, end: 10.5)]),
            F.course("B", "1", [
                // Leaves 15 minutes of the 11:30 – 2 PM window; FREE leaves all of it.
                F.section("BUSY", "B", "1", days: [1, 3], start: 11.75, end: 13.75),
                F.section("FREE", "B", "1", days: [1, 3], start: 14, end: 15.5),
            ]),
        ]
        var p = SchedulePreferences()
        p.lunch = LunchBreak(start: 11 * 60 + 30, end: 14 * 60, minutes: 45)
        let result = F.generate(courses, p)
        #expect(result.schedules.first.map { Set($0.crns) } == ["A1", "FREE"])
        #expect(result.schedules.first?.reasons.contains(where: { $0.text == "Lunch free every day" }) == true)
        #expect(result.schedules.last?.reasons.contains(where: { $0.text == "Lunch often busy" }) == true)
    }

    @Test func avoidingBackToBackPrefersRealBreaks() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [
                F.section("TIGHT", "B", "1", days: [1], start: 10.1, end: 11),
                F.section("SPACED", "B", "1", days: [1], start: 11, end: 12),
            ]),
        ]
        var p = SchedulePreferences()
        p.breaks = .avoidBackToBack
        #expect(F.generate(courses, p).schedules.first.map { Set($0.crns) } == ["A1", "SPACED"])
    }

    @Test func keepingGapsShortPrefersCompactDays() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [
                F.section("GAP", "B", "1", days: [1], start: 13, end: 14),
                F.section("NOGAP", "B", "1", days: [1], start: 10.25, end: 11.25),
            ]),
        ]
        var p = SchedulePreferences()
        p.gaps = .compact
        #expect(F.generate(courses, p).schedules.first.map { Set($0.crns) } == ["A1", "NOGAP"])
        p.gaps = .fine
        // With gaps allowed nothing penalizes them, so the tie falls back on the remaining nudges.
        #expect(F.generate(courses, p).totalFound == 2)
    }

    @Test func preferredAndAvoidedInstructorsMoveSchedules() {
        let course = F.course("CS", "3000", [
            F.section("NEUTRAL", "CS", "3000", days: [1], start: 9, end: 10, instructors: ["Lee, Kim"]),
            F.section("LOVED", "CS", "3000", days: [2], start: 9, end: 10, instructors: ["Smith, Alex"]),
            F.section("AVOIDED", "CS", "3000", days: [3], start: 9, end: 10, instructors: ["Jones, Sam"]),
        ])
        var p = SchedulePreferences()
        p.preferredInstructors = ["Smith, Alex"]
        p.avoidedInstructors = ["jones, sam"]
        let result = F.generate([course], p)
        #expect(result.schedules.map { $0.crns } == [["LOVED"], ["NEUTRAL"], ["AVOIDED"]])
        #expect(result.schedules.first?.reasons.contains(where: { $0.text == "With Alex Smith" }) == true)
    }

    @Test func preferredFormatAndCampusRankWithoutRemoving() {
        let course = F.course("CS", "3000", [
            F.section("ONLINE", "CS", "3000", days: [1], start: 9, end: 10, campus: "Online", method: "Online"),
            F.section("INPERSON", "CS", "3000", days: [2], start: 9, end: 10),
            F.section("OAKLAND", "CS", "3000", days: [3], start: 9, end: 10, campus: "Oakland, CA"),
        ])
        var p = SchedulePreferences()
        p.format = .inPerson
        #expect(F.generate([course], p).schedules.first?.crns == ["INPERSON"])
        #expect(F.generate([course], p).totalFound == 3)

        // Between two in-person sections, the preferred campus wins; the online one fits any campus.
        let inPerson = F.course("CS", "3000", [
            F.section("BOSTON", "CS", "3000", days: [2], start: 9, end: 10),
            F.section("OAKLAND", "CS", "3000", days: [3], start: 9, end: 10, campus: "Oakland, CA"),
        ])
        var campus = SchedulePreferences()
        campus.campus = "Oakland, CA"
        #expect(F.generate([inPerson], campus).schedules.map { $0.crns } == [["OAKLAND"], ["BOSTON"]])
        campus.campus = "Boston"
        #expect(F.generate([inPerson], campus).schedules.map { $0.crns } == [["BOSTON"], ["OAKLAND"]])
    }

    @Test func aSearchThatRunsOutOfLeavesStillMeetsTheBestSectionsFirst() {
        func night(_ crn: String, _ course: String, day: Int) -> CourseSection {
            F.section(crn, course, "1", days: [day], start: 19, end: 20)
        }
        // The best section of each course is the last one the catalog lists.
        let a = F.course("A", "1", (1...8).map { night("A\($0)", "A", day: 1) } + [F.section("AMORNING", "A", "1", days: [1], start: 9, end: 10)])
        let b = F.course("B", "1", (1...8).map { night("B\($0)", "B", day: 2) } + [F.section("BMORNING", "B", "1", days: [2], start: 9, end: 10)])
        var p = SchedulePreferences()
        p[.morning] = .prefer
        p[.night] = .avoid
        let tiny = ScheduleGenerator.Limits(
            maxResults: 100, maxExhaustiveLeaves: 3, maxNodes: 1_000_000, timeBudget: 5,
            sampleLeaves: 0, sampleTimeBudget: 0, allowSampling: false
        )
        let result = ScheduleGenerator.generate(courses: [a, b], filters: ScheduleFilters(), preferences: p, limits: tiny)
        #expect(!result.isExhaustive, "Only three of the 81 schedules were looked at")
        #expect(result.schedules.first.map { Set($0.crns) } == ["AMORNING", "BMORNING"])
    }

    @Test func otherSortOrdersStillWorkWithPreferences() {
        var p = SchedulePreferences()
        p[.morning] = .prefer
        let result = F.generate([morningOrNight], p, sort: .latestStart)
        #expect(result.schedules.first?.crns == ["NIGHT"], "Latest start still sorts by start time first")
    }

    @Test func theScoreOfADefaultScheduleMatchesTheOriginalFormula() {
        let sections = [
            F.section("A1", "A", "1", days: [1, 3], start: 8, end: 9.5),
            F.section("B1", "B", "1", days: [2, 4], start: 13, end: 14.5),
            F.section("C1", "C", "1", days: [1], start: 17, end: 18.5, seats: 0),
        ]
        let schedule = GeneratedSchedule(sections: sections)
        var intervals: [ScheduleInterval] = []
        for section in sections { intervals += ScheduleInterval.intervals(for: section) }
        let m = ScheduleMeasure.measure(intervals)
        // The formula as it was before preferences existed.
        var expected = 100.0
        expected -= 8.0 * Double(m.campusDays)
        expected -= 2.0 * Double(max(0, m.classDays - m.campusDays))
        expected -= Double(m.gapMinutes) / 10.0
        if m.earliestStart < 9 * 60 { expected -= Double(9 * 60 - m.earliestStart) / 15.0 }
        if m.latestEnd > 17 * 60 { expected -= Double(m.latestEnd - 17 * 60) / 20.0 }
        expected -= 6.0
        #expect(schedule.score == expected)
        #expect(ScheduleScoring.score(measure: m, fullSections: 1, minSeats: 0) == expected)
    }

    @Test func generatingWithEmptyPreferencesMatchesGeneratingWithout() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1, 3], start: 9, end: 10), F.section("A2", "A", "1", days: [2, 4], start: 11, end: 12)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1, 3], start: 9.5, end: 11), F.section("B2", "B", "1", days: [5], start: 14, end: 17)]),
        ]
        let plain = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        let withEmpty = F.generate(courses, SchedulePreferences())
        #expect(plain.schedules.map { $0.crns } == withEmpty.schedules.map { $0.crns })
        #expect(plain.schedules.map { $0.score } == withEmpty.schedules.map { $0.score })
    }
}

// MARK: - Explanations

struct ScheduleReasonTests {
    private typealias F = Fixture

    @Test func reasonsAreEmptyWithoutPreferences() {
        let sections = [F.section("A", "A", "1", days: [1], start: 9, end: 10)]
        #expect(SchedulePreferenceRules.reasons(for: sections, preferences: SchedulePreferences()).isEmpty)
    }

    @Test func aScheduleThatMeetsTheWishesSaysSo() {
        let sections = [
            F.section("A", "A", "1", days: [2, 4], start: 10.5, end: 12),
            F.section("B", "B", "1", days: [1, 3], start: 14, end: 15.5),
        ]
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        p.earliestStart = TimeLimit(minutes: 10 * 60)
        p.lunch = LunchBreak()
        let reasons = SchedulePreferenceRules.reasons(for: sections, preferences: p)
        #expect(reasons.map { $0.text } == ["Fridays off", "No classes before 10 AM", "Lunch free every day"])
        #expect(reasons.allSatisfy { !$0.isCaveat })
    }

    @Test func wishesItMissesShowUpAsCaveats() {
        let sections = [F.section("A", "A", "1", days: [5], start: 8, end: 9)]
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        p.earliestStart = TimeLimit(minutes: 10 * 60, strength: .preferred)
        p[.earlyMorning] = .avoid
        let reasons = SchedulePreferenceRules.reasons(for: sections, preferences: p)
        #expect(reasons.filter { !$0.isCaveat }.isEmpty)
        // Cards show at most two things that fall short.
        #expect(reasons.filter { $0.isCaveat }.map { $0.text } == ["Class on Fri", "Starts 8:00 AM"])
        let all = SchedulePreferenceRules.reasons(for: sections, preferences: p, caveats: 5)
        #expect(all.filter { $0.isCaveat }.map { $0.text } == ["Class on Fri", "Starts 8:00 AM", "Includes early mornings"])
    }

    @Test func morningsAndFormatsAreDescribed() {
        let sections = [
            F.section("A", "A", "1", days: [1, 3], start: 9.5, end: 11),
            F.section("B", "B", "1", days: [2, 4], start: 10, end: 11.5),
        ]
        var p = SchedulePreferences()
        p[.morning] = .prefer
        p[.evening] = .avoid
        p.format = .inPerson
        p.dayLayout = .fewerDays
        let reasons = SchedulePreferenceRules.reasons(for: sections, preferences: p).map { $0.text }
        #expect(reasons.contains("All mornings"))
        #expect(reasons.contains("No evenings"))
        #expect(reasons.contains("All in person"))
    }

    @Test func favoritesGetTheSameTreatment() {
        let sections = [F.section("A", "A", "1", days: [2, 4], start: 11, end: 12.5)]
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        let schedule = GeneratedSchedule(sections: sections, preferences: p)
        #expect(schedule.reasons.map { $0.text } == ["Fridays off"])
        #expect(GeneratedSchedule(sections: sections).reasons.isEmpty)
    }

    @Test func theSameThingIsNeverSaidTwice() {
        let sections = [F.section("A", "A", "1", days: [2, 4], start: 18, end: 19.5)]
        var p = SchedulePreferences()
        p.blockedTimes = [
            BlockedTime(label: "Club", days: [.tuesday], start: 17 * 60, end: 19 * 60, strength: .preferred),
            BlockedTime(label: "Club", days: [.thursday], start: 17 * 60, end: 19 * 60, strength: .preferred),
        ]
        let reasons = SchedulePreferenceRules.reasons(for: sections, preferences: p)
        #expect(reasons.map { $0.text } == ["Overlaps Club"])
        #expect(Set(reasons.map { $0.id }).count == reasons.count)
    }

    @Test func campusesAreNamedPlainly() {
        let sections = [F.section("A", "A", "1", days: [1], start: 9, end: 10, campus: "Oakland, CA")]
        var p = SchedulePreferences()
        p.campus = "Oakland, CA"
        #expect(SchedulePreferenceRules.reasons(for: sections, preferences: p).map { $0.text } == ["Oakland, CA campus"])
    }

    @Test func cardTagsAreCapped() {
        let sections = [F.section("A", "A", "1", days: [2, 4], start: 11, end: 12.5)]
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        p.earliestStart = TimeLimit(minutes: 600)
        p.latestEnd = TimeLimit(minutes: 1_020)
        p.dayLayout = .fewerDays
        p[.morning] = .prefer
        p.lunch = LunchBreak()
        p.format = .inPerson
        let reasons = SchedulePreferenceRules.reasons(for: sections, preferences: p)
        #expect(reasons.filter { !$0.isCaveat }.count == 4)
    }
}

// MARK: - Apple Intelligence

struct ScheduleDraftTests {
    @Test func timesAreReadTheWayAModelWritesThem() {
        let parse = ScheduleAssistant.minutes(fromClockText:)
        #expect(parse("18:00") == 18 * 60)
        #expect(parse("6:30 PM") == 18 * 60 + 30)
        #expect(parse("6pm") == 18 * 60)
        #expect(parse("6 p.m.") == 18 * 60)
        #expect(parse("10") == 10 * 60)
        #expect(parse("1800") == 18 * 60)
        #expect(parse("930") == 9 * 60 + 30)
        #expect(parse("12am") == 0)
        #expect(parse("12pm") == 12 * 60)
        #expect(parse("noon") == 12 * 60)
        #expect(parse("midnight") == 24 * 60)
        #expect(parse("24:00") == 24 * 60)
        #expect(parse("25:00") == nil)
        #expect(parse("13pm") == nil)
        #expect(parse("soon") == nil)
        #expect(parse("") == nil)
        #expect(parse("7:75") == nil)
    }

    @Test func theBriefsExampleBecomesTheExpectedSurvey() {
        let draft = SchedulePreferencesDraft(
            earliestStart: "10:00",
            daysOff: [.friday],
            wantsLunchBreak: true,
            blockedTimes: [ScheduleDraftBlockedTime(label: "Robotics club", days: [.tuesday, .thursday], start: "18:00", end: "20:00")]
        )
        let applied = draft.applied(to: SchedulePreferences())
        #expect(applied.earliestStart == TimeLimit(minutes: 600, strength: .required))
        #expect(applied.daysOff == [.friday])
        #expect(applied.daysOffStrength == .preferred)
        #expect(applied.lunch != nil)
        #expect(applied.blockedTimes.count == 1)
        let block = applied.blockedTimes.first
        #expect(block?.label == "Robotics club")
        #expect(block?.days == [.tuesday, .thursday])
        #expect(block?.start == 18 * 60 && block?.end == 20 * 60)
        #expect(block?.strength == .required)
        #expect(applied.summary(limit: 4) == "Nothing before 10 AM · Fridays off · 1 blocked time · Lunch break")
    }

    @Test func bandsAndLayoutsMap() {
        let draft = SchedulePreferencesDraft(
            preferredTimes: [.morning, .earlyMorning], avoidedTimes: [.night, .morning],
            layout: .spreadOut, maxClassesPerDay: 3, maxHoursPerDay: 5, breaks: .timeToWalk, format: .hybrid, seats: .waitlistOK
        )
        let p = draft.applied(to: SchedulePreferences())
        #expect(p[.earlyMorning] == .prefer)
        #expect(p[.morning] == .avoid, "An avoided band wins when it is listed both ways")
        #expect(p[.night] == .avoid)
        #expect(p.dayLayout == .spreadOut)
        #expect(p.maxClassesPerDay == 3)
        #expect(p.maxMinutesPerDay == 300)
        #expect(p.breaks == .atLeast && p.minimumBreakMinutes == 15 && p.minimumBreakStrength == .preferred)
        #expect(p.format == .hybrid)
        #expect(p.seats == .waitlistOK)
    }

    @Test func flexibleLimitsAndRequiredDaysOff() {
        let draft = SchedulePreferencesDraft(
            earliestStart: "9:30", latestEnd: "5pm", timeLimitsAreFlexible: true, daysOff: [.monday, .friday], daysOffAreRequired: true
        )
        let p = draft.applied(to: SchedulePreferences())
        #expect(p.earliestStart == TimeLimit(minutes: 9 * 60 + 30, strength: .preferred))
        #expect(p.latestEnd == TimeLimit(minutes: 17 * 60, strength: .preferred))
        #expect(p.daysOff == [.monday, .friday])
        #expect(p.daysOffStrength == .required)
    }

    @Test func anEndBeforeTheStartIsRepairedAsTheAfternoonOrEvening() {
        let draft = SchedulePreferencesDraft(blockedTimes: [
            ScheduleDraftBlockedTime(label: "Lunch", days: [.monday], start: "11:00", end: "01:00"),
            ScheduleDraftBlockedTime(label: "Choir", days: [.wednesday], start: "18:00", end: "08:00"),
            ScheduleDraftBlockedTime(label: "Run", days: [.friday], start: "06:00", end: "08:00"),
        ])
        let blocks = draft.applied(to: SchedulePreferences()).blockedTimes
        #expect(blocks.map { $0.label } == ["Lunch", "Choir", "Run"])
        #expect(blocks[0].start == 11 * 60 && blocks[0].end == 13 * 60)
        #expect(blocks[1].start == 18 * 60 && blocks[1].end == 20 * 60)
        // Times that make sense as written are never second-guessed: 6 to 8 could be a morning run.
        #expect(blocks[2].start == 6 * 60 && blocks[2].end == 8 * 60)
    }

    @Test func aFinishBeforeTheStartIsNotBelieved() {
        let draft = SchedulePreferencesDraft(earliestStart: "10:00", latestEnd: "09:00")
        let p = draft.applied(to: SchedulePreferences())
        #expect(p.earliestStart?.minutes == 10 * 60)
        #expect(p.latestEnd == nil)
        var current = SchedulePreferences()
        current.latestEnd = TimeLimit(minutes: 15 * 60)
        #expect(SchedulePreferencesDraft(earliestStart: "16:00").applied(to: current).latestEnd?.minutes == 15 * 60, "Only what the description says is judged")
    }

    @Test func unusableAnswersAreDroppedNotGuessedAt() {
        let draft = SchedulePreferencesDraft(
            earliestStart: "whenever", latestEnd: "26:00", maxClassesPerDay: 40, maxHoursPerDay: 0,
            blockedTimes: [
                ScheduleDraftBlockedTime(label: "No days", days: [], start: "10:00", end: "11:00"),
                ScheduleDraftBlockedTime(label: "No time", days: [.monday], start: "later", end: "11:00"),
                ScheduleDraftBlockedTime(label: "Backwards", days: [.monday], start: "17:00", end: "16:00"),
            ]
        )
        let p = draft.applied(to: SchedulePreferences())
        #expect(p.isDefault)
    }

    @Test func aDescriptionAddsToTheSurveyInsteadOfReplacingIt() {
        var current = SchedulePreferences()
        current[.afternoon] = .prefer
        current.daysOff = [.monday]
        current.blockedTimes = [BlockedTime(label: "Work", days: [.wednesday], start: 13 * 60, end: 17 * 60)]
        let draft = SchedulePreferencesDraft(
            daysOff: [.friday],
            blockedTimes: [
                ScheduleDraftBlockedTime(label: "work", days: [.wednesday], start: "13:00", end: "17:00"),
                ScheduleDraftBlockedTime(label: "Choir", days: [.thursday], start: "18:00", end: "19:30"),
            ]
        )
        let merged = draft.applied(to: current)
        #expect(merged[.afternoon] == .prefer, "What the description doesn't mention stays")
        #expect(merged.daysOff == [.friday], "A new list of days off replaces the old one")
        #expect(merged.blockedTimes.map { $0.label } == ["Work", "Choir"], "A block it repeats isn't added twice")
        let changed = merged.changedFields(from: current)
        #expect(changed.contains(.daysOff))
        #expect(!changed.contains(.timeOfDay(.afternoon)))
        #expect(changed.count == 2)
    }

    @Test func anEmptyDraftIsEmpty() {
        #expect(SchedulePreferencesDraft().isEmpty)
        #expect(SchedulePreferencesDraft(wantsLunchBreak: false).isEmpty)
        #expect(!SchedulePreferencesDraft(wantsLunchBreak: true).isEmpty)
        #expect(SchedulePreferencesDraft().applied(to: SchedulePreferences()).isDefault)
        #expect(SchedulePreferencesDraft(preferredTimes: [.morning], daysOff: [.friday]).filledCount == 2)
    }

    // MARK: Grounding

    private let briefsExample = "No classes before 10, I have robotics club Tuesdays and Thursdays 6–8pm, I’d like Fridays off and a lunch break"

    /// What an over-eager model returns for the brief's example: the right answers plus invented ones.
    private func overeagerDraft() -> SchedulePreferencesDraft {
        SchedulePreferencesDraft(
            earliestStart: "10:00", timeLimitsAreFlexible: true,
            daysOff: [.friday], daysOffAreRequired: true, layout: .fewerDays,
            maxClassesPerDay: 3, maxHoursPerDay: 5, breaks: .avoidBackToBack, wantsLunchBreak: true,
            blockedTimes: [ScheduleDraftBlockedTime(label: "Robotics club", days: [.tuesday, .thursday], start: "18:00", end: "20:00")],
            format: .online, seats: .openSeatsOnly
        )
    }

    @Test func answersTheStudentNeverMentionedAreDropped() {
        let grounded = overeagerDraft().grounded(in: briefsExample)
        #expect(grounded.format == nil)
        #expect(grounded.seats == nil)
        #expect(grounded.breaks == nil)
        #expect(grounded.layout == nil)
        #expect(grounded.maxClassesPerDay == nil && grounded.maxHoursPerDay == nil)
        // What was said stays.
        #expect(grounded.earliestStart == "10:00")
        #expect(grounded.wantsLunchBreak == true)
        #expect(grounded.daysOff == [.friday])
        #expect(grounded.blockedTimes?.count == 1)
    }

    @Test func firmnessFollowsTheWordsNotTheModel() {
        let applied = overeagerDraft().grounded(in: briefsExample).applied(to: SchedulePreferences())
        // "No classes before 10" is firm even though "I'd like" appears elsewhere in the sentence…
        #expect(applied.earliestStart == TimeLimit(minutes: 600, strength: .required))
        // …and "I'd like Fridays off" is only a wish.
        #expect(applied.daysOffStrength == .preferred)
        #expect(applied.summary(limit: 4) == "Nothing before 10 AM · Fridays off · 1 blocked time · Lunch break")
    }

    @Test func commitmentsAndSoftenersAreRecognized() {
        let work = SchedulePreferencesDraft(daysOff: [.friday], daysOffAreRequired: false)
            .grounded(in: "I work Fridays so I need them off")
        #expect(work.daysOffAreRequired == true)
        let never = SchedulePreferencesDraft(daysOff: [.monday]).grounded(in: "No classes on Mondays please")
        #expect(never.daysOffAreRequired == true)
        let wish = SchedulePreferencesDraft(daysOff: [.monday], daysOffAreRequired: true).grounded(in: "Mondays off would be great")
        #expect(wish.daysOffAreRequired == false)

        let soft = SchedulePreferencesDraft(earliestStart: "10:00", timeLimitsAreFlexible: false)
            .grounded(in: "Ideally nothing before 10 in the morning")
        #expect(soft.timeLimitsAreFlexible == true)
        let firm = SchedulePreferencesDraft(earliestStart: "10:00", timeLimitsAreFlexible: true)
            .grounded(in: "I can’t do classes before 10")
        #expect(firm.timeLimitsAreFlexible == false)
    }

    @Test func limitsNeedANumberAndADay() {
        let draft = SchedulePreferencesDraft(maxClassesPerDay: 3, maxHoursPerDay: 5)
        #expect(draft.grounded(in: "I don’t want more than three classes a day").maxClassesPerDay == 3)
        #expect(draft.grounded(in: "I don’t want too many classes").maxClassesPerDay == nil)
        #expect(draft.grounded(in: "No more than 5 hours of class each day").maxHoursPerDay == 5)
    }

    @Test func otherLanguagesAreLeftToTheModel() {
        let draft = SchedulePreferencesDraft(timeLimitsAreFlexible: true, daysOff: [.friday], daysOffAreRequired: true, format: .online)
        let text = "Quiero las mañanas libres y los viernes sin clase, porque trabajo por las tardes"
        #expect(!ScheduleAssistant.isEnglish(text))
        #expect(draft.grounded(in: text) == draft)
        #expect(ScheduleAssistant.isEnglish(briefsExample))
    }

    @Test func tooManyBlocksAreCapped() {
        let blocks = (0..<20).map { ScheduleDraftBlockedTime(label: "Block \($0)", days: [.monday], start: "\(8 + $0 % 10):00", end: "\(9 + $0 % 10):00") }
        let p = SchedulePreferencesDraft(blockedTimes: blocks).applied(to: SchedulePreferences())
        #expect(p.blockedTimes.count <= SchedulePreferencesDraft.maxBlockedTimes)
    }

    @Test func failuresHaveHumanMessages() {
        let failures: [ScheduleAssistant.Failure] = [
            .emptyDescription, .descriptionTooLong, .guardrail, .contextTooLarge, .unsupportedLanguage, .busy, .timedOut,
            .nothingFound, .failed("x"), .unavailable(.notEnabled),
        ]
        #expect(failures.allSatisfy { !$0.message.isEmpty })
        #expect(ScheduleAssistantAvailability.deviceNotEligible.note?.contains("survey") == true)
        #expect(ScheduleAssistantAvailability.notEnabled.note?.contains("Settings") == true)
        #expect(ScheduleAssistantAvailability.notReady.note?.contains("later") == true)
        #expect(ScheduleAssistantAvailability.available.note == nil)
    }
}

// MARK: - Blocking courses

struct ScheduleBlockerTests {
    private typealias F = Fixture

    @Test func findsTheCourseThatAlwaysClashes() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 9.5, end: 10.5)]),
            F.course("C", "1", [F.section("C1", "C", "1", days: [2], start: 9, end: 10)]),
        ]
        let result = F.generate(courses)
        #expect(result.totalFound == 0)
        let analysis = ScheduleGenerator.analyzeBlockers(courses: courses, filters: ScheduleFilters(), diagnostics: result.diagnostics)
        #expect(analysis.requiredCount == 3)
        #expect(Set(analysis.options.map { $0.courses.map(\.description) }) == [["A 1"], ["B 1"]])
        #expect(Set(analysis.allBlockingCourses.map(\.description)) == ["A 1", "B 1"])
        #expect(analysis.clashes(of: CourseKey(subject: "A", number: "1")) == [CourseKey(subject: "B", number: "1")])
        #expect(analysis.options.allSatisfy { $0.scheduleCount == 1 })
    }

    @Test func aCourseWithNoSectionsAlwaysHasToGo() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", []),
            F.course("C", "1", [F.section("C1", "C", "1", days: [2], start: 9, end: 10)]),
        ]
        let analysis = ScheduleGenerator.analyzeBlockers(courses: courses, filters: ScheduleFilters())
        #expect(analysis.notOffered.map(\.description) == ["B 1"])
        #expect(analysis.options.map { $0.courses.map(\.description) } == [["B 1"]])
    }

    @Test func coursesTheRulesRuleOutAreReportedSeparately() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [5], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [2], start: 9, end: 10)]),
        ]
        var p = SchedulePreferences()
        p.daysOff = [.friday]
        p.daysOffStrength = .required
        let analysis = ScheduleGenerator.analyzeBlockers(courses: courses, filters: ScheduleFilters(), preferences: p)
        #expect(analysis.filteredOut.map(\.description) == ["A 1"])
        #expect(analysis.notOffered.isEmpty)
        #expect(analysis.options.map { $0.courses.map(\.description) } == [["A 1"]])
    }

    @Test func looksAtPairsWhenNoSingleCourseIsToBlame() {
        // A+B clash and C+D clash: dropping one course can't fix both, dropping one of each can.
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 9, end: 10)]),
            F.course("C", "1", [F.section("C1", "C", "1", days: [2], start: 9, end: 10)]),
            F.course("D", "1", [F.section("D1", "D", "1", days: [2], start: 9, end: 10)]),
        ]
        let analysis = ScheduleGenerator.analyzeBlockers(courses: courses, filters: ScheduleFilters())
        #expect(analysis.options.count == 4)
        #expect(analysis.options.allSatisfy { $0.courses.count == 2 })
        let sets = Set(analysis.options.map { Set($0.courses.map(\.description)) })
        #expect(sets == [["A 1", "C 1"], ["A 1", "D 1"], ["B 1", "C 1"], ["B 1", "D 1"]])
    }

    @Test func countProblemsAreNotCourseProblems() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [2], start: 9, end: 10)]),
        ]
        var filters = ScheduleFilters()
        filters.courseCount = 1
        let result = ScheduleGenerator.generate(courses: courses, filters: filters)
        let analysis = ScheduleGenerator.analyzeBlockers(courses: courses, filters: filters, diagnostics: result.diagnostics)
        #expect(analysis.options.isEmpty)
    }

    @Test func makingTheBlockersOptionalProducesSchedules() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 9.5, end: 10.5)]),
        ]
        let analysis = ScheduleGenerator.analyzeBlockers(courses: courses, filters: ScheduleFilters())
        let drop = Set(analysis.blockingCourses)
        let relaxed = courses.map { input -> ScheduleCourseInput in
            var copy = input
            if drop.contains(copy.key) { copy.isRequired = false }
            return copy
        }
        #expect(ScheduleGenerator.generate(courses: relaxed, filters: ScheduleFilters()).totalFound > 0)
    }

    @Test func noResultsAnalysisCombinesBlockersAndRelaxations() {
        let courses = [
            F.course("A", "1", [F.section("A1", "A", "1", days: [1], start: 9, end: 10)]),
            F.course("B", "1", [F.section("B1", "B", "1", days: [1], start: 9.5, end: 10.5)]),
        ]
        let result = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        let analysis = ScheduleGenerator.analyzeEmptyResult(
            courses: courses, filters: ScheduleFilters(), preferences: SchedulePreferences(), diagnostics: result.diagnostics
        )
        #expect(!analysis.blockers.options.isEmpty)
        #expect(analysis.suggestions.isEmpty, "No filter is in the way, so there is nothing to loosen")
    }
}

// MARK: - The survey's context

@Suite(.serialized)
struct SchedulePreferencesContextTests {
    @Test func campusesInstructorsAndCreditsComeFromThePlansCourses() throws {
        let index = try #require(SearchEngineTests.index)
        var plan = SchedulePlan(name: "Plan", termCode: "202710")
        plan.courses = [
            PlanCourse(key: CourseKey(subject: "CS", number: "3000"), colorIndex: 0),
            PlanCourse(key: CourseKey(subject: "MATH", number: "2331"), isRequired: false, colorIndex: 1),
        ]
        let context = SchedulePreferencesContext(plan: plan, index: index)
        #expect(context.campusNames.contains("Boston"))
        #expect(context.campusNames.allSatisfy { !$0.localizedCaseInsensitiveContains("online") && !$0.localizedCaseInsensitiveContains("no campus") })
        #expect(context.optionalCourseCount == 1)
        #expect(context.requiredCredits > 0)
        #expect(context.totalCredits > context.requiredCredits)
        #expect(!context.instructors.isEmpty)
        #expect(context.instructors.allSatisfy { !$0.courses.isEmpty })
        let names = context.instructors.map(\.name)
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(SchedulePreferencesContext(plan: plan, index: nil).instructors.isEmpty)
    }

    @Test func excludedSectionsDontOfferTheirInstructors() throws {
        let index = try #require(SearchEngineTests.index)
        let key = CourseKey(subject: "CS", number: "3000")
        var plan = SchedulePlan(name: "Plan", termCode: "202710")
        plan.courses = [PlanCourse(key: key, colorIndex: 0)]
        let everyone = SchedulePreferencesContext(plan: plan, index: index).instructors
        plan.courses[0].excludedCRNs = Set(index.sections(for: key).map(\.crn))
        #expect(SchedulePreferencesContext(plan: plan, index: index).instructors.isEmpty)
        #expect(!everyone.isEmpty)
    }
}

// MARK: - Moving a blocking course in the degree plan

struct ScheduleReorderBridgeTests {
    private func key(_ code: String) -> CourseKey { CourseKey(string: code)! }

    private func planned(_ code: String) -> DegreePlanCourse {
        DegreePlanCourse(key: key(code), title: code, credits: 4)
    }

    private let terms = ["202710", "202630", "202610", "202530", "202510"]
    private let spring = ["202630", "202530"]
    private let fall = ["202710", "202610", "202510"]

    private func degreePlan() -> DegreePlan {
        var plan = DegreePlan(name: "Plan")
        plan.terms = [
            DegreePlanTerm(season: .fall, year: 2026, courses: [planned("CS 3386"), planned("CS 3800")]),
            DegreePlanTerm(season: .spring, year: 2027, courses: [planned("CS 4100")]),
        ]
        return plan
    }

    private func history() -> OfferingHistory {
        OfferingHistory(
            checkedTerms: terms,
            offered: [key("CS 3386"): Set(spring), key("CS 3800"): Set(fall), key("CS 4100"): Set(fall + spring)],
            checkedKeys: nil
        )
    }

    @Test func aSuggestionBecomesAnOptionThatMovesTheCourseOutOfTheSchedule() throws {
        let plan = degreePlan()
        let origin = plan.terms[0]
        let found = DegreePlanReordering.suggestions(
            for: plan, termID: origin.id, blocking: [key("CS 3386")], history: history(),
            prerequisites: { _ in .some(nil) }, equivalences: .none
        )
        let single = try #require(found.first { $0.moves.count == 1 })
        let option = ScheduleReorderSuggestions.option(from: single, origin: origin)
        #expect(option.title == "Move CS 3386 to Spring 2027")
        #expect(option.appliedText == "Moved CS 3386 to Spring 2027")
        #expect(option.movedAway == [key("CS 3386")])
        #expect(option.movedIn.isEmpty)
        #expect(option.scheduleEffect == "CS 3386 comes out of this schedule.")
        #expect(option.reasons.first == "Offered every spring")
        #expect(!option.addsSemester)

        var changed = plan
        option.apply(&changed)
        #expect(changed.terms[0].courses.compactMap(\.key) == [key("CS 3800")])
        #expect(changed.terms[1].courses.compactMap(\.key) == [key("CS 4100"), key("CS 3386")])
        #expect(plan.terms[0].courses.count == 2, "Applying edits the copy it is given")
    }

    @Test func aSwapAlsoBringsACourseIn() throws {
        var plan = degreePlan()
        // CS 4100 is taught in the fall too, so it can swap places with CS 3386.
        plan.terms[1].courses = [planned("CS 4100")]
        let origin = plan.terms[0]
        let found = DegreePlanReordering.suggestions(
            for: plan, termID: origin.id, blocking: [key("CS 3386")], history: history(),
            prerequisites: { _ in .some(nil) }, equivalences: .none
        )
        let swap = try #require(found.first { $0.moves.count == 2 })
        let option = ScheduleReorderSuggestions.option(from: swap, origin: origin)
        #expect(option.movedAway == [key("CS 3386")])
        #expect(option.movedIn == [key("CS 4100")])
        #expect(option.scheduleEffect == "CS 3386 comes out of this schedule. CS 4100 will be added to it if it’s offered this term.")
    }

    @Test func aNewSemesterIsFlagged() throws {
        var plan = degreePlan()
        plan.terms = [DegreePlanTerm(season: .fall, year: 2026, courses: [planned("CS 3386")])]
        let origin = plan.terms[0]
        let found = DegreePlanReordering.suggestions(
            for: plan, termID: origin.id, blocking: [key("CS 3386")], history: history(),
            prerequisites: { _ in .some(nil) }, equivalences: .none
        )
        let option = try #require(found.first.map { ScheduleReorderSuggestions.option(from: $0, origin: origin) })
        #expect(option.addsSemester)
        var changed = plan
        option.apply(&changed)
        #expect(changed.terms.count == 2)
        #expect(changed.terms.last?.courses.compactMap(\.key) == [key("CS 3386")])
    }

    @MainActor
    @Test func nothingIsLookedUpWhenNoBlockingCourseIsInTheSemester() async {
        let plan = degreePlan()
        let fall2026 = Term(code: "202710", bannerDescription: "Fall 2026 Semester")
        // CS 9001 isn't in the degree plan's Fall 2026 semester, so there is nothing to move (and no network use).
        let result = await ScheduleReorderSuggestions.load(blocking: [key("CS 9001")], degreePlan: plan, term: fall2026, indexes: [])
        #expect(result.options.isEmpty)
        // A semester the degree plan doesn't have.
        let summer = Term(code: "202750", bannerDescription: "Summer Full 2027 Semester")
        let other = await ScheduleReorderSuggestions.load(blocking: [key("CS 3386")], degreePlan: plan, term: summer, indexes: [])
        #expect(other.options.isEmpty)
    }

    @Test func titlesThatAreNotMovesStillReadSensibly() {
        let option = ScheduleReorderOption(
            id: "x", title: "Something else", reasons: [], addsSemester: false, movedAway: [], movedIn: [], apply: { _ in }
        )
        #expect(option.appliedText == "Updated your degree plan")
        #expect(option.scheduleEffect.isEmpty)
    }
}

// MARK: - Checked against brute force

/// Random small plans, with random hard preferences, must produce exactly the schedules an
/// obviously-correct enumeration finds. This is what keeps the pruned search honest.
struct ScheduleSearchAgainstBruteForceTests {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomInstance(_ rng: inout SplitMix64) -> (courses: [ScheduleCourseInput], filters: ScheduleFilters, preferences: SchedulePreferences) {
        let starts: [Double] = [8, 9.5, 11, 12.5, 14, 15.5, 17]
        let buildings = ["RY", "SL", "WVH"]
        let dayChoices: [[Int]] = [[1, 3], [2, 4], [1, 3, 5], [1], [2], [3], [4], [5], [2, 5]]
        let windows: [(String, String)] = [("2026-09-09", "2026-12-13"), ("2026-09-09", "2026-10-23"), ("2026-10-26", "2026-12-13")]
        let courseCount = Int.random(in: 2...5, using: &rng)
        var courses: [ScheduleCourseInput] = []
        for c in 0..<courseCount {
            var sections: [CourseSection] = []
            for s in 0..<Int.random(in: 1...4, using: &rng) {
                let start = starts.randomElement(using: &rng)!
                let window = windows.randomElement(using: &rng)!
                sections.append(Fixture.section(
                    "C\(c)S\(s)", "C\(c)", "1", days: dayChoices.randomElement(using: &rng)!,
                    start: start, end: start + [0.75, 1.25, 1.5, 2].randomElement(using: &rng)!,
                    building: buildings.randomElement(using: &rng)!, startDate: window.0, endDate: window.1
                ))
            }
            let credits = Int.random(in: 1...4, using: &rng)
            courses.append(Fixture.course("C\(c)", "1", required: Bool.random(using: &rng) || c == 0, credits: credits, sections))
        }
        var filters = ScheduleFilters()
        if Int.random(in: 0..<6, using: &rng) == 0 { filters.courseCount = Int.random(in: 1...courseCount, using: &rng) }
        var p = SchedulePreferences()
        if Bool.random(using: &rng) { p.maxClassesPerDay = Int.random(in: 1...3, using: &rng) }
        if Bool.random(using: &rng) { p.maxMinutesPerDay = [90, 150, 210, 300].randomElement(using: &rng)! }
        if Bool.random(using: &rng) {
            p.breaks = .atLeast
            p.minimumBreakMinutes = [10, 20, 40].randomElement(using: &rng)!
            p.minimumBreakStrength = .required
        }
        if Int.random(in: 0..<3, using: &rng) == 0 {
            let lower = Int.random(in: 2...10, using: &rng)
            p.creditTarget = CreditTarget(lower: lower, upper: lower + Int.random(in: 0...5, using: &rng))
        }
        if Int.random(in: 0..<3, using: &rng) == 0 {
            p.blockedTimes = [BlockedTime(label: "Block", days: DaySet(indices: dayChoices.randomElement(using: &rng)!), start: 11 * 60, end: 14 * 60)]
        }
        return (courses, filters, p)
    }

    /// Whether adding `section` to `picked` keeps every schedule-level rule.
    private func fits(_ section: CourseSection, with picked: [CourseSection], _ p: SchedulePreferences) -> Bool {
        for other in picked {
            if section.conflicts(with: other) { return false }
            if p.breaks == .atLeast, p.minimumBreakStrength == .required, tooClose(section, other, minutes: p.minimumBreakMinutes) { return false }
        }
        let all = picked + [section]
        for day in 0..<7 {
            let onDay = all.filter { $0.meetingDays.contains(day: day) }
            if let cap = p.maxClassesPerDay, onDay.count > cap { return false }
            if let cap = p.maxMinutesPerDay {
                let minutes = onDay.reduce(0) { total, s in
                    var seen = Set<String>()
                    var sum = 0
                    for m in s.weeklyMeetings where m.days.contains(day: day) {
                        let key = "\(m.start ?? 0)-\(m.end ?? 0)"
                        if seen.insert(key).inserted { sum += (m.end ?? 0) - (m.start ?? 0) }
                    }
                    return total + sum
                }
                if minutes > cap { return false }
            }
        }
        return true
    }

    private func tooClose(_ a: CourseSection, _ b: CourseSection, minutes: Int) -> Bool {
        for x in a.weeklyMeetings {
            for y in b.weeklyMeetings {
                guard !x.days.isDisjoint(with: y.days), Meeting.dateWindowsOverlap(x.startDate, x.endDate, y.startDate, y.endDate) else { continue }
                let gap: Int
                if y.start! >= x.end! { gap = y.start! - x.end! } else if x.start! >= y.end! { gap = x.start! - y.end! } else { continue }
                if gap < minutes, x.buildingCode != y.buildingCode { return true }
            }
        }
        return false
    }

    private func bruteForce(_ courses: [ScheduleCourseInput], _ filters: ScheduleFilters, _ p: SchedulePreferences) -> Set<Set<String>> {
        let kept = courses.map { course in
            course.sections.filter { ScheduleGenerator.rejectionReasons(for: $0, filters: filters, preferences: p, excluded: course.excludedCRNs) == 0 }
        }
        var result = Set<Set<String>>()
        let target = filters.courseCount.flatMap { $0 > 0 ? $0 : nil }

        func finish(_ picks: [(course: Int, section: CourseSection)]) {
            guard !picks.isEmpty else { return }
            if let target, picks.count != target { return }
            if let credits = p.creditTarget {
                let low = picks.reduce(0) { $0 + courses[$1.course].minCredits }
                let high = picks.reduce(0) { $0 + max(courses[$1.course].minCredits, courses[$1.course].maxCredits) }
                if low > credits.upper || high < credits.lower { return }
            } else if target == nil {
                // Maximal: no skipped optional course has a section that could still be added.
                let chosenCourses = Set(picks.map(\.course))
                let sections = picks.map(\.section)
                for index in courses.indices where !chosenCourses.contains(index) {
                    if kept[index].contains(where: { fits($0, with: sections, p) }) { return }
                }
            }
            result.insert(Set(picks.map { $0.section.crn }))
        }

        func walk(_ index: Int, _ picks: [(course: Int, section: CourseSection)]) {
            if index == courses.count { finish(picks); return }
            if !courses[index].isRequired { walk(index + 1, picks) }
            for section in kept[index] where fits(section, with: picks.map(\.section), p) {
                walk(index + 1, picks + [(index, section)])
            }
        }
        walk(0, [])
        return result
    }

    @Test func randomPlansMatchAnObviouslyCorrectEnumeration() {
        var rng = SplitMix64(state: 20_261_004)
        var nonTrivial = 0
        for round in 0..<400 {
            let instance = randomInstance(&rng)
            let expected = bruteForce(instance.courses, instance.filters, instance.preferences)
            let result = ScheduleGenerator.generate(courses: instance.courses, filters: instance.filters, preferences: instance.preferences)
            #expect(result.isExhaustive)
            let actual = Fixture.crnSets(result)
            if actual != expected {
                Issue.record("Round \(round): generator found \(actual.count) schedules, enumeration found \(expected.count). Missing: \(expected.subtracting(actual).prefix(3)), extra: \(actual.subtracting(expected).prefix(3))")
            }
            #expect(result.totalFound == expected.count)
            if !expected.isEmpty { nonTrivial += 1 }
        }
        #expect(nonTrivial > 100, "The random plans should usually have schedules, or the comparison proves little")
    }
}

// MARK: - The real catalog

@Suite(.serialized)
struct SchedulePreferencesCatalogTests {
    private func inputs(_ index: CatalogIndex, _ codes: [String]) -> [ScheduleCourseInput] {
        codes.compactMap { code in
            guard let key = CourseKey(string: code) else { return nil }
            let course = index.course(key)
            return ScheduleCourseInput(
                key: key, isRequired: true, sections: index.sections(for: key),
                minCredits: Int((course?.minCredits ?? 0).rounded(.up)), maxCredits: Int((course?.maxCredits ?? 0).rounded(.up))
            )
        }
    }

    @Test func preferencesRankAndFilterARealPlanQuickly() throws {
        let index = try #require(SearchEngineTests.index)
        let courses = inputs(index, ["CS 3000", "CS 3001", "MATH 2331", "PHYS 1151"])
        let plain = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters())
        #expect(plain.totalFound > 0)

        var p = SchedulePreferences()
        p = SchedulePreset.longWeekends.toggled(in: p)
        p = SchedulePreset.morningPerson.toggled(in: p)
        p.blockedTimes = [BlockedTime(label: "Club", days: [.tuesday, .thursday], start: 18 * 60, end: 20 * 60)]
        p.lunch = LunchBreak()
        p.maxClassesPerDay = 3
        let ranked = ScheduleGenerator.generate(courses: courses, filters: ScheduleFilters(), preferences: p)
        #expect(ranked.totalFound <= plain.totalFound)
        #expect(ranked.elapsed < 10, "Preferences must not make generation slow")
        if let best = ranked.schedules.first {
            for section in best.sections {
                for meeting in section.weeklyMeetings {
                    let overlapsClub = !meeting.days.isDisjoint(with: [.tuesday, .thursday])
                        && (meeting.start ?? 0) < 20 * 60 && (meeting.end ?? 0) > 18 * 60
                    #expect(!overlapsClub)
                }
            }
            #expect(!best.reasons.isEmpty)
        }
        // Sorted best first.
        let scores = ranked.schedules.map { $0.score }
        #expect(scores == scores.sorted(by: >))
    }
}
