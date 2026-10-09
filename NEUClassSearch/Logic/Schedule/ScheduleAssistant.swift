//
//  ScheduleAssistant.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

// Everything that touches Apple's Foundation Models framework lives in this file: the rest of the
// app only sees `ScheduleAssistant`, `ScheduleAssistantAvailability` and plain preferences, so it
// compiles, and the survey works, whether or not the on-device model can be used.

import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Availability

/// Whether Apple Intelligence can read a description of the student's ideal week.
enum ScheduleAssistantAvailability: Equatable, Sendable {
    case available
    /// The device can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is turned off in Settings.
    case notEnabled
    /// The model is still downloading or getting ready.
    case notReady
    /// Apple Intelligence doesn't support the current language yet.
    case unsupportedLanguage
    /// Unavailable for a reason this version doesn't know.
    case unavailable

    var isAvailable: Bool { self == .available }

    /// One line for the survey when the description field can't be offered; nil when it can.
    var note: String? {
        switch self {
        case .available:
            nil
        case .deviceNotEligible:
            "Apple Intelligence isn’t available on this device, but the survey below still works."
        case .notEnabled:
            "Turn on Apple Intelligence in Settings to describe your week in your own words. The survey below works without it."
        case .notReady:
            "Apple Intelligence isn’t ready yet. Try again later; the survey below works in the meantime."
        case .unsupportedLanguage:
            "Apple Intelligence doesn’t support your language yet, but the survey below still works."
        case .unavailable:
            "Apple Intelligence isn’t available right now, but the survey below still works."
        }
    }
}

// MARK: - The draft the model fills in

/// A weekday, as the model names it.
@Generable
enum ScheduleDraftWeekday: String, CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    var day: DaySet {
        switch self {
        case .sunday: .sunday
        case .monday: .monday
        case .tuesday: .tuesday
        case .wednesday: .wednesday
        case .thursday: .thursday
        case .friday: .friday
        case .saturday: .saturday
        }
    }
}

/// A part of the day, as the model names it.
@Generable
enum ScheduleDraftTimeOfDay: String, CaseIterable {
    case earlyMorning, morning, midday, afternoon, evening, night

    var band: TimeBand {
        switch self {
        case .earlyMorning: .earlyMorning
        case .morning: .morning
        case .midday: .midday
        case .afternoon: .afternoon
        case .evening: .evening
        case .night: .night
        }
    }
}

@Generable
enum ScheduleDraftLayout: String, CaseIterable {
    case fewerDays, spreadOut
}

@Generable
enum ScheduleDraftBreaks: String, CaseIterable {
    case avoidBackToBack, timeToWalk
}

@Generable
enum ScheduleDraftFormat: String, CaseIterable {
    case inPerson, online, hybrid
}

@Generable
enum ScheduleDraftSeats: String, CaseIterable {
    case openSeatsOnly, waitlistOK
}

/// A weekly commitment classes can't overlap, as the model describes it.
@Generable(description: "A weekly commitment, such as a club meeting, a job or a commute")
struct ScheduleDraftBlockedTime {
    @Guide(description: "A short name, such as Robotics club or Work")
    var label: String
    @Guide(description: "The weekdays it happens on")
    var days: [ScheduleDraftWeekday]
    @Guide(description: "When it starts, as 24-hour HH:mm. 6pm is 18:00")
    var start: String
    @Guide(description: "When it ends, as 24-hour HH:mm. 8pm is 20:00")
    var end: String
}

/// What the model understood from a student's description of their ideal schedule. Every field is
/// optional: only what the student actually said comes back, and `applied(to:)` merges it into the
/// survey, which the student then reviews.
@Generable(description: "A student's wishes for their class schedule. Leave out everything they did not say.")
struct SchedulePreferencesDraft {
    @Guide(description: "Times of day the student likes for classes. earlyMorning is before 9 AM, morning 9 to noon, midday noon to 2 PM, afternoon 2 to 5 PM, evening 5 to 7 PM, night after 7 PM")
    var preferredTimes: [ScheduleDraftTimeOfDay]?

    @Guide(description: "Times of day the student wants to avoid for classes")
    var avoidedTimes: [ScheduleDraftTimeOfDay]?

    @Guide(description: "The earliest time a class may start, as 24-hour HH:mm. For example 10:00 for no classes before 10")
    var earliestStart: String?

    @Guide(description: "The latest time a class may end, as 24-hour HH:mm. For example 17:00 for done by 5")
    var latestEnd: String?

    @Guide(description: "True if the student only prefers those start and end times and could bend them")
    var timeLimitsAreFlexible: Bool?

    @Guide(description: "Weekdays the student wants without classes")
    var daysOff: [ScheduleDraftWeekday]?

    @Guide(description: "True if the days off are a must because of work or other commitments; false if the student only would like them")
    var daysOffAreRequired: Bool?

    @Guide(description: "fewerDays packs classes into as few days as possible. spreadOut spreads them evenly over the week")
    var layout: ScheduleDraftLayout?

    @Guide(description: "The most classes the student wants in one day")
    var maxClassesPerDay: Int?

    @Guide(description: "The most hours of class the student wants in one day")
    var maxHoursPerDay: Int?

    @Guide(description: "avoidBackToBack if the student dislikes classes right after each other. timeToWalk if they need time to get between buildings")
    var breaks: ScheduleDraftBreaks?

    @Guide(description: "True if the student wants a lunch break")
    var wantsLunchBreak: Bool?

    @Guide(description: "Commitments no class can overlap, such as clubs, work, practice or a commute")
    var blockedTimes: [ScheduleDraftBlockedTime]?

    @Guide(description: "The class format the student wants")
    var format: ScheduleDraftFormat?

    @Guide(description: "openSeatsOnly if the student only wants sections with open seats. waitlistOK if they are fine with waitlists")
    var seats: ScheduleDraftSeats?
}

extension ScheduleDraftBlockedTime: Equatable {}
extension SchedulePreferencesDraft: Equatable {}

// MARK: - From draft to preferences

extension SchedulePreferencesDraft {
    /// The most blocked times taken from one description.
    static let maxBlockedTimes = 8

    /// Whether the model found nothing at all.
    var isEmpty: Bool {
        (preferredTimes ?? []).isEmpty && (avoidedTimes ?? []).isEmpty
            && earliestStart == nil && latestEnd == nil
            && (daysOff ?? []).isEmpty && layout == nil
            && maxClassesPerDay == nil && maxHoursPerDay == nil
            && breaks == nil && wantsLunchBreak != true
            && (blockedTimes ?? []).isEmpty && format == nil && seats == nil
    }

    /// `base` with this draft's wishes applied. Fields the draft leaves out keep their values, so a
    /// description adds to the survey instead of replacing it. Everything is validated: times that
    /// can't be read, blocks without days and values out of range are dropped, never guessed at.
    func applied(to base: SchedulePreferences) -> SchedulePreferences {
        var p = base

        for time in preferredTimes ?? [] { p[time.band] = .prefer }
        // An avoided band wins when the model lists the same one twice.
        for time in avoidedTimes ?? [] { p[time.band] = .avoid }

        let strength: PreferenceStrength = timeLimitsAreFlexible == true ? .preferred : .required
        if let minutes = earliestStart.flatMap(ScheduleAssistant.minutes(fromClockText:)), minutes < 24 * 60 {
            p.earliestStart = TimeLimit(minutes: minutes, strength: strength)
        }
        // A finish before the start can't be what the student meant.
        if let minutes = latestEnd.flatMap(ScheduleAssistant.minutes(fromClockText:)), minutes > (p.earliestStart?.minutes ?? 0) {
            p.latestEnd = TimeLimit(minutes: minutes, strength: strength)
        }

        if let wanted = daysOff, !wanted.isEmpty {
            p.daysOff = wanted.reduce(into: DaySet()) { $0.formUnion($1.day) }
            p.daysOffStrength = daysOffAreRequired == true ? .required : .preferred
        }
        switch layout {
        case .fewerDays: p.dayLayout = .fewerDays
        case .spreadOut: p.dayLayout = .spreadOut
        case nil: break
        }
        if let count = maxClassesPerDay, (1...8).contains(count) { p.maxClassesPerDay = count }
        if let hours = maxHoursPerDay, (1...12).contains(hours) { p.maxMinutesPerDay = hours * 60 }

        switch breaks {
        case .avoidBackToBack: p.breaks = .avoidBackToBack
        case .timeToWalk:
            p.breaks = .atLeast
            p.minimumBreakMinutes = 15
            p.minimumBreakStrength = .preferred
        case nil: break
        }
        if wantsLunchBreak == true, p.lunch == nil { p.lunch = LunchBreak() }

        for block in (blockedTimes ?? []).prefix(Self.maxBlockedTimes) {
            guard let start = ScheduleAssistant.minutes(fromClockText: block.start),
                  var end = ScheduleAssistant.minutes(fromClockText: block.end) else { continue }
            // "6 to 8" written without am/pm comes back as 06:00–08:00; evening is far likelier than dawn.
            if end <= start, end < 12 * 60, end + 12 * 60 <= 24 * 60 { end += 12 * 60 }
            let days = block.days.reduce(into: DaySet()) { $0.formUnion($1.day) }
            let candidate = BlockedTime(label: block.label, days: days, start: start, end: end)
            guard candidate.isValid else { continue }
            let label = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isDuplicate = p.blockedTimes.contains {
                $0.label.lowercased() == label && $0.days == candidate.days && $0.start == candidate.start && $0.end == candidate.end
            }
            if !isDuplicate { p.blockedTimes.append(candidate) }
        }

        switch format {
        case .inPerson: p.format = .inPerson
        case .online: p.format = .online
        case .hybrid: p.format = .hybrid
        case nil: break
        }
        switch seats {
        case .openSeatsOnly: p.seats = .openOnly
        case .waitlistOK: p.seats = .waitlistOK
        case nil: break
        }
        return p.normalized()
    }
}

// MARK: - Keeping the model honest

extension SchedulePreferencesDraft {
    /// Drops what the student's own words give no sign of.
    ///
    /// A small model asked to fill in a form likes to fill in all of it. These are the answers it tends to
    /// invent, so each is kept only when the description mentions its subject at all. How firm a time limit
    /// or a day off is follows the student's wording ("I work Fridays" is a must, "I'd like Fridays off" is a
    /// wish) instead of the model's guess. Descriptions that aren't in English are left alone: the cues
    /// below are English words.
    func grounded(in description: String) -> SchedulePreferencesDraft {
        guard ScheduleAssistant.isEnglish(description) else { return self }
        let text = " " + description.lowercased() + " "
        func mentions(_ cues: [String]) -> Bool { cues.contains { text.contains($0) } }

        var copy = self
        if !mentions(Cues.format) { copy.format = nil }
        if !mentions(Cues.seats) { copy.seats = nil }
        if !mentions(Cues.breaks) { copy.breaks = nil }
        if !mentions(Cues.lunch) { copy.wantsLunchBreak = nil }
        if !mentions(Cues.layout) { copy.layout = nil }
        // A daily limit needs a number, "a day" (or the like) and what is being counted.
        let perDay = mentions(Cues.perDay) && Self.hasQuantity(text)
        if !(perDay && text.contains("class")) { copy.maxClassesPerDay = nil }
        if !(perDay && text.contains("hour")) { copy.maxHoursPerDay = nil }

        // Firmness is judged clause by clause, so "I'd like Fridays off" doesn't soften "no classes before 10".
        let clauses = Self.clauses(of: text)
        func has(_ cues: [String], _ clause: String) -> Bool { cues.contains { clause.contains($0) } }
        let limitClauses = clauses.filter { has(Cues.timeLimit, $0) }
        copy.timeLimitsAreFlexible = !limitClauses.isEmpty && limitClauses.allSatisfy { has(Cues.soft, $0) && !has(Cues.firm, $0) }
        let offClauses = clauses.filter { has(Cues.weekday, $0) && has(Cues.off, $0) }
        copy.daysOffAreRequired = offClauses.contains { has(Cues.firm, $0) || has(Cues.noClassesOn, $0) }
        return copy
    }

    private enum Cues {
        static let format = ["online", "remote", "virtual", "zoom", "in person", "in-person", "on campus", "on-campus", "hybrid", "face to face", "face-to-face"]
        static let seats = ["seat", "waitlist", "wait list", "wait-list", "capacity", "full class", "full section", "open section", "open class", "closed class"]
        static let breaks = ["back to back", "back-to-back", "walk", "between class", "between building", "break between", "gap", "rush", "far apart", "time to get", "travel"]
        static let lunch = ["lunch", "meal", " eat "]
        static let perDay = ["per day", "a day", "each day", "every day", "in a day", "in one day", "daily", "same day"]
        static let layout = ["few days", "fewer days", "fewest days", "spread", "evenly", "compact", "long weekend", "bunch", "pack ", "cram", "consolidat", "every day", "each day", "all week", "days a week", "days per week", "days on campus"]
        /// Phrases that set a start or finish time.
        static let timeLimit = ["before", "after", "earlier than", "later than", "start", "finish", "end by", "done by", "out by", "no classes", "nothing"]
        /// Weekday names, as far as their first three letters.
        static let weekday = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        static let off = [" off", "free", "no class", "without class", "skip", "nothing on"]
        static let noClassesOn = ["no class on", "no classes on", "nothing on"]
        /// Words that make a wish a requirement.
        static let firm = ["must", "have to", "has to", "need to", "i need", "can't", "can’t", "cannot", "can not", "no way", "never", "always", "required", "i work", "my job", "my shift", "shifts", "only available"]
        /// Words that make a requirement a wish.
        static let soft = ["ideally", "prefer", "if possible", "if i can", "if it's possible", "would like", "i'd like", "i’d like", "id like", "rather", "hopefully", "try to", "nice if", "would be nice", "wish"]
    }

    private static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "twelve", "couple", "no more than", "at most", "max"]

    /// Whether the text says a number, in digits or words.
    private static func hasQuantity(_ text: String) -> Bool {
        text.contains { $0.isNumber } || numberWords.contains { text.contains($0) }
    }

    /// The text split at commas, semicolons, full stops, line breaks and "and"/"but"/"so".
    private static func clauses(of text: String) -> [String] {
        var parts = [text]
        for separator in [",", ";", ".", "\n", " and ", " but "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - The assistant

/// Reads a student's description of their ideal schedule with the on-device language model and
/// turns it into survey answers. Nothing leaves the device.
enum ScheduleAssistant {
    /// What the model understood, to be reviewed before anything is used.
    struct Interpretation: Sendable {
        /// The wishes it found, minus the answers the student's words gave no basis for.
        var draft: SchedulePreferencesDraft

        /// `base` with the wishes merged in, and the parts of the survey that changed. The merge happens
        /// when the answer arrives, so whatever the student changed meanwhile is kept.
        func merged(into base: SchedulePreferences) -> (preferences: SchedulePreferences, changedFields: Set<PreferenceField>) {
            let merged = draft.applied(to: base)
            return (merged, merged.changedFields(from: base))
        }
    }

    /// Why a description couldn't be used.
    enum Failure: Error, Equatable, Sendable {
        case unavailable(ScheduleAssistantAvailability)
        case emptyDescription
        case descriptionTooLong
        /// Apple's safety guardrails declined the text.
        case guardrail
        /// The text and the answer didn't fit in the model's context window.
        case contextTooLarge
        case unsupportedLanguage
        case busy
        case timedOut
        /// The model answered, but nothing in the answer was usable.
        case nothingFound
        case failed(String)

        var message: String {
            switch self {
            case .unavailable(let availability):
                availability.note ?? "Apple Intelligence isn’t available right now."
            case .emptyDescription:
                "Describe the schedule you want first."
            case .descriptionTooLong:
                "That’s a lot to read at once. Try describing the most important things in a few sentences."
            case .guardrail:
                "Apple Intelligence couldn’t use that description. Try rephrasing it, or fill in the survey yourself."
            case .contextTooLarge:
                "That description is too long for Apple Intelligence. Shorten it, or fill in the survey yourself."
            case .unsupportedLanguage:
                "Apple Intelligence can’t read that language yet. Try English, or fill in the survey yourself."
            case .busy:
                "Apple Intelligence is busy right now. Try again in a moment."
            case .timedOut:
                "Apple Intelligence took too long. Try a shorter description, or fill in the survey yourself."
            case .nothingFound:
                "Couldn’t find any schedule wishes in that. Try mentioning times, days or commitments, like “no classes before 10” or “work Tuesdays 1–5”."
            case .failed:
                "Something went wrong reading that. Try again, or fill in the survey yourself."
            }
        }
    }

    /// The longest description sent to the model (characters).
    static let maxDescriptionLength = 1_500
    /// How long a request may take before it is abandoned.
    static let timeout: Duration = .seconds(60)

    static let instructions = """
        You turn a college student's description of their ideal class schedule into structured preferences.
        Only fill in a field when the student clearly says it. Leave everything else out. Never guess or invent.
        Times use the 24-hour clock: 6pm is 18:00, 10am is 10:00. "No classes before 10" is earliestStart 10:00. "Done by 5" is latestEnd 17:00.
        Clubs, jobs, practices and commutes are blocked times with the weekdays and hours they repeat.
        Example: "No classes before 10, choir Tuesdays 6-8pm, Fridays off" gives earliestStart 10:00, a blocked time Choir on Tuesday from 18:00 to 20:00, and Friday in daysOff.
        """

    /// Whether `text` is written in English (the language the grounding cues are in).
    static func isEnglish(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return (recognizer.languageHypotheses(withMaximum: 3)[.english] ?? 0) >= 0.4
    }

    // MARK: Availability

    /// Whether the on-device model can be used right now. Reads `SystemLanguageModel`, which is
    /// observable, so a view that calls this updates when the model finishes downloading.
    static var availability: ScheduleAssistantAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.supportsLocale() ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .notReady
            @unknown default: return .unavailable
            }
        }
    }

    /// Loads the model ahead of time so the first answer comes quickly.
    static func prewarm() {
        guard availability.isAvailable else { return }
        LanguageModelSession(instructions: instructions).prewarm()
    }

    // MARK: Interpreting

    /// Reads `text` and returns the wishes it states.
    ///
    /// `onProgress` receives how many settings the model has found so far while it streams its answer
    /// (on the main actor). Cancelling the calling task stops the model. Throws `Failure` (or
    /// `CancellationError`).
    static func interpret(
        _ text: String,
        onProgress: @escaping @MainActor @Sendable (Int) -> Void = { _ in }
    ) async throws -> Interpretation {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw Failure.emptyDescription }
        guard description.count <= maxDescriptionLength else { throw Failure.descriptionTooLong }
        let state = Self.availability
        guard state.isAvailable else { throw Failure.unavailable(state) }

        do {
            let draft = try await withThrowingTaskGroup(of: SchedulePreferencesDraft.self) { group in
                group.addTask { try await generateDraft(from: description, onProgress: onProgress) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw Failure.failed("No answer") }
                return first
            }
            try Task.checkCancellation()
            let grounded = draft.grounded(in: description)
            guard !grounded.isEmpty else { throw Failure.nothingFound }
            return Interpretation(draft: grounded)
        } catch {
            throw failure(from: error)
        }
    }

    /// Streams the model's structured answer and returns the finished draft.
    private static func generateDraft(
        from description: String,
        onProgress: @escaping @MainActor @Sendable (Int) -> Void
    ) async throws -> SchedulePreferencesDraft {
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(
            to: "Student: \(description)",
            generating: SchedulePreferencesDraft.self,
            // Nearly deterministic: this is extraction, not writing.
            options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 900)
        )
        var latest: GeneratedContent?
        var reported = 0
        for try await snapshot in stream {
            try Task.checkCancellation()
            latest = snapshot.rawContent
            // A half-written answer may not parse yet; progress is only a courtesy.
            if let partial = try? SchedulePreferencesDraft(snapshot.rawContent), partial.filledCount != reported {
                reported = partial.filledCount
                await onProgress(reported)
            }
        }
        guard let latest else { throw Failure.nothingFound }
        return try SchedulePreferencesDraft(latest)
    }

    // MARK: Errors

    /// Maps whatever the framework (or this file) threw to a `Failure`.
    static func failure(from error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? Failure { return failure }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation, .refusal: return Failure.guardrail
            case .exceededContextWindowSize: return Failure.contextTooLarge
            case .unsupportedLanguageOrLocale: return Failure.unsupportedLanguage
            case .assetsUnavailable: return Failure.unavailable(.notReady)
            case .rateLimited, .concurrentRequests: return Failure.busy
            case .decodingFailure, .unsupportedGuide: return Failure.nothingFound
            @unknown default: return Failure.failed(error.localizedDescription)
            }
        }
        #if compiler(>=6.4)
        // iOS and macOS 27 report the same problems with new error types.
        if #available(iOS 27.0, macOS 27.0, *), let modelError = error as? LanguageModelError {
            switch modelError {
            case .guardrailViolation, .refusal: return Failure.guardrail
            case .contextSizeExceeded: return Failure.contextTooLarge
            case .unsupportedLanguageOrLocale: return Failure.unsupportedLanguage
            case .rateLimited: return Failure.busy
            case .timeout: return Failure.timedOut
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: return Failure.nothingFound
            @unknown default: return Failure.failed(error.localizedDescription)
            }
        }
        #endif
        return Failure.failed(error.localizedDescription)
    }

    // MARK: Clock times

    /// Reads a time as the model writes it (`18:00`, `6:30 pm`, `6pm`, `1800`, `noon`) into minutes after
    /// midnight; nil when it can't be read. `24:00` and `midnight` are the end of the day (1440).
    static func minutes(fromClockText text: String) -> Int? {
        var s = text.lowercased().filter { !$0.isWhitespace && $0 != "." }
        switch s {
        case "noon": return 12 * 60
        case "midnight": return 24 * 60
        default: break
        }
        var meridiem: Bool?   // true = pm
        if s.hasSuffix("am") { meridiem = false; s.removeLast(2) } else if s.hasSuffix("pm") { meridiem = true; s.removeLast(2) }
        guard !s.isEmpty else { return nil }

        var hour: Int
        var minute = 0
        if let colon = s.firstIndex(of: ":") {
            guard let h = Int(s[..<colon]), let m = Int(s[s.index(after: colon)...]) else { return nil }
            hour = h
            minute = m
        } else if s.count >= 3, s.count <= 4, let number = Int(s) {
            hour = number / 100
            minute = number % 100
        } else if let h = Int(s) {
            hour = h
        } else {
            return nil
        }
        guard (0...24).contains(hour), (0..<60).contains(minute) else { return nil }
        if let isPM = meridiem {
            guard (1...12).contains(hour) else { return nil }
            if isPM, hour < 12 { hour += 12 }
            if !isPM, hour == 12 { hour = 0 }
        }
        let total = hour * 60 + minute
        return total <= 24 * 60 ? total : nil
    }
}

extension SchedulePreferencesDraft {
    /// How many settings the draft fills in (for the progress line).
    var filledCount: Int {
        var n = 0
        if !(preferredTimes ?? []).isEmpty { n += 1 }
        if !(avoidedTimes ?? []).isEmpty { n += 1 }
        if earliestStart != nil { n += 1 }
        if latestEnd != nil { n += 1 }
        if !(daysOff ?? []).isEmpty { n += 1 }
        if layout != nil { n += 1 }
        if maxClassesPerDay != nil || maxHoursPerDay != nil { n += 1 }
        if breaks != nil { n += 1 }
        if wantsLunchBreak == true { n += 1 }
        n += (blockedTimes ?? []).count
        if format != nil { n += 1 }
        if seats != nil { n += 1 }
        return n
    }
}
