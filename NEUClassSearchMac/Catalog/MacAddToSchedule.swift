//
//  MacAddToSchedule.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  "Add to Schedule ▸": the term's schedules as a menu in toolbars and context menus, plus a
//  "New Schedule…" that asks for a name.
//

import SwiftUI

/// A course, and optionally the section of it, to put in a schedule.
struct MacCatalogScheduleAddition: Hashable {
    var key: CourseKey
    var crn: String?
}

/// A pending "New Schedule…" that receives its courses once it has a name.
struct MacCatalogNewScheduleRequest: Identifiable {
    let id = UUID()
    var termCode: String
    var additions: [MacCatalogScheduleAddition]
}

/// Puts courses in schedules, the way the iPhone's "Add to Schedule" sheet does.
@MainActor
enum MacCatalogScheduleAdding {
    /// Whether the plan already holds what `addition` asks for: the course, and the chosen section.
    static func holds(_ plan: SchedulePlan, _ addition: MacCatalogScheduleAddition) -> Bool {
        guard plan.contains(addition.key) else { return false }
        guard let crn = addition.crn else { return true }
        return plan.courses.contains { $0.pinnedCRN == crn } || plan.selectedCRNs.contains(crn)
    }

    /// Adds the courses to the plan (and picks the sections asked for). Returns the courses that
    /// were not in it yet or whose section changed.
    @discardableResult
    static func add(
        _ additions: [MacCatalogScheduleAddition],
        to planID: UUID,
        termCode: String,
        userData: UserDataStore,
        catalog: CatalogStore
    ) -> [MacCatalogScheduleAddition] {
        var changed: [MacCatalogScheduleAddition] = []
        let index = catalog.cachedIndex(for: termCode)
        for addition in additions {
            let wasThere = userData.plan(id: planID).map { holds($0, addition) } ?? false
            let courseCRNs = Set(index?.sections(for: addition.key).map(\.crn) ?? [])
                .union(addition.crn.map { [$0] } ?? [])
            let admission = userData.includeCourse(addition.key, crn: addition.crn, courseCRNs: courseCRNs, toPlan: planID)
            if !wasThere || admission == .added { changed.append(addition) }
        }
        return changed
    }

    /// "CS 3000", "CS 3000 section 02" or "3 courses".
    static func description(of additions: [MacCatalogScheduleAddition], index: CatalogIndex?) -> String {
        guard additions.count == 1, let only = additions.first else { return "\(additions.count) courses" }
        guard let crn = only.crn, let section = index?.section(crn: crn) else { return only.key.description }
        return "\(only.key.description) section \(section.sectionNumber)"
    }
}

/// A menu of the term's schedules that adds the courses to the one chosen.
struct MacCatalogAddToScheduleMenu<MenuLabel: View>: View {
    var termCode: String
    var additions: [MacCatalogScheduleAddition]
    /// Set by "New Schedule…"; the host view shows `catalogNewScheduleAlert` for it.
    @Binding var newSchedule: MacCatalogNewScheduleRequest?
    @ViewBuilder var label: MenuLabel

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.catalogToast) private var toast

    var body: some View {
        let plans = userData.plans(in: termCode)
        Menu {
            ForEach(plans) { plan in
                planButton(plan)
            }
            if !plans.isEmpty { Divider() }
            Button("New Schedule…", systemImage: "plus") {
                newSchedule = MacCatalogNewScheduleRequest(termCode: termCode, additions: additions)
            }
        } label: {
            label
        }
        .disabled(additions.isEmpty)
    }

    /// One schedule: a check when it has everything already, a star for the primary one.
    private func planButton(_ plan: SchedulePlan) -> some View {
        let holdsAll = additions.allSatisfy { MacCatalogScheduleAdding.holds(plan, $0) }
        return Button {
            add(to: plan)
        } label: {
            if holdsAll {
                Label(plan.name, systemImage: "checkmark")
            } else if plan.isPrimary {
                Label(plan.name, systemImage: "star")
            } else {
                Text(plan.name)
            }
        }
        .disabled(holdsAll)
    }

    private func add(to plan: SchedulePlan) {
        let changed = MacCatalogScheduleAdding.add(additions, to: plan.id, termCode: termCode, userData: userData, catalog: catalog)
        let what = MacCatalogScheduleAdding.description(of: additions, index: catalog.cachedIndex(for: termCode))
        let planID = plan.id
        if changed.isEmpty {
            toast("\(what) is already in \(plan.name)", systemImage: "checkmark.circle")
        } else {
            toast("Added \(what) to \(plan.name)", actionTitle: "View") {
                MacCatalogNavigation.showSchedule(planID, navigator: navigator, openWindow: openWindow)
            }
        }
    }
}

extension MacCatalogAddToScheduleMenu where MenuLabel == Label<Text, Image> {
    /// The menu as it appears in context menus: "Add to Schedule".
    init(termCode: String, additions: [MacCatalogScheduleAddition], newSchedule: Binding<MacCatalogNewScheduleRequest?>, title: String = "Add to Schedule") {
        self.init(termCode: termCode, additions: additions, newSchedule: newSchedule) {
            Label(title, systemImage: "calendar.badge.plus")
        }
    }
}

extension View {
    /// Asks for the name of a new schedule when "New Schedule…" is chosen, then creates it with the
    /// courses.
    func catalogNewScheduleAlert(_ request: Binding<MacCatalogNewScheduleRequest?>) -> some View {
        modifier(MacCatalogNewScheduleAlert(request: request))
    }
}

private struct MacCatalogNewScheduleAlert: ViewModifier {
    @Binding var request: MacCatalogNewScheduleRequest?

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.catalogToast) private var toast
    @State private var name = ""

    private var isPresented: Binding<Bool> {
        Binding(get: { request != nil }, set: { if !$0 { request = nil } })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in
                guard let request else { return }
                name = PlanEditing.nextPlanName(existing: userData.plans(in: request.termCode).map(\.name))
            }
            .alert("New Schedule", isPresented: isPresented, presenting: request) { request in
                TextField("Name", text: $name)
                Button("Create") { create(for: request) }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: { request in
                let term = catalog.cachedIndex(for: request.termCode)?.term.name ?? "this term"
                Text("Choose a name for the schedule in \(term). \(MacCatalogScheduleAdding.description(of: request.additions, index: catalog.cachedIndex(for: request.termCode)).capitalizedFirst) will be added to it.")
            }
    }

    private func create(for request: MacCatalogNewScheduleRequest) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty
            ? PlanEditing.nextPlanName(existing: userData.plans(in: request.termCode).map(\.name))
            : trimmed
        let plan = userData.createPlan(name: title, termCode: request.termCode)
        MacCatalogScheduleAdding.add(request.additions, to: plan.id, termCode: request.termCode, userData: userData, catalog: catalog)
        let what = MacCatalogScheduleAdding.description(of: request.additions, index: catalog.cachedIndex(for: request.termCode))
        let planID = plan.id
        toast("Added \(what) to the new schedule \(plan.name)", actionTitle: "View") {
            MacCatalogNavigation.showSchedule(planID, navigator: navigator, openWindow: openWindow)
        }
    }
}

private extension String {
    /// The string with its first letter capitalized, the rest untouched ("CS 3000" stays as it is).
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
