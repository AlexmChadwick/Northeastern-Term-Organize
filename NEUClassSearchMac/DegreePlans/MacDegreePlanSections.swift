//
//  MacDegreePlanSections.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Semester

/// One planned semester: a header with its credits, an Add Course button (a search popover) and
/// a menu (build a schedule, remove the semester), then its courses. Courses can be dragged
/// from one semester to another, or reordered within one; an empty semester takes a drop too.
struct MacDegreePlanSemesterSection: View {
    var plan: DegreePlan
    var term: DegreePlanTerm
    var review: DegreePlanReview
    var catalog: DegreePlanCatalogSnapshot
    var editor: MacDegreePlanEditor
    /// Where the degree requirements count a course of this semester, when they're set up.
    var requirementNote: (DegreePlanCourse) -> String? = { _ in nil }
    var onBuildSchedule: () -> Void
    var onRemove: () -> Void
    /// Why this semester can't be taken, when it can't.
    var feasibility: DegreePlanFeasibility.TermReport? = nil
    var onReorganize: (() -> Void)? = nil
    /// Courses dropped on the semester: at a position between its courses, or (nil) at the end.
    var onDrop: ([MacDegreeCourseDrag], Int?) -> Bool

    @State private var isAddingCourse = false
    @State private var isTargeted = false

    var body: some View {
        Section {
            ForEach(term.courses) { course in
                MacDegreePlanCourseRow(
                    course: course,
                    title: catalog.title(for: course),
                    status: review.status(for: course),
                    note: review.note(for: course),
                    catalogAvailable: review.hasCatalog,
                    uncheckedReason: review.uncheckedReason(for: course),
                    offeringNote: review.offeringNote(for: course),
                    equivalenceNote: plan.degreeEquivalenceNote(for: course.key),
                    requirementNote: requirementNote(course),
                    caption: catalog.cpsCaption(for: course, in: term),
                    creditSpan: catalog.creditSpan(for: course, in: term),
                    onSetCredits: { credits in
                        editor.perform("Change Credits") {
                            DegreePlanEditing.setCredits(course.id, to: credits, in: &$0)
                        }
                        editor.userData.syncChosenCredits(fromDegreePlan: plan.id)
                    }
                )
                .tag(course.id)
                .draggable(MacDegreeCourseDrag(planID: plan.id, courseID: course.id, summary: Self.summary(of: course, catalog: catalog)))
            }
            .dropDestination(for: MacDegreeCourseDrag.self) { items, index in
                _ = onDrop(items, index)
            }
            if term.courses.isEmpty {
                Text("No courses yet. Drag a course here, or choose Add Course.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .background(isTargeted ? Color.accentColor.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 6))
                    .selectionDisabled()
                    .dropDestination(for: MacDegreeCourseDrag.self) { items, _ in
                        onDrop(items, nil)
                    } isTargeted: { isTargeted = $0 }
            }
        } header: {
            header
        }
    }

    /// `CS 3500 Object-Oriented Design`, for other apps a course is dragged to.
    static func summary(of course: DegreePlanCourse, catalog: DegreePlanCatalogSnapshot) -> String {
        [course.key?.description ?? course.label, catalog.title(for: course)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(term.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(term.degreePlanSummaryLine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button {
                isAddingCourse = true
            } label: {
                Label("Add Course", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a course to \(term.name)")
            .popover(isPresented: $isAddingCourse, arrowEdge: .bottom) {
                MacDegreePlanAddCourse(planID: plan.id, termID: term.id, editor: editor)
            }
            Menu {
                Button {
                    isAddingCourse = true
                } label: {
                    Label("Add Course…", systemImage: "plus")
                }
                buildScheduleItem
                if feasibility?.isInfeasible == true, let onReorganize {
                    Button(action: onReorganize) {
                        Label(DegreePlanReorganizeCopy.action, systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove Semester…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("\(term.name) options")
            .accessibilityLabel("\(term.name) options")
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .background(isTargeted ? Color.accentColor.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 6))
        .macListHeaderBackground()
        .dropDestination(for: MacDegreeCourseDrag.self) { items, _ in
            onDrop(items, nil)
        } isTargeted: { isTargeted = $0 }
        if let feasibility, feasibility.isInfeasible, let onReorganize {
            DegreePlanTermWarning(report: feasibility, onReorganize: onReorganize)
        }
        }
    }

    /// "Build Schedule…", or a disabled item that says why it can't be used yet.
    @ViewBuilder
    private var buildScheduleItem: some View {
        let hasCourses = term.courses.contains { $0.key != nil }
        let reason = catalog.scheduleUnavailableReason(for: term) ?? (hasCourses ? nil : "Add courses first")
        if let reason {
            Section(reason) {
                Button {} label: {
                    Label("Build Schedule…", systemImage: "calendar.badge.plus")
                }
                .disabled(true)
            }
        } else {
            Button {
                onBuildSchedule()
            } label: {
                Label("Build Schedule…", systemImage: "calendar.badge.plus")
            }
        }
    }
}

// MARK: - Completed courses

/// The courses the audit lists as completed (it includes courses in progress), collapsible
/// (collapsed to start with when the list is long). Dropping a planned course on the header
/// marks it completed.
struct MacDegreePlanCompletedSection: View {
    var plan: DegreePlan
    var review: DegreePlanReview
    var catalog: DegreePlanCatalogSnapshot
    var editor: MacDegreePlanEditor
    @Binding var isExpanded: Bool
    /// Where the degree requirements count a completed course, when they're set up.
    var requirementNote: (DegreePlanCourse) -> String? = { _ in nil }
    var onDrop: ([MacDegreeCourseDrag]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Section {
            if plan.completed.isEmpty {
                Label("No completed courses", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            } else if isExpanded {
                ForEach(plan.completed) { course in
                    MacDegreePlanCourseRow(
                        course: course,
                        title: catalog.title(for: course),
                        status: nil,
                        note: review.note(for: course),
                        equivalenceNote: plan.degreeEquivalenceNote(for: course.key),
                        requirementNote: requirementNote(course),
                        caption: catalog.cpsCaption(for: course, in: nil),
                        creditSpan: catalog.creditSpan(for: course, in: nil),
                        onSetCredits: { credits in
                            editor.perform("Change Credits") {
                                DegreePlanEditing.setCredits(course.id, to: credits, in: &$0)
                            }
                            editor.userData.syncChosenCredits(fromDegreePlan: plan.id)
                        }
                    )
                    .tag(course.id)
                }
            }
        } header: {
            header
        } footer: {
            Text("The degree audit counts courses you’re taking now as completed.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !plan.completed.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            Text("Completed Courses")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text("\(DegreePlanText.courses(plan.completed.count)) · \(DegreePlanText.credits(plan.completedCredits))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
        }
        .textCase(nil)
        .padding(.vertical, 2)
        .background(isTargeted ? Color.accentColor.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 6))
        .macListHeaderBackground()
        .contentShape(.rect)
        .onTapGesture {
            guard !plan.completed.isEmpty else { return }
            withAnimation(.snappy) { isExpanded.toggle() }
        }
        .dropDestination(for: MacDegreeCourseDrag.self) { items, _ in
            onDrop(items)
        } isTargeted: { isTargeted = $0 }
        .help(plan.completed.isEmpty ? "Drop a planned course here to mark it completed" : (isExpanded ? "Hide completed courses" : "Show completed courses"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(plan.completed.isEmpty ? "" : (isExpanded ? "Collapses the list" : "Expands the list"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Student

/// The student's name and a masked ID, with a way to remove both. They're only kept so
/// exported PDFs match the degree audit's header.
struct MacDegreePlanStudentSection: View {
    var plan: DegreePlan
    var onRemove: () -> Void

    @State private var showsID = false

    private static let mask = "•••••••••"
    /// A name and an ID don't need a wide list's whole width between label and value.
    private static let readingWidth: CGFloat = 520

    var body: some View {
        Section {
            if let name = plan.studentName {
                LabeledContent("Name") {
                    Text(name)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .selectionDisabled()
            }
            if let id = plan.studentID {
                LabeledContent("Student ID") {
                    HStack(spacing: 10) {
                        Text(showsID ? id : Self.mask)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .accessibilityLabel(showsID ? id : "Hidden")
                        Button(showsID ? "Hide" : "Show") {
                            showsID.toggle()
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel(showsID ? "Hide student ID" : "Show student ID")
                    }
                }
                .frame(maxWidth: Self.readingWidth, alignment: .leading)
                .selectionDisabled()
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove Student Info…", systemImage: "person.crop.circle.badge.minus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .selectionDisabled()
        } header: {
            Text("Student")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .macListHeaderBackground()
        } footer: {
            Text("Your name and ID are only kept so exported PDFs match your degree audit. They stay on this Mac and are never uploaded.")
        }
    }
}

// MARK: - Equivalences

/// The plan's course equivalences: suggestions to confirm, the ones declared, and a way to add
/// one. Shows nothing until there is something to show (adding one is also in the plan's menu
/// and in each course's context menu).
struct MacDegreePlanEquivalencesSection: View {
    var plan: DegreePlan
    var prompts: [DegreeEquivalencePrompt]
    var onConfirm: (DegreeEquivalencePrompt) -> Void
    var onDismiss: (DegreeEquivalencePrompt) -> Void
    var onEdit: (CourseEquivalence) -> Void
    var onDelete: (CourseEquivalence) -> Void
    var onAdd: () -> Void

    var body: some View {
        if !plan.courseEquivalences.isEmpty || !prompts.isEmpty {
            Section {
                ForEach(prompts) { prompt in
                    MacDegreeEquivalencePromptRow(prompt: prompt, onConfirm: { onConfirm(prompt) }, onDismiss: { onDismiss(prompt) })
                        .selectionDisabled()
                }
                ForEach(plan.courseEquivalences) { equivalence in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "equal.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(equivalence.course.description) counts as \(equivalence.countsAs.description)")
                            if let note = equivalence.note.nilIfBlank {
                                Text(note)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Edit…") { onEdit(equivalence) }
                            .buttonStyle(.link)
                        Button {
                            onDelete(equivalence)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this equivalence")
                        .accessibilityLabel("Delete equivalence")
                    }
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                    .selectionDisabled()
                    .onTapGesture(count: 2) { onEdit(equivalence) }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Edits the equivalence")
                }
                Button(action: onAdd) {
                    Label("Add Course Equivalence…", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.link)
                .selectionDisabled()
            } header: {
                Text("Course Equivalences")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .macListHeaderBackground()
            } footer: {
                Text("Courses that count as one another, like a renumbered course and its new number. Prerequisite checks and degree requirements use them.")
            }
        }
    }
}

/// A suggested equivalence: the question, why it's suggested, and Confirm or Dismiss.
struct MacDegreeEquivalencePromptRow: View {
    var prompt: DegreeEquivalencePrompt
    var onConfirm: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "equal.circle")
                .foregroundStyle(.tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.question)
                    .fontWeight(.semibold)
                Text(prompt.evidence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .accessibilityLabel("Dismiss this suggestion")
            Button("Confirm", action: onConfirm)
                .accessibilityLabel("Confirm that \(prompt.course.description) counts as \(prompt.countsAs.description)")
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}
