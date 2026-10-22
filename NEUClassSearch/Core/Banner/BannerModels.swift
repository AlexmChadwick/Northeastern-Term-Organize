//
//  BannerModels.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Portions of this file are derived from SearchNEU
//  (https://github.com/sandboxnu/searchneu): the wire-format fields follow its zod
//  schemas in packages/scraper/src/schemas/banner/*.ts, and
//  `BannerMeetingTime.toMeeting()` follows `parseMeetingTimes` in
//  packages/scraper/src/generate/marshall.ts, Copyright (C) Sandbox at Northeastern
//  University and the SearchNEU contributors, licensed under the GNU Affero General
//  Public License v3.
//  Modified 2026-10-02: ported from TypeScript to Swift as lenient Decodable models
//  (most fields optional), with meeting times converted to minutes after midnight
//  and dates to ISO format.
//
//  Wire formats for Northeastern's public Banner 9 class search API
//  (https://nubanner.neu.edu/StudentRegistrationSsb). Decoding is intentionally
//  lenient so that new or missing fields do not break the app.
//

import Foundation

struct BannerTerm: Decodable, Sendable {
    var code: String
    var description: String
}

struct BannerCodeDescription: Decodable, Sendable {
    var code: String
    var description: String
}

struct BannerSectionPage: Decodable, Sendable {
    var success: Bool?
    var totalCount: Int
    var data: [BannerSection]?
}

struct BannerSection: Decodable, Sendable {
    var term: String?
    var courseReferenceNumber: String
    var partOfTerm: String?
    var courseNumber: String
    var subject: String
    var subjectDescription: String?
    var sequenceNumber: String?
    var campusDescription: String?
    var scheduleTypeDescription: String?
    var courseTitle: String?
    var creditHours: Double?
    var maximumEnrollment: Int?
    var enrollment: Int?
    var seatsAvailable: Int?
    var waitCapacity: Int?
    var waitCount: Int?
    var waitAvailable: Int?
    var crossList: String?
    var crossListCapacity: Int?
    var crossListCount: Int?
    var crossListAvailable: Int?
    var creditHourHigh: Double?
    var creditHourLow: Double?
    /// `TO` on a variable-credit section. Absent on a fixed section.
    var creditHourIndicator: String? = nil
    var openSection: Bool?
    var subjectCourse: String?
    var meetingsFaculty: [BannerMeetingFaculty]?
    var sectionAttributes: [BannerSectionAttribute]?
    var instructionalMethod: String?
    var instructionalMethodDescription: String?
}

struct BannerSectionAttribute: Decodable, Sendable {
    var code: String
    var description: String?
}

struct BannerMeetingFaculty: Decodable, Sendable {
    var courseReferenceNumber: String?
    var faculty: [BannerFaculty]?
    var meetingTime: BannerMeetingTime?
}

struct BannerFaculty: Decodable, Sendable {
    var displayName: String?
    var emailAddress: String?
    var primaryIndicator: Bool?
}

struct BannerMeetingTime: Decodable, Sendable {
    var beginTime: String?
    var endTime: String?
    var building: String?
    var buildingDescription: String?
    var room: String?
    var campus: String?
    var campusDescription: String?
    var startDate: String?
    var endDate: String?
    var meetingType: String?
    var meetingTypeDescription: String?
    var monday: Bool?
    var tuesday: Bool?
    var wednesday: Bool?
    var thursday: Bool?
    var friday: Bool?
    var saturday: Bool?
    var sunday: Bool?
}

struct BannerFacultyMeetingTimes: Decodable, Sendable {
    var fmt: [BannerMeetingFaculty]?
}

// MARK: - Conversion

extension BannerMeetingTime {
    var daySet: DaySet {
        var days = DaySet()
        if sunday == true { days.insert(.sunday) }
        if monday == true { days.insert(.monday) }
        if tuesday == true { days.insert(.tuesday) }
        if wednesday == true { days.insert(.wednesday) }
        if thursday == true { days.insert(.thursday) }
        if friday == true { days.insert(.friday) }
        if saturday == true { days.insert(.saturday) }
        return days
    }

    /// Converts to the app model. Mirrors SearchNEU's `parseMeetingTimes`:
    /// placeholder rooms named `ROOM` are dropped and `HHMM` strings are
    /// converted (here to minutes after midnight).
    func toMeeting() -> Meeting {
        let start = beginTime.flatMap { Int($0) }.map(TimeOfDay.minutes(fromHHMM:))
        let end = endTime.flatMap { Int($0) }.map(TimeOfDay.minutes(fromHHMM:))
        let cleanRoom: String? = {
            guard let room = room?.trimmingCharacters(in: .whitespaces), !room.isEmpty, room.uppercased() != "ROOM" else { return nil }
            return room
        }()
        let kind: String = {
            if meetingType == "FNEX" { return "Final Exam" }
            return HTMLText.decodeEntities(meetingTypeDescription ?? "Class")
        }()
        return Meeting(
            days: daySet,
            start: start,
            end: end,
            buildingCode: building?.nilIfBlank,
            building: buildingDescription.map(HTMLText.decodeEntities)?.nilIfBlank,
            room: cleanRoom,
            campusCode: campus?.nilIfBlank,
            kind: kind,
            startDate: startDate.flatMap(BannerDate.iso),
            endDate: endDate.flatMap(BannerDate.iso)
        )
    }
}

extension BannerFaculty {
    func toInstructor() -> Instructor? {
        guard let name = displayName.map({ HTMLText.decodeEntities(HTMLText.decodeEntities($0)) })?.nilIfBlank else { return nil }
        return Instructor(name: name, primary: primaryIndicator ?? false, email: emailAddress?.nilIfBlank)
    }
}

enum BannerDate {
    /// Converts Banner's `MM/dd/yyyy` to ISO `yyyy-MM-dd`.
    static func iso(_ banner: String) -> String? {
        let parts = banner.split(separator: "/")
        guard parts.count == 3, let m = Int(parts[0]), let d = Int(parts[1]), let y = Int(parts[2]) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

extension String {
    /// Returns nil for empty or whitespace-only strings.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
