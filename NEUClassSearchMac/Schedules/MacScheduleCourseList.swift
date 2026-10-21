//
//  MacScheduleCourseList.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the course list of a schedule can ask its schedule to do.
struct MacCourseListActions {
    var chooseSection: (String) -> Void
    var openCourse: (CourseKey) -> Void
    var toggleRequired: (String) -> Void
    var remove: ([String]) -> Void
    var addCourse: () -> Void
    var fix: (ScheduleNotice.Fix) -> Void
    var addAutofill: (ScheduleAutofillSuggestion) -> Void
    var dismissNudge: (ScheduleAutofillSuggestion) -> Void
    var editPreferences: () -> Void
    var generate: () -> Void
    var showFilters: () -> Void
    /// Courses (or sections) pasted as text: `CS 3000` or `CS 3000 12345` per line.
    var paste: ([String]) -> Void
}

/// The left side of a schedule: what needs attention, then the courses with their chosen sections,
/// the classes that have no meeting time, and the "ideal week" summary. Below it, the button that
/// generates schedules.
struct MacScheduleCourseList: View {
    var plan: SchedulePlan
    var resolved: ResolvedPlan
    var notices: [ScheduleNotice]
    var termName: String
    var index: CatalogIndex?
    var seatsDate: Date?
    var autofill: [ScheduleAutofillSuggestion]
    @Binding var autofillChoice: String?
    var nudge: ScheduleAutofillSuggestion?
    @Binding var selection: Set<String>
    var actions: MacCourseListActions

    /// The class of the "Online / TBA" group whose popover is open.
    @State private var untimedPopoverCRN: String?

    var body: some View {
        List(selection: $selection) {
            if plan.courses.isEmpty, !autofill.isEmpty {
                Section {
                    MacAutofillCard(suggestions: autofill, choice: $autofillChoice, plan: plan, index: index, onAdd: actions.addAutofill)
                        .plainListRow()
                }
            }
            if !notices.isEmpty {
                Section {
                    ForEach(notices) { notice in
                        MacNoticeRow(notice: notice, onFix: actions.fix).plainListRow()
                    }
                }
            }
            if let nudge {
                Section {
                    MacAutofillNudge(
                        suggestion: nudge,
                        onAdd: { actions.addAutofill(nudge) },
                        onDismiss: { actions.dismissNudge(nudge) }
                    )
                    .plainListRow()
                }
            }
            coursesSection
            untimedSection
            preferencesSection
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            for entry in resolved.entries where ids.contains(entry.id) { actions.openCourse(entry.key) }
        }
        .onDeleteCommand {
            if !selection.isEmpty { actions.remove(Array(selection)) }
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            for entry in resolved.entries where selection.contains(entry.id) { actions.openCourse(entry.key) }
            return .handled
        }
        // ⌘C copies the selected courses (with their chosen sections) as text, ⌘V adds courses copied
        // from a course table.
        .onCopyCommand {
            let lines = resolved.entries.filter { selection.contains($0.id) }.map { entry in
                entry.chosen.map { "\(entry.key.description) \($0.crn)" } ?? entry.key.description
            }
            return lines.isEmpty ? [] : [NSItemProvider(object: lines.joined(separator: "\n") as NSString)]
        }
        .onPasteCommand(of: [.plainText]) { providers in
            Task { actions.paste(await MacPasteboard.strings(from: providers)) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    // MARK: Courses

    private var coursesSection: some View {
        Section {
            if resolved.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No courses yet")
                        .font(.headline)
                    Text("Add the courses you’re considering, then generate every schedule that fits.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add Course…", action: actions.addCourse)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .plainListRow()
            }
            ForEach(resolved.entries) { entry in
                MacPlanCourseRow(
                    entry: entry,
                    termName: termName,
                    conflictingKeys: conflictingKeys(for: entry),
                    onChooseSection: { actions.chooseSection(entry.id) },
                    onToggleRequired: { actions.toggleRequired(entry.id) }
                )
                .tag(entry.id)
            }
            if !resolved.entries.isEmpty {
                MacListNote {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Required courses appear in every generated schedule. Optional courses are added when they fit.")
                        PlanSeatsFreshness(date: seatsDate, refreshHint: "Choose View › Refresh Seats (⌘R) to update them.")
                    }
                }
            }
        } header: {
            HStack {
                Text("Courses")
                Spacer()
                if resolved.hasCatalog, resolved.credits.max > 0 {
                    Text(resolved.creditsLabel).monospacedDigit()
                }
            }
        }
    }

    private func conflictingKeys(for entry: ResolvedPlan.Entry) -> [CourseKey] {
        let crns = Set(entry.selected.map(\.crn))
        var keys: [CourseKey] = []
        for conflict in resolved.conflicts {
            if crns.contains(conflict.first.crn) { keys.append(conflict.second.courseKey) }
            if crns.contains(conflict.second.crn) { keys.append(conflict.first.courseKey) }
        }
        return Array(Set(keys)).sorted()
    }

    // MARK: Online / TBA

    @ViewBuilder
    private var untimedSection: some View {
        if !resolved.untimed.isEmpty {
            Section {
                ForEach(resolved.untimed, id: \.section.crn) { pair in
                    Button {
                        untimedPopoverCRN = pair.section.crn
                    } label: {
                        HStack(spacing: 10) {
                            PlanColorDot(colorIndex: pair.entry.planCourse.colorIndex, size: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(pair.section.courseKey.description) · \(ScheduleFormat.sectionTitle(pair.section))")
                                    .font(.callout.weight(.semibold))
                                Text(pair.section.scheduleSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: pair.section.isOnline ? "wifi" : "clock.badge.questionmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: Binding(
                            get: { untimedPopoverCRN == pair.section.crn },
                            set: { if !$0, untimedPopoverCRN == pair.section.crn { untimedPopoverCRN = nil } }
                        ),
                        arrowEdge: .trailing
                    ) {
                        MacSectionDetailsView(planID: plan.id, crn: pair.section.crn) { _, entryID in
                            // Let the popover go before the sheet comes.
                            Task {
                                try? await Task.sleep(for: .milliseconds(200))
                                actions.chooseSection(entryID)
                            }
                        }
                    }
                }
                MacListNote {
                    Text("These sections don’t meet at a set time, so they don’t appear on the calendar.")
                }
            } header: {
                Text("Online / TBA")
            }
        }
    }

    // MARK: Ideal week

    @ViewBuilder
    private var preferencesSection: some View {
        if !plan.courses.isEmpty {
            let preferences = plan.preferences ?? SchedulePreferences()
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your ideal week")
                            .font(.callout.weight(.semibold))
                        Text(preferences.hasWishes ? preferences.summary(limit: 4) : "Describe the schedule you want, or answer a few questions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Edit…", action: actions.editPreferences)
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
                MacListNote {
                    Text("Mornings or nights, days off, clubs and work: generated schedules follow what you tell us.")
                }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        let ordered = resolved.entries.filter { ids.contains($0.id) }
        if let entry = ordered.first, ordered.count == 1 {
            Button("Choose Section…", systemImage: "checklist") { actions.chooseSection(entry.id) }
            Button("Open in New Window", systemImage: "macwindow") { actions.openCourse(entry.key) }
            Button(entry.planCourse.isRequired ? "Make Optional" : "Make Required", systemImage: entry.planCourse.isRequired ? "circle.dashed" : "lock") {
                actions.toggleRequired(entry.id)
            }
            if let section = entry.chosen {
                Button("Copy CRN", systemImage: "doc.on.doc") { MacPasteboard.copy(section.crn) }
            }
            Divider()
            Button("Remove from Schedule", systemImage: "trash", role: .destructive) { actions.remove([entry.id]) }
        } else if !ordered.isEmpty {
            Button("Open in New Windows", systemImage: "macwindow") { for entry in ordered { actions.openCourse(entry.key) } }
            Divider()
            Button("Remove \(ordered.count) Courses from Schedule", systemImage: "trash", role: .destructive) { actions.remove(ordered.map(\.id)) }
        } else {
            Button("Add Course…", systemImage: "plus", action: actions.addCourse)
        }
    }

    // MARK: Footer

    /// How much of its labels the footer shows: all of them, only the main button's, or just icons.
    private enum FooterStyle {
        case full, short, compact
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            // The buttons give up their labels, one by one, before the list asks the window for more width.
            ViewThatFits(in: .horizontal) {
                footerButtons(.full)
                footerButtons(.short)
                footerButtons(.compact)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func footerButtons(_ style: FooterStyle) -> some View {
        let activeFilters = plan.filters.activeCount
        let filtersTitle = activeFilters == 0 ? "Filters" : "Filters · \(activeFilters)"
        return HStack(spacing: 8) {
            Button(action: actions.addCourse) {
                if style == .full {
                    Label("Add Course", systemImage: "plus")
                } else {
                    Label("Add Course", systemImage: "plus").labelStyle(.iconOnly)
                }
            }
            .help("Add a course to this schedule")
            Spacer(minLength: 0)
            Button(action: actions.showFilters) {
                if style == .full {
                    Label(filtersTitle, systemImage: "line.3.horizontal.decrease")
                } else {
                    Label(filtersTitle, systemImage: "line.3.horizontal.decrease").labelStyle(.iconOnly)
                }
            }
            .help(activeFilters == 0 ? "Limit which sections the generator uses" : "Filters: \(activeFilters) active")
            Button(action: actions.generate) {
                Label(style == .compact ? "Generate" : "Generate Schedules", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(plan.courses.isEmpty || !resolved.hasCatalog)
            .help("Find every combination of sections that fits")
        }
    }
}

// MARK: - Row

/// One course of a schedule: color dot, code and title, the chosen section (days, time, place,
/// instructor, seats) and the Required / Optional switch. In a wide list the section sits beside the
/// course instead of under it.
struct MacPlanCourseRow: View {
    var entry: ResolvedPlan.Entry
    var termName: String
    /// Courses whose chosen sections overlap this course's section.
    var conflictingKeys: [CourseKey] = []
    var onChooseSection: () -> Void
    var onToggleRequired: () -> Void

    /// The width of the row: a wide one has room for two columns.
    @State private var width: CGFloat = 0

    private var isWide: Bool { width >= 540 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PlanColorDot(colorIndex: entry.planCourse.colorIndex, size: 10)
                .padding(.top, 4)
            if isWide {
                wideLayout
            } else {
                narrowLayout
            }
        }
        .padding(.vertical, 4)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
    }

    /// Everything stacked: the course, its title, then the section.
    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The credits give way before the code does, in a narrow list.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    codeAndCredits
                    Spacer(minLength: 4)
                    MacRequiredToggle(key: entry.key, isRequired: entry.planCourse.isRequired, action: onToggleRequired)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    code
                    Spacer(minLength: 4)
                    MacRequiredToggle(key: entry.key, isRequired: entry.planCourse.isRequired, action: onToggleRequired)
                }
            }
            if !entry.title.isEmpty {
                Text(entry.title)
                    .lineLimit(2)
            }
            sectionLines
        }
    }

    /// The course and its title on the left, the section (days, time, place, instructor, seats) beside
    /// it, and the Required switch at the end.
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                codeAndCredits
                if !entry.title.isEmpty {
                    Text(entry.title)
                        .lineLimit(3)
                }
            }
            .frame(minWidth: 140, idealWidth: 200, maxWidth: 240, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                sectionLines
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MacRequiredToggle(key: entry.key, isRequired: entry.planCourse.isRequired, action: onToggleRequired)
        }
    }

    private var code: some View {
        Text(entry.key.description)
            .font(.body.weight(.bold))
            .foregroundStyle(entry.color.text)
            .monospacedDigit()
            .fixedSize()
    }

    private var codeAndCredits: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            code
            if let course = entry.course {
                Text(course.creditsLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var sectionLines: some View {
        if let section = entry.chosen {
            Text(ScheduleFormat.sectionSummary(section))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail = detail(for: section) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // On one line while there is room, else wrapped (a narrow window shrinks the list).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    SeatsBadge(section: section)
                    if !conflictingKeys.isEmpty {
                        ScheduleConflictTag(text: conflictText)
                    }
                    Spacer(minLength: 0)
                    changeButton
                }
                CourseFlowLayout(spacing: 6, lineSpacing: 4) {
                    SeatsBadge(section: section)
                    if !conflictingKeys.isEmpty {
                        ScheduleConflictTag(text: conflictText)
                    }
                    changeButton
                }
            }
            .padding(.top, 2)
            if entry.selected.count > 1 {
                Text("+\(entry.selected.count - 1) more section\(entry.selected.count == 2 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !entry.catalogAvailable {
            Label("Course data unavailable", systemImage: "icloud.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if entry.isMissing {
            Label("Not offered in \(termName)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        } else if entry.hasNoSections {
            Label("No sections in \(termName)", systemImage: "calendar.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.orange)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    noSectionLabel
                    Spacer(minLength: 0)
                    chooseButton
                }
                VStack(alignment: .leading, spacing: 2) {
                    noSectionLabel
                    chooseButton
                }
            }
        }
        if !entry.planCourse.excludedCRNs.isEmpty, !entry.isMissing {
            Label("\(entry.planCourse.excludedCRNs.count) skipped when generating", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var changeButton: some View {
        Button("Change…", action: onChooseSection)
            .buttonStyle(.macInline)
            .font(.caption)
            .help("Choose a different section of \(entry.key.description)")
    }

    /// Optional courses may legitimately stay out of the schedule.
    private var noSectionLabel: some View {
        Label("No section chosen", systemImage: "circle.dashed")
            .font(.callout)
            .foregroundStyle(entry.planCourse.isRequired ? Color.orange : Color.secondary)
    }

    private var chooseButton: some View {
        Button("Choose from \(entry.availableSections.count) \(entry.availableSections.count == 1 ? "section" : "sections")…", action: onChooseSection)
            .buttonStyle(.macInline)
            .font(.caption)
            .monospacedDigit()
    }

    private var conflictText: String {
        conflictingKeys.count == 1 ? "Overlaps \(conflictingKeys[0])" : "Overlaps \(conflictingKeys.count) courses"
    }

    private func detail(for section: CourseSection) -> String? {
        var parts: [String] = []
        if let location = ScheduleFormat.location(of: section) { parts.append(location) }
        if let instructors = ScheduleFormat.instructors(of: section) { parts.append(instructors) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A note under a section of the list. It is a row of its own rather than the section's footer, which
/// would cut the text off at the end of one line instead of wrapping it.
struct MacListNote<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .plainListRow()
    }
}

extension View {
    /// A list row that is content rather than a selectable item: no separator, no selection highlight.
    func plainListRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }
}
