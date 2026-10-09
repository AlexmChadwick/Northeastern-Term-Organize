//
//  RoomsTabView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Finding a free classroom is a feature of SearchNEU's rooms page
//  (https://github.com/sandboxnu/searchneu). This implementation is new.
//

import SwiftUI

/// Root of the Rooms tab: which classrooms are free at a chosen day and time.
struct RoomsTabView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    private enum DaySelection: Hashable {
        case now
        case day(Int)
    }

    private enum CampusChoice: Hashable {
        /// The preferred campus from Settings when it has buildings, otherwise everything.
        case automatic
        case all
        case campus(String)
    }

    private struct CampusOption: Identifiable, Hashable {
        var code: String
        var name: String
        var buildingCount: Int
        var id: String { code }
    }

    @State private var selection: DaySelection = .now
    /// The time of day used while a weekday chip is selected.
    @State private var customMinutes = 10 * 60
    @State private var showsTimePicker = false
    @State private var searchText = ""
    @State private var campusChoice: CampusChoice = .automatic
    @State private var classDates: RoomAvailability.ClassDates?
    @AppStorage("rooms.buildingSort") private var sortRaw = RoomAvailability.BuildingSort.mostFree.rawValue
    @AppStorage("rooms.showsRoomsInUse") private var showsRoomsInUse = true

    /// Monday through Saturday.
    private static let chipDays = [1, 2, 3, 4, 5, 6]

    var body: some View {
        content
            .navigationTitle("Free Rooms")
            .navigationSubtitle(catalog.selectedTerm?.name ?? "")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .roomsClassDates($classDates, in: catalog.index)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let index = catalog.index {
            if index.buildings.isEmpty {
                ContentUnavailableView(
                    "No room data",
                    systemImage: "door.left.hand.closed",
                    description: Text("This term's catalog doesn't list classroom locations yet. Refresh it from Settings.")
                )
            } else {
                TimelineView(.everyMinute) { context in
                    roomList(index: index, now: context.date)
                }
                .searchable(text: $searchText, prompt: "Search buildings and rooms")
                .safeAreaBar(edge: .top) { chipBar }
            }
        } else {
            RoomsCatalogUnavailableView()
        }
    }

    private func roomList(index: CatalogIndex, now: Date) -> some View {
        let current = moment(at: now)
        let campusCode = resolvedCampusCode(in: index)
        let buildings = index.buildings.filter { campusCode == nil || $0.campusCode == campusCode }
        let everything = RoomAvailability.availability(of: buildings, at: current)
        let visible = RoomAvailability.sorted(RoomAvailability.filter(everything, matching: searchText), by: sort)
        let freeTotal = everything.reduce(0) { $0 + $1.freeCount }
        let roomTotal = everything.reduce(0) { $0 + $1.roomCount }
        let campusName = index.roomsCampusName(forCode: campusCode)

        return Group {
            if visible.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("No rooms to show", systemImage: "door.left.hand.closed")
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                List {
                    summarySection(
                        moment: current,
                        now: now,
                        termName: index.term.shortName,
                        freeTotal: freeTotal,
                        roomTotal: roomTotal,
                        campusName: campusName
                    )
                    ForEach(visible) { item in
                        Section {
                            rows(for: item, moment: current, termCode: index.term.code)
                        } header: {
                            RoomsBuildingHeader(item: item, campusName: index.roomsCampusName(forCode: item.building.campusCode)) {
                                router.show(.building(termCode: index.term.code, code: item.building.code), in: .rooms)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func summarySection(
        moment: RoomAvailability.Moment,
        now: Date,
        termName: String,
        freeTotal: Int,
        roomTotal: Int,
        campusName: String?
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection == .now ? "Right now · \(moment.label)" : moment.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(RoomsText.freeSummary(free: freeTotal, total: roomTotal))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if let campusName {
                    Text(campusName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(RoomsText.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .accessibilityElement(children: .combine)

            if let dates = classDates, !dates.contains(now) {
                RoomsNotice(
                    systemImage: "calendar.badge.exclamationmark",
                    text: RoomsText.classDatesMessage(termName: termName, dates: dates)
                )
            }
            if !moment.isWithinClassHours {
                RoomsNotice(systemImage: "moon.zzz.fill", text: RoomsText.outsideHours, tint: .indigo)
            }
        }
    }

    @ViewBuilder
    private func rows(for item: RoomAvailability.BuildingAvailability, moment: RoomAvailability.Moment, termCode: String) -> some View {
        ForEach(item.free) { entry in
            roomLink(entry, moment: moment, termCode: termCode)
        }
        if showsRoomsInUse {
            ForEach(item.busy) { entry in
                roomLink(entry, moment: moment, termCode: termCode)
            }
        } else if item.free.isEmpty {
            Text("All rooms are in use right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func roomLink(_ entry: RoomAvailability.Entry, moment: RoomAvailability.Moment, termCode: String) -> some View {
        NavigationLink(value: AppRoute.room(termCode: termCode, buildingCode: entry.room.buildingCode, room: entry.room.room)) {
            RoomsRoomRow(entry: entry, moment: moment)
        }
    }

    // MARK: Controls

    private var chipBar: some View {
        GlassChipBar {
            GlassChip(title: "Now", systemImage: "clock", isOn: selection == .now) {
                selection = .now
            }
            ForEach(Self.chipDays, id: \.self) { day in
                GlassChip(title: DaySet.shortNames[day], systemImage: nil, isOn: selection == .day(day)) {
                    select(day: day)
                }
            }
            timeChip
        }
    }

    private var timeChip: some View {
        GlassChip(
            title: selection == .now ? "Choose Time" : TimeOfDay.label(customMinutes),
            systemImage: "calendar.badge.clock",
            isOn: selection != .now,
            showsChevron: true
        ) {
            if selection == .now {
                customMinutes = Self.defaultMinutes(for: .now)
                selection = .day(RoomAvailability.Moment(date: .now).weekday)
            }
            showsTimePicker = true
        }
        .popover(isPresented: $showsTimePicker) {
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            TermMenu()
        }
        if catalog.index?.buildings.isEmpty == false {
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Section("Sort Buildings") {
                Picker("Sort Buildings", selection: sortBinding) {
                    ForEach(RoomAvailability.BuildingSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            }
            Toggle(isOn: $showsRoomsInUse) {
                Label("Show Rooms in Use", systemImage: "door.left.hand.closed")
            }
            if campusOptions.count > 1 {
                Section("Campus") {
                    Picker("Campus", selection: campusBinding) {
                        Text("All Campuses").tag(CampusChoice.all)
                        ForEach(campusOptions) { option in
                            Text(option.name).tag(CampusChoice.campus(option.code))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            Label("Options", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: State

    private var sort: RoomAvailability.BuildingSort {
        RoomAvailability.BuildingSort(rawValue: sortRaw) ?? .mostFree
    }

    private var sortBinding: Binding<RoomAvailability.BuildingSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    private var campusBinding: Binding<CampusChoice> {
        Binding(
            get: {
                guard let index = catalog.index, let code = resolvedCampusCode(in: index) else { return .all }
                return .campus(code)
            },
            set: { campusChoice = $0 }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: customMinutes / 60, minute: customMinutes % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                customMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var campusOptions: [CampusOption] {
        guard let index = catalog.index else { return [] }
        var counts: [String: Int] = [:]
        for building in index.buildings {
            if let code = building.campusCode { counts[code, default: 0] += 1 }
        }
        return counts
            .map { CampusOption(code: $0.key, name: index.roomsCampusName(forCode: $0.key) ?? $0.key, buildingCount: $0.value) }
            .sorted { lhs, rhs in
                lhs.buildingCount != rhs.buildingCount ? lhs.buildingCount > rhs.buildingCount : lhs.name < rhs.name
            }
    }

    private func resolvedCampusCode(in index: CatalogIndex) -> String? {
        switch campusChoice {
        case .all:
            return nil
        case .campus(let code):
            return index.buildings.contains { $0.campusCode == code } ? code : nil
        case .automatic:
            guard let preferred = userData.preferences.preferredCampus,
                  let code = index.catalog.campuses.first(where: { $0.name == preferred })?.code,
                  index.buildings.contains(where: { $0.campusCode == code }) else { return nil }
            return code
        }
    }

    private func moment(at date: Date) -> RoomAvailability.Moment {
        switch selection {
        case .now: RoomAvailability.Moment(date: date)
        case .day(let day): RoomAvailability.Moment(weekday: day, minutes: customMinutes)
        }
    }

    private func select(day: Int) {
        if selection == .now {
            customMinutes = Self.defaultMinutes(for: .now)
        }
        selection = .day(day)
    }

    /// The current time rounded down to a quarter hour, or mid-morning outside class hours.
    private static func defaultMinutes(for date: Date) -> Int {
        let moment = RoomAvailability.Moment(date: date)
        return moment.isWithinClassHours ? moment.minutes / 15 * 15 : 10 * 60
    }
}
