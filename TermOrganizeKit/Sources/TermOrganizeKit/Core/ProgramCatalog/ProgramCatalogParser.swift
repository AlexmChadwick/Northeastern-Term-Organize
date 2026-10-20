//
//  ProgramCatalogParser.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Reads Northeastern's academic catalog (catalog.northeastern.edu, a CourseLeaf site):
/// which editions exist, the degree programs of an edition, and a program's requirements.
///
/// Nothing here depends on a particular year. The current edition is read from the site's
/// own header ("Academic Catalog 2026-2027") and archived editions from its archive page, so
/// a new edition works without an app update. Requirement tables have had the same markup
/// in every edition online (2016–2017 on):
///
///     <h2>Computer Science Requirements</h2>
///     <table class="sc_courselist">
///       <tr class="areaheader">…Computer Science Required Courses…</tr>
///       <tr><td class="codecol"><a>CS 3000</a></td><td>Algorithms and Data</td><td class="hourscol">4</td></tr>
///       <tr class="orclass"><td class="codecol">or <a>CS 4530</a></td>…</tr>
///       <tr><td colspan="2"><span class="courselistcomment">Complete one of the following:</span></td><td class="hourscol">4</td></tr>
///       <tr><td class="codecol"><a>CY 2550</a></td><td>…</td><td class="hourscol"></td></tr>
///       <tr><td colspan="2"><span class="courselistcomment"><a>CS 2500</a> or higher, except <a>CS 5010</a></span></td>…</tr>
enum ProgramCatalogParser {
    // MARK: Editions

    /// The edition the site serves at its root, from any page's header
    /// ("Academic Catalog 2026-2027", "2026-2027 Edition").
    static func currentEdition(fromHTML html: String) -> CatalogYear? {
        let text = HTMLText.decodeEntities(html)
        for pattern in [#"Academic Catalog\s+\d{4}\s*[-–]\s*\d{2,4}"#, #"\d{4}\s*[-–]\s*\d{2,4}\s+Edition"#] {
            if let range = text.range(of: pattern, options: .regularExpression),
               let year = CatalogYear(string: String(text[range])) {
                return year
            }
        }
        return nil
    }

    /// Archived editions linked from a page (the archive page links each `/archive/<year>/`).
    static func archivedEditions(fromHTML html: String) -> [CatalogYear] {
        var years = Set<CatalogYear>()
        for match in html.matches(of: #/archive/(\d{4})-(\d{4})/#) {
            guard let start = Int(match.1), let end = Int(match.2), end == start + 1 else { continue }
            years.insert(CatalogYear(startYear: start))
        }
        return years.sorted(by: >)
    }

    // MARK: Programs

    /// Degree programs (`Computer Science, BSCS (Boston)`) from an edition's A–Z index.
    static func programs(fromAZIndexHTML html: String) -> [CatalogProgram] {
        var byPath: [String: CatalogProgram] = [:]
        for (href, label) in links(in: html) {
            let path = editionRelativePath(href)
            guard path.hasPrefix("undergraduate/") || path.hasPrefix("graduate/"), path.hasSuffix("/") else { continue }
            let title = HTMLText.plainText(label)
            let program = CatalogProgram(title: title, path: path)
            guard let degree = program.degree, degree.first?.isUppercase == true,
                  degree.filter(\.isUppercase).count >= 2, byPath[path] == nil else { continue }
            byPath[path] = program
        }
        return byPath.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// `/archive/2023-2024/undergraduate/x/` or `https://catalog.northeastern.edu/undergraduate/x/`
    /// → `undergraduate/x/`.
    static func editionRelativePath(_ href: String) -> String {
        var path = href
        if let url = URL(string: href), url.host != nil { path = url.path + (href.hasSuffix("/") && !url.path.hasSuffix("/") ? "/" : "") }
        path = path.replacingOccurrences(of: #"^/?archive/\d{4}-\d{4}/?"#, with: "", options: .regularExpression)
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    // MARK: Requirements

    /// The requirements on a program page; nil when the page has no requirement tables.
    static func requirements(fromHTML html: String, year: CatalogYear, program: CatalogProgram, fetchedAt: Date = .now) -> ProgramRequirements? {
        var builder = RequirementsBuilder()
        for token in tokens(in: requirementsContainer(of: html)) {
            switch token {
            case .heading(let text): builder.startSection(text)
            case .paragraph(let text): builder.addParagraph(text)
            case .table(let table): builder.addTable(table)
            }
        }
        let sections = builder.finish()
        guard sections.contains(where: { !$0.groups.isEmpty }) else { return nil }
        return ProgramRequirements(year: year, program: program, sections: sections, totalHours: builder.totalHours,
                                   fetchedAt: fetchedAt, courseTitles: builder.courseTitles)
    }

    // MARK: Universitywide requirements

    /// The edition's universitywide requirements page as a program page links it, relative to
    /// the edition (`undergraduate/university-academics/university-wide-requirements/`); nil when
    /// the page doesn't link one.
    static func universitywideLink(in html: String) -> String? {
        for (href, _) in links(in: html) where href.range(of: #"(?i)university-?wide-?requirements"#, options: .regularExpression) != nil {
            let path = editionRelativePath(href.components(separatedBy: "#")[0])
            if !path.isEmpty { return path.hasSuffix("/") ? path : path + "/" }
        }
        return nil
    }

    /// The minimums on a "Universitywide Requirements" page: "Minimum 128 total semester hours
    /// required", "Minimum 2.000 GPA required", "Students must earn a minimum of 64 Northeastern
    /// University semester hours…", "…including the experiential learning graduation
    /// requirement". Nil when the page states none of them.
    static func universitywideRequirements(fromHTML html: String, fetchedAt: Date = .now) -> UniversitywideRequirements? {
        let text = HTMLText.plainText(requirementsContainer(of: html))
        func number(_ pattern: some RegexComponent<(Substring, Substring)>) -> Double? {
            text.firstMatch(of: pattern).flatMap { Double($0.1) }
        }
        let requirements = UniversitywideRequirements(
            totalHours: number(#/(?i)minimum\s+(?:of\s+)?(\d+(?:\.\d+)?)\s+total\s+semester\s+hours/#),
            gpa: number(#/(?i)minimum\s+(?:cumulative\s+)?(\d\.\d+)\s+GPA/#),
            residencyHours: number(#/(?i)minimum\s+of\s+(\d+(?:\.\d+)?)\s+Northeastern\s+University\s+semester\s+hours/#),
            requiresExperientialLearning: text.firstMatch(of: #/(?i)experiential\s+learning\s+graduation\s+requirement/#) != nil,
            fetchedAt: fetchedAt
        )
        guard requirements.totalHours != nil || requirements.gpa != nil || requirements.residencyHours != nil
                || requirements.requiresExperientialLearning else { return nil }
        return requirements
    }

    /// The "Program Requirements" tab (pages without tabs: the main text).
    static func requirementsContainer(of html: String) -> String {
        let start = html.range(of: #"<div[^>]*id="programrequirementstextcontainer""#, options: .regularExpression)
            ?? html.range(of: #"<div[^>]*id="textcontainer""#, options: .regularExpression)
        guard let start else { return html }
        let rest = html[start.upperBound...]
        if let next = rest.range(of: #"<div[^>]*id="[a-z]+textcontainer""#, options: .regularExpression) {
            return String(rest[..<next.lowerBound])
        }
        if let footer = rest.range(of: "<footer", options: .caseInsensitive) {
            return String(rest[..<footer.lowerBound])
        }
        return String(rest)
    }

    // MARK: Tokens

    private enum Token {
        case heading(String)
        case paragraph(String)
        case table(String)
    }

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"<h([2-4])[^>]*>([\s\S]*?)</h\1>|<table[^>]*class="[^"]*sc_courselist[^"]*"[^>]*>([\s\S]*?)</table>|<p[^>]*>([\s\S]*?)</p>"#,
        options: [.caseInsensitive]
    )

    private static func tokens(in html: String) -> [Token] {
        let ns = html as NSString
        return tokenPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            func group(_ i: Int) -> String? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            if let heading = group(2) { return .heading(HTMLText.plainText(heading)) }
            if let table = group(3) { return .table(table) }
            if let paragraph = group(4) {
                let text = HTMLText.plainText(paragraph)
                return text.isEmpty ? nil : .paragraph(text)
            }
            return nil
        }
    }

    // MARK: Rows

    struct Row {
        enum Kind {
            case skip
            case areaHeader(String)
            case subheader(String)
            case comment(String)
            /// Course sets that satisfy the row (`CS 1800 and CS 1802`, `CS 4500 or CS 4530`).
            case courses([[CourseKey]], isAlternative: Bool)
        }

        var kind: Kind
        var hours: Double?
        /// The title column, one entry per course (`Discrete Structures`, `Seminar for CS 1800`).
        var titles: [String] = []
    }

    private static let rowPattern = try! NSRegularExpression(pattern: #"<tr([^>]*)>([\s\S]*?)</tr>"#, options: [.caseInsensitive])
    private static let cellPattern = try! NSRegularExpression(pattern: #"<t([dh])([^>]*)>([\s\S]*?)</t[dh]>"#, options: [.caseInsensitive])

    static func rows(inTable html: String) -> [Row] {
        let ns = html as NSString
        return rowPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            parseRow(attributes: ns.substring(with: match.range(at: 1)), body: ns.substring(with: match.range(at: 2)))
        }
    }

    private static func parseRow(attributes: String, body: String) -> Row {
        let rowClass = attributes.firstMatch(of: #/class="([^"]*)"/#).map { String($0.1) } ?? ""
        let ns = body as NSString
        var cells: [(isHeader: Bool, cls: String, html: String)] = []
        for match in cellPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: match.range(at: 2))
            cells.append((
                ns.substring(with: match.range(at: 1)).lowercased() == "h",
                attrs.firstMatch(of: #/class="([^"]*)"/#).map { String($0.1) } ?? "",
                ns.substring(with: match.range(at: 3))
            ))
        }
        let hours = cells.first { $0.cls.contains("hourscol") }.flatMap { hoursValue(HTMLText.plainText($0.html)) }

        if rowClass.contains("hidden") || cells.contains(where: \.isHeader) { return Row(kind: .skip) }
        if rowClass.contains("areasubheader") || body.contains("areasubheader") {
            return Row(kind: .subheader(HTMLText.plainText(body)), hours: hours)
        }
        if rowClass.contains("areaheader") || body.contains("courselistcomment areaheader") {
            return Row(kind: .areaHeader(HTMLText.plainText(body)), hours: hours)
        }
        if let code = cells.first(where: { $0.cls.contains("codecol") }) {
            let text = spacedText(code.html)
            let isAlternative = rowClass.contains("orclass") || code.cls.contains("orclass") || text.lowercased().hasPrefix("or ")
            let sets = courseSets(in: text)
            if !sets.isEmpty {
                let titleCell = cells.first { !$0.cls.contains("codecol") && !$0.cls.contains("hourscol") && !$0.isHeader }
                let titles = titleCell.map { HTMLText.plainText($0.html) }?
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.lowercased().hasPrefix("and ") ? String($0.dropFirst(4)) : $0 }
                    .filter { !$0.isEmpty } ?? []
                return Row(kind: .courses(sets, isAlternative: isAlternative), hours: hours, titles: titles)
            }
        }
        if body.contains("courselistcomment") {
            let text = spacedText(cells.first.map(\.html) ?? body)
            return text.isEmpty ? Row(kind: .skip) : Row(kind: .comment(text), hours: hours)
        }
        return Row(kind: .skip)
    }

    /// Plain text that keeps neighboring elements apart (`<a>CS 1800</a><span>and …` →
    /// `CS 1800 and …`).
    private static func spacedText(_ html: String) -> String {
        HTMLText.plainText(html.replacingOccurrences(of: "<", with: " <"))
            .replacingOccurrences(of: #"\s+([,.:;])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `CS 1800 and CS 1802` → [[CS 1800, CS 1802]]; `or CS 4530` → [[CS 4530]];
    /// `CS 4500 or CS 4530` → [[CS 4500], [CS 4530]].
    static func courseSets(in text: String) -> [[CourseKey]] {
        var cleaned = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        if cleaned.lowercased().hasPrefix("or ") { cleaned = String(cleaned.dropFirst(3)) }
        return cleaned.components(separatedBy: " or ").compactMap { part in
            let keys = courseKeys(in: part)
            return keys.isEmpty ? nil : keys
        }
    }

    static func courseKeys(in text: String) -> [CourseKey] {
        text.matches(of: #/\b([A-Z]{2,5})\s+(\d{4}[A-Z]?)\b/#).map { CourseKey(subject: String($0.1), number: String($0.2)) }
    }

    /// `4` → 4, `8-9` → 8, `` → nil.
    static func hoursValue(_ text: String) -> Double? {
        text.firstMatch(of: #/\d+(\.\d+)?/#).flatMap { Double($0.0) }
    }

    /// `CS 2500 or higher, except CS 5010`, `CS 2500 to CS 7999 but not CS 5010`.
    static func courseRange(in text: String) -> CourseRange? {
        let cleaned = text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
        if let match = cleaned.wholeMatch(of: #/([A-Z]{2,5}) (\d{4}) or (?:higher|above)(?:,? (?:except|excluding|but not) (.+?))?\.?/#),
           let lowest = Int(match.2) {
            return CourseRange(subject: String(match.1), lowest: lowest, highest: nil,
                               except: match.3.map { courseKeys(in: String($0)) } ?? [], label: cleaned)
        }
        if let match = cleaned.wholeMatch(of: #/([A-Z]{2,5}) (\d{4}) (?:to|through|-|–) (?:([A-Z]{2,5}) )?(\d{4})(?:,? (?:except|excluding|but not) (.+?))?\.?/#),
           let lowest = Int(match.2), let highest = Int(match.4),
           match.3.map({ String($0) == String(match.1) }) ?? true {
            return CourseRange(subject: String(match.1), lowest: lowest, highest: highest,
                               except: match.5.map { courseKeys(in: String($0)) } ?? [], label: cleaned)
        }
        return nil
    }

    /// What a "Complete …" line asks for: a number of options or of semester hours.
    static func chooseAmount(in text: String) -> (count: Int?, hours: Double?)? {
        let lower = text.lowercased()
        guard lower.hasPrefix("complete") || lower.hasPrefix("choose") || lower.hasPrefix("select") || lower.hasPrefix("take") else { return nil }
        if let match = lower.firstMatch(of: #/(\d+(?:\.\d+)?)(?:\s*[-–]\s*\d+)?\s+(?:semester hours?|credits?|credit hours?|sh)\b/#),
           let hours = Double(match.1) {
            return (nil, hours)
        }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
        if let match = lower.firstMatch(of: #/^(?:complete|choose|select|take)\s+(?:any\s+)?(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b/#) {
            let token = String(match.1)
            if let count = Int(token) ?? words[token] { return (count, nil) }
        }
        return nil
    }

    // MARK: Building

    private struct RuleDraft {
        enum Kind {
            case required([[CourseKey]])
            case choose(count: Int?, hours: Double?, options: [[[CourseKey]]], ranges: [CourseRange])
            case general(Double)
        }

        var kind: Kind
        var label: String
        var hours: Double?
        var notes: [String] = []
        /// The category subheader in effect when each option was listed.
        var optionCategories: [String?] = []
        var currentCategory: String?
    }

    private struct GroupDraft {
        var title: String?
        var rules: [RuleDraft] = []
        var notes: [String] = []
    }

    private struct SectionDraft {
        var title: String
        var groups: [GroupDraft] = []
        var notes: [String] = []
    }

    private struct RequirementsBuilder {
        var sections: [SectionDraft] = []
        var totalHours: Double?
        /// Catalog titles of the courses listed, first seen wins.
        var courseTitles: [CourseKey: String] = [:]
        /// Index of the "Complete …" rule that course rows without hours belong to.
        var chooseIndex: Int?

        mutating func startSection(_ title: String) {
            sections.append(SectionDraft(title: title.trimmingCharacters(in: .whitespaces)))
            chooseIndex = nil
        }

        mutating func addParagraph(_ text: String) {
            if let match = text.firstMatch(of: #/(\d+(?:\.\d+)?)\s+total semester hours/#), let hours = Double(match.1) {
                totalHours = max(totalHours ?? 0, hours)
            }
            guard !sections.isEmpty else { return }
            sections[sections.count - 1].notes.append(text)
        }

        mutating func addTable(_ html: String) {
            if sections.isEmpty { startSection("Program Requirements") }
            chooseIndex = nil
            var startedGroup = false
            for row in ProgramCatalogParser.rows(inTable: html) {
                switch row.kind {
                case .skip:
                    continue
                case .areaHeader(let title):
                    appendGroup(title: title)
                    startedGroup = true
                case .subheader(let title):
                    if let chooseIndex {
                        currentGroup.rules[chooseIndex].notes.append(title)
                        currentGroup.rules[chooseIndex].currentCategory = title
                    } else {
                        currentGroup.notes.append(title)
                    }
                case .comment(let text):
                    if !startedGroup { appendGroup(title: nil); startedGroup = true }
                    addComment(text, hours: row.hours)
                case .courses(let sets, let isAlternative):
                    if !startedGroup { appendGroup(title: nil); startedGroup = true }
                    addCourses(sets, isAlternative: isAlternative, hours: row.hours)
                    // Titles line up with the courses in order ("CS 1800 and CS 1802" has two).
                    for (key, title) in zip(sets.flatMap { $0 }, row.titles) where courseTitles[key] == nil {
                        courseTitles[key] = title
                    }
                }
            }
        }

        private mutating func appendGroup(title: String?) {
            sections[sections.count - 1].groups.append(GroupDraft(title: title))
            chooseIndex = nil
        }

        private var currentGroup: GroupDraft {
            get { sections[sections.count - 1].groups[sections[sections.count - 1].groups.count - 1] }
            set { sections[sections.count - 1].groups[sections[sections.count - 1].groups.count - 1] = newValue }
        }

        private mutating func addComment(_ text: String, hours: Double?) {
            if text.lowercased().contains("general elective"), let amount = hours ?? ProgramCatalogParser.chooseAmount(in: text)?.hours {
                currentGroup.rules.append(RuleDraft(kind: .general(amount), label: text, hours: amount))
                chooseIndex = nil
            } else if let range = ProgramCatalogParser.courseRange(in: text) {
                if let chooseIndex, case .choose(let count, let amount, let options, var ranges) = currentGroup.rules[chooseIndex].kind {
                    ranges.append(range)
                    currentGroup.rules[chooseIndex].kind = .choose(count: count, hours: amount, options: options, ranges: ranges)
                } else {
                    currentGroup.notes.append(text)
                }
            } else if let amount = ProgramCatalogParser.chooseAmount(in: text) {
                currentGroup.rules.append(RuleDraft(kind: .choose(count: amount.count, hours: amount.hours, options: [], ranges: []),
                                                    label: text, hours: hours ?? amount.hours))
                chooseIndex = currentGroup.rules.count - 1
            } else if let chooseIndex {
                currentGroup.rules[chooseIndex].notes.append(text)
            } else {
                currentGroup.notes.append(text)
            }
        }

        private mutating func addCourses(_ sets: [[CourseKey]], isAlternative: Bool, hours: Double?) {
            if isAlternative {
                // "or …" continues the item above it.
                if let chooseIndex, case .choose(let count, let amount, var options, let ranges) = currentGroup.rules[chooseIndex].kind, !options.isEmpty {
                    options[options.count - 1] += sets
                    currentGroup.rules[chooseIndex].kind = .choose(count: count, hours: amount, options: options, ranges: ranges)
                    return
                }
                if let last = currentGroup.rules.indices.last, case .required(let alternatives) = currentGroup.rules[last].kind {
                    currentGroup.rules[last].kind = .required(alternatives + sets)
                    return
                }
            }
            if let chooseIndex, hours == nil, case .choose(let count, let amount, var options, let ranges) = currentGroup.rules[chooseIndex].kind {
                // A course without hours under "Complete …" is one of its options.
                options.append(sets)
                currentGroup.rules[chooseIndex].kind = .choose(count: count, hours: amount, options: options, ranges: ranges)
                currentGroup.rules[chooseIndex].optionCategories.append(currentGroup.rules[chooseIndex].currentCategory)
                return
            }
            currentGroup.rules.append(RuleDraft(kind: .required(sets), label: "", hours: hours))
            chooseIndex = nil
        }

        func finish() -> [RequirementSection] {
            var sectionIDs = Set<String>()
            return sections.map { draft in
                let sectionID = unique(slug(draft.title), in: &sectionIDs)
                var groupIDs = Set<String>()
                let groups: [RequirementGroup] = draft.groups.compactMap { group in
                    let groupID = unique("\(sectionID)/\(slug(group.title ?? "courses"))", in: &groupIDs)
                    var ruleIDs = Set<String>()
                    let rules: [RequirementRule] = group.rules.compactMap { rule in
                        let kind: RequirementRule.Kind
                        var label = rule.label
                        switch rule.kind {
                        case .required(let alternatives):
                            guard !alternatives.isEmpty else { return nil }
                            let option = CourseOption(alternatives: alternatives)
                            kind = .required(option)
                            label = option.label
                        case .choose(let count, let hours, let options, let ranges):
                            // Kept even without options or ranges the app can read: the requirement
                            // still exists, and a substitution can satisfy it.
                            kind = .choose(count: count, hours: hours, options: options.map(CourseOption.init(alternatives:)), ranges: ranges)
                        case .general(let hours):
                            kind = .generalElectives(hours: hours)
                        }
                        let id = unique("\(groupID)/\(slug(label))", in: &ruleIDs)
                        let categories = rule.optionCategories.contains { $0 != nil } ? rule.optionCategories : nil
                        return RequirementRule(id: id, kind: kind, label: label, hours: rule.hours, notes: rule.notes,
                                               optionCategories: categories)
                    }
                    guard !rules.isEmpty || !group.notes.isEmpty else { return nil }
                    return RequirementGroup(id: groupID, title: group.title, rules: rules, notes: group.notes)
                }
                let title = draft.title.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                let isConcentration = !groups.isEmpty && isChoosableSection(title)
                return RequirementSection(id: sectionID, title: title, isConcentration: isConcentration, groups: groups, notes: draft.notes)
            }
        }

        /// `Concentration in Software`, `Concentration: Software`, `Software Concentration`,
        /// `Track in …`, `… Option`.
        private func isChoosableSection(_ title: String) -> Bool {
            title.range(of: #"^(concentration|track|option|pathway)( in\b|\s*:)|\b(concentration|track|option|pathway)$"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
        }

        private func slug(_ text: String) -> String {
            let lowered = text.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return String(trimmed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        private func unique(_ id: String, in used: inout Set<String>) -> String {
            var candidate = id.isEmpty ? "item" : id
            var n = 2
            while used.contains(candidate) {
                candidate = "\(id)-\(n)"
                n += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    // MARK: Links

    private static let linkPattern = try! NSRegularExpression(pattern: ##"<a\s[^>]*href="([^"#]+)"[^>]*>([\s\S]*?)</a>"##, options: [.caseInsensitive])

    private static func links(in html: String) -> [(href: String, label: String)] {
        let ns = html as NSString
        return linkPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }
}
