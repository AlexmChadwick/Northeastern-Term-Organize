//
//  MacDegreePlanDetailsSheet.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Renames a degree plan and edits its program, the code from the degree audit.
struct MacDegreePlanDetailsSheet: View {
    var planID: UUID

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let plan = userData.degreePlan(id: planID) {
            MacDegreePlanDetailsForm(plan: plan)
        } else {
            ContentUnavailableView("Plan not found", systemImage: "list.bullet.clipboard")
                .frame(width: 440, height: 220)
        }
    }
}

private struct MacDegreePlanDetailsForm: View {
    var plan: DegreePlan

    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var program: String

    init(plan: DegreePlan) {
        self.plan = plan
        _name = State(initialValue: plan.name)
        _program = State(initialValue: plan.program ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Program", text: $program, prompt: Text("CS-B-CSCI-BSCS"))
                        .autocorrectionDisabled()
                } header: {
                    Text("Edit Plan")
                } footer: {
                    Text("The program is the code from your degree audit, like CS-B-CSCI-BSCS.")
                }
            }
            .formStyle(.grouped)
            Divider()
            MacDegreeSheetButtons(confirmTitle: "Save", isConfirmDisabled: false, onConfirm: save, onCancel: { dismiss() })
        }
        .frame(width: 440)
    }

    private func save() {
        let newName = name.nilIfBlank ?? plan.name
        let newProgram = program.nilIfBlank?.uppercased()
        userData.updateDegreePlan(id: plan.id) {
            $0.name = newName
            $0.program = newProgram
        }
        dismiss()
    }
}
