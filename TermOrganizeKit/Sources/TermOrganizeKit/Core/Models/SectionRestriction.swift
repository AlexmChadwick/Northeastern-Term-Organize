//
//  SectionRestriction.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Banner's getRestrictions fragment, parsed into must/cannot lists. A section
//  is CPS-only when its Must Levels are only "CPS - ..." values, or its Must
//  Colleges list is only the College of Professional Studies.
//

import Foundation

/// One restriction list from Banner (`Must` or `Cannot` be enrolled in a category).
struct SectionRestriction: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case must
        case cannot
    }

    var kind: Kind
    /// Banner's category, such as `Levels` or `Colleges`.
    var category: String
    var values: [String]
}

enum RestrictionParser {
    /// Headings and the values that follow them. An empty result means the
    /// fragment was read and listed nothing. A failed request stays nil upstream.
    static func parse(_ html: String) -> [SectionRestriction] {
        let lines = plainLines(html)
        var restrictions: [SectionRestriction] = []
        var current: SectionRestriction?
        func flush() {
            if var current {
                current.values = current.values.filter { !$0.isEmpty }
                if !current.values.isEmpty { restrictions.append(current) }
            }
            current = nil
        }
        for line in lines {
            if let heading = heading(line) {
                flush()
                current = SectionRestriction(kind: heading.kind, category: heading.category, values: [])
            } else if current != nil {
                current?.values.append(line)
            }
        }
        flush()
        return restrictions
    }

    private static func heading(_ line: String) -> (kind: SectionRestriction.Kind, category: String)? {
        let mustPrefix = "must be enrolled in one of the following "
        let cannotPrefix = "cannot be enrolled in one of the following "
        let lower = line.lowercased()
        let kind: SectionRestriction.Kind
        let rest: Substring
        if lower.hasPrefix(mustPrefix) {
            kind = .must
            rest = line.dropFirst(mustPrefix.count)
        } else if lower.hasPrefix(cannotPrefix) {
            kind = .cannot
            rest = line.dropFirst(cannotPrefix.count)
        } else {
            return nil
        }
        var category = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if category.hasSuffix(":") { category.removeLast() }
        category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty else { return nil }
        return (kind, category)
    }

    /// Tag-strips without NSRegularExpression. Banner fragments are small, and
    /// this stays reliable where Foundation's HTML helpers return nothing.
    static func plainLines(_ html: String) -> [String] {
        var source = html
        while let start = source.range(of: "<!--"),
              let end = source.range(of: "-->", range: start.upperBound..<source.endIndex) {
            source.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var text = ""
        text.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "<" {
                let rest = source[index...].lowercased()
                if rest.hasPrefix("<br") || rest.hasPrefix("</p") || rest.hasPrefix("</div")
                    || rest.hasPrefix("</li") || rest.hasPrefix("</tr") || rest.hasPrefix("</h") {
                    text.append("\n")
                }
                if let close = source[index...].firstIndex(of: ">") {
                    index = source.index(after: close)
                    continue
                }
            }
            text.append(source[index])
            index = source.index(after: index)
        }
        text = HTMLText.decodeEntities(HTMLText.decodeEntities(text))
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum CPSNote {
    static let only = "Restricted to CPS (College of Professional Studies) students"
    static let some = "Some sections are CPS only"

    /// Nil when restrictions were never loaded. False when they were loaded and
    /// the section is not CPS-only. Cannot lists never qualify.
    static func isCPSOnly(_ restrictions: [SectionRestriction]?) -> Bool? {
        guard let restrictions else { return nil }
        let musts = restrictions.filter { $0.kind == .must }
        let levels = musts.filter { $0.category.caseInsensitiveCompare("Levels") == .orderedSame && !$0.values.isEmpty }
        let colleges = musts.filter { $0.category.caseInsensitiveCompare("Colleges") == .orderedSame && !$0.values.isEmpty }
        let levelsAreCPS = !levels.isEmpty && levels.allSatisfy { list in
            list.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("CPS -") }
        }
        let collegesAreCPS = !colleges.isEmpty && colleges.allSatisfy { list in
            list.values.allSatisfy(isProfessionalStudiesCollege)
        }
        return levelsAreCPS || collegesAreCPS
    }

    /// True when every section was loaded and all of them are CPS-only.
    /// False when a loaded section is not. Nil when that is still unknown.
    static func courseFlag(sections: [CourseSection]) -> Bool? {
        let flags = sections.map { isCPSOnly($0.restrictions) }
        if flags.contains(where: { $0 == false }) { return false }
        if !flags.isEmpty, flags.allSatisfy({ $0 == true }) { return true }
        return nil
    }

    /// The course caption. Nothing when no section is known to be CPS-only.
    /// The full sentence when every section was loaded and all of them are.
    /// The shorter sentence when at least one is and the rest are not, or not yet loaded.
    static func courseCaption(sections: [CourseSection]) -> String? {
        let flags = sections.map { isCPSOnly($0.restrictions) }
        let cps = flags.filter { $0 == true }.count
        let notCPS = flags.filter { $0 == false }.count
        let unknown = flags.filter { $0 == nil }.count
        guard cps > 0 else { return nil }
        if notCPS == 0 && unknown == 0 { return only }
        return some
    }

    static func isProfessionalStudiesCollege(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "cps" || trimmed.hasPrefix("cps -") || trimmed.hasPrefix("cps-") { return true }
        return trimmed.contains("college of professional studies")
    }
}
