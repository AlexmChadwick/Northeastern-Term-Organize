//
//  DegreePlanImportSheet.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Reviews a parsed degree audit plan before saving it: what was found, anything that
/// was skipped, whether it updates a plan you already have, and what to keep of the
/// student's info. When the file isn't a degree audit plan, explains and offers another try.
struct DegreePlanImportSheet: View {
    var request: DegreePlanImportRequest

    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var name: String
    @State private var keepsStudentInfo = true
    @State private var mode = SaveMode.update
    @State private var showsSkippedLines = false
    @State private var detent: PresentationDetent

    private enum SaveMode: Hashable {
        case update, new
    }

    init(request: DegreePlanImportRequest) {
        self.request = request
        switch request.result {
        case .success(let result):
            _name = State(initialValue: result.plan.name)
            _detent = State(initialValue: .large)
        case .failure:
            _name = State(initialValue: "")
            _detent = State(initialValue: .medium)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch request.result {
                case .success(let result):
                    review(result)
                case .failure(let error):
                    failure(error)
                }
            }
            .navigationTitle("Import degree plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    // MARK: Review

    private func review(_ result: DegreePlanFormat.ParseResult) -> some View {
        let imported = result.plan
        let match = DegreePlanEditing.existingMatch(for: imported, name: name, in: userData.degreePlans)
        return List {
            Section {
                LabeledContent("Name") {
                    TextField("Plan name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                if let program = imported.program {
                    LabeledContent("Program") {
                        Text(program)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Plan")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileLine(imported))
                    if let renamed = renamedNote(match: match) {
                        Text(renamed)
                    }
                }
            }

            if let match {
                Section {
                    savePicker
                } footer: {
                    Text(mode == .update
                         ? "Replaces the courses and semesters of “\(match.name)” with the ones in this file. Edits you made to them are lost\(keptNote(match))."
                         : "Keeps “\(match.name)” as it is and saves this file as another plan.")
                }
            }

            Section("What was found") {
                DegreePlanPreviewRows(plan: imported)
            }

            if !result.skippedLines.isEmpty {
                skippedSection(result.skippedLines)
            }

            if imported.degreePlanHasStudentInfo {
                Section {
                    Toggle("Keep student name and ID for exports", isOn: $keepsStudentInfo)
                } footer: {
                    Text("Only used to rebuild the header when you export a PDF. It stays on this device and is never uploaded.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) { saveBar(result, match: match) }
    }

    @ViewBuilder
    private var savePicker: some View {
        let picker = Picker("Save as", selection: $mode) {
            Text("Update existing plan").tag(SaveMode.update)
            Text("Save as new plan").tag(SaveMode.new)
        }
        .labelsHidden()
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.inline)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private func skippedSection(_ lines: [String]) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showsSkippedLines) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } label: {
                Label(
                    lines.count == 1 ? "1 line wasn’t understood" : "\(lines.count) lines weren’t understood",
                    systemImage: "exclamationmark.triangle"
                )
            }
        } footer: {
            Text("These lines are left out. If courses are missing, export the plan from the degree audit again and import the new PDF.")
        }
    }

    private func saveBar(_ result: DegreePlanFormat.ParseResult, match: DegreePlan?) -> some View {
        Button {
            save(result, match: match)
        } label: {
            Text("Save plan")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(name.nilIfBlank == nil)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    /// `From view-plan.pdf · printed Oct 3, 2026`.
    private func fileLine(_ plan: DegreePlan) -> String {
        var line = "From \(request.fileName)"
        // The audit prints its timestamp in Boston time, so show the date the PDF shows.
        if let printedAt = plan.printedAt {
            line += " · printed \(DegreePlanText.date(printedAt, in: TermCalendar.newYork))"
        }
        return line
    }

    /// Plans are saved under unique names; say so when the name had to change.
    private func renamedNote(match: DegreePlan?) -> String? {
        guard let wanted = name.nilIfBlank, match == nil || mode == .new else { return nil }
        let unique = DegreePlanEditing.uniqueName(wanted, existing: userData.degreePlans.map(\.name))
        guard unique != wanted else { return nil }
        return "You already have a plan called “\(wanted)”, so this one is saved as “\(unique)”."
    }

    // MARK: Failure

    private func failure(_ error: Error) -> some View {
        ContentUnavailableView {
            Label("Couldn’t import this file", systemImage: "doc.text.magnifyingglass")
        } description: {
            VStack(spacing: 6) {
                Text(error.localizedDescription)
                Text(request.fileName)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        } actions: {
            Button {
                chooseAnotherFile()
            } label: {
                Text("Choose another file")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }

    /// Closes the sheet, then reopens the file picker once the sheet is gone.
    private func chooseAnotherFile() {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            router.isDegreePlanImporterPresented = true
        }
    }

    /// `; its degree requirements, substitutions and course equivalences are kept`, for what an
    /// update keeps.
    private func keptNote(_ match: DegreePlan) -> String {
        var kept: [String] = []
        if match.catalogProgramPath != nil { kept.append("degree requirements") }
        if !match.substitutions.isEmpty { kept.append("substitutions") }
        if !match.courseEquivalences.isEmpty { kept.append("course equivalences") }
        guard let last = kept.last else { return "" }
        let list = kept.count == 1 ? last : kept.dropLast().joined(separator: ", ") + " and " + last
        return "; its \(list) are kept"
    }

    // MARK: Saving

    private func save(_ result: DegreePlanFormat.ParseResult, match: DegreePlan?) {
        var plan = result.plan
        plan.name = name.nilIfBlank ?? plan.name
        if !keepsStudentInfo {
            plan.studentName = nil
            plan.studentID = nil
        }

        let savedID: UUID
        if let match, mode == .update {
            // A re-import refreshes the courses; the degree requirement setup, substitutions
            // and the plan's star stay as they were.
            let existing = userData.degreePlan(id: match.id) ?? match
            DegreePlanEditing.carryOverRequirements(from: existing, to: &plan)
            // So do course equivalences: they describe the student's courses, which the audit's
            // PDF doesn't record.
            plan.courseEquivalences = existing.courseEquivalences
            userData.replaceDegreePlan(id: match.id, with: plan)
            savedID = match.id
        } else {
            plan.name = DegreePlanEditing.uniqueName(plan.name, existing: userData.degreePlans.map(\.name))
            savedID = userData.addDegreePlan(plan).id
        }

        DegreePlanFeedback.success()
        dismiss()
        router.show(.degreePlan(id: savedID), in: .schedule)
    }
}
