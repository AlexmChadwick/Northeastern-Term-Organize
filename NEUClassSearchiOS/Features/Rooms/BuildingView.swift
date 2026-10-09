//
//  BuildingView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// One building: every classroom with whether it is free right now.
struct BuildingView: View {
    var termCode: String
    var buildingCode: String

    var body: some View {
        RoomsIndexLoader(termCode: termCode) { index in
            if let building = index.buildings.first(where: { $0.code == buildingCode }) {
                BuildingContentView(index: index, building: building)
            } else {
                ContentUnavailableView(
                    "Building not found",
                    systemImage: "building.2",
                    description: Text("\(buildingCode) has no classrooms in the \(index.term.shortName) schedule.")
                )
            }
        }
        .navigationTitle(buildingCode)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BuildingContentView: View {
    var index: CatalogIndex
    var building: BuildingSummary

    @AppStorage("rooms.buildingRoomOrder") private var ordersByNumber = false
    @State private var classDates: RoomAvailability.ClassDates?

    var body: some View {
        TimelineView(.everyMinute) { context in
            roomList(now: context.date)
        }
        .navigationTitle(building.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Order Rooms By", selection: $ordersByNumber) {
                        Text("Availability").tag(false)
                        Text("Room Number").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                }
            }
        }
        .roomsClassDates($classDates, in: index)
    }

    private var subtitle: String {
        let campus = index.roomsCampusName(forCode: building.campusCode)
        let count = "\(building.rooms.count) \(building.rooms.count == 1 ? "room" : "rooms")"
        return [building.code, campus, count].compactMap { $0 }.joined(separator: " · ")
    }

    private func roomList(now: Date) -> some View {
        let moment = RoomAvailability.Moment(date: now)
        let item = RoomAvailability.availability(of: building, at: moment)

        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(RoomsText.freeSummary(free: item.freeCount, total: item.roomCount))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text("Right now · \(moment.label)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(RoomsText.disclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .combine)

                if let dates = classDates, !dates.contains(now) {
                    RoomsNotice(
                        systemImage: "calendar.badge.exclamationmark",
                        text: RoomsText.classDatesMessage(termName: index.term.shortName, dates: dates)
                    )
                }
                if !moment.isWithinClassHours {
                    RoomsNotice(systemImage: "moon.zzz.fill", text: RoomsText.outsideHours, tint: .indigo)
                }
            }

            if ordersByNumber {
                Section("Rooms") {
                    ForEach(byNumber(item)) { entry in
                        link(entry, moment: moment)
                    }
                }
            } else {
                if !item.free.isEmpty {
                    Section("Free Now") {
                        ForEach(item.free) { entry in
                            link(entry, moment: moment)
                        }
                    }
                }
                if !item.busy.isEmpty {
                    Section("In Use") {
                        ForEach(item.busy) { entry in
                            link(entry, moment: moment)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func byNumber(_ item: RoomAvailability.BuildingAvailability) -> [RoomAvailability.Entry] {
        (item.free + item.busy).sorted { $0.room.room.localizedStandardCompare($1.room.room) == .orderedAscending }
    }

    private func link(_ entry: RoomAvailability.Entry, moment: RoomAvailability.Moment) -> some View {
        NavigationLink(value: AppRoute.room(termCode: index.term.code, buildingCode: building.code, room: entry.room.room)) {
            RoomsRoomRow(entry: entry, moment: moment, showsBuildingCode: false)
        }
    }
}
