//
//  SchedulePreferencesView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - The survey

/// "Your ideal week": a survey of what the student wants their schedule to look like, with an optional
/// description that Apple Intelligence turns into answers for them to review. Edits stay in the sheet
/// until "Done", which saves them with the schedule (so schedules regenerate once, not per tap).
struct SchedulePreferencesSheet: View {
    var planID: UUID
    var context: SchedulePreferencesContext

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scheduleAssistantAvailability) private var availabilityOverride

    private let initial: SchedulePreferences
    @State private var draft: SchedulePreferences
    /// What Apple Intelligence changed, highlighted until the sheet closes.
    @State private var filledIn: Set<PreferenceField> = []
    /// The survey as it was before Apple Intelligence filled it in, for "Undo".
    @State private var beforeAssistant: SchedulePreferences?
    @State private var description = ""
    @State private var assistant = ScheduleAssistantModel()
    @State private var showsMore = false
    @State private var path: [SurveyRoute] = []
    @State private var confirmsDiscard = false
    @State private var haptic = PlanHaptic()
    @FocusState private var isDescriptionFocused: Bool

    private enum SurveyRoute: Hashable {
        case block(UUID)
        case instructors
    }

    private static let placeholder = "No classes before 10, I have robotics club Tuesdays and Thursdays 6–8pm, I’d like Fridays off and a lunch break"

    /// - Parameters:
    ///   - description: What the description field starts with (for previews and tests).
    ///   - filledIn: Rows to start highlighted as filled in by Apple Intelligence (for previews and tests).
    ///   - assistant: The request to show (for previews and tests); by default a new, idle one.
    @MainActor
    init(
        planID: UUID, initial: SchedulePreferences, context: SchedulePreferencesContext,
        description: String = "", filledIn: Set<PreferenceField> = [], assistant: ScheduleAssistantModel? = nil
    ) {
        self.planID = planID
        self.context = context
        self.initial = initial
        _draft = State(initialValue: initial)
        _description = State(initialValue: description)
        _filledIn = State(initialValue: filledIn)
        _assistant = State(initialValue: assistant ?? ScheduleAssistantModel())
        _showsMore = State(initialValue: filledIn.contains(where: Self.isInMoreSection))
    }

    private var hasChanges: Bool { draft != initial }
    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            form
                .navigationTitle("Your ideal week")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: commit)
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { isDescriptionFocused = false }
                    }
                }
                .navigationDestination(for: SurveyRoute.self) { route in
                    destination(route)
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasChanges || assistant.isWorking)
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .onChange(of: path) { _, _ in dropUnfinishedBlocks() }
        .onDisappear { assistant.cancel() }
        .task { ScheduleAssistant.prewarm() }
        .planHaptic(haptic)
    }

    private var form: some View {
        Form {
            describeSection
            presetsSection
            timeOfDaySection
            startFinishSection
            daysSection
            blockedTimesSection
            moreSection
            resetSection
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func destination(_ route: SurveyRoute) -> some View {
        switch route {
        case .block(let id):
            if draft.blockedTimes.contains(where: { $0.id == id }) {
                ScheduleBlockedTimeEditor(block: blockBinding(id), days: selectableDays(including: blockDays(id))) {
                    path.removeAll()
                    draft.blockedTimes.removeAll { $0.id == id }
                    haptic.fire(.warning)
                }
            } else {
                ContentUnavailableView("Blocked time not found", systemImage: "calendar.badge.exclamationmark")
            }
        case .instructors:
            ScheduleInstructorPreferencesList(
                preferred: $draft.preferredInstructors,
                avoided: $draft.avoidedInstructors,
                instructors: context.instructors
            )
        }
    }

    // MARK: Describe

    @ViewBuilder
    private var describeSection: some View {
        let availability = availabilityOverride ?? ScheduleAssistant.availability
        if availability.isAvailable {
            // Three ordinary rows with their separators hidden: the section's one rounded container wraps
            // the field, the status and the button, so it reads as a single unit with nothing cut off. (One
            // custom row holding all three would be measured too short by the list, and clip its text.)
            Section {
                descriptionField
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                assistantStatus
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                fillButton
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text("Describe your ideal schedule")
            } footer: {
                Label("Processed on device with Apple Intelligence", systemImage: "lock.shield")
            }
        } else if let note = availability.note {
            Section {
                Label(note, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A multi-line field with the example as its placeholder. The placeholder is a plain `Text` under the
    /// field, not the field's own prompt: it sizes the row, so the whole example shows at any text size
    /// (the field's own prompt is cut off after a few lines), and it is hidden once there is text.
    private var descriptionField: some View {
        ZStack(alignment: .topLeading) {
            Text(Self.placeholder)
                .foregroundStyle(.tertiary)
                .opacity(description.isEmpty ? 1 : 0)
                .accessibilityHidden(true)
            TextField("", text: $description, axis: .vertical)
                .lineLimit(1...8)
                .focused($isDescriptionFocused)
                .disabled(assistant.isWorking)
                .submitLabel(.return)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel("Describe your ideal schedule")
                .accessibilityHint("For example: \(Self.placeholder)")
        }
        .contentShape(.rect)
        .onTapGesture { isDescriptionFocused = true }
    }

    private var fillButton: some View {
        Button(action: fill) {
            Label("Fill in the survey", systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(trimmedDescription.isEmpty || assistant.isWorking)
    }

    @ViewBuilder
    private var assistantStatus: some View {
        switch assistant.state {
        case .idle:
            EmptyView()
        case .working(let found):
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading your description…")
                        if found > 0 {
                            Text(found == 1 ? "Found 1 setting" : "Found \(found) settings")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button("Stop") { assistant.cancel() }
                    .buttonStyle(.borderless)
            }
        case .filled(let count):
            VStack(alignment: .leading, spacing: 8) {
                Label(count == 1 ? "Apple Intelligence filled in 1 setting" : "Apple Intelligence filled in \(count) settings", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text("Review the highlighted rows below and change anything that’s off. Nothing is saved until you tap Done.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Undo") { undoAssistant() }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section {
            // They wrap instead of scrolling: a scrolling row is clipped at the section's edge, which
            // cuts the last chip in half and hides that there are more.
            GlassEffectContainer(spacing: 8) {
                PlanFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(SchedulePreset.allCases) { preset in
                        SchedulePresetChip(preset: preset, isOn: preset.isApplied(to: draft)) {
                            draft = preset.toggled(in: draft)
                            haptic.fire(.selection)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            Text("Quick start")
        }
    }

    // MARK: Time of day

    private var timeOfDaySection: some View {
        Section {
            ForEach(TimeBand.allCases) { band in
                let isFilledIn = filledIn.contains(.timeOfDay(band))
                Picker(selection: bandBinding(band)) {
                    ForEach(TimePreference.allCases) { Text($0.title).tag($0) }
                } label: {
                    SurveyRowLabel(title: band.title, subtitle: band.detail, systemImage: band.symbol, isFilledIn: isFilledIn)
                }
                .pickerStyle(.menu)
                .filledInHighlight(isFilledIn)
            }
        } header: {
            Text("Time of day")
        } footer: {
            Text("“Prefer” puts schedules with classes then first. “Avoid” puts them last. Neither removes any schedule.")
        }
    }

    private func bandBinding(_ band: TimeBand) -> Binding<TimePreference> {
        Binding(get: { draft[band] }, set: { draft[band] = $0 })
    }

    // MARK: Start and finish

    private var startFinishSection: some View {
        Section {
            limitRows(
                title: "Start no earlier than", pickerTitle: "Earliest start", systemImage: "sunrise", limit: $draft.earliestStart,
                defaultMinutes: 10 * 60, field: .earliestStart
            )
            limitRows(
                title: "Finish by", pickerTitle: "Latest finish", systemImage: "sunset", limit: $draft.latestEnd,
                defaultMinutes: 17 * 60, field: .latestEnd
            )
        } header: {
            Text("Start and finish")
        } footer: {
            if let start = draft.earliestStart, let end = draft.latestEnd, start.minutes >= end.minutes {
                Label("The earliest start (\(TimeOfDay.label(start.minutes))) isn’t before the latest finish (\(TimeOfDay.label(end.minutes))), so no class can fit.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("“Always” leaves out any class that starts or ends outside these times. “If possible” only ranks those schedules lower, the further outside the lower.")
            }
        }
    }

    @ViewBuilder
    private func limitRows(
        title: String, pickerTitle: String, systemImage: String, limit: Binding<TimeLimit?>, defaultMinutes: Int, field: PreferenceField
    ) -> some View {
        let isFilledIn = filledIn.contains(field)
        Toggle(isOn: Binding(
            get: { limit.wrappedValue != nil },
            set: { limit.wrappedValue = $0 ? (limit.wrappedValue ?? TimeLimit(minutes: defaultMinutes)) : nil }
        )) {
            SurveyRowLabel(title: title, systemImage: systemImage, isFilledIn: isFilledIn)
        }
        .filledInHighlight(isFilledIn)
        if let current = limit.wrappedValue {
            DatePicker(
                pickerTitle,
                selection: Binding(
                    get: { ScheduleClock.date(forMinutes: current.minutes) },
                    set: { limit.wrappedValue?.minutes = ScheduleClock.minutes(from: $0) }
                ),
                displayedComponents: .hourAndMinute
            )
            .filledInHighlight(isFilledIn)
            Picker("How strict", selection: Binding(
                get: { current.strength },
                set: { limit.wrappedValue?.strength = $0 }
            )) {
                ForEach(PreferenceStrength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .filledInHighlight(isFilledIn)
        }
    }

    // MARK: Days

    private func selectableDays(including extra: DaySet = DaySet()) -> [Int] {
        var days = [1, 2, 3, 4, 5]
        let weekends = userData.preferences.showWeekends
        if weekends || draft.daysOff.contains(day: 6) || extra.contains(day: 6) { days.append(6) }
        if weekends || draft.daysOff.contains(day: 0) || extra.contains(day: 0) { days.insert(0, at: 0) }
        return days
    }

    private var daysSection: some View {
        Section {
            let daysOffFilledIn = filledIn.contains(.daysOff)
            VStack(alignment: .leading, spacing: 10) {
                SurveyRowLabel(title: "Days off", systemImage: "calendar.badge.minus", isFilledIn: daysOffFilledIn)
                ScheduleDayChips(selection: $draft.daysOff, days: selectableDays(), onValue: "Day off", offValue: "Classes allowed")
            }
            .filledInHighlight(daysOffFilledIn)
            if !draft.daysOff.isEmpty {
                Picker("How strict", selection: $draft.daysOffStrength) {
                    ForEach(PreferenceStrength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .filledInHighlight(daysOffFilledIn)
            }
            let layoutFilledIn = filledIn.contains(.dayLayout)
            Picker(selection: $draft.dayLayout) {
                ForEach(DayLayout.allCases) { Text($0.title).tag($0) }
            } label: {
                SurveyRowLabel(title: "Class days", systemImage: "calendar", isFilledIn: layoutFilledIn)
            }
            .pickerStyle(.menu)
            .filledInHighlight(layoutFilledIn)
        } header: {
            Text("Days")
        } footer: {
            Text("“Always” leaves out any class on a day off. “If possible” puts schedules with those days free first.")
        }
    }

    // MARK: Blocked times

    private var blockedTimesSection: some View {
        Section {
            ForEach(draft.blockedTimes) { block in
                let isFilledIn = filledIn.contains(.blockedTime(block.id))
                NavigationLink(value: SurveyRoute.block(block.id)) {
                    ScheduleBlockedTimeRow(block: block, isFilledIn: isFilledIn)
                }
                .filledInHighlight(isFilledIn)
            }
            .onDelete { offsets in
                draft.blockedTimes.remove(atOffsets: offsets)
                haptic.fire(.warning)
            }
            Button(action: addBlockedTime) {
                Label("Add blocked time", systemImage: "plus.circle.fill")
                    .font(.body.weight(.medium))
            }
        } header: {
            Text("Blocked times")
        } footer: {
            Text("Classes won’t be scheduled over these. Think club meetings, work, a commute or practice.")
        }
    }

    private func blockBinding(_ id: UUID) -> Binding<BlockedTime> {
        Binding(
            get: { draft.blockedTimes.first { $0.id == id } ?? BlockedTime(label: "", days: DaySet(), start: 17 * 60, end: 19 * 60) },
            set: { value in
                if let index = draft.blockedTimes.firstIndex(where: { $0.id == id }) { draft.blockedTimes[index] = value }
            }
        )
    }

    private func blockDays(_ id: UUID) -> DaySet {
        draft.blockedTimes.first { $0.id == id }?.days ?? DaySet()
    }

    private func addBlockedTime() {
        let block = BlockedTime(label: "", days: DaySet(), start: 17 * 60, end: 19 * 60)
        draft.blockedTimes.append(block)
        path.append(.block(block.id))
    }

    /// A block the student added and walked away from without naming it or choosing days is just clutter.
    private func dropUnfinishedBlocks() {
        let editing = path.compactMap { route -> UUID? in
            if case .block(let id) = route { return id }
            return nil
        }
        draft.blockedTimes.removeAll { block in
            block.label.isEmpty && block.days.isEmpty && !editing.contains(block.id) && !initial.blockedTimes.contains { $0.id == block.id }
        }
    }

    // MARK: More preferences

    private var moreSection: some View {
        Section {
            DisclosureGroup("More preferences", isExpanded: $showsMore) {
                breaksRows
                workloadRows
                formatRows
                seatsRows
                instructorRows
                creditRows
            }
        }
    }

    private func subheader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .listRowSeparator(.hidden, edges: .bottom)
            .accessibilityAddTraits(.isHeader)
    }

    // Breaks and lunch

    @ViewBuilder
    private var breaksRows: some View {
        subheader("Breaks")
        let breaksFilledIn = filledIn.contains(.breaks)
        Picker(selection: $draft.breaks) {
            ForEach(BreakPreference.allCases) { Text($0.title).tag($0) }
        } label: {
            SurveyRowLabel(title: "Back-to-back", systemImage: "figure.walk", isFilledIn: breaksFilledIn)
        }
        .pickerStyle(.menu)
        .filledInHighlight(breaksFilledIn)
        if draft.breaks == .atLeast {
            Stepper(value: $draft.minimumBreakMinutes, in: 5...60, step: 5) {
                Text("At least \(draft.minimumBreakMinutes) minutes between buildings")
            }
            .filledInHighlight(breaksFilledIn)
            Picker("How strict", selection: $draft.minimumBreakStrength) {
                ForEach(PreferenceStrength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .filledInHighlight(breaksFilledIn)
        }
        let gapsFilledIn = filledIn.contains(.gaps)
        Picker(selection: $draft.gaps) {
            ForEach(GapPreference.allCases) { Text($0.title).tag($0) }
        } label: {
            SurveyRowLabel(title: "Gaps", subtitle: "Idle time", systemImage: "rectangle.compress.vertical", isFilledIn: gapsFilledIn)
        }
        .pickerStyle(.menu)
        .filledInHighlight(gapsFilledIn)
        lunchRows
    }

    @ViewBuilder
    private var lunchRows: some View {
        let isFilledIn = filledIn.contains(.lunch)
        Toggle(isOn: Binding(
            get: { draft.lunch != nil },
            set: { draft.lunch = $0 ? (draft.lunch ?? LunchBreak()) : nil }
        )) {
            SurveyRowLabel(title: "Protect a lunch break", subtitle: "Schedules with lunch free on more days rank higher", systemImage: "fork.knife", isFilledIn: isFilledIn)
        }
        .filledInHighlight(isFilledIn)
        if let lunch = draft.lunch {
            DatePicker("Window starts", selection: Binding(
                get: { ScheduleClock.date(forMinutes: lunch.start) },
                set: { draft.lunch?.start = ScheduleClock.minutes(from: $0) }
            ), displayedComponents: .hourAndMinute)
            .filledInHighlight(isFilledIn)
            DatePicker("Window ends", selection: Binding(
                get: { ScheduleClock.date(forMinutes: lunch.end) },
                set: { draft.lunch?.end = ScheduleClock.minutes(from: $0) }
            ), displayedComponents: .hourAndMinute)
            .filledInHighlight(isFilledIn)
            Picker("Keep free", selection: Binding(
                get: { lunch.minutes },
                set: { draft.lunch?.minutes = $0 }
            )) {
                ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            .pickerStyle(.menu)
            .filledInHighlight(isFilledIn)
            if lunch.end - lunch.start < lunch.minutes {
                Label("The window is shorter than the time you want free.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    // Workload

    @ViewBuilder
    private var workloadRows: some View {
        subheader("Workload")
        let isFilledIn = filledIn.contains(.workload)
        Toggle(isOn: Binding(
            get: { draft.maxClassesPerDay != nil },
            set: { draft.maxClassesPerDay = $0 ? (draft.maxClassesPerDay ?? 3) : nil }
        )) {
            SurveyRowLabel(title: "Limit classes per day", systemImage: "square.stack", isFilledIn: isFilledIn)
        }
        .filledInHighlight(isFilledIn)
        if let count = draft.maxClassesPerDay {
            Stepper(value: Binding(get: { count }, set: { draft.maxClassesPerDay = $0 }), in: 1...6) {
                Text(count == 1 ? "At most 1 class a day" : "At most \(count) classes a day")
            }
            .filledInHighlight(isFilledIn)
        }
        Toggle(isOn: Binding(
            get: { draft.maxMinutesPerDay != nil },
            set: { draft.maxMinutesPerDay = $0 ? (draft.maxMinutesPerDay ?? 5 * 60) : nil }
        )) {
            SurveyRowLabel(title: "Limit class hours per day", systemImage: "clock", isFilledIn: isFilledIn)
        }
        .filledInHighlight(isFilledIn)
        if let minutes = draft.maxMinutesPerDay {
            Stepper(value: Binding(get: { minutes }, set: { draft.maxMinutesPerDay = $0 }), in: 60...(10 * 60), step: 30) {
                Text("At most \(SchedulePreferences.hoursLabel(minutes: minutes)) of class a day")
            }
            .filledInHighlight(isFilledIn)
        }
    }

    // Format and campus

    @ViewBuilder
    private var formatRows: some View {
        subheader("Format and campus")
        let formatFilledIn = filledIn.contains(.format)
        Picker(selection: $draft.format) {
            ForEach(FormatPreference.allCases) { Text($0.title).tag($0) }
        } label: {
            SurveyRowLabel(title: "Format", systemImage: "building.2", isFilledIn: formatFilledIn)
        }
        .pickerStyle(.menu)
        .filledInHighlight(formatFilledIn)
        if draft.format != .noPreference {
            Picker("How strict", selection: $draft.formatStrength) {
                ForEach(PreferenceStrength.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .filledInHighlight(formatFilledIn)
        }
        if !campusChoices.isEmpty {
            let campusFilledIn = filledIn.contains(.campus)
            Picker(selection: $draft.campus) {
                Text("No preference").tag(String?.none)
                ForEach(campusChoices, id: \.self) { Text($0).tag(String?.some($0)) }
            } label: {
                SurveyRowLabel(title: "Campus", systemImage: "mappin.and.ellipse", isFilledIn: campusFilledIn)
            }
            .pickerStyle(.menu)
            .filledInHighlight(campusFilledIn)
            if draft.campus != nil {
                Picker("How strict", selection: $draft.campusStrength) {
                    ForEach(PreferenceStrength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .filledInHighlight(campusFilledIn)
            }
        }
    }

    private var campusChoices: [String] {
        var names = context.campusNames
        if let campus = draft.campus, !names.contains(campus) { names.append(campus) }
        return names
    }

    // Seats

    @ViewBuilder
    private var seatsRows: some View {
        subheader("Seats")
        let isFilledIn = filledIn.contains(.seats)
        Picker(selection: $draft.seats) {
            ForEach(SeatPolicy.allCases) { Text($0.title).tag($0) }
        } label: {
            SurveyRowLabel(title: "Sections to use", systemImage: "chair.lounge", isFilledIn: isFilledIn)
        }
        .pickerStyle(.menu)
        .filledInHighlight(isFilledIn)
    }

    // Instructors

    @ViewBuilder
    private var instructorRows: some View {
        subheader("Instructors")
        let isFilledIn = filledIn.contains(.instructors)
        let chosen = draft.preferredInstructors.count + draft.avoidedInstructors.count
        NavigationLink(value: SurveyRoute.instructors) {
            LabeledContent {
                Text(chosen == 0 ? "None chosen" : "\(chosen) chosen")
            } label: {
                SurveyRowLabel(title: "Prefer or avoid", systemImage: "person.2", isFilledIn: isFilledIn)
            }
        }
        .filledInHighlight(isFilledIn)
    }

    // Credits

    @ViewBuilder
    private var creditRows: some View {
        if context.optionalCourseCount > 0 {
            subheader("Credit load")
            let isFilledIn = filledIn.contains(.credits)
            Toggle(isOn: Binding(
                get: { draft.creditTarget != nil },
                set: { draft.creditTarget = $0 ? (draft.creditTarget ?? defaultCreditTarget) : nil }
            )) {
                SurveyRowLabel(
                    title: "Aim for a credit total",
                    subtitle: "Required courses add up to \(context.requiredCredits) credits. Optional courses are worth up to \(max(0, context.totalCredits - context.requiredCredits)) more.",
                    systemImage: "number",
                    isFilledIn: isFilledIn
                )
            }
            .filledInHighlight(isFilledIn)
            if let target = draft.creditTarget {
                Stepper(value: Binding(
                    get: { target.lower },
                    set: { draft.creditTarget = CreditTarget(lower: $0, upper: max($0, target.upper)) }
                ), in: 1...30) {
                    Text("At least \(target.lower) credits")
                }
                .filledInHighlight(isFilledIn)
                Stepper(value: Binding(
                    get: { target.upper },
                    set: { draft.creditTarget = CreditTarget(lower: min(target.lower, $0), upper: $0) }
                ), in: 1...30) {
                    Text("At most \(target.upper) credits")
                }
                .filledInHighlight(isFilledIn)
            }
        }
    }

    private var defaultCreditTarget: CreditTarget {
        let available = max(context.totalCredits, context.requiredCredits)
        let lower = min(max(context.requiredCredits, 16), max(1, available))
        return CreditTarget(lower: lower, upper: min(lower + 2, max(lower, available)))
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                draft = SchedulePreferences()
                filledIn = []
                beforeAssistant = nil
                assistant.reset()
                haptic.fire(.warning)
            } label: {
                Label("Reset ideal week", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .disabled(draft.isDefault)
        } footer: {
            Text("Your ideal week is saved with this schedule. Filters still apply on top of it.")
        }
    }

    // MARK: Actions

    /// Sends the description to Apple Intelligence. The answer lands in the survey, highlighted,
    /// and nothing is saved until the student taps Done.
    private func fill() {
        isDescriptionFocused = false
        assistant.start(description) { interpretation in
            // Merged now, into what the survey looks like now: edits made while it was thinking stay.
            let before = draft
            let (merged, changed) = interpretation.merged(into: before)
            guard !changed.isEmpty else { return 0 }
            beforeAssistant = before
            draft = merged
            filledIn.formUnion(changed)
            // Changed rows hidden in "More preferences" shouldn't stay out of sight.
            if changed.contains(where: Self.isInMoreSection) { showsMore = true }
            haptic.fire(.success)
            AccessibilityNotification.Announcement(
                changed.count == 1 ? "Apple Intelligence filled in 1 setting. Review it." : "Apple Intelligence filled in \(changed.count) settings. Review them."
            ).post()
            return changed.count
        }
    }

    private static func isInMoreSection(_ field: PreferenceField) -> Bool {
        switch field {
        case .workload, .gaps, .breaks, .lunch, .format, .campus, .seats, .instructors, .credits: true
        case .timeOfDay, .earliestStart, .latestEnd, .daysOff, .dayLayout, .blockedTime: false
        }
    }

    private func undoAssistant() {
        if let beforeAssistant { draft = beforeAssistant }
        beforeAssistant = nil
        filledIn = []
        assistant.reset()
        haptic.fire(.selection)
    }

    private func cancel() {
        if hasChanges {
            confirmsDiscard = true
        } else {
            dismiss()
        }
    }

    private func commit() {
        assistant.cancel()
        var final = draft
        final.blockedTimes.removeAll { !$0.isValid }
        final = final.normalized()
        let stored: SchedulePreferences? = final.isDefault ? nil : final
        if stored != userData.plan(id: planID)?.preferences {
            userData.updatePlan(id: planID) { $0.preferences = stored }
        }
        haptic.fire(.success)
        dismiss()
    }
}
