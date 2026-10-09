//
//  MacDegreeRequirementInspector.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One requirement in detail, in the requirements page's inspector: the catalog's wording and
/// notes, every option with where it stands in the plan, the courses counted, and the
/// substitutions or petitions that change it.
struct MacDegreeRequirementInspector: View {
    var page: MacDegreeRequirementsPage
    var ruleID: String?

    var body: some View {
        if let ruleID {
            if let location = page.requirements.degreeLocation(ofRule: ruleID) {
                if let result = page.audit.result(for: ruleID) {
                    details(location: location, result: result)
                } else {
                    ContentUnavailableView {
                        Label("Not part of your requirements", systemImage: "checklist")
                    } description: {
                        Text("This requirement belongs to another concentration.")
                    }
                }
            } else {
                ContentUnavailableView("Requirement not found", systemImage: "checklist")
            }
        } else {
            ContentUnavailableView {
                Label("No Requirement Selected", systemImage: "checklist")
            } description: {
                Text("Select a requirement to see its courses, the catalog’s notes and any substitutions.")
            }
        }
    }

    // MARK: Details

    private func details(location: (section: RequirementSection, group: RequirementGroup, rule: RequirementRule),
                         result: DegreeAudit.RuleResult) -> some View {
        let rule = location.rule
        let requirements = page.requirements
        let name = requirements.degreeShortName(ofRule: rule.id) ?? rule.displayLabel
        let notes = location.group.notes + rule.degreeParagraphs
        let categories = rule.degreeCategories
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(result.status.degreeLabel.capitalizedFirst)
                    } icon: {
                        DegreeStatusIcon(status: result.status)
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(result.status.degreeColor)
                    Text(requirements.degreeRowTitle(ofRule: rule))
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if requirements.degreeRowTitle(ofRule: rule) != rule.displayLabel {
                        Text(rule.displayLabel)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(([DegreeRequirementText.progress(result)] + [rule.hours.map(DegreeRequirementText.hours)].compactMap { $0 }).joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Text(location.section.title)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if !notes.isEmpty || !categories.isEmpty {
                Section("From the Catalog") {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !categories.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Categories")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(categories.joined(separator: ", "))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            petitionQuestionsSection(result: result)

            coursesSection(rule: rule, result: result)

            nearMissSection(result: result)

            substitutionsSection(name: name, result: result)
        }
        .formStyle(.grouped)
    }

    // MARK: Petition questions and near misses

    /// This requirement's petitions that haven't said whether the minimum course number of the
    /// requirement they take courses like applies; asked here even when it changes nothing.
    @ViewBuilder
    private func petitionQuestionsSection(result: DegreeAudit.RuleResult) -> some View {
        let questions = result.substitutions.compactMap {
            DegreePetitionQuestions.question(
                about: $0, plan: page.plan, requirements: page.requirements, equivalences: page.equivalences, audit: page.audit
            )
        }
        if !questions.isEmpty {
            Section {
                ForEach(questions, id: \.substitution.id.uuidString) { question in
                    MacDegreePetitionQuestionRow(question: question) { limit in
                        page.actions.answerPetition(question, limit)
                    } onOther: {
                        page.actions.editSubstitution(question.substitution)
                    }
                }
            } header: {
                Text("Course Numbers")
            }
        }
    }

    /// Plan courses this requirement's number limits keep out, while it's short.
    @ViewBuilder
    private func nearMissSection(result: DegreeAudit.RuleResult) -> some View {
        let misses = page.audit.nearMisses(for: result.rule.id)
        if !misses.isEmpty {
            Section {
                ForEach(misses) { miss in
                    MacDegreeNearMissRow(miss: miss, title: page.lookup.title(of: miss.course.key)) {
                        page.actions.countSpecificCourse(result.rule.id, miss.course.key)
                    }
                }
            } header: {
                Text("In Your Plan, Not Counted")
            } footer: {
                Text("Their course numbers fall outside this requirement’s ranges. If an adviser approved one for it, count it here.")
            }
        }
    }

    // MARK: Courses

    @ViewBuilder
    private func coursesSection(rule: RequirementRule, result: DegreeAudit.RuleResult) -> some View {
        let (options, ranges) = DegreeRequirementsListing.listing(of: rule)
        let listed = Set(options.flatMap(\.allCourses))
        let others = result.used.filter { !DegreeRequirementsListing.isShown($0, listed: listed) }
        if !options.isEmpty || !ranges.isEmpty || !others.isEmpty {
            Section {
                ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                    ForEach(Array(option.alternatives.enumerated()), id: \.offset) { alternativeIndex, alternative in
                        ForEach(Array(alternative.enumerated()), id: \.offset) { index, key in
                            let connector: MacDegreeRuleRow.Connector? = index > 0 ? .and : (alternativeIndex > 0 ? .or : nil)
                            courseRow(key, connector: connector, result: result, counted: nil, id: "\(optionIndex)-\(alternativeIndex)-\(index)")
                        }
                    }
                }
                ForEach(ranges, id: \.label) { range in
                    MacDegreeRangeRow(label: range.label)
                        .padding(.leading, 0)
                }
                ForEach(others) { use in
                    courseRow(use.key, connector: use.bySubstitution ? .substitution : nil, result: result, counted: use, id: "used-\(use.id)")
                }
            } header: {
                Text(rule.degreeIsGeneralElectives ? "Counted Courses" : "Courses")
            } footer: {
                if result.effectiveKind == nil {
                    Text("Waived: these courses aren’t needed.")
                } else if DegreeRequirementsListing.isReplaced(result) {
                    Text("Replaced by petition: courses that count toward the replacement are listed last.")
                }
            }
        }
    }

    private func courseRow(_ key: CourseKey, connector: MacDegreeRuleRow.Connector?, result: DegreeAudit.RuleResult,
                           counted: DegreeAudit.CourseUse?, id: String) -> some View {
        let row = MacDegreeRuleRow(id: "\(result.rule.id)#\(id)", result: result,
                                   kind: .course(key, connector: connector, counted: counted), isHead: false)
        return MacDegreeRuleRowView(row: row, page: page, isCompact: true)
            .modifier(MacDegreeCourseDoubleClick(row: row, page: page))
            .modifier(MacDegreeCourseClick(row: row, page: page))
    }

    // MARK: Substitutions

    private func substitutionsSection(name: String, result: DegreeAudit.RuleResult) -> some View {
        Section {
            ForEach(result.substitutions) { substitution in
                let renumbering = DegreeSubstitutionEditing.renumbering(for: substitution, requirements: page.requirements)
                MacDegreeSubstitutionRow(
                    substitution: substitution, ruleName: name, status: nil, doesNotApply: false,
                    renumbering: renumbering, onConvert: { page.actions.convertToEquivalence(substitution) }
                )
                .onTapGesture { page.actions.editSubstitution(substitution) }
                .accessibilityAddTraits(.isButton)
                .contextMenu {
                    Button("Edit…") { page.actions.editSubstitution(substitution) }
                    if let renumbering {
                        Button("Same Course, New Number (\(renumbering.course.description) = \(renumbering.countsAs.description))") {
                            page.actions.convertToEquivalence(substitution)
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { page.actions.deleteSubstitution(substitution) }
                }
            }
            Button {
                page.actions.startSubstitution(result.rule.id, .countCourse)
            } label: {
                Label("Count a Course Toward This…", systemImage: "arrow.left.arrow.right")
            }
            Button {
                page.actions.startSubstitution(result.rule.id, .replace)
            } label: {
                Label("Replace This Requirement (Petition)…", systemImage: "signature")
            }
            Button {
                page.actions.startSubstitution(result.rule.id, .waive)
            } label: {
                Label("Waive This Requirement…", systemImage: "minus.circle")
            }
        } header: {
            Text("Substitutions & Petitions")
        } footer: {
            Text("Record exceptions your advisor or college approved. They’re saved with this plan.")
        }
    }
}

private extension String {
    /// `Not in your plan` from `not in your plan`.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
