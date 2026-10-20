//
//  Term.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A Banner term such as `202710` ("Fall 2026 Semester").
///
/// Northeastern term codes are `YYYYSC`: the academic year the term ends in,
/// a season digit, and a college digit (0 = semester, 2 = Law, 4 = CPS
/// semester, 5 = CPS quarter, 8 = Law quarter).
struct Term: Codable, Hashable, Identifiable, Sendable, Comparable {
    /// Six digit Banner code, e.g. `202710`.
    var code: String
    /// Banner's raw description, e.g. `Fall 2026 Semester (View Only)`.
    var bannerDescription: String

    var id: String { code }

    init(code: String, bannerDescription: String) {
        self.code = code
        self.bannerDescription = bannerDescription
    }

    /// Human friendly name, e.g. `Fall 2026` or `Spring 2026 (CPS Quarter)`.
    var name: String {
        var s = bannerDescription
            .replacingOccurrences(of: "(View Only)", with: "")
            .trimmingCharacters(in: .whitespaces)
        switch college {
        case .neu:
            s = s.replacingOccurrences(of: " Semester", with: "")
        case .cps, .law:
            // "Spring 2026 CPS Quarter" -> "Spring 2026 · CPS Quarter"
            for marker in [" CPS ", " Law "] {
                if let r = s.range(of: marker) {
                    let head = s[..<r.lowerBound]
                    let tail = s[r.lowerBound...].trimmingCharacters(in: .whitespaces)
                    s = "\(head) · \(tail)"
                    break
                }
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Short name without the college qualifier, e.g. `Fall 2026`.
    var shortName: String {
        name.components(separatedBy: " · ").first ?? name
    }

    /// Whether Banner marks this term as view only (registration closed).
    var isViewOnly: Bool { bannerDescription.localizedCaseInsensitiveContains("view only") }

    var college: College {
        guard let last = code.last else { return .neu }
        switch last {
        case "4", "5": return .cps
        case "2", "8": return .law
        default: return .neu
        }
    }

    enum College: String, Codable, Sendable, CaseIterable {
        case neu, cps, law

        var displayName: String {
            switch self {
            case .neu: "Northeastern"
            case .cps: "Professional Studies"
            case .law: "School of Law"
            }
        }
    }

    enum Season: String, Sendable {
        case fall, winter, spring, summer1, summerFull, summer2

        var displayName: String {
            switch self {
            case .fall: "Fall"
            case .winter: "Winter"
            case .spring: "Spring"
            case .summer1: "Summer 1"
            case .summerFull: "Summer"
            case .summer2: "Summer 2"
            }
        }
    }

    var season: Season {
        let chars = Array(code)
        guard chars.count == 6 else { return .fall }
        switch chars[4] {
        case "1": return .fall
        case "2": return .winter
        case "3": return .spring
        case "4": return .summer1
        case "6": return .summer2
        default: return .summerFull
        }
    }

    /// The calendar year in which the term takes place (Fall 2026 has code 2027xx).
    var calendarYear: Int {
        let year = Int(code.prefix(4)) ?? 0
        return season == .fall ? year - 1 : year
    }

    static func < (lhs: Term, rhs: Term) -> Bool { lhs.code < rhs.code }
}
