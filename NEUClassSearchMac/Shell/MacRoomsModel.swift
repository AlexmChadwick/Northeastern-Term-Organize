//
//  MacRoomsModel.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One classroom with its status at the moment on screen: a row of the rooms list.
struct MacRoomRow: Identifiable {
    var entry: RoomAvailability.Entry
    var buildingName: String
    /// Minutes from the moment on screen until the status changes (the rest of the day when free all day).
    var minutesLeft: Int
    var tint: Color

    var id: String { entry.id }
    var room: RoomSchedule { entry.room }
    var label: String { entry.room.label }
    var isFree: Bool { entry.status.isFree }

    /// Sorts `WVH 210` before `WVH 1010` and `RY 210` before `WVH 210`.
    var naturalKey: String { Self.naturalKey(entry.room.label) }

    /// `Free until 2:50 PM`, `In use until 11:35 AM`, or, shorter than the usual sentence, `Free · rest of day`.
    var statusText: String {
        if case .free(nil) = entry.status { return "Free · rest of day" }
        return entry.status.summary
    }

    /// `45 min`, `1 hr 20 min`, `2 hr`; `Rest of day` for a room with no class left today.
    var durationText: String {
        if case .free(nil) = entry.status { return "Rest of day" }
        return Self.duration(minutes: minutesLeft)
    }

    static func duration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }

    /// Pads every run of digits to six places so text compares the way people read room numbers.
    static func naturalKey(_ text: String) -> String {
        var result = ""
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else {
                if !digits.isEmpty { result += String(repeating: "0", count: max(0, 6 - digits.count)) + digits; digits = "" }
                result.append(character)
            }
        }
        if !digits.isEmpty { result += String(repeating: "0", count: max(0, 6 - digits.count)) + digits }
        return result
    }
}

/// How the rooms of a building are ordered.
enum MacRoomsOrder: String, CaseIterable, Identifiable {
    /// The rooms free for longest first, then the ones in use that empty soonest.
    case availability
    case number

    var id: String { rawValue }

    var title: String {
        switch self {
        case .availability: "Availability"
        case .number: "Room Number"
        }
    }
}

/// The side pane that is open over the list while the window is too narrow for both side panes
/// next to it: one at a time.
enum MacRoomsFloatingPane {
    case buildings
    case details
}

/// Which time the rooms are shown for.
enum MacRoomsTime: Hashable {
    case now
    case day(Int)
}

/// Which campus's buildings are listed.
enum MacRoomsCampus: Hashable {
    /// The preferred campus from Settings when it has buildings, otherwise everything.
    case automatic
    case all
    case campus(String)
}

struct MacRoomsCampusOption: Identifiable, Hashable {
    var code: String
    var name: String
    var buildingCount: Int
    var id: String { code }
}

extension CatalogIndex {
    /// Campuses that have buildings, the one with most buildings first.
    var roomsCampusOptions: [MacRoomsCampusOption] {
        var counts: [String: Int] = [:]
        for building in buildings {
            if let code = building.campusCode { counts[code, default: 0] += 1 }
        }
        return counts
            .map { MacRoomsCampusOption(code: $0.key, name: roomsCampusName(forCode: $0.key) ?? $0.key, buildingCount: $0.value) }
            .sorted { lhs, rhs in
                lhs.buildingCount != rhs.buildingCount ? lhs.buildingCount > rhs.buildingCount : lhs.name < rhs.name
            }
    }

    /// The room with this `RoomSchedule.id`, if the term has it.
    func roomsRoom(withID id: String) -> RoomSchedule? {
        for building in buildings {
            if let room = building.rooms.first(where: { $0.id == id }) { return room }
        }
        return nil
    }
}
