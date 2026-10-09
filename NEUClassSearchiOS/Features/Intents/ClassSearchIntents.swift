//
//  ClassSearchIntents.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppIntents
import Foundation

/// "What's my next class?" — answered from the schedule shared with the
/// widgets, without opening the app.
struct NextClassIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Class"
    static let description = IntentDescription("Tells you when and where your next class is, based on My Schedule.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let data = WidgetScheduleData.load() else {
            return .result(dialog: "You haven't set up My Schedule yet. Build a schedule in Term Organize and mark it as My Schedule.")
        }
        guard let next = data.occurrences(from: .now, limit: 1).first else {
            return .result(dialog: "You have no upcoming classes in \(data.planName).")
        }
        let time = next.start.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let day: String
        if next.start <= .now {
            return .result(dialog: "You're in \(next.meeting.courseCode) right now, in \(next.meeting.location), until \(next.end.formatted(date: .omitted, time: .shortened)).")
        } else if calendar.isDateInToday(next.start) {
            day = "today"
        } else if calendar.isDateInTomorrow(next.start) {
            day = "tomorrow"
        } else {
            day = "on \(next.start.formatted(.dateTime.weekday(.wide)))"
        }
        return .result(dialog: "Your next class is \(next.meeting.courseCode), \(next.meeting.title), \(day) at \(time) in \(next.meeting.location).")
    }
}

/// Opens the Schedule tab.
struct OpenScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "Open My Schedule"
    static let description = IntentDescription("Opens your schedules in Term Organize.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AppLink.url("schedule")!))
    }
}

/// Opens search with a query.
struct SearchCoursesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Courses"
    static let description = IntentDescription("Searches Northeastern courses by code, title, professor or CRN.")

    @Parameter(title: "Search", requestValueDialog: "What would you like to search for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search courses for \(\.$query)")
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        var components = URLComponents(string: "\(AppLink.scheme)://search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return .result(opensIntent: OpenURLIntent(components.url!))
    }
}

struct ClassSearchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextClassIntent(),
            phrases: [
                "What's my next class in \(.applicationName)",
                "Next class in \(.applicationName)",
            ],
            shortTitle: "Next Class",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: OpenScheduleIntent(),
            phrases: ["Show my schedule in \(.applicationName)"],
            shortTitle: "My Schedule",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: SearchCoursesIntent(),
            phrases: ["Search courses in \(.applicationName)"],
            shortTitle: "Search Courses",
            systemImageName: "magnifyingglass"
        )
    }
}
