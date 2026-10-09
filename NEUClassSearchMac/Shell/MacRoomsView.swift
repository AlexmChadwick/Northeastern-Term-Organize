//
//  MacRoomsView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Finding a free classroom is a feature of SearchNEU's rooms page
//  (https://github.com/sandboxnu/searchneu). This implementation is new.
//

import AppKit
import SwiftUI

/// Free classrooms now or at any time: buildings on the left, the rooms of the selected building
/// (or of all of them) as a timeline of the day in the middle, and, on the right, the selected
/// room's classes for a day or the week. The panes share the window's width and can be dragged;
/// the middle one takes what is left, so a wide window shows more of the day at a glance. What is
/// free comes from the term's class schedule (`RoomAvailability`), so it only says which rooms have
/// no class, not which are locked or reserved.
struct MacRoomsView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.openWindow) private var openWindow

    /// The row that lists every building's rooms.
    static let allBuildingsID = "*"
    /// Below this width the two side panes can't both sit beside the list: one floats at a time.
    private static let narrowWidth: CGFloat = 900

    @State private var time = MacRoomsTime.now
    /// The time of day used while a weekday is selected.
    @State private var customMinutes = 10 * 60
    /// The current time. A ticker in state rather than a `TimelineView`, which must not wrap the
    /// room pane's calendar (it has a timeline of its own).
    @State private var now = MacShellClock.now
    @State private var searchText = ""
    @State private var campus = MacRoomsCampus.automatic
    @State private var buildingID: String? = MacRoomsView.allBuildingsID
    @State private var roomID: MacRoomRow.ID?
    /// A room chosen in the overview, which the list scrolls to.
    @State private var revealID: MacRoomRow.ID?
    @State private var availability: [RoomAvailability.BuildingAvailability] = []
    @State private var classDates: RoomAvailability.ClassDates?
    /// The width this screen has, to tell a window with room for both panes from a narrow one.
    @State private var areaWidth: CGFloat = 1_000
    /// Where the rows' bars are horizontally, as they report it, for the axis above them.
    @State private var trackRange: Range<CGFloat>?
    @State private var floatingPane: MacRoomsFloatingPane?
    @AppStorage("rooms.buildingSort") private var sortRaw = RoomAvailability.BuildingSort.mostFree.rawValue
    @AppStorage("rooms.roomOrder") private var orderRaw = MacRoomsOrder.availability.rawValue
    @AppStorage("rooms.showsRoomsInUse") private var showsRoomsInUse = true
    // Snapshot runs keep the panes in state instead: they must neither read nor write the app's defaults.
    @AppStorage("mac.rooms.showsBuildings") private var storedShowsBuildings = true
    @AppStorage("mac.rooms.showsDetails") private var storedShowsDetails = true
    @State private var snapshotShowsBuildings = true
    @State private var snapshotShowsDetails = true

    var body: some View {
        content
            .navigationTitle("Free Rooms")
            .navigationSubtitle(catalog.selectedTerm?.name ?? "")
            .toolbar { toolbarContent }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search buildings and rooms")
            // Which rooms are free comes from the term's class schedule, so ⌘R downloads it again.
            .focusedSceneValue(\.macReload, catalog.readyIndex != nil && !catalog.isSyncing ? MacMenuAction(title: "Update Room Data") { catalog.syncSelectedTerm() } : nil)
            .focusedSceneValue(\.macSidePane, catalog.index?.buildings.isEmpty == false ? MacPaneToggle(title: "Room Details", isShown: detailsShown, toggle: toggleDetails) : nil)
            .focusedSceneValue(\.macListPane, catalog.index?.buildings.isEmpty == false ? MacPaneToggle(title: "Buildings", isShown: buildingsShown, toggle: toggleBuildings) : nil)
            .roomsClassDates($classDates, in: catalog.index)
            .task { await MacShellClock.everyMinute { now = $0 } }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let index = catalog.index {
            if index.buildings.isEmpty {
                ContentUnavailableView(
                    "No Room Data",
                    systemImage: "door.left.hand.closed",
                    description: Text("This term's catalog doesn't list classroom locations yet. Refresh it from Settings.")
                )
            } else {
                rooms(in: index)
            }
        } else {
            MacRoomsCatalogUnavailable()
        }
    }

    private func rooms(in index: CatalogIndex) -> some View {
        MacSplitPane(
            storageKey: "mac.split.rooms.details", paneEdge: .trailing, defaultShare: 0.3,
            paneMinWidth: 300, primaryMinWidth: 380, maxShare: 0.5, isPaneShown: detailsBinding
        ) {
            MacSplitPane(
                storageKey: "mac.split.rooms.buildings", paneEdge: .leading, defaultShare: 0.2,
                paneMinWidth: 190, primaryMinWidth: 380, maxShare: 0.4, isPaneShown: buildingsBinding
            ) {
                roomsColumn(in: index)
            } pane: {
                buildingList(in: index)
            }
        } pane: {
            inspector(in: index)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { areaWidth = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        // Recomputed when the time, the campus or the catalog changes, off the main actor.
        .task(id: ComputeKey(identity: index.roomsIdentity, moment: momentKey, campusCode: resolvedCampusCode(in: index))) {
            let buildings = index.buildings.filter { resolvedCampusCode(in: index) == nil || $0.campusCode == resolvedCampusCode(in: index) }
            let moment = moment
            let computed = await Task.detached(priority: .userInitiated) {
                RoomAvailability.availability(of: buildings, at: moment)
            }.value
            guard !Task.isCancelled else { return }
            availability = computed
        }
        .task(id: index.roomsIdentity) {
            preselectForSnapshot(in: index)
        }
        .onChange(of: time) { old, new in
            if old == .now, case .day = new { customMinutes = Self.defaultMinutes(for: now) }
        }
    }

    /// What decides whether the availability has to be worked out again.
    private struct ComputeKey: Hashable {
        var identity: String
        var moment: Int
        var campusCode: String?
    }

    // MARK: Buildings

    private func buildingList(in index: CatalogIndex) -> some View {
        let visible = visibleBuildings
        let freeTotal = availability.reduce(0) { $0 + $1.freeCount }
        let roomTotal = availability.reduce(0) { $0 + $1.roomCount }
        return List(selection: $buildingID) {
            MacRoomsAllBuildingsRow(free: freeTotal, total: roomTotal, campusName: index.roomsCampusName(forCode: resolvedCampusCode(in: index)))
                .tag(Self.allBuildingsID)
            Section("Buildings") {
                ForEach(visible) { item in
                    MacRoomsBuildingRow(item: item, campusName: index.roomsCampusName(forCode: item.building.campusCode))
                        .tag(item.building.code)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if visible.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    /// The buildings that match the search, in the chosen order.
    private var visibleBuildings: [RoomAvailability.BuildingAvailability] {
        RoomAvailability.sorted(RoomAvailability.filter(availability, matching: searchText), by: sort)
    }

    // MARK: Rooms

    /// The notices, the hours and the rooms.
    private func roomsColumn(in index: CatalogIndex) -> some View {
        VStack(spacing: 0) {
            notices(in: index)
            MacRoomsAxis(trackRange: trackRange)
            roomList(in: index)
        }
    }

    private struct RoomGroup: Identifiable {
        var item: RoomAvailability.BuildingAvailability
        var rows: [MacRoomRow]
        var id: String { item.id }
    }

    /// The buildings the list covers: the selected one, or all that match the search.
    private var scopeItems: [RoomAvailability.BuildingAvailability] {
        let visible = visibleBuildings
        // A search that filters the selected building out looks through all the matching ones.
        let items = visible.filter { buildingID == nil || buildingID == Self.allBuildingsID || $0.building.code == buildingID }
        return items.isEmpty ? visible : items
    }

    private func row(for entry: RoomAvailability.Entry, in item: RoomAvailability.BuildingAvailability, at current: RoomAvailability.Moment) -> MacRoomRow {
        MacRoomRow(
            entry: entry,
            buildingName: item.building.name,
            minutesLeft: entry.status.minutesRemaining(at: current),
            tint: entry.status.roomsTint(at: current)
        )
    }

    /// The rooms of the selected building, or of all the buildings that match the search, building
    /// by building.
    private var roomGroups: [RoomGroup] {
        let current = moment
        let byNumber = order == .number
        return scopeItems.compactMap { item in
            let entries = item.free + (showsRoomsInUse ? item.busy : [])
            var rows = entries.map { row(for: $0, in: item, at: current) }
            if byNumber { rows.sort { $0.naturalKey < $1.naturalKey } }
            return rows.isEmpty ? nil : RoomGroup(item: item, rows: rows)
        }
    }

    private func roomList(in index: CatalogIndex) -> some View {
        let groups = roomGroups
        let current = moment
        return ScrollViewReader { scroller in
            List(selection: $roomID) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            MacRoomTimelineRow(row: row, moment: current) { range in
                                if trackRange != range { trackRange = range }
                            }
                            .tag(row.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: MacRoomsTimeline.inset, bottom: 0, trailing: MacRoomsTimeline.inset))
                        }
                    } header: {
                        MacRoomsGroupHeader(item: group.item, campusName: index.roomsCampusName(forCode: group.item.building.campusCode))
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: MacRoomRow.ID.self) { ids in
                if let id = ids.first, let row = groups.lazy.flatMap(\.rows).first(where: { $0.id == id }) {
                    contextMenu(for: row)
                }
            } primaryAction: { ids in
                if let id = ids.first {
                    roomID = id
                    showDetails()
                }
            }
            // Return shows the selected room's classes, like a double-click.
            .onKeyPress(.return) {
                guard roomID != nil else { return .ignored }
                showDetails()
                return .handled
            }
            .overlay {
                if groups.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No Rooms to Show",
                            systemImage: "door.left.hand.closed",
                            description: Text(showsRoomsInUse ? "" : "All rooms are in use at this time. Show rooms in use from the Options menu.")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
            .onChange(of: buildingID) {
                if let first = groups.first?.rows.first?.id { scroller.scrollTo(first, anchor: .top) }
                // The pane shows the new building's overview instead of a room that isn't in it (unless the
                // rooms aren't worked out yet).
                if !groups.isEmpty, let roomID, !groups.contains(where: { $0.rows.contains { $0.id == roomID } }) { self.roomID = nil }
            }
            .task(id: revealID) {
                guard let revealID else { return }
                scroller.scrollTo(revealID, anchor: .center)
            }
            .task(id: roomID) {
                // A room chosen from outside the list (a snapshot) is brought into view.
                guard MacShellRun.isSnapshot, let roomID else { return }
                scroller.scrollTo(roomID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for row: MacRoomRow) -> some View {
        Button("Show Classes") {
            roomID = row.id
            showDetails()
        }
        if case .busy(let occupancy) = row.entry.status, let code = catalog.index?.term.code {
            Button("Open \(occupancy.booking.course.description) in a Window") {
                openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: code, key: occupancy.booking.course))
            }
        }
        Divider()
        Button("Copy Room Name") {
            MacShellPasteboard.copy(row.label)
        }
    }

    // MARK: Room details

    @ViewBuilder
    private func inspector(in index: CatalogIndex) -> some View {
        if let id = roomID, let room = index.roomsRoom(withID: id) {
            MacRoomInspector(
                index: index,
                room: room,
                moment: moment,
                isNow: time == .now,
                now: now,
                classDates: classDates,
                onShowOverview: { roomID = nil }
            )
        } else {
            overview(in: index)
        }
    }

    /// While no room is selected: how the rooms in the list stay free through the day, and which
    /// stay free the longest.
    @ViewBuilder
    private func overview(in index: CatalogIndex) -> some View {
        let items = scopeItems
        if items.isEmpty {
            ContentUnavailableView(
                "No Room Selected",
                systemImage: "door.left.hand.open",
                description: Text("Select a room to see its classes.")
            )
        } else {
            let current = moment
            let free = items.reduce(0) { $0 + $1.freeCount }
            let total = items.reduce(0) { $0 + $1.roomCount }
            // The longest free first; rooms free as long come in the order of the buildings (most free
            // rooms first, as in the list) and of the building's own rooms.
            let longest = items
                .flatMap { item in item.free.map { row(for: $0, in: item, at: current) } }
                .enumerated()
                .sorted { lhs, rhs in
                    lhs.element.minutesLeft != rhs.element.minutesLeft
                        ? lhs.element.minutesLeft > rhs.element.minutesLeft : lhs.offset < rhs.offset
                }
                .map(\.element)
            MacRoomsOverview(
                title: items.count == 1 ? items[0].building.name : "All Buildings",
                summary: RoomsText.freeSummary(free: free, total: total),
                when: time == .now ? "Right now · \(current.label)" : current.label,
                rooms: items.flatMap { ($0.free + $0.busy).map(\.room) },
                longest: Array(longest.prefix(6)),
                moment: current,
                showsBuilding: items.count > 1,
                onSelect: { id in
                    roomID = id
                    revealID = id
                }
            )
        }
    }

    // MARK: Notices and status bar

    @ViewBuilder
    private func notices(in index: CatalogIndex) -> some View {
        let showsDates = time == .now && classDates.map { !$0.contains(now) } == true
        if showsDates || !moment.isWithinClassHours {
            VStack(alignment: .leading, spacing: 6) {
                if showsDates, let classDates {
                    MacRoomsNotice(
                        systemImage: "calendar.badge.exclamationmark",
                        text: RoomsText.classDatesMessage(termName: index.term.shortName, dates: classDates),
                        lineLimit: 2
                    )
                }
                if !moment.isWithinClassHours {
                    MacRoomsNotice(systemImage: "moon.zzz.fill", text: RoomsText.outsideHours, tint: .indigo, lineLimit: 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var statusBar: some View {
        let freeTotal = availability.reduce(0) { $0 + $1.freeCount }
        let roomTotal = availability.reduce(0) { $0 + $1.roomCount }
        return HStack(spacing: 8) {
            Text(time == .now ? "Right now · \(moment.label)" : moment.label)
            Text("·")
            Text(RoomsText.freeSummary(free: freeTotal, total: roomTotal))
                .fontWeight(.medium)
                .monospacedDigit()
            Spacer()
            Text(RoomsText.disclaimer)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                // A pop-up button in a narrow window, where seven segments don't fit the toolbar.
                if isNarrow {
                    Picker("Time", selection: $time) {
                        Text("Now").tag(MacRoomsTime.now)
                        Divider()
                        ForEach(Self.weekdays, id: \.self) { day in
                            Text(DaySet.fullNames[day]).tag(MacRoomsTime.day(day))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Show which rooms are free now or at a time on a weekday")
                } else {
                    Picker("Time", selection: $time) {
                        Text("Now").tag(MacRoomsTime.now)
                        ForEach(Self.weekdays, id: \.self) { day in
                            Text(DaySet.shortNames[day]).tag(MacRoomsTime.day(day))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Show which rooms are free now or at a time on a weekday")
                }
                if time != .now {
                    DatePicker("Time of day", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .help("The time of day")
                }
            }
        }
        if catalog.index?.buildings.isEmpty == false {
            ToolbarItemGroup(placement: .primaryAction) {
                optionsMenu
                Button(action: toggleBuildings) {
                    Label("Buildings", systemImage: "building.2")
                }
                .help("Show or hide the list of buildings")
                Button(action: toggleDetails) {
                    Label("Room Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the selected room's classes (⌥⌘0)")
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Section("Sort Rooms") {
                Picker("Sort Rooms", selection: orderBinding) {
                    ForEach(MacRoomsOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
            }
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
            if let options = catalog.index?.roomsCampusOptions, options.count > 1 {
                Section("Campus") {
                    Picker("Campus", selection: campusBinding) {
                        Text("All Campuses").tag(MacRoomsCampus.all)
                        ForEach(options) { option in
                            Text(option.name).tag(MacRoomsCampus.campus(option.code))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        } label: {
            Label("Options", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Sort rooms and buildings, show rooms in use and choose a campus")
    }

    // MARK: Side panes

    private var isNarrow: Bool { areaWidth < Self.narrowWidth }

    private var showsBuildings: Bool {
        get { MacShellRun.isSnapshot ? snapshotShowsBuildings : storedShowsBuildings }
        nonmutating set {
            if MacShellRun.isSnapshot { snapshotShowsBuildings = newValue } else { storedShowsBuildings = newValue }
        }
    }

    private var showsDetails: Bool {
        get { MacShellRun.isSnapshot ? snapshotShowsDetails : storedShowsDetails }
        nonmutating set {
            if MacShellRun.isSnapshot { snapshotShowsDetails = newValue } else { storedShowsDetails = newValue }
        }
    }

    /// Whether each pane is open: as the user left them in a window with room for both, and, in a
    /// narrow one, only the pane they last asked for (it floats over the list).
    private var buildingsShown: Bool { isNarrow ? floatingPane == .buildings : showsBuildings }
    private var detailsShown: Bool { isNarrow ? floatingPane == .details : showsDetails }

    private var buildingsBinding: Binding<Bool> {
        Binding(get: { buildingsShown }, set: { setBuildings($0) })
    }

    private var detailsBinding: Binding<Bool> {
        Binding(get: { detailsShown }, set: { setDetails($0) })
    }

    private func setBuildings(_ shown: Bool) {
        if isNarrow {
            floatingPane = shown ? .buildings : (floatingPane == .buildings ? nil : floatingPane)
        } else {
            showsBuildings = shown
        }
    }

    private func setDetails(_ shown: Bool) {
        if isNarrow {
            floatingPane = shown ? .details : (floatingPane == .details ? nil : floatingPane)
        } else {
            showsDetails = shown
        }
    }

    private func toggleBuildings() { setBuildings(!buildingsShown) }
    private func toggleDetails() { setDetails(!detailsShown) }
    private func showDetails() { setDetails(true) }

    // MARK: State

    /// Monday through Saturday.
    private static let weekdays = [1, 2, 3, 4, 5, 6]

    private var sort: RoomAvailability.BuildingSort {
        RoomAvailability.BuildingSort(rawValue: sortRaw) ?? .mostFree
    }

    private var sortBinding: Binding<RoomAvailability.BuildingSort> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    private var order: MacRoomsOrder {
        MacRoomsOrder(rawValue: orderRaw) ?? .availability
    }

    private var orderBinding: Binding<MacRoomsOrder> {
        Binding(get: { order }, set: { orderRaw = $0.rawValue })
    }

    private var campusBinding: Binding<MacRoomsCampus> {
        Binding(
            get: {
                guard let index = catalog.index, let code = resolvedCampusCode(in: index) else { return .all }
                return .campus(code)
            },
            set: { campus = $0 }
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

    private func resolvedCampusCode(in index: CatalogIndex) -> String? {
        switch campus {
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

    /// The moment the list is for.
    private var moment: RoomAvailability.Moment {
        switch time {
        case .now: RoomAvailability.Moment(date: now)
        case .day(let day): RoomAvailability.Moment(weekday: day, minutes: customMinutes)
        }
    }

    /// Changes when `moment` does: every minute for "now" (the date matters for class dates).
    private var momentKey: Int {
        switch time {
        case .now: Int(now.timeIntervalSince1970 / 60)
        case .day(let day): -(day * 10_000 + customMinutes) - 1
        }
    }

    /// The current time rounded down to a quarter hour, or mid-morning outside class hours.
    private static func defaultMinutes(for date: Date) -> Int {
        let moment = RoomAvailability.Moment(date: date)
        return moment.isWithinClassHours ? moment.minutes / 15 * 15 : 10 * 60
    }

    /// Debug snapshots can open on a building and room (`-MacSnapshotBuilding WVH`,
    /// `-MacSnapshotRoom "WVH 210"`), and on a side pane of a narrow window
    /// (`-MacSnapshotRoomPane buildings|details`).
    private func preselectForSnapshot(in index: CatalogIndex) {
        #if DEBUG
        guard MacShellRun.isSnapshot else { return }
        let defaults = UserDefaults.standard
        if let code = defaults.string(forKey: "MacSnapshotBuilding"), index.buildings.contains(where: { $0.code == code }) {
            buildingID = code
        }
        if let label = defaults.string(forKey: "MacSnapshotRoom"),
           let room = index.buildings.flatMap(\.rooms).first(where: { $0.label == label }) {
            roomID = room.id
        }
        switch defaults.string(forKey: "MacSnapshotRoomPane") {
        case "buildings": floatingPane = .buildings
        case "details": floatingPane = .details
        default: break
        }
        if defaults.bool(forKey: "MacSnapshotHidePanes") {
            showsBuildings = false
            showsDetails = false
        }
        #endif
    }
}

// MARK: - Building rows

private struct MacRoomsAllBuildingsRow: View {
    var free: Int
    var total: Int
    var campusName: String?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("All Buildings")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(campusName ?? "All campuses")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            MacRoomsCountBadge(free: free)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("All buildings, \(RoomsText.freeSummary(free: free, total: total))")
    }
}

private struct MacRoomsBuildingRow: View {
    var item: RoomAvailability.BuildingAvailability
    var campusName: String?

    private var subtitle: String {
        [item.building.code, campusName].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.building.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            MacRoomsCountBadge(free: item.freeCount)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.building.name), \(RoomsText.freeSummary(free: item.freeCount, total: item.roomCount))")
    }
}

/// The header of a building's rooms in the list.
private struct MacRoomsGroupHeader: View {
    var item: RoomAvailability.BuildingAvailability
    var campusName: String?

    private var subtitle: String {
        [item.building.code, campusName].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.building.name)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(RoomsText.freeSummary(free: item.freeCount, total: item.roomCount))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(item.freeCount == 0 ? Color.secondary : Color.green)
        }
        .padding(.horizontal, MacRoomsTimeline.inset)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// How many rooms are free, in green, or a gray zero when none are.
private struct MacRoomsCountBadge: View {
    var free: Int

    private var tint: Color { free == 0 ? .secondary : .green }

    var body: some View {
        Text("\(free)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .capsule)
            .help(free == 0 ? "No free rooms" : "\(free) free \(free == 1 ? "room" : "rooms")")
    }
}

// MARK: - Catalog state

/// Shown instead of rooms while the catalog is loading, missing or failed.
private struct MacRoomsCatalogUnavailable: View {
    @Environment(CatalogStore.self) private var catalog

    private var termName: String { catalog.selectedTerm?.name ?? "this term" }

    var body: some View {
        switch catalog.loadState {
        case .idle, .loading, .loaded:
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading rooms…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .missing:
            ContentUnavailableView {
                Label("No Course Data Yet", systemImage: "arrow.down.circle")
            } description: {
                Text("Download \(termName) from Northeastern to see which rooms are free.")
            } actions: {
                if case .syncing(let progress) = catalog.syncState {
                    VStack(spacing: 6) {
                        ProgressView(value: progress.fraction)
                            .frame(maxWidth: 240)
                        Text(progress.label)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Download \(termName)") {
                        catalog.syncSelectedTerm()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Course Data", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    guard let code = catalog.selectedTermCode else { return }
                    Task { await catalog.select(termCode: code) }
                }
            }
        }
    }
}
