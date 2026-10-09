//
//  MacScheduleSupport.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Small pieces the schedule screens share: notices, tags, the dialogs that rename and delete a
//  schedule, copying to the pasteboard.
//

import AppKit
import SwiftUI

// MARK: - Pasteboard

enum MacPasteboard {
    /// Puts plain text on the general pasteboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The plain text of pasted or dropped items, once they have all been read.
    static func strings(from providers: [NSItemProvider]) async -> [String] {
        var texts: [String] = []
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    continuation.resume(returning: object as? String)
                }
            }
            if let text { texts.append(text) }
        }
        return texts
    }
}

// MARK: - Inline buttons

/// A text-only button in the app's accent color, for inline actions such as "Change…" or "Undo".
struct MacInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == MacInlineButtonStyle {
    static var macInline: MacInlineButtonStyle { MacInlineButtonStyle() }
}

// MARK: - Survey rows

extension View {
    /// Tints a survey row that Apple Intelligence filled in, so the student reviews it. (Grouped forms
    /// on the Mac don't honor `listRowBackground`, so the tint is drawn behind the row's content.)
    func macFilledInHighlight(_ isFilledIn: Bool) -> some View {
        self
            .background {
                if isFilledIn {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                }
            }
            .accessibilityHint(isFilledIn ? "Filled in by Apple Intelligence. Review it." : "")
    }
}

// MARK: - Severity colors

extension ScheduleNotice.Severity {
    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }
}

extension ScheduleWarning.Severity {
    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

// MARK: - Notices

/// A tinted notice at the top of a schedule: a conflict, a full section, a heavy credit load…
struct MacNoticeRow: View {
    var notice: ScheduleNotice
    var onFix: (ScheduleNotice.Fix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.severity.symbol)
                .foregroundStyle(notice.severity.color)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(notice.lines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fix = notice.fix, let title = notice.fixTitle {
                    Button(title) { onFix(fix) }
                        .buttonStyle(.macInline)
                        .font(.caption.weight(.semibold))
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(notice.severity.color.opacity(0.10), in: .rect(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: notice.fix == nil ? .combine : .contain)
    }
}

// MARK: - Warnings

/// The short warnings of a schedule (`2 conflicts`, `1 full section`) as a wrapping row of labels.
struct MacWarningLabels: View {
    var warnings: [ScheduleWarning]

    var body: some View {
        if !warnings.isEmpty {
            CourseFlowLayout(spacing: 10, lineSpacing: 2) {
                ForEach(warnings) { warning in
                    Label(warning.text, systemImage: warning.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(warning.severity.color)
                }
            }
        }
    }
}

// MARK: - Required / optional

/// The capsule that shows whether a course is required or optional and switches it when clicked.
struct MacRequiredToggle: View {
    var key: CourseKey
    var isRequired: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isRequired ? "Required" : "Optional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isRequired ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(isRequired ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color.secondary.opacity(0.1)), in: .capsule)
                .overlay {
                    if !isRequired {
                        Capsule().strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(isRequired
              ? "Required courses appear in every generated schedule. Click to make \(key.description) optional."
              : "Optional courses are only added when they fit. Click to make \(key.description) required.")
        .accessibilityLabel("\(key.description) is \(isRequired ? "required" : "optional")")
        .accessibilityHint("Switches between required and optional")
    }
}

// MARK: - Managing a schedule

/// Renames, duplicates, sets as primary and deletes schedules, with the dialogs those need. The
/// overview and the schedule itself both use it, so a schedule behaves the same in either.
@MainActor
@Observable
final class MacPlanManager {
    /// The schedule being renamed (a sheet with a name field is showing).
    var planToRename: SchedulePlan?
    /// The schedule waiting for the student to confirm its deletion.
    var planToDelete: SchedulePlan?
    var toast: PlanToast?

    func startRenaming(_ plan: SchedulePlan) {
        planToRename = plan
    }

    func rename(_ id: UUID, to name: String, userData: UserDataStore) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userData.updatePlan(id: id) { $0.name = trimmed }
    }

    /// Duplicates the schedule and returns the copy.
    @discardableResult
    func duplicate(_ plan: SchedulePlan, userData: UserDataStore) -> SchedulePlan? {
        guard let copy = userData.duplicatePlan(id: plan.id) else { return nil }
        toast = PlanToast(text: "Created “\(copy.name)”", systemImage: "plus.square.on.square")
        return copy
    }

    func setPrimary(_ plan: SchedulePlan, userData: UserDataStore) {
        guard !plan.isPrimary else { return }
        userData.setPrimary(id: plan.id)
        toast = PlanToast(text: "\(plan.name) is now My Schedule", systemImage: "star.fill")
    }
}

/// The context menu of a schedule: rename, duplicate, set "My Schedule", delete. The sidebar, the
/// overview and the schedule's own title menu all offer the same actions; attach
/// `macPlanDialogs(_:userData:onDelete:)` with the same manager to the screen so the rename alert and
/// the delete confirmation can appear.
struct MacSchedulePlanMenu: View {
    var plan: SchedulePlan
    var manager: MacPlanManager
    /// What to do with the copy "Duplicate" made; by default it opens in the sidebar.
    var onDuplicate: ((SchedulePlan) -> Void)?

    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator

    var body: some View {
        Button("Rename…", systemImage: "pencil") { manager.startRenaming(plan) }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            guard let copy = manager.duplicate(plan, userData: userData) else { return }
            if let onDuplicate { onDuplicate(copy) } else { navigator.selection = .schedule(copy.id) }
        }
        if !plan.isPrimary {
            Button("Set as My Schedule", systemImage: "star") { manager.setPrimary(plan, userData: userData) }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { manager.planToDelete = plan }
    }
}

extension View {
    /// The rename alert and the delete confirmation of a `MacPlanManager`. `onDelete` runs when the
    /// student confirms, so the screen can move away from the schedule first.
    func macPlanDialogs(_ manager: MacPlanManager, userData: UserDataStore, onDelete: @escaping (SchedulePlan) -> Void) -> some View {
        modifier(MacPlanDialogs(manager: manager, userData: userData, onDelete: onDelete))
    }
}

private struct MacPlanDialogs: ViewModifier {
    @Bindable var manager: MacPlanManager
    var userData: UserDataStore
    var onDelete: (SchedulePlan) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $manager.planToRename) { plan in
                MacRenameScheduleSheet(plan: plan) { name in
                    manager.rename(plan.id, to: name, userData: userData)
                }
            }
            .confirmationDialog(
                manager.planToDelete.map { "Delete “\($0.name)”?" } ?? "Delete schedule?",
                isPresented: Binding(get: { manager.planToDelete != nil }, set: { if !$0 { manager.planToDelete = nil } }),
                titleVisibility: .visible,
                presenting: manager.planToDelete
            ) { plan in
                Button("Delete Schedule", role: .destructive) { onDelete(plan) }
            } message: { _ in
                Text("The schedule and its saved combinations will be removed. This can’t be undone.")
            }
            .planToast($manager.toast)
    }
}

/// A small sheet that asks for a schedule's new name.
struct MacRenameScheduleSheet: View {
    var plan: SchedulePlan
    var onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var isFocused: Bool

    init(plan: SchedulePlan, onRename: @escaping (String) -> Void) {
        self.plan = plan
        self.onRename = onRename
        _name = State(initialValue: plan.name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Schedule")
                .font(.headline)
            Text("Choose a name for this schedule.")
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .focused($isFocused)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}

// MARK: - Dates

extension Date {
    /// `5 min. ago`, `yesterday`.
    var macRelativeLabel: String {
        formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
