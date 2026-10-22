//
//  MacDegreePlanSupport.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag and drop

/// A course being dragged within a degree plan: a planned course moving from one semester to
/// another (or onto the completed courses), or a course the requirements still need, dragged
/// from the requirements onto a semester to plan it. Other apps receive its text, e.g.
/// `CS 3500 Object-Oriented Design`.
struct MacDegreeCourseDrag: Codable, Transferable {
    /// A course the requirements list that the plan doesn't have yet.
    struct Addition: Codable, Hashable {
        var key: CourseKey
        var title: String
        var credits: Double
    }

    var planID: UUID
    /// The planned course being moved; nil for an addition.
    var courseID: UUID?
    /// The course being added to the plan; nil for a move.
    var addition: Addition?
    var summary: String

    /// A course of the plan, being moved.
    init(planID: UUID, courseID: UUID, summary: String) {
        self.planID = planID
        self.courseID = courseID
        addition = nil
        self.summary = summary
    }

    /// A course the requirements need, being added to a semester.
    init(planID: UUID, adding addition: Addition, summary: String) {
        self.planID = planID
        courseID = nil
        self.addition = addition
        self.summary = summary
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
        ProxyRepresentation(exporting: \.summary)
    }
}

// MARK: - PDF export

/// The plan's PDF, for `.fileExporter`.
struct MacDegreePlanPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension DegreePlan {
    /// The file name a PDF export starts with: `New Plan – view-plan.pdf`, like the file the
    /// degree audit makes.
    var macExportFileName: String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: "-")
        return "\(safe.isEmpty ? "Degree Plan" : safe) – view-plan"
    }
}

// MARK: - Printing

/// File › Print (⌘P): prints the plan in the degree audit's "View Plan" layout, the same pages
/// as the exported PDF (without the student's name and ID; export the PDF to include them).
@MainActor
enum MacDegreePlanPrinting {
    static func print(_ plan: DegreePlan) {
        let data = DegreePlanPDFRenderer.render(plan, includeStudent: false)
        guard let document = PDFDocument(data: data),
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        operation.jobTitle = plan.name
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

// MARK: - Undo

/// Edits to one degree plan that Edit › Undo (⌘Z) and Redo can take back. Like the iPhone's
/// undo, an undo puts back only the parts of the plan the edit changed, so it never undoes a
/// rename or another change made in the meantime.
@MainActor
struct MacDegreePlanEditor {
    /// The parts of a plan an edit can change.
    struct Parts: OptionSet {
        let rawValue: Int
        /// Semesters and completed courses.
        static let courses = Parts(rawValue: 1 << 0)
        static let student = Parts(rawValue: 1 << 1)
        static let equivalences = Parts(rawValue: 1 << 2)
        static let substitutions = Parts(rawValue: 1 << 3)
    }

    var userData: UserDataStore
    var planID: UUID
    var undoManager: UndoManager?

    /// Applies an edit and registers its undo.
    func perform(_ actionName: String, touching parts: Parts = .courses, _ change: (inout DegreePlan) -> Void) {
        guard let before = userData.degreePlan(id: planID) else { return }
        userData.updateDegreePlan(id: planID, change)
        if parts.contains(.courses) { userData.syncChosenCredits(fromDegreePlan: planID) }
        register(actionName, parts: parts, restore: Self.restorer(for: before, parts: parts))
    }

    /// The edit that puts a plan's parts back as they are now.
    private static func restorer(for plan: DegreePlan, parts: Parts) -> (inout DegreePlan) -> Void {
        let terms = plan.terms
        let completed = plan.completed
        let studentName = plan.studentName
        let studentID = plan.studentID
        let equivalences = plan.courseEquivalences
        let substitutions = plan.substitutions
        return { plan in
            if parts.contains(.courses) {
                plan.terms = terms
                plan.completed = completed
            }
            if parts.contains(.student) {
                plan.studentName = studentName
                plan.studentID = studentID
            }
            if parts.contains(.equivalences) { plan.courseEquivalences = equivalences }
            if parts.contains(.substitutions) { plan.substitutions = substitutions }
        }
    }

    private func register(_ actionName: String, parts: Parts, restore: @escaping (inout DegreePlan) -> Void) {
        guard let undoManager else { return }
        let planID = planID
        undoManager.registerUndo(withTarget: userData) { [weak undoManager] store in
            MainActor.assumeIsolated {
                guard let current = store.degreePlan(id: planID) else { return }
                let redo = Self.restorer(for: current, parts: parts)
                store.updateDegreePlan(id: planID) { restore(&$0) }
                if parts.contains(.courses) { store.syncChosenCredits(fromDegreePlan: planID) }
                // Registered while undoing, so the undo manager keeps it as the redo.
                MacDegreePlanEditor(userData: store, planID: planID, undoManager: undoManager)
                    .register(actionName, parts: parts, restore: redo)
            }
        }
        undoManager.setActionName(actionName)
    }
}

// MARK: - Toast

/// A brief confirmation at the bottom of the window, such as `Created “Spring 2027 plan”`,
/// optionally with an action (Open).
struct MacDegreeToast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var systemImage = "checkmark.circle.fill"
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (lhs: MacDegreeToast, rhs: MacDegreeToast) -> Bool { lhs.id == rhs.id }
}

private struct MacDegreeToastModifier: ViewModifier {
    @Binding var toast: MacDegreeToast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    HStack(spacing: 12) {
                        Label(toast.text, systemImage: toast.systemImage)
                            .lineLimit(2)
                        if let title = toast.actionTitle, let action = toast.action {
                            Button(title) {
                                action()
                                withAnimation { self.toast = nil }
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 14)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.action == nil ? 2.5 : 6))
                        guard !Task.isCancelled else { return }
                        withAnimation { self.toast = nil }
                    }
                }
            }
            .animation(.snappy, value: toast)
            .onChange(of: toast) { _, new in
                if let new { AccessibilityNotification.Announcement(new.text).post() }
            }
    }
}

extension View {
    /// Shows `toast` as a glass capsule at the bottom of the view for a few seconds.
    func macDegreeToast(_ toast: Binding<MacDegreeToast?>) -> some View {
        modifier(MacDegreeToastModifier(toast: toast))
    }
}

// MARK: - Sheet buttons

/// The button row at the bottom of a sheet: Cancel on the left of the default action, as in
/// AppKit sheets. Return takes the default action and Escape cancels.
struct MacDegreeSheetButtons<Leading: View>: View {
    var confirmTitle: String
    var isConfirmDisabled = false
    var cancelTitle = "Cancel"
    var onConfirm: () -> Void
    var onCancel: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 12)
            Button(cancelTitle, role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(isConfirmDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

extension MacDegreeSheetButtons where Leading == EmptyView {
    init(confirmTitle: String, isConfirmDisabled: Bool = false, cancelTitle: String = "Cancel",
         onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.init(confirmTitle: confirmTitle, isConfirmDisabled: isConfirmDisabled, cancelTitle: cancelTitle,
                  onConfirm: onConfirm, onCancel: onCancel) { EmptyView() }
    }
}

// MARK: - Plan text

/// The code of a course in a list row: the accent color, or plain text while the row is
/// selected (a colored code would vanish against the selection).
struct MacDegreeCodeText: View {
    var text: String
    var isCourse = true
    var weight: Font.Weight = .semibold

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(text)
            .font(.body.weight(weight))
            .monospacedDigit()
            .foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        if !isCourse { return AnyShapeStyle(.secondary) }
        return prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
    }
}

extension View {
    /// An opaque background for a list section's header: while it is pinned to the top, rows
    /// scroll under it, and their text would show through the header's.
    func macListHeaderBackground() -> some View {
        background(Color(nsColor: .controlBackgroundColor))
    }
}

extension MacDegreePlanEditor {
    /// A plan course (completed or planned) from a `DegreePlanCourse` search result: the
    /// catalog's title shortened like the degree audit's, and its (maximum) credits.
    static func newCourse(from course: Course) -> DegreePlanCourse {
        DegreePlanCourse(key: course.key, title: DegreePlanFormat.exportTitle(course.title), credits: course.defaultChoiceCredits)
    }
}
