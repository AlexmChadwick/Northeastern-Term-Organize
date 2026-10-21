//
//  UserModels.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// A course the user bookmarked.
struct SavedCourse: Codable, Hashable, Identifiable, Sendable {
    var termCode: String
    var key: CourseKey
    var savedAt: Date
    var id: String { "\(termCode)|\(key)" }
}

/// A recently viewed course.
struct RecentCourse: Codable, Hashable, Identifiable, Sendable {
    var termCode: String
    var key: CourseKey
    var viewedAt: Date
    var id: String { "\(termCode)|\(key)" }
}

/// Constraints used by the schedule generator.
/// Mirrors SearchNEU's scheduler filters (start/end time, free days, honors,
/// remote, minimum seats, campus, number of courses).
struct ScheduleFilters: Codable, Hashable, Sendable {
    /// Earliest allowed class start, minutes after midnight.
    var earliestStart: Int?
    /// Latest allowed class end, minutes after midnight.
    var latestEnd: Int?
    /// Days that must stay free of classes.
    var freeDays = DaySet()
    var includeHonors = true
    var includeOnline = true
    /// Exclude sections with no open seats.
    var hideFullSections = false
    /// Minimum open seats a section must have (0 = no minimum).
    var minSeats = 0
    /// Restrict in-person sections to a campus name (online sections still allowed).
    var campus: String?
    /// Exact number of courses per schedule; nil means "all required + as many optional as fit".
    var courseCount: Int?

    var activeCount: Int {
        var n = 0
        if earliestStart != nil { n += 1 }
        if latestEnd != nil { n += 1 }
        if !freeDays.isEmpty { n += 1 }
        if !includeHonors { n += 1 }
        if !includeOnline { n += 1 }
        if hideFullSections || minSeats > 0 { n += 1 }
        if campus != nil { n += 1 }
        if courseCount != nil { n += 1 }
        return n
    }
}

/// A course added to a schedule plan.
struct PlanCourse: Codable, Hashable, Identifiable, Sendable {
    var key: CourseKey
    /// Required courses appear in every generated schedule; optional ones are
    /// added when they fit.
    var isRequired = true
    /// Sections the user never wants (hidden from generation).
    var excludedCRNs: Set<String> = []
    /// Index into `CourseColor.palette`.
    var colorIndex: Int
    /// The section the user chose for this row. Two rows may share a subject and
    /// number only when each has one of these and the CRNs differ (special topics).
    /// Nil on plans saved before the choice lived on the row; `selectedCRNs` still
    /// holds it then. Optional so those plans still decode.
    var pinnedCRN: String? = nil
    /// `CS 4973`, or `CS 4973|11111` once a CRN is chosen, so two topics are two rows.
    var id: String {
        if let pinnedCRN, !pinnedCRN.isEmpty { return "\(key.description)|\(pinnedCRN)" }
        return key.description
    }
}

/// What `SchedulePlan.include` did with one course row.
enum PlanCourseAdmission: Equatable, Sendable {
    /// A new row was appended.
    case added
    /// The CRN was stored on a row that did not have one yet.
    case pinnedExisting
    /// The number was already present, or this CRN was already stored.
    case alreadyPresent
}

/// A named schedule for one term (SearchNEU calls these "plans").
struct SchedulePlan: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var termCode: String
    var courses: [PlanCourse] = []
    /// Sections shown on the calendar. A row's own choice is `PlanCourse.pinnedCRN`.
    /// A second row of the same subject and number keeps a different CRN.
    /// One course can still contribute more than one CRN when it has a linked
    /// component (a lecture and its lab).
    var selectedCRNs: [String] = []
    var filters = ScheduleFilters()
    /// "Your ideal week": what the student wants the generated schedules to look like. Nil until they
    /// set anything. Optional so plans saved before it existed still decode.
    var preferences: SchedulePreferences?
    /// Generated combinations the user starred, each a sorted CRN list.
    var favoriteCombinations: [[String]] = []
    /// The plan used for "Up Next", widgets and calendar export defaults.
    var isPrimary = false
    var createdAt = Date.now
    var updatedAt = Date.now
    /// Optimistic concurrency token. Nil on plans saved before it existed (treated as 0).
    /// Incremented on every saved edit. Optional so older files still decode.
    var revision: Int?
    /// Schedule plans that belong to one multi-term plan share this id. Nil means the
    /// plan stands alone (one term), which is how the app itself creates schedules.
    var folderID: UUID?

    func contains(_ key: CourseKey) -> Bool { courses.contains { $0.key == key } }

    func course(_ key: CourseKey) -> PlanCourse? { courses.first { $0.key == key } }

    func entries(for key: CourseKey) -> [PlanCourse] { courses.filter { $0.key == key } }

    /// Adds `key`, or another row of it.
    ///
    /// The first row of a subject and number may omit a CRN. Another row is added
    /// only when every existing row of that number already has a pinned CRN and
    /// `crn` is a different one. The same CRN twice is refused. Without a CRN,
    /// a subject and number that is already in the plan is left as it is.
    ///
    /// `courseCRNs` is every section CRN of `key` this term. A choice saved only
    /// in `selectedCRNs` (plans from before `pinnedCRN`) still counts as that
    /// row's pin, so a second topic can be added beside it.
    @discardableResult
    mutating func include(key: CourseKey, crn: String?, courseCRNs: Set<String> = [], required: Bool = true) -> PlanCourseAdmission {
        let trimmed = crn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested: String? = (trimmed?.isEmpty == false) ? trimmed : nil
        let rows = courses.indices.filter { courses[$0].key == key }
        if rows.isEmpty {
            courses.append(PlanCourse(key: key, isRequired: required, colorIndex: nextColorIndex, pinnedCRN: requested))
            if let requested, !selectedCRNs.contains(requested) { selectedCRNs.append(requested) }
            return .added
        }

        if rows.count == 1, courses[rows[0]].pinnedCRN == nil {
            let owned = selectedCRNs.filter { courseCRNs.contains($0) }
            if let requested, owned.contains(requested) {
                courses[rows[0]].pinnedCRN = requested
                return .alreadyPresent
            }
            if let first = owned.first {
                courses[rows[0]].pinnedCRN = first
            }
        }

        guard let requested else { return .alreadyPresent }
        if courses.contains(where: { $0.pinnedCRN == requested }) { return .alreadyPresent }

        if let i = rows.first(where: { courses[$0].pinnedCRN == nil }) {
            courses[i].pinnedCRN = requested
            if !courseCRNs.isEmpty {
                let kept = requested
                selectedCRNs.removeAll { courseCRNs.contains($0) && $0 != kept }
            }
            if !selectedCRNs.contains(requested) { selectedCRNs.append(requested) }
            return .pinnedExisting
        }

        courses.append(PlanCourse(key: key, isRequired: required, colorIndex: nextColorIndex, pinnedCRN: requested))
        if !selectedCRNs.contains(requested) { selectedCRNs.append(requested) }
        return .added
    }

    /// The next unused palette index.
    var nextColorIndex: Int {
        let used = Set(courses.map(\.colorIndex))
        return (0..<CourseColorPalette.count).first { !used.contains($0) } ?? courses.count % CourseColorPalette.count
    }
}

/// Number of colors available for courses; the palette itself lives in the design system.
enum CourseColorPalette {
    static let count = 10
}

/// A section the user wants seat notifications for.
struct WatchItem: Codable, Hashable, Identifiable, Sendable {
    var termCode: String
    var crn: String
    var courseKey: CourseKey
    var courseTitle: String
    /// e.g. `Lecture · Section 02`.
    var sectionLabel: String
    var addedAt = Date.now
    /// Seats and waitlist at the last check.
    var lastSeatsRemaining: Int
    var lastWaitlistRemaining: Int
    var seatCapacity: Int
    var lastCheckedAt: Date?
    /// Also notify when a waitlist spot opens.
    var notifyOnWaitlist = false
    var lastNotifiedAt: Date?
    var id: String { "\(termCode)|\(crn)" }
}

/// App-wide preferences.
struct AppPreferences: Codable, Hashable, Sendable {
    /// Term shown at launch; nil means "newest available".
    var selectedTermCode: String?
    /// Campus pre-selected in search filters, if any.
    var preferredCampus: String?
    var hasCompletedOnboarding = false
    /// Show Saturday/Sunday columns in calendars.
    var showWeekends = false
    /// Refresh seat counts automatically when opening a course.
    var autoRefreshSeats = true
    /// Refresh watched sections in the background.
    var backgroundRefreshEnabled = true
    /// Calendar visible range (hours).
    var calendarStartHour = 8
    var calendarEndHour = 21
}

// MARK: - Degree plans

/// A semester slot in a degree plan, as Northeastern's degree audit planner names
/// them ("Spring 2027", "Summer Session A 2027", "Fall 2027").
enum PlanSeason: String, Codable, CaseIterable, Hashable, Sendable {
    case winter, spring, summerA, summerFull, summerB, fall

    /// Name used by the degree audit export, e.g. `Summer Session A`.
    var exportName: String {
        switch self {
        case .winter: "Winter"
        case .spring: "Spring"
        case .summerA: "Summer Session A"
        case .summerFull: "Summer Full"
        case .summerB: "Summer Session B"
        case .fall: "Fall"
        }
    }

    /// Short name for compact UI, e.g. `Summer A`.
    var shortName: String {
        switch self {
        case .summerA: "Summer A"
        case .summerB: "Summer B"
        case .summerFull: "Summer"
        default: exportName
        }
    }

    /// Month the season starts in, used to order terms and measure how far apart they are.
    var startMonth: Int {
        switch self {
        case .winter: 1
        case .spring: 1
        case .summerA: 5
        case .summerFull: 5
        case .summerB: 7
        case .fall: 9
        }
    }

    /// Tie-breaker for seasons starting in the same month.
    var orderWithinMonth: Int {
        switch self {
        case .winter: 0
        case .spring: 1
        case .summerA: 0
        case .summerFull: 1
        default: 0
        }
    }

    /// Parses "Spring", "Summer Session A", "Summer 1", "Summer Full", "Summer"…
    init?(exportName raw: String) {
        let s = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch s {
        case "fall", "autumn": self = .fall
        case "spring": self = .spring
        case "winter": self = .winter
        case "summer session a", "summer a", "summer 1", "summer i", "summer session 1": self = .summerA
        case "summer session b", "summer b", "summer 2", "summer ii", "summer session 2": self = .summerB
        case "summer full", "summer", "full summer", "summer session full": self = .summerFull
        default: return nil
        }
    }

    /// The matching season of a Banner term, if any.
    init(termSeason: Term.Season) {
        switch termSeason {
        case .fall: self = .fall
        case .winter: self = .winter
        case .spring: self = .spring
        case .summer1: self = .summerA
        case .summerFull: self = .summerFull
        case .summer2: self = .summerB
        }
    }

    /// Whether a Banner term season can hold this plan season's classes. Summer
    /// sessions also match Northeastern's combined summer term.
    func matches(_ termSeason: Term.Season) -> Bool {
        switch (self, termSeason) {
        case (.fall, .fall), (.spring, .spring), (.winter, .winter): true
        case (.summerA, .summer1), (.summerA, .summerFull): true
        case (.summerB, .summer2), (.summerB, .summerFull): true
        case (.summerFull, .summerFull), (.summerFull, .summer1), (.summerFull, .summer2): true
        default: false
        }
    }
}

/// A course (or other credit line, such as "NO AP CREDIT") in a degree plan.
struct DegreePlanCourse: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Nil for entries that aren't catalog courses.
    var key: CourseKey?
    /// Code as written in the plan, e.g. `CS 1800` or `NO AP CREDIT`.
    var label: String
    /// Title as written in the plan (the degree audit uses Banner's 30-character short titles).
    var title: String
    var credits: Double
    /// The section chosen for this row. Two rows may share a subject and number
    /// only when each has its own CRN and the CRNs differ. Nil when no section
    /// has been chosen. Optional so plans saved before the field existed still decode.
    var crn: String?

    init(id: UUID = UUID(), key: CourseKey?, label: String? = nil, title: String, credits: Double, crn: String? = nil) {
        self.id = id
        self.key = key
        self.label = label ?? key?.description ?? ""
        self.title = title
        self.credits = credits
        self.crn = crn
    }
}

/// What `DegreePlanTerm.include` did with one course row.
enum DegreeCourseAdmission: Equatable, Sendable {
    /// A new row was appended.
    case added
    /// The CRN was stored on a row that did not have one yet.
    case pinnedExisting
    /// The number was already present, or this CRN was already stored.
    case alreadyPresent
}

/// One semester of planned courses.
struct DegreePlanTerm: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var season: PlanSeason
    var year: Int
    var courses: [DegreePlanCourse] = []

    /// e.g. `Summer Session A 2027`.
    var name: String { "\(season.exportName) \(year)" }
    /// e.g. `Summer A 2027`.
    var shortName: String { "\(season.shortName) \(year)" }
    var credits: Double { courses.reduce(0) { $0 + $1.credits } }

    /// Adds a row, or stores `crn` on the one row of that course that does not
    /// have one yet. A second row is created only when the new course has a CRN,
    /// every existing row of that subject and number already has a different CRN,
    /// and this CRN is not already stored. A missing CRN never creates a second row.
    @discardableResult
    mutating func include(course newCourse: DegreePlanCourse) -> DegreeCourseAdmission {
        guard let key = newCourse.key else {
            courses.append(newCourse)
            return .added
        }
        let trimmed = newCourse.crn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = (trimmed?.isEmpty == false) ? trimmed : nil
        let rows = courses.indices.filter { courses[$0].key == key }
        if pin == nil {
            guard rows.isEmpty else { return .alreadyPresent }
            courses.append(newCourse)
            return .added
        }
        if rows.contains(where: { courses[$0].crn == pin }) { return .alreadyPresent }
        if let open = rows.first(where: { courses[$0].crn?.isEmpty != false }) {
            courses[open].crn = pin
            return .pinnedExisting
        }
        var copy = newCourse
        copy.crn = pin
        courses.append(copy)
        return .added
    }

    /// Months since year 0, used for ordering and "closest term" comparisons.
    var monthIndex: Int { year * 12 + season.startMonth - 1 }
    var sortKey: Int { monthIndex * 4 + season.orderWithinMonth }

    /// Whether a Banner term is this semester (same season and calendar year).
    func matches(_ term: Term) -> Bool {
        term.calendarYear == year && season.matches(term.season)
    }
}

/// A multi-semester degree plan, importable from (and exportable to) the PDF that
/// Northeastern's degree audit planner produces ("View Plan").
struct DegreePlan: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Degree program code, e.g. `CS-B-CSCI-BSCS`.
    var program: String?
    /// Only kept so exports can reproduce the original header; stays on this device.
    var studentName: String?
    var studentID: String?
    /// Courses the audit lists as completed (it also includes courses in progress).
    var completed: [DegreePlanCourse] = []
    /// Future semesters, in chronological order.
    var terms: [DegreePlanTerm] = []
    /// The plan used for prerequisite checks and autofill.
    var isPrimary = false
    /// File name of the PDF this plan was imported from, if any.
    var importedFrom: String?
    /// "Printed:" time of the imported export.
    var printedAt: Date?
    var createdAt = Date.now
    var updatedAt = Date.now
    /// Optimistic concurrency token. Nil or 0 on plans saved before it existed
    /// (both count as 1). Incremented on every saved edit. Optional so older
    /// files still decode.
    var revision: Int?

    // Degree requirements (from the academic catalog). All optional: a plan works without them.

    /// The catalog edition whose requirements apply — the year the student entered the
    /// program — as its first year (2023 for 2023–2024).
    var catalogYear: Int?
    /// The program's page within that edition, e.g.
    /// `undergraduate/computer-information-science/computer-science/bscs/`.
    var catalogProgramPath: String?
    /// e.g. `Computer Science, BSCS`.
    var catalogProgramTitle: String?
    /// The chosen concentration (`RequirementSection.id`), for programs that have them.
    var concentrationID: String?
    /// Approved course substitutions and petitions.
    var substitutions: [RequirementSubstitution] = []
    /// Courses the student says count as other courses, e.g. a renumbered course and its
    /// replacement. They apply to prerequisite checks and to the requirements audit, on top
    /// of the equivalences Banner knows about, and sync with the plan.
    var courseEquivalences: [CourseEquivalence] = []

    var completedCredits: Double { completed.reduce(0) { $0 + $1.credits } }
    var plannedCredits: Double { terms.reduce(0) { $0 + $1.credits } }
    var completedKeys: Set<CourseKey> { Set(completed.compactMap(\.key)) }

    /// Keeps terms in chronological order.
    mutating func sortTerms() {
        terms.sort { $0.sortKey < $1.sortKey }
    }

    /// The term for a Banner term, if the plan has one.
    func term(matching term: Term) -> DegreePlanTerm? {
        terms.first { $0.matches(term) }
    }

    /// The catalog edition of the requirements, when one is chosen.
    var requirementsYear: CatalogYear? { catalogYear.map(CatalogYear.init(startYear:)) }
}

extension DegreePlan {
    /// Tolerant decoding: fields added in later versions may be missing from saved data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Degree Plan"
        program = try c.decodeIfPresent(String.self, forKey: .program)
        studentName = try c.decodeIfPresent(String.self, forKey: .studentName)
        studentID = try c.decodeIfPresent(String.self, forKey: .studentID)
        completed = try c.decodeIfPresent([DegreePlanCourse].self, forKey: .completed) ?? []
        terms = try c.decodeIfPresent([DegreePlanTerm].self, forKey: .terms) ?? []
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        importedFrom = try c.decodeIfPresent(String.self, forKey: .importedFrom)
        printedAt = try c.decodeIfPresent(Date.self, forKey: .printedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        catalogYear = try c.decodeIfPresent(Int.self, forKey: .catalogYear)
        catalogProgramPath = try c.decodeIfPresent(String.self, forKey: .catalogProgramPath)
        catalogProgramTitle = try c.decodeIfPresent(String.self, forKey: .catalogProgramTitle)
        concentrationID = try c.decodeIfPresent(String.self, forKey: .concentrationID)
        substitutions = (try? c.decodeIfPresent([RequirementSubstitution].self, forKey: .substitutions)) ?? []
        courseEquivalences = (try? c.decodeIfPresent([CourseEquivalence].self, forKey: .courseEquivalences)) ?? []
    }
}

/// A student-declared equivalence: a course the student took that counts as another course,
/// because the department renumbered it, an advisor accepted it, or Banner doesn't link them.
/// For prerequisites and degree requirements the two courses count as one another.
struct CourseEquivalence: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// The course that was taken (or is planned), e.g. `CS 2510`.
    var course: CourseKey
    /// The course it counts as, e.g. `CS 2100`.
    var countsAs: CourseKey
    /// e.g. "Renumbered in 2025".
    var note: String = ""
}

/// An approved exception to the catalog's requirements: a course counted toward a
/// requirement it isn't listed under, a requirement replaced by petition, or a waiver.
struct RequirementSubstitution: Codable, Hashable, Identifiable, Sendable {
    enum Change: Codable, Hashable, Sendable {
        /// Count this course toward the requirement (e.g. a special topics course as an
        /// HCI elective, or a capstone for the software engineering requirement).
        case countCourse(CourseKey)
        /// Satisfy the requirement differently (e.g. the science requirement with two
        /// Khoury electives).
        case replace(RequirementReplacement)
        /// The requirement doesn't apply.
        case waive
    }

    var id = UUID()
    /// The requirement it changes (`RequirementRule.id`).
    var ruleID: String
    /// The requirement's name when the substitution was made, shown if the catalog changes.
    var ruleTitle: String
    var change: Change
    /// e.g. "Petition approved by Khoury advising".
    var note: String = ""
    var approvedOn: Date?
    var createdAt = Date.now
}

/// What replaces a requirement: `count` courses or `hours` semester hours, drawn from
/// another requirement's options (`likeRuleID`, e.g. Khoury electives) and/or from `courses`.
struct RequirementReplacement: Codable, Hashable, Sendable {
    var count: Int?
    var hours: Double?
    var likeRuleID: String?
    /// The other requirement's name when this was made, e.g. `Khoury Elective Courses`.
    var likeRuleTitle: String?
    var courses: [CourseKey] = []
    /// Which course numbers count when the other requirement limits them (`CS 2500 or
    /// higher`). Nil when that hasn't been answered (petitions saved before the app asked).
    var courseNumbers: CourseNumberLimit?

    /// `2 courses like Khoury Elective Courses`, `8 semester hours from CS 4973, CS 4100`,
    /// `1 course like Khoury Elective Courses, any course number`.
    var summary: String {
        let amount: String
        if let count { amount = count == 1 ? "1 course" : "\(count) courses" }
        else if let hours { amount = "\(hours.formatted(.number.precision(.fractionLength(0...1)))) semester hours" }
        else { amount = "Courses" }
        var sources: [String] = []
        if let likeRuleTitle { sources.append("like \(likeRuleTitle)") }
        if !courses.isEmpty { sources.append("from \(courses.map(\.description).joined(separator: ", "))") }
        var text = ([amount] + sources).joined(separator: " ")
        if likeRuleTitle != nil, let numbers = courseNumbers?.summary { text += ", \(numbers)" }
        return text
    }
}

/// Which course numbers a petition accepts when it takes courses like a requirement that limits
/// them, such as "CS 2500 or higher, except CS 5010". Petitions differ: "two Khoury electives"
/// may mean exactly that requirement's courses, or any course in its subjects.
enum CourseNumberLimit: Codable, Hashable, Sendable {
    /// The requirement's own limits.
    case sameAsRequirement
    /// No minimum: any course in the same subjects. A maximum and exceptions still apply.
    case anyNumber
    /// A different minimum for every subject, e.g. 2000. A maximum and exceptions still apply.
    case atLeast(Int)

    /// For the petition's summary; nil when the requirement's limits apply.
    var summary: String? {
        switch self {
        case .sameAsRequirement: nil
        case .anyNumber: "any course number"
        case .atLeast(let minimum): "numbered \(minimum) or higher"
        }
    }
}

/// Everything the app persists for the user.
struct UserData: Codable, Sendable {
    var version = 1
    var preferences = AppPreferences()
    var saved: [SavedCourse] = []
    var recents: [RecentCourse] = []
    var plans: [SchedulePlan] = []
    var watchlist: [WatchItem] = []
    var searchHistory: [String] = []
    var degreePlans: [DegreePlan] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        preferences = (try? c.decode(AppPreferences.self, forKey: .preferences)) ?? AppPreferences()
        // Lists are decoded item by item: one unreadable entry (say, from a newer version of
        // the app) is skipped instead of losing the whole list.
        saved = c.decodeEach(SavedCourse.self, forKey: .saved)
        recents = c.decodeEach(RecentCourse.self, forKey: .recents)
        plans = c.decodeEach(SchedulePlan.self, forKey: .plans)
        watchlist = c.decodeEach(WatchItem.self, forKey: .watchlist)
        searchHistory = c.decodeEach(String.self, forKey: .searchHistory)
        degreePlans = c.decodeEach(DegreePlan.self, forKey: .degreePlans)
    }
}

/// Decodes any value without failing, so a lossy array decode can step past bad elements.
private struct SkippedElement: Decodable {
    init(from decoder: Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// The decodable elements of the array at `key`; unreadable ones are skipped. Empty when
    /// the key is missing or isn't an array.
    func decodeEach<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard var array = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !array.isAtEnd {
            if let element = try? array.decode(T.self) {
                result.append(element)
            } else if (try? array.decode(SkippedElement.self)) == nil {
                break   // the container couldn't advance; stop rather than loop
            }
        }
        return result
    }
}
