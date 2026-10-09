//
//  MacDegreeRequirementRows.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Page data

/// How the rows of the requirements are laid out: in aligned columns when there is room, else
/// two or three lines a course. The requirements screen measures itself and sets it.
enum MacDegreeRowLayout: Sendable {
    case table, compact
}

extension EnvironmentValues {
    /// Whether requirement rows have room for columns (see `MacDegreeRowLayout`).
    @Entry var macDegreeRowLayout: MacDegreeRowLayout = .table
}

/// What the rows of the requirements page ask the screen to do. The screen owns the state
/// (sheets, confirmations, undo), so rows just call these.
struct MacDegreeRequirementActions {
    /// Selects a requirement (shows its details in the details pane).
    var selectRule: (String) -> Void = { _ in }
    /// Opens a requirement's details, within the pane that lists the requirements.
    var openDetails: (String) -> Void = { _ in }
    /// Adds a course to a semester of the plan (creating the semester when it's new).
    var addCourse: (CourseKey, DegreePlanTerm) -> Void = { _, _ in }
    /// Starts a substitution of a kind for a requirement.
    var startSubstitution: (String, DegreeSubstitutionRequest.Kind) -> Void = { _, _ in }
    /// Starts a "count a course" substitution for a requirement with a course of the plan chosen
    /// (a near miss that an adviser approved).
    var countSpecificCourse: (String, CourseKey) -> Void = { _, _ in }
    /// Saves which course numbers a petition accepts.
    var answerPetition: (DegreePetitionQuestion, CourseNumberLimit) -> Void = { _, _ in }
    var editSubstitution: (RequirementSubstitution) -> Void = { _ in }
    var deleteSubstitution: (RequirementSubstitution) -> Void = { _ in }
    /// Turns a substitution that is really the required course under a new number into the
    /// equivalence it amounts to.
    var convertToEquivalence: (RequirementSubstitution) -> Void = { _ in }
    /// Keeps a substitution as one: turns down the suggestion that it is a renumbering.
    var keepAsSubstitution: (DegreeSubstitutionEditing.LikelyRenumbering) -> Void = { _ in }
    /// Opens a course in its own window.
    var viewCourse: (CourseKey) -> Void = { _ in }
    /// Selects a course of the plan, and shows it there (the semester it's planned in, when it
    /// is taken more than once).
    var showCourseInPlan: ((CourseKey, String?) -> Void)?
    /// Declares a suggested equivalence.
    var confirmEquivalence: (DegreeEquivalencePrompt) -> Void = { _ in }
    var dismissEquivalence: (DegreeEquivalencePrompt) -> Void = { _ in }
    /// Opens the equivalence sheet for a listed course ("Same course, different number…").
    var addEquivalence: (CourseKey) -> Void = { _ in }
    /// Shows all of a long list's options, or fewer again (by rule id).
    var toggleExpanded: (String) -> Void = { _ in }
    /// Shows or hides the parts of a checked sentence (by check id).
    var toggleCheck: (String) -> Void = { _ in }
    /// Searches the catalog for courses with an NUpath attribute.
    var findCourses: ((NUPath) -> Void)?
}

/// Everything the requirements rows need, computed once per update of the page.
struct MacDegreeRequirementsPage {
    var plan: DegreePlan
    var context: DegreeRequirementsContext
    var requirements: ProgramRequirements
    var audit: DegreeAudit
    var lookup: DegreeCourseLookup
    /// Which courses count as which: Banner's and the plan's declared ones.
    var equivalences: CourseEquivalences
    /// Semesters "Add to plan" offers.
    var addTargets: [DegreePlanTerm]
    /// Suggested equivalences for listed courses the plan doesn't have.
    var prompts: DegreeEquivalencePrompts
    /// Rules whose long lists show every option.
    var expandedRules: Set<String>
    /// Checked sentences whose parts are shown.
    var expandedChecks: Set<String> = []
    /// A subject's name (`PHYS` → `Physics`), to place a list's category subheaders.
    var subjectName: (String) -> String?
    /// The courses selected in the plan beside the requirements: where they count is marked.
    var linkedCourses: Set<CourseKey> = []
    var actions: MacDegreeRequirementActions
}

// MARK: - Row model

/// One row of a requirement in the catalog-like list. A requirement is a few consecutive rows:
/// its heading (for lists of options, hours, petitions and waivers), then its courses in
/// catalog order.
struct MacDegreeRuleRow: Identifiable {
    enum Connector: String {
        case and, or
        /// A course that counts for the requirement above it by substitution or petition.
        case substitution
    }

    enum Kind {
        /// The catalog's wording (`Complete one of the following`) with the status and progress.
        case header
        /// A course the catalog lists (or that counts here), annotated with where it stands.
        case course(CourseKey, connector: Connector?, counted: DegreeAudit.CourseUse?)
        /// A category subheader within a list of options (`Biology`).
        case category(String)
        /// A range of course numbers the requirement accepts.
        case range(String)
        /// "Show all 22 options" under a long list.
        case disclosure(total: Int, isExpanded: Bool)
        /// A course of the plan the requirement's number limits keep out.
        case nearMiss(DegreeAudit.NearMiss)
    }

    var id: String
    var result: DegreeAudit.RuleResult
    var kind: Kind
    /// The row that stands for the requirement: selecting it shows the requirement's details.
    var isHead: Bool

    /// The course of the plan this row counts toward the requirement, when it counts one (the
    /// course itself, or the one that counts as it).
    var countedCourse: CourseKey? {
        guard case .course(let key, _, let counted) = kind else { return nil }
        return (counted ?? result.use(for: key))?.key
    }

    /// A course that counts for the requirement by substitution or petition, listed after the
    /// requirement's own courses.
    var isSubstitute: Bool {
        if case .course(_, .substitution?, _) = kind { return true }
        return false
    }
}

enum MacDegreeRuleRows {
    /// The rows of one requirement, laid out like the academic catalog: the same choices as the
    /// iPhone's requirements page (which items a long list keeps, where its category subheaders
    /// go), made by the shared `DegreeRequirementsListing`.
    static func rows(for result: DegreeAudit.RuleResult, page: MacDegreeRequirementsPage) -> [MacDegreeRuleRow] {
        var rows: [MacDegreeRuleRow] = []

        func add(_ kind: MacDegreeRuleRow.Kind) {
            rows.append(MacDegreeRuleRow(id: "\(result.rule.id)#\(rows.count)", result: result, kind: kind, isHead: rows.isEmpty))
        }

        /// A course counted for the requirement that it doesn't list: a substitute sits under the
        /// requirement's own courses, joined to them.
        func addCounted(_ use: DegreeAudit.CourseUse) {
            add(.course(use.key, connector: use.bySubstitution ? .substitution : nil, counted: use))
        }

        /// The courses of a list: `and` joins courses taken together, `or` joins alternatives.
        func addList(_ entries: [DegreeListEntry], joinedByOr: Bool) {
            let isExpanded = page.expandedRules.contains(result.rule.id)
            let visible = DegreeRequirementsListing.visible(entries, result: result, isExpanded: isExpanded, lookup: page.lookup, prompts: page.prompts)
            for (position, entry) in visible.shown.enumerated() {
                if visible.showsCategories, let category = entry.category {
                    add(.category(category))
                }
                for (alternativeIndex, alternative) in entry.alternatives.enumerated() {
                    for (index, key) in alternative.enumerated() {
                        let isAlternative = alternativeIndex > 0 || (joinedByOr && position > 0)
                        add(.course(key, connector: index > 0 ? .and : (isAlternative ? .or : nil), counted: nil))
                    }
                }
            }
            if visible.isLong {
                add(.disclosure(total: entries.count, isExpanded: isExpanded))
            }
        }

        if DegreeRequirementsListing.hasHeaderRow(result) {
            add(.header)
            if DegreeRequirementsListing.isReplaced(result) {
                for use in result.used { addCounted(use) }
            } else {
                switch result.effectiveKind {
                case .choose(_, _, let options, let ranges)?:
                    addList(DegreeRequirementsListing.entries(options: options, of: result.rule, subjectName: page.subjectName), joinedByOr: false)
                    for range in ranges { add(.range(range.label)) }
                    let listed = Set(options.flatMap(\.allCourses))
                    for use in result.used where !DegreeRequirementsListing.isShown(use, listed: listed) {
                        addCounted(use)
                    }
                    for miss in page.audit.nearMisses(for: result.rule.id) { add(.nearMiss(miss)) }
                case .generalElectives?:
                    for use in result.used { add(.course(use.key, connector: nil, counted: use)) }
                default:
                    break
                }
            }
        } else if case .required(let option)? = result.effectiveKind {
            addList(DegreeRequirementsListing.entries(alternativesOf: option), joinedByOr: true)
            let listed = Set(option.allCourses)
            for use in result.used where !DegreeRequirementsListing.isShown(use, listed: listed) {
                addCounted(use)
            }
        }
        return rows
    }
}

// MARK: - Row view

/// A row of a requirement, in the page's list or in the details. In the list, the head row of a
/// requirement is the selectable one; clicking any other row of it selects the requirement.
struct MacDegreeRuleRowView: View {
    var row: MacDegreeRuleRow
    var page: MacDegreeRequirementsPage
    /// A narrower layout for the details, where a course row isn't a way to select the
    /// requirement (it already is the one shown).
    var isCompact = false
    /// The head row of a requirement offers to open its details (for the requirements beside the
    /// plan, whose details replace the list).
    var opensDetails = false

    var body: some View {
        let result = row.result
        switch row.kind {
        case .header:
            header(result)
        case .course(let key, let connector, let counted):
            courseRow(key, connector: connector, result: result, counted: counted)
        case .category(let title):
            MacDegreeCategoryRow(title: title)
        case .range(let label):
            MacDegreeRangeRow(label: label)
        case .disclosure(let total, let isExpanded):
            MacDegreeListDisclosureRow(total: total, isExpanded: isExpanded) {
                page.actions.toggleExpanded(result.rule.id)
            }
        case .nearMiss(let miss):
            MacDegreeNearMissRow(miss: miss, title: page.lookup.title(of: miss.course.key)) {
                page.actions.countSpecificCourse(result.rule.id, miss.course.key)
            }
        }
    }

    /// The catalog's wording (`Complete one of the following`) with the status and progress;
    /// the group's band above it carries the group's title.
    private func header(_ result: DegreeAudit.RuleResult) -> some View {
        let rule = result.rule
        let replacement = result.substitutions.first { if case .replace = $0.change { true } else { false } }
        // A counted course's note shows on its own row, under the requirement; the petition's
        // and waiver's note belong to the heading.
        let notes = result.substitutions.filter { !$0.isCountCourse }
        return MacDegreeRuleHeaderRow(
            title: rule.displayLabel,
            wording: replacement.flatMap(DegreeRequirementText.substitutionDetail),
            progress: DegreeRequirementText.progress(result),
            status: result.status,
            badge: replacement == nil ? nil : "Petition",
            details: notes.compactMap(DegreeRequirementText.substitutionCaption),
            onOpenDetails: opensDetails && row.isHead ? { page.actions.openDetails(rule.id) } : nil
        )
        .contextMenu {
            if opensDetails, row.isHead {
                Button("Show Requirement Details", systemImage: "checklist") { page.actions.openDetails(rule.id) }
            }
        }
        // Double-clicking a requirement's heading opens its details, like Return.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if opensDetails, row.isHead { page.actions.openDetails(rule.id) }
        })
    }

    @ViewBuilder
    private func courseRow(_ key: CourseKey, connector: MacDegreeRuleRow.Connector?, result: DegreeAudit.RuleResult,
                           counted: DegreeAudit.CourseUse?) -> some View {
        // Open requirements offer to add the course, to count another one instead, or to say the
        // plan has it under another number.
        let course = DegreeRequirementsListing.row(for: key, in: result, lookup: page.lookup, counted: counted)
        let info = course.info
        let canAct = course.canAct
        let targets = canAct && info.addKey != nil ? page.addTargets : []
        let use = counted ?? result.use(for: key)
        // The course of the plan this row stands for, to show it in the plan.
        let planKey = use?.key ?? (info.status.isInPlan ? key : nil)
        let tag: String? = (info.bySubstitution || use?.bySubstitution == true) ? Self.tag(for: result) : nil
        // The substitution a counted course stands for: edit it, say it is a renumbering, or delete it.
        let substitution = use.flatMap { use in
            use.bySubstitution ? result.substitutions.first { $0.change == .countCourse(use.key) } : nil
        }
        let drag = canAct ? info.addKey.map { addKey in
            MacDegreeCourseDrag(
                planID: page.plan.id,
                adding: MacDegreeCourseDrag.Addition(
                    key: addKey,
                    title: DegreePlanFormat.exportTitle(page.lookup.title(of: addKey) ?? addKey.description),
                    credits: page.lookup.credits(of: addKey) ?? 4
                ),
                summary: [addKey.description, page.lookup.title(of: addKey)].compactMap { $0 }.joined(separator: " ")
            )
        } : nil
        MacDegreeCatalogCourseRow(
            key: key,
            title: page.lookup.title(of: key),
            credits: page.lookup.credits(of: key),
            connector: connector,
            status: info.status,
            isCountedHere: info.isCountedHere,
            bySubstitution: info.bySubstitution,
            substitutionTag: tag,
            isWaived: course.isWaived,
            caption: course.caption,
            addKey: info.addKey,
            addTargets: targets,
            onAdd: canAct ? { term in if let addKey = info.addKey { page.actions.addCourse(addKey, term) } } : nil,
            onCountCourse: canAct ? { page.actions.startSubstitution(result.rule.id, .countCourse) } : nil,
            onViewCourse: { page.actions.viewCourse(key) },
            equivalence: course.isMissing ? ("Same Course, Different Number…", { page.actions.addEquivalence(key) }) : nil,
            requirementAction: isCompact ? nil : { page.actions.selectRule(result.rule.id) },
            showInPlan: planKey.flatMap { planKey in
                page.actions.showCourseInPlan.map { show in { show(planKey, use?.semester) } }
            },
            onOpenDetails: opensDetails && row.isHead ? { page.actions.openDetails(result.rule.id) } : nil,
            reservesDetailsSpace: opensDetails,
            drag: drag,
            substitutionActions: substitution.map { substitution in
                MacDegreeCatalogCourseRow.SubstitutionActions(
                    edit: { page.actions.editSubstitution(substitution) },
                    convert: DegreeSubstitutionEditing.renumbering(for: substitution, requirements: page.requirements) == nil
                        ? nil : { page.actions.convertToEquivalence(substitution) },
                    delete: { page.actions.deleteSubstitution(substitution) }
                )
            },
            isCompact: isCompact
        )
        if course.isMissing, let prompt = page.prompts.forListed(key) {
            MacDegreeEquivalencePromptRow(
                prompt: prompt,
                onConfirm: { page.actions.confirmEquivalence(prompt) },
                onDismiss: { page.actions.dismissEquivalence(prompt) }
            )
        }
    }

    /// What marks a course that counts here by substitution: the tag by its code.
    static func tag(for result: DegreeAudit.RuleResult) -> String {
        DegreeRequirementsListing.isReplaced(result) ? "Petition" : "Substitution"
    }
}

/// Clicking a course row that is in the plan selects the course in the plan too.
struct MacDegreeCourseClick: ViewModifier {
    var row: MacDegreeRuleRow
    var page: MacDegreeRequirementsPage

    func body(content: Content) -> some View {
        if case .course(let key, _, let counted) = row.kind, let show = page.actions.showCourseInPlan,
           let planKey = row.countedCourse ?? (page.lookup.status(of: key).isInPlan ? key : nil) {
            content.simultaneousGesture(TapGesture().onEnded { show(planKey, counted?.semester ?? row.result.use(for: key)?.semester) })
        } else {
            content
        }
    }
}

/// Double-clicking a course row opens the course in its own window.
struct MacDegreeCourseDoubleClick: ViewModifier {
    var row: MacDegreeRuleRow
    var page: MacDegreeRequirementsPage

    func body(content: Content) -> some View {
        if case .course(let key, _, _) = row.kind {
            content.simultaneousGesture(TapGesture(count: 2).onEnded { page.actions.viewCourse(key) })
        } else {
            content
        }
    }
}

private extension RequirementSubstitution {
    /// A "count a course" substitution (as opposed to a petition or a waiver).
    var isCountCourse: Bool {
        if case .countCourse = change { return true }
        return false
    }
}

// MARK: - Course row

/// One course the catalog lists, annotated with where it stands in the plan: code, title and
/// credits in columns, and a status chip. Courses that count toward the requirement are
/// emphasized. For a course that isn't in the plan, the chip opens a menu to add it to a
/// semester or to count another course instead; the course can also be dragged onto a semester
/// of the plan. A course that is in the plan can be shown there.
struct MacDegreeCatalogCourseRow: View {
    var key: CourseKey
    var title: String?
    var credits: Double?
    /// `and` for a course taken together with the one above, `or` for an alternative, an arrow
    /// for a substitute for the requirement above.
    var connector: MacDegreeRuleRow.Connector?
    var status: DegreeCourseStatus
    /// The audit counts this course toward the requirement shown.
    var isCountedHere: Bool
    var bySubstitution = false
    /// `Substitution` or `Petition`, by the course's code, for a course that counts here as one.
    var substitutionTag: String?
    var isWaived = false
    /// e.g. `Counts toward Khoury Elective Courses`, or a substitution's note.
    var caption: String?
    /// The course "Add to plan" adds, when it isn't this one (a current equivalent of a course
    /// that is no longer offered).
    var addKey: CourseKey?
    /// Semesters "Add to plan" offers.
    var addTargets: [DegreePlanTerm] = []
    var onAdd: ((DegreePlanTerm) -> Void)?
    var onCountCourse: (() -> Void)?
    /// Opens the course in its own window.
    var onViewCourse: (() -> Void)?
    /// "Same Course, Different Number…" for a listed course the plan may have under another
    /// number.
    var equivalence: (title: String, action: () -> Void)?
    /// Selects the requirement this course belongs to (nil in the requirement's own details).
    var requirementAction: (() -> Void)?
    /// Selects the course in the plan, when it is in it.
    var showInPlan: (() -> Void)?
    /// Opens the requirement's details, for the first row of a requirement beside the plan.
    var onOpenDetails: (() -> Void)?
    /// Leaves room for the details chevron on the rows without one, so the status chips of a
    /// list whose first rows have it line up.
    var reservesDetailsSpace = false
    /// What dragging the row onto a semester of the plan adds; nil when the course isn't needed.
    var drag: MacDegreeCourseDrag?
    /// What the row's menu does with the substitution a substitute course stands for.
    var substitutionActions: SubstitutionActions?
    /// A narrower layout for the details: the status chip shares the code's line, and the title
    /// and credits go below.
    var isCompact = false

    /// The menu items of a course that counts here by substitution.
    struct SubstitutionActions {
        var edit: () -> Void
        /// "Same Course, New Number", when the substituted course is the required course under a
        /// new number.
        var convert: (() -> Void)?
        var delete: () -> Void
    }

    @Environment(\.macDegreeRowLayout) private var layout

    private static let connectorWidth: CGFloat = 26
    private static let codeWidth: CGFloat = 92
    private static let creditsWidth: CGFloat = 72
    /// How far a substitute is indented under the requirement's own courses.
    private static let substituteIndent: CGFloat = 16

    private var usesTable: Bool { layout == .table && !isCompact }
    private var isSubstitute: Bool { connector == .substitution }

    var body: some View {
        Group {
            if usesTable {
                tableLayout
            } else {
                compactLayout
            }
        }
        // (In columns, the arrow in the connector column does the joining; the codes stay in line.)
        .padding(.leading, isSubstitute && !usesTable ? Self.substituteIndent : 0)
        .padding(.vertical, 1)
        .contentShape(.rect)
        .modifier(CourseDrag(payload: drag))
        .contextMenu {
            if let showInPlan {
                Button("Show in Degree Plan", systemImage: "list.bullet.rectangle", action: showInPlan)
            }
            if let onViewCourse {
                Button("Open Course in New Window", systemImage: "book", action: onViewCourse)
            }
            if let onOpenDetails {
                Button("Show Requirement Details", systemImage: "checklist", action: onOpenDetails)
            } else if let requirementAction {
                Button("Show Requirement Details", systemImage: "checklist", action: requirementAction)
            }
            if showsMenu {
                Divider()
                if let onAdd, !addTargets.isEmpty {
                    Menu(addKey.flatMap { $0 == key ? nil : "Add \($0.description) to Plan" } ?? "Add to Plan", systemImage: "calendar.badge.plus") {
                        ForEach(addTargets, id: \.name) { term in
                            Button(term.shortName) { onAdd(term) }
                        }
                    }
                }
                if let onCountCourse {
                    Button("Count Another Course Toward This…", systemImage: "arrow.left.arrow.right", action: onCountCourse)
                }
            }
            if let equivalence {
                Button(equivalence.title, systemImage: "equal.circle", action: equivalence.action)
            }
            if let substitutionActions {
                Divider()
                Button("Edit Substitution…", systemImage: "pencil", action: substitutionActions.edit)
                if let convert = substitutionActions.convert {
                    Button("Same Course, New Number", systemImage: "equal.circle", action: convert)
                }
                Button("Delete Substitution…", systemImage: "trash", role: .destructive, action: substitutionActions.delete)
            }
        }
        // One element for VoiceOver; adding or substituting are its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityActions {
            if let showInPlan {
                Button("Show in Degree Plan", action: showInPlan)
            }
            if let onViewCourse {
                Button("Open Course in New Window", action: onViewCourse)
            }
            if let onOpenDetails {
                Button("Show Requirement Details", action: onOpenDetails)
            }
            if showsMenu {
                if let onAdd {
                    ForEach(addTargets, id: \.name) { term in
                        Button("Add \((addKey ?? key).description) to \(term.shortName)") { onAdd(term) }
                    }
                }
                if let onCountCourse {
                    Button("Count Another Course Toward This", action: onCountCourse)
                }
            }
            if let equivalence {
                Button(equivalence.title, action: equivalence.action)
            }
            if let substitutionActions {
                Button("Edit Substitution", action: substitutionActions.edit)
                if let convert = substitutionActions.convert {
                    Button("Same Course, New Number", action: convert)
                }
            }
        }
    }

    /// Makes a needed course draggable onto the plan's semesters.
    private struct CourseDrag: ViewModifier {
        var payload: MacDegreeCourseDrag?

        func body(content: Content) -> some View {
            if let payload {
                content
                    .draggable(payload)
                    .help("Drag onto a semester to add \(payload.addition?.key.description ?? "it") to your plan")
            } else {
                content
            }
        }
    }

    /// The glyph or word that joins the row to the one above it.
    @ViewBuilder
    private var connectorMark: some View {
        switch connector {
        case .substitution?:
            Image(systemName: "arrow.turn.down.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
        case let connector?:
            Text(connector.rawValue)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    /// The column the connector words and arrows sit in, so codes line up whether a row has one or not.
    private var connectorColumn: some View {
        ZStack(alignment: .trailing) {
            Color.clear.frame(height: 1)
            connectorMark
        }
        .frame(width: Self.connectorWidth)
    }

    /// Code, title, credits and status in aligned columns, as wide as the page.
    private var tableLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                connectorColumn
                codeText
                    .frame(width: Self.codeWidth, alignment: .leading)
                // The tag follows the title, so titles line up from one row to the next.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let substitutionTag {
                        DegreeStatusChip(text: substitutionTag, color: .indigo, isProminent: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(credits.map(DegreePlanText.credits) ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: Self.creditsWidth, alignment: .trailing)
                statusControl
                    .frame(minWidth: 170, alignment: .trailing)
                detailsButton
            }
            if let caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.connectorWidth + 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                connectorMark
                codeText
                    .fixedSize()
                Spacer(minLength: 8)
                statusControl
                detailsButton
            }
            // The tag starts the second line, so the first keeps room for the code and the status.
            if substitutionTag != nil || detailLine != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let substitutionTag {
                        DegreeStatusChip(text: substitutionTag, color: .indigo, isProminent: true)
                    }
                    if let detailLine {
                        Text(detailLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The chevron of a requirement's first row that opens its details.
    @ViewBuilder
    private var detailsButton: some View {
        if let onOpenDetails {
            Button(action: onOpenDetails) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show this requirement’s details")
            .accessibilityHidden(true)
        } else if reservesDetailsSpace {
            Color.clear.frame(width: 14, height: 18)
        }
    }

    private var codeText: some View {
        Text(key.description)
            .font(.body.weight(isEmphasized ? .semibold : .regular))
            .foregroundStyle(status.isInPlan || bySubstitution ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .monospacedDigit()
    }

    /// `Algorithms and Data · 4 credits`.
    private var detailLine: String? {
        let parts = [title, credits.map(DegreePlanText.credits)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var isEmphasized: Bool { isCountedHere || bySubstitution }

    private var showsMenu: Bool {
        !isWaived && !bySubstitution && status == .notInPlan && (onAdd != nil || onCountCourse != nil || equivalence != nil)
    }

    @ViewBuilder
    private var statusControl: some View {
        if isWaived {
            DegreeStatusChip(text: "Waived", color: .gray, isProminent: false)
        } else if showsMenu {
            Menu {
                if let onAdd, !addTargets.isEmpty {
                    Section("Add \((addKey ?? key).description) to") {
                        ForEach(addTargets, id: \.name) { term in
                            Button(term.shortName) { onAdd(term) }
                        }
                    }
                }
                if let onCountCourse {
                    Button("Count Another Course Toward This…", systemImage: "arrow.left.arrow.right", action: onCountCourse)
                }
                if let equivalence {
                    Button(equivalence.title, systemImage: "equal.circle", action: equivalence.action)
                }
            } label: {
                DegreeStatusChip(text: status.label, color: status.color, isProminent: false, showsMenuIndicator: true)
            }
            // A plain button style keeps the chip's capsule (a borderless pull-down flattens its label).
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            DegreeStatusChip(text: status.label, color: status.color, isProminent: isCountedHere || bySubstitution)
        }
    }

    private var spokenLabel: String {
        var parts = [key.description]
        if let title { parts.append(title) }
        if isWaived {
            parts.append("waived")
        } else {
            parts.append(status.spoken)
            if let substitutionTag { parts.append("\(substitutionTag.lowercased()) for the requirement above") }
            else if isCountedHere { parts.append("counts toward this requirement") }
        }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Rule header

/// The heading of a list of options or an hours requirement: the catalog's wording
/// (`Complete one of the following`), progress (`1 of 1 done`, `Needs 4 more semester hours`)
/// and any petition or waiver.
struct MacDegreeRuleHeaderRow: View {
    var title: String
    /// A second line: what a petition replaced the requirement with.
    var wording: String?
    var progress: String
    var status: DegreeAudit.Status
    /// `Petition`, for a requirement replaced by petition.
    var badge: String?
    /// Substitution notes and the area's notes.
    var details: [String] = []
    /// Opens the requirement's details, with a chevron.
    var onOpenDetails: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DegreeStatusIcon(status: status)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)
                    if let badge {
                        DegreeStatusChip(text: badge, color: .indigo, isProminent: true)
                    }
                }
                if let wording {
                    Text(wording)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Text(progress)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.degreeColor)
                ForEach(details, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onOpenDetails {
                Button(action: onOpenDetails) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show this requirement’s details")
                .accessibilityLabel("Show details")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([title, badge.map { _ in "replaced by petition" }, status.degreeLabel, wording, progress].compactMap { $0 } + details).joined(separator: ", "))
    }
}

// MARK: - Other rows

/// An area header within a section, like the catalog's shaded rows (`Computer Science
/// Required Courses`).
struct MacDegreeAreaBand: View {
    var title: String

    var body: some View {
        Text(title)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A category subheader within a list of options (`Biology`), as the catalog shows them.
struct MacDegreeCategoryRow: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .italic()
            .foregroundStyle(.secondary)
            .padding(.leading, 36)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Show all 22 options" under a long list that shows only the options that matter.
struct MacDegreeListDisclosureRow: View {
    var total: Int
    var isExpanded: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(isExpanded ? "Show fewer options" : "Show all \(total) options")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.link)
        .padding(.leading, 36)
    }
}

/// A range of course numbers a requirement accepts (`CS 2500 or higher, except CS 5010`).
struct MacDegreeRangeRow: View {
    var label: String

    var body: some View {
        Label {
            Text(label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 36)
        .accessibilityLabel("Any course in \(label)")
    }
}

/// A substitution in the list: what it changes, its note and approval, and whether it still
/// applies to the plan's catalog year and concentration. When the substituted course is the
/// required course under a new number, it offers to say so.
struct MacDegreeSubstitutionRow: View {
    var substitution: RequirementSubstitution
    var ruleName: String
    /// The requirement's status in the audit; nil when it isn't part of these requirements.
    var status: DegreeAudit.Status?
    var doesNotApply: Bool
    /// The renumbering the substitution amounts to, when it does: shown as a link-button.
    var renumbering: CourseEquivalence?
    var onConvert: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if doesNotApply {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let status {
                    DegreeStatusIcon(status: status)
                } else {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(DegreeRequirementText.substitutionTitle(substitution, ruleName: ruleName))
                if let detail = DegreeRequirementText.substitutionDetail(substitution) {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                if let caption = DegreeRequirementText.substitutionCaption(substitution) {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if doesNotApply {
                    Text("Doesn’t apply to this catalog year or concentration")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if renumbering != nil, let onConvert {
                    Button("Same Course, New Number…", action: onConvert)
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Count \(renumbering?.course.description ?? "this course") as \(renumbering?.countsAs.description ?? "the required course") everywhere, like a renumbered course")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edits the substitution")
    }
}
