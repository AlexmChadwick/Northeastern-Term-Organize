//
//  MacDegreeRequirementsSetupSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Chooses the catalog year, program and concentration a plan is checked against. The years
/// and programs come from the academic catalog itself, so new catalog years show up on their
/// own.
struct MacDegreeRequirementsSetupSheet: View {
    var planID: UUID

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog

    var body: some View {
        if let plan = userData.degreePlan(id: planID) {
            MacDegreeRequirementsSetupForm(
                plan: plan,
                initialYear: plan.requirementsYear
                    ?? ProgramCatalogStore.suggestedYear(completedCredits: plan.completedCredits, editions: programCatalog.editions)
            )
        } else {
            ContentUnavailableView("Plan not found", systemImage: "list.bullet.clipboard")
                .frame(width: 520, height: 260)
        }
    }
}

private struct MacDegreeRequirementsSetupForm: View {
    var plan: DegreePlan

    @Environment(UserDataStore.self) private var userData
    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var year: CatalogYear
    /// The year was set by the user (or the plan), so a suggestion doesn't replace it.
    @State private var yearIsFixed: Bool
    @State private var program: CatalogProgram?
    @State private var programWasSuggested = false
    @State private var concentrationID: String?
    @State private var confirmsTurnOff = false
    @State private var isChoosingProgram = false

    init(plan: DegreePlan, initialYear: CatalogYear) {
        self.plan = plan
        _year = State(initialValue: initialYear)
        _yearIsFixed = State(initialValue: plan.catalogYear != nil)
        _program = State(initialValue: plan.catalogProgramPath.map { CatalogProgram(title: plan.catalogProgramTitle ?? $0, path: $0) })
        _concentrationID = State(initialValue: plan.concentrationID)
    }

    private var isSetUp: Bool { plan.catalogYear != nil && plan.catalogProgramPath != nil }

    private var programs: [CatalogProgram]? { programCatalog.programs(for: year) }

    private var requirements: ProgramRequirements? {
        program.flatMap { programCatalog.degreeRequirements(year: year, path: $0.path) }
    }

    private var requirementsState: ProgramCatalogStore.LoadState {
        program.map { programCatalog.degreeRequirementsState(year: year, path: $0.path) } ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                yearSection
                programSection
                if program != nil {
                    concentrationSection
                }
                if changesCatalog, !plan.substitutions.isEmpty {
                    Section {
                        Label("Substitutions from the old catalog stay listed but may no longer apply.", systemImage: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                    }
                }
                if isSetUp {
                    Section {
                        Button("Turn Off Requirement Checks…", role: .destructive) { confirmsTurnOff = true }
                    } footer: {
                        Text("Your substitutions and petitions are kept in case you set this up again.")
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Save", isConfirmDisabled: program == nil, onConfirm: save, onCancel: { dismiss() })
        }
        .frame(width: 520, height: 560)
        .confirmationDialog("Turn off requirement checks?", isPresented: $confirmsTurnOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) { turnOff() }
        } message: {
            Text("This plan won’t be checked against the catalog. Your substitutions are kept.")
        }
        .task { await programCatalog.loadEditions() }
        .task(id: year) { await programCatalog.loadPrograms(for: year) }
        .task(id: "\(year.slug)|\(program?.path ?? "")") {
            if let program { await programCatalog.loadRequirements(for: program, year: year) }
        }
        .onChange(of: programCatalog.editions) { _, editions in
            guard !yearIsFixed else { return }
            year = ProgramCatalogStore.suggestedYear(completedCredits: plan.completedCredits, editions: editions)
        }
        .onChange(of: programs, initial: true) { _, programs in
            reconcileProgram(with: programs)
        }
        .onChange(of: requirements, initial: true) { _, requirements in
            reconcileConcentration(with: requirements)
        }
    }

    // MARK: Year

    private var yearSection: some View {
        let editions = programCatalog.editions
        let years = Array(Set(editions.all + [year])).sorted(by: >)
        return Section {
            Picker("Catalog year", selection: Binding(get: { year }, set: { year = $0; yearIsFixed = true })) {
                ForEach(years) { option in
                    Text(option == editions.current ? "\(option.description) (current)" : option.description)
                        .tag(option)
                }
            }
        } header: {
            Text("Degree Requirements")
        } footer: {
            Text("Use the catalog for the year you started your program; your degree audit lists it.")
        }
    }

    // MARK: Program

    private var programSection: some View {
        Section {
            LabeledContent("Program") {
                Button(program?.titleWithoutCampus ?? "Choose…") {
                    isChoosingProgram = true
                }
                .popover(isPresented: $isChoosingProgram, arrowEdge: .bottom) {
                    MacDegreeProgramPicker(year: year, auditCode: plan.program, selection: Binding(
                        get: { program },
                        set: { program = $0; programWasSuggested = false }
                    ))
                }
            }
            if programs == nil, case .failed(let message) = programCatalog.programsState(for: year) {
                retryRow(message) { Task { await programCatalog.loadPrograms(for: year, forceRefresh: true) } }
            }
        } footer: {
            if programWasSuggested, let code = plan.program {
                Text("Suggested from your degree audit’s program, \(code).")
            }
        }
    }

    // MARK: Concentration

    @ViewBuilder
    private var concentrationSection: some View {
        if let requirements {
            if !requirements.concentrations.isEmpty {
                Section {
                    Picker("Concentration", selection: $concentrationID) {
                        Text("Decide later").tag(String?.none)
                        Divider()
                        ForEach(requirements.concentrations) { concentration in
                            Text(concentration.concentrationName).tag(Optional(concentration.id))
                        }
                    }
                } footer: {
                    Text("Requirements differ by concentration. You can choose later.")
                }
            }
        } else if case .failed(let message) = requirementsState {
            Section {
                retryRow(message) {
                    guard let program else { return }
                    Task { await programCatalog.loadRequirements(for: program, year: year, forceRefresh: true) }
                }
            }
        } else {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading requirements…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func retryRow(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Button("Try Again", action: retry)
                .controlSize(.small)
        }
    }

    // MARK: Keeping choices valid

    private var changesCatalog: Bool {
        guard isSetUp else { return false }
        return year.startYear != plan.catalogYear || program?.path != plan.catalogProgramPath
    }

    /// Keeps the program when the year changes (same page, or the same program under a new
    /// path), and suggests one from the audit's program code when none is chosen.
    private func reconcileProgram(with programs: [CatalogProgram]?) {
        guard let programs, !programs.isEmpty else { return }
        if let current = program {
            if let same = programs.first(where: { $0.path == current.path }) {
                program = same
            } else if let renamed = programs.first(where: { $0.titleWithoutCampus == current.titleWithoutCampus }) {
                program = renamed
            }
            return
        }
        let suggestions = ProgramCatalogStore.suggestedPrograms(forAuditCode: plan.program, in: programs)
        // Only when the suggestions are one program (possibly on several campuses).
        if let first = suggestions.first, Set(suggestions.map(\.name)).count == 1 {
            program = first
            programWasSuggested = true
        }
    }

    /// Keeps the concentration when it still exists (by id, else by name).
    private func reconcileConcentration(with requirements: ProgramRequirements?) {
        guard let requirements, let chosen = concentrationID else { return }
        if requirements.concentrations.contains(where: { $0.id == chosen }) { return }
        let previousName = programCatalog.requirements(for: plan)?.concentrations.first { $0.id == chosen }?.concentrationName
        concentrationID = requirements.concentrations.first { $0.concentrationName == previousName }?.id
    }

    // MARK: Saving

    private func save() {
        guard let program else { return }
        let concentration = requirements.map { requirements in
            concentrationID.flatMap { id in requirements.concentrations.contains { $0.id == id } ? id : nil }
        } ?? concentrationID
        userData.updateDegreePlan(id: plan.id) { plan in
            plan.catalogYear = year.startYear
            plan.catalogProgramPath = program.path
            plan.catalogProgramTitle = program.titleWithoutCampus
            plan.concentrationID = concentration
        }
        dismiss()
    }

    private func turnOff() {
        userData.updateDegreePlan(id: plan.id) { plan in
            plan.catalogYear = nil
            plan.catalogProgramPath = nil
            plan.catalogProgramTitle = nil
            plan.concentrationID = nil
        }
        dismiss()
    }
}

/// Every degree program in a catalog edition, searchable, with the ones matching the degree
/// audit's program code on top.
struct MacDegreeProgramPicker: View {
    var year: CatalogYear
    var auditCode: String?
    @Binding var selection: CatalogProgram?

    @Environment(ProgramCatalogStore.self) private var programCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search \(year.description) programs", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if let programs = programCatalog.programs(for: year) {
                list(programs)
            } else if case .failed(let message) = programCatalog.programsState(for: year) {
                ContentUnavailableView {
                    Label("Couldn’t load programs", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await programCatalog.loadPrograms(for: year, forceRefresh: true) }
                    }
                }
            } else {
                ProgressView("Loading programs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 420, height: 440)
        .task { await programCatalog.loadPrograms(for: year) }
    }

    private func list(_ programs: [CatalogProgram]) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? programs : programs.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let suggested = query.isEmpty ? ProgramCatalogStore.suggestedPrograms(forAuditCode: auditCode, in: programs) : []
        let undergraduate = matches.filter { $0.level == .undergraduate }
        let graduate = matches.filter { $0.level == .graduate }
        let other = matches.filter { $0.level == .other }
        return List {
            if !suggested.isEmpty {
                Section {
                    ForEach(suggested) { row($0) }
                } header: {
                    Text("Suggested")
                } footer: {
                    if let auditCode { Text("Matches \(auditCode) from your degree audit.") }
                }
            }
            if !undergraduate.isEmpty {
                Section("Undergraduate") { ForEach(undergraduate) { row($0) } }
            }
            if !graduate.isEmpty {
                Section("Graduate") { ForEach(graduate) { row($0) } }
            }
            if !other.isEmpty {
                Section("Other") { ForEach(other) { row($0) } }
            }
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .listStyle(.plain)
    }

    private func row(_ program: CatalogProgram) -> some View {
        let isSelected = selection?.path == program.path
        return Button {
            selection = program
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.titleWithoutCampus)
                    if let campus = program.campus {
                        Text(campus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
