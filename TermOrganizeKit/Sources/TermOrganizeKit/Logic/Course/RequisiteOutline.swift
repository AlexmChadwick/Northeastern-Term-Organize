//
//  RequisiteOutline.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  How a prerequisite or corequisite is laid out on the course page.
//
//  Banner stores requisites as nested "and" / "or" trees. CS 3000's is
//  `((CS 2100 or CS 201M or CS 2510 or DS 2500) and (CS 1800 or MATH 209M or
//  EECE 2160)) or CS 2700`, which is correct but reads badly when each level of
//  the tree becomes a level of boxes ("One of > All of > One of"). This file
//  decides what to draw instead, and the views only draw it:
//
//  - Groups that need no nesting are flattened: a group of one is that one,
//    "and" inside "and" and "or" inside "or" merge, and an alternative Banner
//    lists twice is shown once.
//  - A group of plain courses is one flat group ("One of" / "All of these").
//  - An "and" that mixes courses with "one of" choices is a checklist.
//  - An "or" with compound branches is a set of numbered options (paths).
//  - Never more than two levels: anything deeper is drawn as an inline expression.
//
//  It also writes the sentence VoiceOver reads. Nothing here touches SwiftUI.
//

import Foundation

// MARK: - Display form of a requisite

extension Requisite {
    /// The requisite as the course page reads it.
    ///
    /// A group of one becomes that one, an "and" inside an "and" (or an "or" inside
    /// an "or") merges into its parent, and an alternative Banner lists more than once
    /// is kept once, so `(A or A or B) and (C and D)` reads as `(A or B) and C and D`.
    /// Nil when nothing is left.
    func normalizedForDisplay() -> Requisite? {
        switch self {
        case .course, .test:
            return self
        case .and(let items):
            return Requisite.merging(items, asAnd: true)
        case .or(let items):
            return Requisite.merging(items, asAnd: false)
        }
    }

    private static func merging(_ items: [Requisite], asAnd: Bool) -> Requisite? {
        var members: [Requisite] = []
        var seen = Set<String>()
        func add(_ member: Requisite) {
            if seen.insert(member.displayKey).inserted { members.append(member) }
        }
        for item in items {
            guard let member = item.normalizedForDisplay() else { continue }
            switch member {
            case .and(let inner) where asAnd, .or(let inner) where !asAnd:
                inner.forEach(add)
            default:
                add(member)
            }
        }
        switch members.count {
        case 0: return nil
        case 1: return members[0]
        default: return asAnd ? .and(members) : .or(members)
        }
    }

    /// Identifies a requisite whatever the order of its members, to spot repeats.
    private var displayKey: String {
        switch self {
        case .course(let key):
            return "c:\(key.description)"
        case .test(let name, let score):
            return "t:\(name):\(score.map { String($0) } ?? "")"
        case .and(let items):
            return "and(" + items.map(\.displayKey).sorted().joined(separator: ",") + ")"
        case .or(let items):
            return "or(" + items.map(\.displayKey).sorted().joined(separator: ",") + ")"
        }
    }
}

// MARK: - Items

/// A course or a placement test, with what the card needs to draw it.
struct RequisiteItem: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case course(CourseKey)
        case test(name: String, score: Double?)
    }

    var kind: Kind
    /// Whether the user's degree plan counts the course as done. Tests are never
    /// marked: nothing records them.
    var isComplete = false
    /// The course that counted when it was not this one (a renumbered or
    /// cross-listed equivalent). Only set on a completed course.
    var via: CourseKey?
    /// Whether this term's catalog lists the course, so it has a page to open.
    var isOffered = true

    var id: String {
        switch kind {
        case .course(let key): "c:\(key.description)"
        case .test(let name, let score): "t:\(name):\(score.map { String($0) } ?? "")"
        }
    }

    var courseKey: CourseKey? {
        if case .course(let key) = kind { return key }
        return nil
    }

    /// A course drawn as a greyed-out chip: this term's catalog doesn't list it and the
    /// user hasn't completed it (a completed course is drawn green instead).
    var isGreyedOut: Bool { courseKey != nil && !isOffered && !isComplete }

    /// A placement test's minimum score, when it adds anything. Banner sometimes
    /// repeats a course number as the "score" ("Placement in SPNS 1101", 1101).
    var scoreText: String? {
        guard case .test(let name, let score) = kind, let score else { return nil }
        let text = score.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
        return name.contains(text) ? nil : text
    }
}

// MARK: - Normalized tree

/// A normalized requisite: courses and tests, "all of" groups and "one of" groups.
/// Groups hold two or more members and never directly hold a group of their own kind.
indirect enum RequisiteNode: Hashable, Sendable {
    case item(RequisiteItem)
    case all([RequisiteNode])
    case oneOf([RequisiteNode])

    /// Normalizes `requisite` and marks each course with what `isOffered` and
    /// `completion` say about it. Nil when the requisite is empty.
    init?(
        _ requisite: Requisite,
        isOffered: (CourseKey) -> Bool,
        completion: (CourseKey) -> (isComplete: Bool, via: CourseKey?)
    ) {
        guard let tree = requisite.normalizedForDisplay() else { return nil }
        self = RequisiteNode.make(tree, isOffered: isOffered, completion: completion)
    }

    private static func make(
        _ requisite: Requisite,
        isOffered: (CourseKey) -> Bool,
        completion: (CourseKey) -> (isComplete: Bool, via: CourseKey?)
    ) -> RequisiteNode {
        switch requisite {
        case .course(let key):
            let status = completion(key)
            return .item(RequisiteItem(
                kind: .course(key),
                isComplete: status.isComplete,
                via: status.isComplete ? status.via : nil,
                isOffered: isOffered(key)
            ))
        case .test(let name, let score):
            return .item(RequisiteItem(kind: .test(name: name, score: score)))
        case .and(let items):
            return .all(items.map { make($0, isOffered: isOffered, completion: completion) })
        case .or(let items):
            return .oneOf(items.map { make($0, isOffered: isOffered, completion: completion) })
        }
    }

    /// Every course and test in the tree, in order.
    var allItems: [RequisiteItem] {
        switch self {
        case .item(let item): [item]
        case .all(let members), .oneOf(let members): members.flatMap(\.allItems)
        }
    }
}

private extension Array where Element == RequisiteNode {
    /// The members when every one is a plain course or test.
    var itemMembers: [RequisiteItem]? {
        var items: [RequisiteItem] = []
        for member in self {
            guard case .item(let item) = member else { return nil }
            items.append(item)
        }
        return items
    }

    /// The members with groups of the same kind merged in (normalized nodes have none).
    func flattened(oneOf: Bool) -> [RequisiteNode] {
        flatMap { member -> [RequisiteNode] in
            switch member {
            case .oneOf(let inner) where oneOf: inner.flattened(oneOf: true)
            case .all(let inner) where !oneOf: inner.flattened(oneOf: false)
            default: [member]
            }
        }
    }
}

private extension Array where Element == RequisiteItem {
    /// Alternatives in the order a student cares about: what they have completed,
    /// then what is offered this term, then the rest. Otherwise as Banner lists them.
    func inChoiceOrder() -> [RequisiteItem] {
        func rank(_ item: RequisiteItem) -> Int {
            if item.isComplete { return 0 }
            return item.courseKey != nil && item.isOffered ? 1 : 2
        }
        return enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.element), rank(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// MARK: - Layout

/// Two or more plain courses or tests, all of them or any one of them.
struct RequisiteGroup: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case all
        case oneOf
    }

    var kind: Kind
    var items: [RequisiteItem]

    /// Whether completed courses already meet the group.
    var isDone: Bool {
        switch kind {
        case .all: items.allSatisfy(\.isComplete)
        case .oneOf: items.contains(where: \.isComplete)
        }
    }

    /// For a "one of" group that is done, the course that did it ("Done with CS 2510").
    var doneWith: CourseKey? {
        guard kind == .oneOf, let done = items.first(where: \.isComplete) else { return nil }
        return done.via ?? done.courseKey
    }
}

/// One requirement inside a checklist or an option.
enum RequisitePart: Hashable, Sendable {
    /// A single required course or test.
    case item(RequisiteItem)
    /// Courses grouped: "one of" these, or all of these (several loose required courses).
    case group(RequisiteGroup)
    /// A choice that is itself compound, too deep for boxes: drawn inline.
    case expression(RequisiteNode)

    var isDone: Bool {
        switch self {
        case .item(let item): item.isComplete
        case .group(let group): group.isDone
        case .expression(let node): node.isDone
        }
    }
}

/// An "and" that mixes courses with "one of" choices: every part is needed.
struct RequisiteChecklist: Hashable, Sendable {
    /// How many separate requirements it holds, for "Both of these" / "All of these".
    var requirementCount: Int
    var parts: [RequisitePart]

    var isDone: Bool { parts.allSatisfy(\.isDone) }

    init(members: [RequisiteNode]) {
        let members = members.flattened(oneOf: false)
        var parts: [RequisitePart] = []
        var looseIndex: Int?
        var loose: [RequisiteItem] = []
        for member in members {
            switch member {
            case .item(let item):
                // Loose courses gather into one group where the first of them stood.
                if looseIndex == nil {
                    looseIndex = parts.count
                    parts.append(.item(item))
                }
                loose.append(item)
            case .oneOf(let alternatives):
                if let items = alternatives.itemMembers {
                    parts.append(.group(RequisiteGroup(kind: .oneOf, items: items.inChoiceOrder())))
                } else {
                    parts.append(.expression(member))
                }
            case .all:
                parts.append(.expression(member))
            }
        }
        if let looseIndex {
            parts[looseIndex] = loose.count == 1
                ? .item(loose[0])
                : .group(RequisiteGroup(kind: .all, items: loose))
        }
        self.requirementCount = members.count
        self.parts = parts
    }
}

/// One way to meet an "or" whose branches are not all plain courses.
struct RequisitePath: Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case item(RequisiteItem)
        case group(RequisiteGroup)
        case checklist(RequisiteChecklist)
    }

    var content: Content

    var isDone: Bool {
        switch content {
        case .item(let item): item.isComplete
        case .group(let group): group.isDone
        case .checklist(let checklist): checklist.isDone
        }
    }

    /// The options an "or" offers: each compound branch is an option, and the plain
    /// courses it lists gather into one option where the first of them stood.
    static func paths(from members: [RequisiteNode]) -> [RequisitePath] {
        var paths: [RequisitePath] = []
        var looseIndex: Int?
        var loose: [RequisiteItem] = []
        for member in members.flattened(oneOf: true) {
            switch member {
            case .item(let item):
                if looseIndex == nil {
                    looseIndex = paths.count
                    paths.append(RequisitePath(content: .item(item)))
                }
                loose.append(item)
            case .all(let inner):
                if let items = inner.itemMembers {
                    paths.append(RequisitePath(content: .group(RequisiteGroup(kind: .all, items: items))))
                } else {
                    paths.append(RequisitePath(content: .checklist(RequisiteChecklist(members: inner))))
                }
            case .oneOf:
                break
            }
        }
        if let looseIndex {
            paths[looseIndex].content = loose.count == 1
                ? .item(loose[0])
                : .group(RequisiteGroup(kind: .oneOf, items: loose.inChoiceOrder()))
        }
        return paths
    }
}

/// What the requirements card draws for a requisite.
enum RequisiteLayout: Hashable, Sendable {
    /// One course or test.
    case item(RequisiteItem)
    /// Two or more plain courses or tests: "One of" / "All of these".
    case group(RequisiteGroup)
    /// Courses mixed with "one of" choices; every part is needed.
    case checklist(RequisiteChecklist)
    /// Alternative ways in, numbered and joined by "or".
    case paths([RequisitePath])

    /// Nil when the requisite is empty.
    init?(
        _ requisite: Requisite,
        isOffered: (CourseKey) -> Bool,
        completion: (CourseKey) -> (isComplete: Bool, via: CourseKey?)
    ) {
        guard let node = RequisiteNode(requisite, isOffered: isOffered, completion: completion) else { return nil }
        self.init(node)
    }

    init(_ node: RequisiteNode) {
        switch node {
        case .item(let item):
            self = .item(item)
        case .all(let members):
            let members = members.flattened(oneOf: false)
            if let items = members.itemMembers {
                self = .group(RequisiteGroup(kind: .all, items: items))
            } else {
                self = .checklist(RequisiteChecklist(members: members))
            }
        case .oneOf(let members):
            let members = members.flattened(oneOf: true)
            if let items = members.itemMembers {
                self = .group(RequisiteGroup(kind: .oneOf, items: items.inChoiceOrder()))
            } else {
                self = .paths(RequisitePath.paths(from: members))
            }
        }
    }

    /// Whether completed courses already meet the whole requisite (placement tests
    /// are never counted: nothing records them).
    var isDone: Bool {
        switch self {
        case .item(let item): item.isComplete
        case .group(let group): group.isDone
        case .checklist(let checklist): checklist.isDone
        case .paths(let paths): paths.contains(where: \.isDone)
        }
    }

    /// Whether any chip is greyed out, so the card should explain grey. (A lone
    /// course is a row, which says "Not offered this term" itself.)
    var hasGreyedOutChips: Bool {
        switch self {
        case .item: false
        case .group(let group): group.items.contains(where: \.isGreyedOut)
        case .checklist(let checklist): checklist.hasGreyedOutChips
        case .paths(let paths): paths.contains { $0.hasGreyedOutChips }
        }
    }
}

extension RequisiteChecklist {
    var hasGreyedOutChips: Bool {
        parts.contains { part in
            switch part {
            case .item: false
            case .group(let group): group.items.contains(where: \.isGreyedOut)
            case .expression(let node): node.allItems.contains(where: \.isGreyedOut)
            }
        }
    }
}

extension RequisitePath {
    var hasGreyedOutChips: Bool {
        switch content {
        case .item: false
        case .group(let group): group.items.contains(where: \.isGreyedOut)
        case .checklist(let checklist): checklist.hasGreyedOutChips
        }
    }
}

extension RequisiteNode {
    /// Whether completed courses already meet the node.
    var isDone: Bool {
        switch self {
        case .item(let item): item.isComplete
        case .all(let members): members.allSatisfy(\.isDone)
        case .oneOf(let members): members.contains(where: \.isDone)
        }
    }

    /// For a "one of" that is done through a single course, that course ("Done with
    /// CS 2510"). Nil when a compound alternative did it, or it isn't done.
    var doneWith: CourseKey? {
        guard case .oneOf(let members) = self,
              let done = members.first(where: \.isDone),
              case .item(let item) = done else { return nil }
        return item.via ?? item.courseKey
    }
}

// MARK: - VoiceOver

private func spokenList(_ names: [String], joining word: String) -> String {
    guard let last = names.last else { return "" }
    guard names.count > 1 else { return last }
    return names.dropLast().joined(separator: ", ") + " \(word) " + last
}

extension RequisiteItem {
    /// How the item is read in a sentence: "CS 2510 (completed)".
    var spokenText: String {
        switch kind {
        case .course(let key):
            guard isComplete else { return key.description }
            if let via { return "\(key.description) (completed via \(via.description))" }
            return "\(key.description) (completed)"
        case .test(let name, _):
            guard let scoreText else { return name }
            return "\(name) (minimum score \(scoreText))"
        }
    }
}

extension RequisiteGroup {
    /// "one of CS 2100, CS 2510 or DS 2500", "both CS 2510 and CS 1800".
    var spokenText: String {
        let names = items.map(\.spokenText)
        switch kind {
        case .oneOf:
            return "one of " + spokenList(names, joining: "or")
        case .all:
            return names.count == 2
                ? "both \(names[0]) and \(names[1])"
                : "all of " + spokenList(names, joining: "and")
        }
    }
}

extension RequisiteNode {
    /// A compound requirement as a phrase, for the rare choice that is too deep to
    /// draw as boxes: "either ME 4550, or ME 4570, or all of IE 4510, IE 4515 and
    /// IE 4516". The commas before each "or" keep the "and" groups apart.
    var spokenExpression: String {
        switch self {
        case .item(let item):
            return item.spokenText
        case .all(let members):
            let spoken = members.map(\.spokenExpression)
            return spoken.count == 2
                ? "both \(spoken[0]) and \(spoken[1])"
                : "all of " + spokenList(spoken, joining: "and")
        case .oneOf(let members):
            return "either " + members.map(\.spokenExpression).joined(separator: ", or ")
        }
    }
}

extension RequisitePart {
    var spokenText: String {
        switch self {
        case .item(let item): item.spokenText
        case .group(let group): group.spokenText
        case .expression(let node): node.spokenExpression
        }
    }

    var isExpression: Bool {
        if case .expression = self { return true }
        return false
    }
}

extension RequisiteChecklist {
    var spokenText: String {
        // Parts that hold "or"s read more clearly with a stronger break between them.
        let separator = parts.contains(where: \.isExpression) ? "; and " : ", and "
        return parts.map(\.spokenText).joined(separator: separator)
    }
}

extension RequisitePath {
    var spokenText: String {
        switch content {
        case .item(let item): item.spokenText
        case .group(let group): group.spokenText
        case .checklist(let checklist): checklist.spokenText
        }
    }
}

extension RequisiteLayout {
    /// The whole requirement as one sentence for VoiceOver, e.g. "Prerequisites:
    /// either one of CS 2100, CS 201M, CS 2510 or DS 2500, and one of CS 1800,
    /// MATH 209M or EECE 2160; or CS 2700."
    func spokenDescription(title: String) -> String {
        let body: String
        switch self {
        case .item(let item): body = item.spokenText
        case .group(let group): body = group.spokenText
        case .checklist(let checklist): body = checklist.spokenText
        case .paths(let paths): body = "either " + paths.map(\.spokenText).joined(separator: "; or ")
        }
        return "\(title): \(body)."
    }
}
