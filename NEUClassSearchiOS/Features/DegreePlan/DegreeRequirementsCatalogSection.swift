//
//  DegreeRequirementsCatalogSection.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What rows on the requirements page can ask the screen to do.
struct DegreeRequirementsActions {
    /// Opens a requirement's details.
    var openRule: (String) -> Void = { _ in }
    /// Adds a course to a semester of the plan (creating the semester when it's new).
    var addCourse: (CourseKey, DegreePlanTerm) -> Void = { _, _ in }
    /// Starts a substitution that counts a course toward a requirement.
    var countCourse: (String) -> Void = { _ in }
    /// Starts one that counts this course toward the requirement (a course that nearly fits).
    var countSpecificCourse: (String, CourseKey) -> Void = { _, _ in }
    /// Opens a course's page.
    var viewCourse: (CourseKey) -> Void = { _ in }
    /// Declares a suggested equivalence.
    var confirmEquivalence: (DegreeEquivalencePrompt) -> Void = { _ in }
    var dismissEquivalence: (DegreeEquivalencePrompt) -> Void = { _ in }
    /// Opens the equivalence sheet for a listed course ("Same course, different number…").
    var addEquivalence: (CourseKey) -> Void = { _ in }
    /// Shows all of a long list's options, or fewer again (by rule id).
    var toggleExpanded: (String) -> Void = { _ in }
    /// Opens a substitution to edit it, with the requirement it changes.
    var editSubstitution: (RequirementSubstitution, String) -> Void = { _, _ in }
    /// Makes a substitution the same course under a new number ("Same course, new number").
    var renumber: (RequirementSubstitution) -> Void = { _ in }
    /// Keeps a substitution that looked like a renumbering.
    var keepSubstitution: (DegreeSubstitutionEditing.LikelyRenumbering) -> Void = { _ in }
    /// Opens or closes the parts of a checked sentence (by note id).
    var toggleNote: (String) -> Void = { _ in }
    /// Opens the courses with a NUpath attribute.
    var findCourses: (NUPath) -> Void = { _ in }
}

/// How a requirement's counted courses that it doesn't list are laid out: the ones counted by
/// substitution sit directly under the requirement they replace, the others after its list.
enum DegreeSubstituteRows {
    /// - Parameter listed: the courses the requirement lists.
    static func split(_ result: DegreeAudit.RuleResult, listed: Set<CourseKey>)
        -> (substitutes: [DegreeAudit.CourseUse], others: [DegreeAudit.CourseUse]) {
        let unlisted = result.used.filter { !DegreeRequirementsListing.isShown($0, listed: listed) }
        return (unlisted.filter(\.bySubstitution), unlisted.filter { !$0.bySubstitution })
    }

    /// The substitution that counts a course toward the requirement.
    static func substitution(counting key: CourseKey, in result: DegreeAudit.RuleResult) -> RequirementSubstitution? {
        result.substitutions.first { $0.change == .countCourse(key) }
    }

    /// The requirement under the name that reads on its own (`CS 4500 or CS 4530`, `Science
    /// Requirement`, `Human-Centered Computing concentration`).
    static func requirementName(of result: DegreeAudit.RuleResult, requirements: ProgramRequirements) -> String {
        requirements.degreeShortName(ofRule: result.rule.id) ?? result.rule.displayLabel
    }

    /// `Petition approved by advising · Approved Sep 12, 2026`: the substitution's note and approval.
    static func note(counting key: CourseKey, in result: DegreeAudit.RuleResult) -> String? {
        substitution(counting: key, in: result).flatMap(DegreeRequirementText.substitutionCaption)
    }

    /// `Counts for CS 4500 or CS 4530 by substitution · Petition approved by advising`.
    static func caption(counting key: CourseKey, in result: DegreeAudit.RuleResult, requirements: ProgramRequirements) -> String {
        (["Counts for \(requirementName(of: result, requirements: requirements)) by substitution"]
            + [note(counting: key, in: result)].compactMap { $0 }).joined(separator: " · ")
    }

    /// The caption of a course row. A course counted by substitution says where it counts; one that
    /// sits under its requirement (`isChild`) says so in its heading, so only the note and approval
    /// remain. Any other row keeps the lookup's caption.
    static func caption(of info: DegreeCourseRowInfo, counting key: CourseKey, in result: DegreeAudit.RuleResult,
                        requirements: ProgramRequirements, isChild: Bool) -> String? {
        guard info.bySubstitution else { return info.caption }
        return isChild ? note(counting: key, in: result) : caption(counting: key, in: result, requirements: requirements)
    }
}

/// One section of the catalog's requirements (`Computer Science Requirements`), laid out like
/// the catalog page: area headers, then every course in catalog order, each annotated with its
/// status in the plan.
struct DegreeRequirementsCatalogSection: View {
    var section: DegreeAudit.SectionResult
    var filter: DegreeRequirementsFilter
    var lookup: DegreeCourseLookup
    /// Semesters "Add to plan" offers.
    var addTargets: [DegreePlanTerm]
    var actions: DegreeRequirementsActions
    /// Suggested equivalences for listed courses the plan doesn't have.
    var prompts = DegreeEquivalencePrompts()
    /// Substitutions that may be a renumbered course, by substitution id.
    var likelyRenumberings: [UUID: DegreeSubstitutionEditing.LikelyRenumbering] = [:]
    /// Substitutions that amount to a renumbered course (the requirement names one course).
    var renumberable: Set<UUID> = []
    /// Rules whose long lists show every option.
    var expandedRules: Set<String> = []
    /// A subject's name (`PHYS` → `Physics`), to place a list's category subheaders.
    var subjectName: (String) -> String? = { _ in nil }
    /// Plan courses a short requirement's number limits keep out (`DegreeAudit.nearMisses`).
    var nearMisses: (String) -> [DegreeAudit.NearMiss] = { _ in [] }
    /// The section's sentences the app checked against the plan.
    var checkedNotes: [DegreeNoteEntry] = []
    /// Checked sentences whose parts are open.
    var expandedNotes: Set<String> = []

    private struct VisibleGroup {
        var group: DegreeAudit.GroupResult
        var rules: [DegreeAudit.RuleResult]
    }

    var body: some View {
        let groups = section.groups.compactMap { group -> VisibleGroup? in
            let rules = group.rules.filter { filter.includes($0.status) }
            return rules.isEmpty ? nil : VisibleGroup(group: group, rules: rules)
        }
        if !groups.isEmpty || !checkedNotes.isEmpty {
            Section {
                ForEach(groups, id: \.group.id) { entry in
                    groupRows(entry.group, rules: entry.rules)
                }
                ForEach(checkedNotes) { entry in
                    DegreeNoteRow(entry: entry, isExpanded: expandedNotes.contains(entry.id), onToggle: {
                        actions.toggleNote(entry.id)
                    }, onFindCourses: actions.findCourses)
                }
            } header: {
                header
            } footer: {
                // The sentences the app checked are rows above; the others stay fine print.
                let checked = Set(checkedNotes.map(\.text))
                let rest = section.section.notes.filter { !checked.contains($0) }
                if !rest.isEmpty {
                    Text(rest.joined(separator: "\n"))
                }
            }
        }
    }

    private var header: some View {
        let rules = section.rules
        let covered = rules.filter(\.status.isSatisfied).count
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(section.section.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: Theme.Spacing.s)
            Text("\(covered) of \(rules.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.section.title), \(covered) of \(rules.count) requirements covered")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Groups

    @ViewBuilder
    private func groupRows(_ group: DegreeAudit.GroupResult, rules: [DegreeAudit.RuleResult]) -> some View {
        // Every titled group gets its band, as in the catalog, however many rules it has, so a
        // group never reads as nested in the one above it. (Groups the filter empties aren't
        // shown at all, so there are no empty bands.)
        if let title = group.group.title {
            DegreeAreaHeaderRow(title: title)
                .listRowBackground(Color.secondary.opacity(0.08))
        }
        ForEach(rules) { result in
            ruleRows(result)
        }
    }

    // MARK: Rules

    @ViewBuilder
    private func ruleRows(_ result: DegreeAudit.RuleResult) -> some View {
        if DegreeRequirementsListing.hasHeaderRow(result) {
            headerRow(result)
            if isReplaced(result) {
                let split = DegreeSubstituteRows.split(result, listed: [])
                countedRows(split.substitutes, result: result)
                countedRows(split.others, result: result)
            } else {
                switch result.effectiveKind {
                case .choose(_, _, let options, let ranges)?:
                    // What counts by substitution comes first, right under the requirement's
                    // heading, then the catalog's options.
                    let listed = Set(options.flatMap(\.allCourses))
                    let split = DegreeSubstituteRows.split(result, listed: listed)
                    countedRows(split.substitutes, result: result)
                    listRows(DegreeRequirementsListing.entries(options: options, of: result.rule, subjectName: subjectName),
                             joinedByOr: false, result: result)
                    ForEach(ranges, id: \.label) { range in
                        DegreeRangeRow(label: range.label)
                    }
                    countedRows(split.others, result: result)
                    ForEach(nearMisses(result.rule.id)) { miss in
                        DegreeNearMissRow(miss: miss, title: lookup.title(of: miss.course.key)) {
                            actions.countSpecificCourse(result.rule.id, miss.course.key)
                        }
                    }
                case .generalElectives?:
                    let split = DegreeSubstituteRows.split(result, listed: [])
                    countedRows(split.substitutes, result: result)
                    countedRows(split.others, result: result)
                default:
                    EmptyView()
                }
            }
        } else if case .required(let option)? = result.effectiveKind {
            // The required course or its alternatives, then the substitute that replaces them.
            listRows(DegreeRequirementsListing.entries(alternativesOf: option), joinedByOr: true, result: result)
            let split = DegreeSubstituteRows.split(result, listed: Set(option.allCourses))
            countedRows(split.substitutes, result: result)
            countedRows(split.others, result: result)
        }
    }

    private func isReplaced(_ result: DegreeAudit.RuleResult) -> Bool {
        DegreeRequirementsListing.isReplaced(result)
    }

    /// Courses a requirement counts that it doesn't list; one counted by substitution is a child
    /// of the requirement.
    @ViewBuilder
    private func countedRows(_ uses: [DegreeAudit.CourseUse], result: DegreeAudit.RuleResult) -> some View {
        ForEach(uses) { use in
            courseRow(use.key, connector: use.bySubstitution ? .substitution : nil, result: result, counted: use)
        }
    }

    /// The catalog's wording (`Complete one of the following`) with the status and progress;
    /// the group's band above it carries the group's title.
    private func headerRow(_ result: DegreeAudit.RuleResult) -> some View {
        let rule = result.rule
        let replacement = result.substitutions.first { if case .replace = $0.change { true } else { false } }
        let wording = replacement.flatMap(DegreeRequirementText.substitutionDetail)
        // A substituted course carries its own note and approval; the heading keeps the petition's.
        let details = result.substitutions
            .filter { if case .countCourse = $0.change { false } else { true } }
            .compactMap(DegreeRequirementText.substitutionCaption)
        return DegreeRuleHeaderRow(
            title: rule.displayLabel,
            wording: wording,
            progress: DegreeRequirementText.progress(result),
            status: result.status,
            badge: replacement == nil ? nil : "Petition",
            details: details
        ) {
            actions.openRule(rule.id)
        }
    }

    // MARK: Lists

    /// The courses of a list, in catalog order: `and` joins courses taken together, `or` joins
    /// alternatives. A long list shows the options in the plan (or counted, or with a suggested
    /// equivalence) and, while the requirement is open, a few more, then "Show all 22 options";
    /// the full list keeps the catalog's category subheaders.
    @ViewBuilder
    private func listRows(_ entries: [DegreeListEntry], joinedByOr: Bool, result: DegreeAudit.RuleResult) -> some View {
        let isExpanded = expandedRules.contains(result.rule.id)
        let visible = DegreeRequirementsListing.visible(entries, result: result, isExpanded: isExpanded, lookup: lookup, prompts: prompts)
        ForEach(Array(visible.shown.enumerated()), id: \.element.id) { position, entry in
            if visible.showsCategories, let category = entry.category {
                DegreeCategoryRow(title: category)
            }
            ForEach(Array(entry.alternatives.enumerated()), id: \.offset) { alternativeIndex, alternative in
                ForEach(Array(alternative.enumerated()), id: \.offset) { index, key in
                    let isAlternative = alternativeIndex > 0 || (joinedByOr && position > 0)
                    courseRow(key, connector: index > 0 ? .and : (isAlternative ? .or : nil), result: result)
                }
            }
        }
        if visible.isLong {
            DegreeListDisclosureRow(total: entries.count, isExpanded: isExpanded) {
                actions.toggleExpanded(result.rule.id)
            }
        }
    }

    @ViewBuilder
    private func courseRow(_ key: CourseKey, connector: DegreeCatalogCourseRow.Connector?, result: DegreeAudit.RuleResult,
                           counted: DegreeAudit.CourseUse? = nil) -> some View {
        // Open requirements offer to add the course, to count another one instead, or to say the
        // plan has it under another number.
        let row = DegreeRequirementsListing.row(for: key, in: result, lookup: lookup, counted: counted)
        let info = row.info
        let canAct = row.canAct
        // A course counted by substitution: where it's counted, and what can be done with it.
        let countedKey = (counted ?? result.use(for: key))?.key ?? key
        let substitution = info.bySubstitution ? DegreeSubstituteRows.substitution(counting: countedKey, in: result) : nil
        let isChild = connector == .substitution
        DegreeCatalogCourseRow(
            key: key,
            title: lookup.title(of: key),
            credits: counted?.credits ?? lookup.credits(of: key),
            connector: connector,
            status: info.status,
            isCountedHere: info.isCountedHere,
            bySubstitution: info.bySubstitution,
            isWaived: row.isWaived,
            caption: DegreeSubstituteRows.caption(of: info, counting: countedKey, in: result, requirements: lookup.requirements, isChild: isChild),
            addKey: info.addKey,
            addTargets: canAct && info.addKey != nil ? addTargets : [],
            onOpen: { actions.openRule(result.rule.id) },
            onAdd: canAct ? { term in if let addKey = info.addKey { actions.addCourse(addKey, term) } } : nil,
            onCountCourse: canAct ? { actions.countCourse(result.rule.id) } : nil,
            onViewCourse: { actions.viewCourse(key) },
            equivalenceAction: row.isMissing ? DegreeRowAction(title: "Same course, different number…") { actions.addEquivalence(key) } : nil,
            substitutionActions: substitutionActions(for: substitution, ruleID: result.rule.id),
            substitutionFor: isChild ? DegreeSubstituteRows.requirementName(of: result, requirements: lookup.requirements) : nil
        )
        .listRowSeparator(isChild ? .hidden : .automatic, edges: .top)
        .listRowInsets(.top, isChild ? 0 : nil)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let substitution, renumberable.contains(substitution.id) {
                Button {
                    actions.renumber(substitution)
                } label: {
                    Label("Same course, new number", systemImage: "equal.circle")
                }
                .tint(.indigo)
            }
        }
        if let substitution, let prompt = likelyRenumberings[substitution.id] {
            // The substitute may be the required course under a new number: asked right under it.
            DegreeRenumberingPromptRow(
                prompt: prompt,
                isIndented: isChild,
                onConfirm: { actions.renumber(substitution) },
                onDismiss: { actions.keepSubstitution(prompt) }
            )
            .listRowSeparator(.hidden, edges: .top)
        }
        if row.isMissing, let prompt = prompts.forListed(key) {
            DegreeEquivalencePromptRow(
                prompt: prompt,
                onConfirm: { actions.confirmEquivalence(prompt) },
                onDismiss: { actions.dismissEquivalence(prompt) }
            )
        }
    }

    private func substitutionActions(for substitution: RequirementSubstitution?, ruleID: String) -> [DegreeRowAction] {
        guard let substitution else { return [] }
        var items = [DegreeRowAction(title: "Edit substitution…", systemImage: "pencil") {
            actions.editSubstitution(substitution, ruleID)
        }]
        if renumberable.contains(substitution.id) {
            items.append(DegreeRowAction(title: "Same course, new number", systemImage: "equal.circle") {
                actions.renumber(substitution)
            })
        }
        return items
    }
}

/// A section of the catalog that states its requirements in words (a credit minimum, NUpath, a
/// GPA): the sentences the app checked against the plan with their status, the others as notes.
struct DegreeRequirementsNotesSection: View {
    var section: RequirementSection
    var entries: [DegreeNoteEntry]
    var expandedNotes: Set<String>
    var actions: DegreeRequirementsActions

    var body: some View {
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    DegreeNoteRow(entry: entry, isExpanded: expandedNotes.contains(entry.id), onToggle: {
                        actions.toggleNote(entry.id)
                    }, onFindCourses: actions.findCourses)
                }
            } header: {
                Text(section.title)
                    .textCase(nil)
            }
        }
    }
}
