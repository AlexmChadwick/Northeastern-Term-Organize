//
//  MacDegreePlanImportSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Reviews a degree audit "View Plan" PDF (opened with ⌘O, dropped on the window or opened from
/// the Finder) before it's saved as a degree plan: what was found, anything that was skipped,
/// whether it updates a plan you already have, and what to keep of the student's info. When the
/// file isn't a degree audit plan, explains and offers another try.
struct MacDegreePlanImportSheet: View {
    var url: URL

    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    /// The file once it has been read.
    @State private var loaded: Loaded?
    @State private var name = ""
    @State private var keepsStudentInfo = true
    @State private var mode = SaveMode.update
    @State private var showsSkippedLines = false

    private struct Loaded {
        var fileName: String
        var result: Result<DegreePlanFormat.ParseResult, Error>
    }

    private enum SaveMode: Hashable {
        case update, new
    }

    var body: some View {
        Group {
            switch loaded?.result {
            case .success(let result)?:
                review(result, fileName: loaded?.fileName ?? url.lastPathComponent)
                    .frame(width: 560, height: 680)
            case .failure(let error)?:
                failure(error)
                    .frame(width: 520, height: 340)
            case nil:
                ProgressView("Reading \(url.lastPathComponent)…")
                    .frame(width: 520, height: 340)
            }
        }
        // The file is read as soon as the sheet appears, off the main actor.
        .task(id: url) { await read() }
    }

    private func read() async {
        loaded = nil
        let url = url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<DegreePlanFormat.ParseResult, Error> in
            Result { try DegreePlanImporter.importPlan(from: url) }
        }.value
        loaded = Loaded(fileName: url.lastPathComponent, result: result)
        if case .success(let parsed) = result {
            name = parsed.plan.name
            keepsStudentInfo = true
            mode = .update
        }
    }

    // MARK: Review

    private func review(_ result: DegreePlanFormat.ParseResult, fileName: String) -> some View {
        let imported = result.plan
        let match = DegreePlanEditing.existingMatch(for: imported, name: name, in: userData.degreePlans)
        return VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Plan name"))
                    if let program = imported.program {
                        LabeledContent("Program", value: program)
                    }
                } header: {
                    Text("Import Degree Plan")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileLine(imported, fileName: fileName))
                        if let renamed = renamedNote(match: match) {
                            Text(renamed)
                        }
                    }
                }

                if let match {
                    Section {
                        Picker("Save as", selection: $mode) {
                            Text("Update existing plan").tag(SaveMode.update)
                            Text("Save as new plan").tag(SaveMode.new)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    } footer: {
                        Text(mode == .update
                             ? "Replaces the courses and semesters of “\(match.name)” with the ones in this file. Edits you made to them are lost\(keptNote(match))."
                             : "Keeps “\(match.name)” as it is and saves this file as another plan.")
                    }
                }

                Section("What was found") {
                    MacDegreePlanPreviewRows(plan: imported)
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
            .formStyle(.grouped)
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Save Plan", isConfirmDisabled: name.nilIfBlank == nil) {
                save(result, match: match)
            } onCancel: {
                dismiss()
            }
        }
    }

    private func skippedSection(_ lines: [String]) -> some View {
        Section {
            DisclosureGroup(isExpanded: $showsSkippedLines) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout.monospaced())
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

    /// `From view-plan.pdf · printed Oct 3, 2026`.
    private func fileLine(_ plan: DegreePlan, fileName: String) -> String {
        var line = "From \(fileName)"
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

    // MARK: Failure

    private func failure(_ error: Error) -> some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label("Couldn’t import this file", systemImage: "doc.text.magnifyingglass")
            } description: {
                VStack(spacing: 6) {
                    Text(error.localizedDescription)
                    Text(url.lastPathComponent)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Choose Another File…", cancelTitle: "Cancel") {
                chooseAnotherFile()
            } onCancel: {
                dismiss()
            }
        }
    }

    /// Closes the sheet, then reopens the file picker once the sheet is gone.
    private func chooseAnotherFile() {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            navigator.isDegreePlanImporterPresented = true
        }
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

        dismiss()
        navigator.selection = .degreePlan(savedID)
    }
}
