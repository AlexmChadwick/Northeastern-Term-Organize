//
//  MacWatchlistView.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Seat alerts are a feature of SearchNEU (https://github.com/sandboxnu/searchneu), which
//  texts people. This screen is new: it lists the watched sections the way the iPhone app does
//  and checks them with the same engine (`WatchlistService`), on the Mac while the app runs.
//

import AppKit
import SwiftUI
import UserNotifications

/// Watched sections and their seats: a sortable table with what the registrar lists for each
/// section (instructor, times) and how its seats looked at the last check.
struct MacWatchlistView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(MacNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    /// Whether sections of other terms than the selected one are listed too.
    @AppStorage("mac.watchlist.allTerms") private var showsAllTerms = false
    // Snapshot runs keep the columns in state: they must neither read nor write the app's defaults.
    @AppStorage("mac.watchlist.columns") private var storedColumns = TableColumnCustomization<MacWatchRow>()
    @State private var snapshotColumns = TableColumnCustomization<MacWatchRow>()
    @State private var selection: Set<MacWatchRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\MacWatchRow.courseKey)]
    @State private var pendingStop: Set<MacWatchRow.ID> = []
    @State private var confirmsStopping = false
    /// The current time, for "Checked 4 min ago". A ticker in state rather than a `TimelineView`.
    @State private var now = MacShellClock.now
    /// The width this screen has, to tell a window with room for the pane from a narrow one.
    @State private var areaWidth: CGFloat = 1_000
    /// The width of the table's area (what the pane leaves it), nil until it is measured.
    @State private var tableWidth: CGFloat?
    /// The columns the table was made with. It follows the width, but only once the width has held still.
    @State private var settledTier: ColumnTier?
    /// Whether the pane floats over the table of a narrow window (it is closed there until asked for).
    @State private var floatsDetails = false
    // Snapshot runs keep the pane in state: they must neither read nor write the app's defaults.
    @AppStorage("mac.watchlist.showsDetails") private var storedShowsDetails = true
    @State private var snapshotShowsDetails = true

    /// Shows a given notification permission instead of the real one (snapshots only).
    var previewStatus: UNAuthorizationStatus?

    private let service = WatchlistService.shared

    init(previewStatus: UNAuthorizationStatus? = nil) {
        self.previewStatus = previewStatus
    }

    var body: some View {
        Group {
            if userData.watchlist.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("Watchlist")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .focusedSceneValue(\.macSidePane, rows.isEmpty ? nil : MacPaneToggle(title: "Section Details", isShown: detailsShown, toggle: toggleDetails))
        .focusedSceneValue(\.macReload, MacMenuAction(title: "Check Seats Now", perform: checkNow))
        .focusedSceneValue(\.macPrint, rows.isEmpty ? nil : MacMenuAction(title: "Print Watchlist…", perform: printWatchlist))
        .focusedSceneValue(\.macDelete, selection.isEmpty ? nil : MacMenuAction(title: stopTitle) { requestStop(selection) })
        .confirmationDialog(
            "Stop watching \(pendingStop.count) sections?",
            isPresented: $confirmsStopping,
            titleVisibility: .visible
        ) {
            Button("Stop Watching", role: .destructive) { stopWatching(pendingStop) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't be notified about open seats in them anymore. You can watch them again from their course windows.")
        }
        .task { await prepare() }
        .task { await MacShellClock.everyMinute { now = $0 } }
        .task { preselectForSnapshot() }
    }

    // MARK: Content

    private var emptyState: some View {
        MacWatchlistEmptyState { navigator.selection = .search }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if showsPermissionBanner {
                MacWatchlistPermissionBanner(
                    status: status,
                    requestAction: { Task { await service.requestAuthorization() } },
                    openSettingsAction: MacSystemSettings.openNotifications
                )
            }
            if let error = service.lastError {
                MacWatchlistErrorBanner(message: error)
            }
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Watched in \(catalog.selectedTerm?.shortName ?? "This Term")", systemImage: "bell")
                } description: {
                    Text("Your watched sections are in other terms, and they are still checked.")
                } actions: {
                    Button("Show All Terms") {
                        showsAllTerms = true
                    }
                }
            } else {
                MacSplitPane(
                    storageKey: "mac.split.watchlist", paneEdge: .trailing, defaultShare: 0.3,
                    paneMinWidth: 300, primaryMinWidth: 380, maxShare: 0.5, isPaneShown: detailsBinding
                ) {
                    tableArea
                } pane: {
                    detailPane
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { areaWidth = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
    }

    // MARK: Detail pane

    private var detailPane: some View {
        MacWatchlistDetail(
            rows: selectedRows(selection),
            allRows: sortedRows,
            preferredTermCode: catalog.selectedTermCode,
            showsWeekends: userData.preferences.showWeekends,
            course: { row in catalog.cachedIndex(for: row.item.termCode)?.course(row.courseKey) },
            now: now,
            notifiesOnWaitlist: waitlistBinding(for: selection),
            onOpen: { openCourses(selection) },
            onCopy: { copyCRNs(selection) },
            onStop: { requestStop(selection) },
            onSelect: { selection = [$0] }
        )
    }

    private var isNarrow: Bool { areaWidth < 700 }

    private var showsDetails: Bool {
        get { MacShellRun.isSnapshot ? snapshotShowsDetails : storedShowsDetails }
        nonmutating set {
            if MacShellRun.isSnapshot { snapshotShowsDetails = newValue } else { storedShowsDetails = newValue }
        }
    }

    /// Whether the pane is open: as the user left it in a window with room for it, and, in a narrow
    /// one, only when they asked (then it floats over the table).
    private var detailsShown: Bool { isNarrow ? floatsDetails : showsDetails }

    private var detailsBinding: Binding<Bool> {
        Binding(get: { detailsShown }, set: { setDetails($0) })
    }

    private func setDetails(_ shown: Bool) {
        if isNarrow { floatsDetails = shown } else { showsDetails = shown }
    }

    private func toggleDetails() { setDetails(!detailsShown) }

    /// The table, made once there is a width to measure: which columns it has depends on the room it gets.
    private var tableArea: some View {
        ZStack {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured($0) }
            if let tier = settledTier {
                table(tier)
            }
        }
        .task(id: measuredTier) { await settleTier() }
    }

    private func measured(_ width: CGFloat) {
        tableWidth = width
        // The first table is made right away; later changes of columns wait for the width to settle.
        if settledTier == nil { settledTier = Self.tier(forWidth: width) }
    }

    private var measuredTier: ColumnTier? {
        tableWidth.map { Self.tier(forWidth: $0) }
    }

    /// A table made while the window is still changing size comes out with its columns sized for the
    /// wrong width (the last ones run out of room), and one that only gains or loses columns keeps the
    /// widths it had. So a new set of columns waits for the width to hold still, then starts a new table.
    private func settleTier() async {
        guard let measuredTier, measuredTier != settledTier else { return }
        // A snapshot has no window being dragged, and takes its picture a moment after resizing.
        if !MacShellRun.isSnapshot {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        settledTier = measuredTier
    }

    private func table(_ tier: ColumnTier) -> some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder, columnCustomization: columnsBinding(for: tier)) {
            identityColumns
            statusColumns
            optionalColumns
        }
        .id(tier)
        .macFitsTableColumns(when: tier)
        .contextMenu(forSelectionType: MacWatchRow.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            openCourses(ids)
        }
        .onDeleteCommand { requestStop(selection) }
        // Return opens the selected sections' courses, like a double-click (opening one that is
        // already open only brings its window forward).
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            openCourses(selection)
            return .handled
        }
        .copyable(selection.isEmpty ? [] : [selectedCRNs.joined(separator: "\n")])
    }

    /// The columns, in three parts so the compiler can check each: which section it is and when it meets,
    /// where it meets and how many seats it has, and the ones that are off unless asked for.
    @TableColumnBuilder<MacWatchRow, KeyPathComparator<MacWatchRow>>
    private var identityColumns: some TableColumnContent<MacWatchRow, KeyPathComparator<MacWatchRow>> {
        TableColumn("Course", value: \.courseKey) { row in
            HStack(spacing: 6) {
                Text(row.courseKey.description)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                Text(row.item.courseTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("\(row.courseKey.description) \(row.item.courseTitle)")
        }
        .width(min: 100, ideal: 240)
        .customizationID("course")

        TableColumn("Section", value: \.sectionLabel) { row in
            Text(row.sectionName)
                .lineLimit(1)
        }
        .width(min: 76, ideal: 80, max: 96)
        .customizationID("section")

        TableColumn("CRN", value: \.crn) { row in
            Text(row.crn)
                .monospacedDigit()
        }
        .width(min: 52, ideal: 56, max: 72)
        .customizationID("crn")

        TableColumn("Instructor", value: \.instructor) { row in
            Text(row.instructor)
                .foregroundStyle(row.section?.instructors == nil ? .tertiary : .primary)
                .lineLimit(1)
                .help(row.instructor)
        }
        .width(min: 130, ideal: 150, max: 200)
        .customizationID("instructor")

        TableColumn("Times", value: \.times) { row in
            Text(row.times)
                .monospacedDigit()
                .lineLimit(1)
                .help(row.times)
        }
        .width(min: 140, ideal: 160, max: 210)
        .customizationID("times")
    }

    @TableColumnBuilder<MacWatchRow, KeyPathComparator<MacWatchRow>>
    private var statusColumns: some TableColumnContent<MacWatchRow, KeyPathComparator<MacWatchRow>> {
        TableColumn("Location", value: \.location) { row in
            Text(row.location)
                .foregroundStyle(row.section == nil ? .tertiary : .primary)
                .lineLimit(1)
                .help(row.longLocation)
        }
        .width(min: 70, ideal: 100, max: 140)
        .customizationID("location")

        TableColumn("Seats", value: \.seatsRank) { row in
            Label {
                Text(row.status.detail(for: row.item))
                    .monospacedDigit()
            } icon: {
                Image(systemName: row.status.symbol)
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(row.status.color)
            .lineLimit(1)
            .help(row.status.detail(for: row.item))
        }
        .width(min: 185, ideal: 190, max: 230)
        .customizationID("seats")

        TableColumn("Checked", value: \.checkedAt) { row in
            if let date = row.item.lastCheckedAt {
                Text(WatchlistFormat.ago(date, now: now))
                    .foregroundStyle(.secondary)
            } else {
                Text("Not yet")
                    .foregroundStyle(.tertiary)
            }
        }
        .width(min: 70, ideal: 84, max: 110)
        .customizationID("checked")
    }

    /// Off unless asked for, from the table's column menu.
    @TableColumnBuilder<MacWatchRow, KeyPathComparator<MacWatchRow>>
    private var optionalColumns: some TableColumnContent<MacWatchRow, KeyPathComparator<MacWatchRow>> {
        TableColumn("Last Opened", value: \.lastOpening) { row in
            if let date = row.item.lastNotifiedAt {
                Text(WatchlistFormat.ago(date, now: now))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .width(min: 80, ideal: 92)
        .customizationID("lastOpening")
        .defaultVisibility(.hidden)

        TableColumn("Alerts", value: \.alertsRank) { row in
            Text(row.item.notifyOnWaitlist ? "Seats and waitlist" : "Seats")
                .foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 110)
        .customizationID("alerts")
        .defaultVisibility(.hidden)

        TableColumn("Term", value: \.termName) { row in
            Text(row.termName)
                .foregroundStyle(.secondary)
        }
        .width(min: 60, ideal: 90)
        .customizationID("term")
        .defaultVisibility(.hidden)
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<MacWatchRow.ID>) -> some View {
        if !ids.isEmpty {
            Button("Open Course Window") { openCourses(ids) }
            Button(ids.count == 1 ? "Copy CRN" : "Copy CRNs") { copyCRNs(ids) }
            Divider()
            Toggle(isOn: waitlistBinding(for: ids)) {
                Text("Notify for Waitlist Spots")
            }
            Divider()
            Button(ids.count == 1 ? "Stop Watching" : "Stop Watching \(ids.count) Sections", role: .destructive) {
                requestStop(ids)
            }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if service.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Checking seats…")
            } else {
                Text(summary)
            }
            Spacer()
            Text(checkedSummary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// `5 sections · 2 open`.
    private var summary: String {
        let all = rows
        let open = all.filter { $0.status == .open }.count
        let sections = "\(all.count) \(all.count == 1 ? "section" : "sections")"
        return open > 0 ? "\(sections) · \(open) open" : sections
    }

    private var checkedSummary: String {
        let interval = "Checks every \(MacWatchlistMonitor.minutes) min while Term Organize is open"
        guard let date = lastChecked else { return interval }
        return "Checked \(WatchlistFormat.ago(date, now: now)) · \(interval)"
    }

    private var lastChecked: Date? {
        service.lastRefresh ?? rows.compactMap(\.item.lastCheckedAt).max()
    }

    private var subtitle: String {
        guard !userData.watchlist.isEmpty else { return "" }
        let open = userData.watchlist.filter { $0.lastSeatsRemaining > 0 && !service.missingItemIDs.contains($0.id) }.count
        let watching = "\(userData.watchlist.count) \(userData.watchlist.count == 1 ? "section" : "sections")"
        return open > 0 ? "\(watching) · \(open) open" : watching
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if hasOtherTerms {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $showsAllTerms) {
                    Text(catalog.selectedTerm?.shortName ?? "This Term").tag(false)
                    Text("All Terms").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Show the watched sections of this term, or of every term")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                requestStop(selection)
            } label: {
                Label("Stop Watching", systemImage: "bell.slash")
            }
            .disabled(selection.isEmpty)
            .help("Stop watching the selected sections (⌘⌫)")

            Button(action: checkNow) {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .disabled(service.isRefreshing || userData.watchlist.isEmpty)
            .help("Check seats now (⌘R)")

            Button(action: toggleDetails) {
                Label("Section Details", systemImage: "sidebar.trailing")
            }
            .disabled(rows.isEmpty)
            .help("Show or hide the details of the selected section (⌥⌘0)")
        }
    }

    // MARK: Rows

    /// Every term's sections when the user asked for them or there are no others, otherwise the
    /// selected term's.
    private var rows: [MacWatchRow] {
        let selected = catalog.selectedTermCode
        return userData.watchlist
            .filter { showsAllTerms || selected == nil || $0.termCode == selected }
            .map { item in
                MacWatchRow(
                    item: item,
                    section: catalog.cachedIndex(for: item.termCode)?.section(crn: item.crn),
                    status: WatchlistStatus(item: item, isMissing: service.missingItemIDs.contains(item.id)),
                    termName: termName(for: item.termCode)
                )
            }
    }

    /// Which columns a table of this width has room for.
    private enum ColumnTier: Hashable {
        /// Course, CRN, times and seats.
        case compact
        /// Adds the section and the instructor.
        case regular
        /// Adds where it meets and when it was checked.
        case wide

        /// What the tier leaves out of the user's columns, without changing what is remembered.
        var dropped: [String] {
            switch self {
            case .compact: ["section", "instructor", "location", "checked"]
            case .regular: ["location", "checked"]
            case .wide: []
            }
        }
    }

    private static func tier(forWidth width: CGFloat) -> ColumnTier {
        if width < compactTableWidth { return .compact }
        return width < wideTableWidth ? .regular : .wide
    }

    /// The table's columns as the user left them, except those its width has no room for.
    private func columnsBinding(for tier: ColumnTier) -> Binding<TableColumnCustomization<MacWatchRow>> {
        let base = MacShellRun.isSnapshot ? $snapshotColumns : $storedColumns
        let dropped = tier.dropped
        return Binding(
            get: {
                var columns = base.wrappedValue
                for id in dropped { columns[visibility: id] = .hidden }
                return columns
            },
            set: { newValue in
                var columns = newValue
                for id in dropped { columns[visibility: id] = base.wrappedValue[visibility: id] }
                base.wrappedValue = columns
            }
        )
    }

    /// Below this width the table drops its section and instructor columns. (The columns' minimum widths
    /// add up to 480 points for the four of them, with what the table puts between columns 560; for six
    /// columns 800.)
    private static let compactTableWidth: CGFloat = 800
    /// From this width on the table also shows where each section meets and when it was last checked
    /// (eight columns need 975 points at the least).
    private static let wideTableWidth: CGFloat = 1_000

    /// The chosen order, then the lecture before its labs and recitations, so equal rows keep a stable order.
    private var sortedRows: [MacWatchRow] {
        rows.sorted(using: sortOrder + [
            KeyPathComparator(\MacWatchRow.sectionOrder),
            KeyPathComparator(\MacWatchRow.sectionLabel, comparator: .localizedStandard),
            KeyPathComparator(\MacWatchRow.crn),
        ])
    }

    private var hasOtherTerms: Bool {
        guard let selected = catalog.selectedTermCode else { return false }
        return userData.watchlist.contains { $0.termCode != selected }
    }

    private func termName(for code: String) -> String {
        if let term = catalog.terms.first(where: { $0.code == code }) { return term.shortName }
        if let term = catalog.index?.term, term.code == code { return term.shortName }
        return "Term \(code)"
    }

    private func selectedRows(_ ids: Set<MacWatchRow.ID>) -> [MacWatchRow] {
        sortedRows.filter { ids.contains($0.id) }
    }

    private var selectedCRNs: [String] {
        selectedRows(selection).map(\.crn)
    }

    // MARK: Permission

    private var status: UNAuthorizationStatus { previewStatus ?? service.authorizationStatus }

    private var showsPermissionBanner: Bool {
        guard previewStatus != nil || service.hasLoadedAuthorization else { return false }
        return status == .notDetermined || status == .denied
    }

    // MARK: Actions

    private var stopTitle: String {
        selection.count > 1 ? "Stop Watching \(selection.count) Sections" : "Stop Watching"
    }

    private func checkNow() {
        Task { await service.refresh(force: true) }
    }

    /// File › Print…: the sections on screen, in the order on screen.
    private func printWatchlist() {
        let scope = showsAllTerms && hasOtherTerms ? "All Terms" : (catalog.selectedTerm?.name ?? "Watchlist")
        let checked = lastChecked.map { "checked \(WatchlistFormat.ago($0, now: now))" } ?? "not checked yet"
        MacWatchlistPrinter.printRows(sortedRows, termName: scope, checked: checked)
    }

    /// Opens each course once, even when several of its sections are selected.
    private func openCourses(_ ids: Set<MacWatchRow.ID>) {
        var opened = Set<String>()
        for row in selectedRows(ids) where opened.insert("\(row.item.termCode)|\(row.courseKey)").inserted {
            openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: row.item.termCode, key: row.courseKey))
        }
    }

    private func copyCRNs(_ ids: Set<MacWatchRow.ID>) {
        MacShellPasteboard.copy(selectedRows(ids).map(\.crn).joined(separator: "\n"))
    }

    /// Asks before stopping several sections at once; a single one is easy to watch again.
    private func requestStop(_ ids: Set<MacWatchRow.ID>) {
        guard !ids.isEmpty else { return }
        if ids.count > 1 {
            pendingStop = ids
            confirmsStopping = true
        } else {
            stopWatching(ids)
        }
    }

    private func stopWatching(_ ids: Set<MacWatchRow.ID>) {
        let items = userData.watchlist.filter { ids.contains($0.id) }
        withAnimation {
            for item in items { userData.unwatch(crn: item.crn, termCode: item.termCode) }
        }
        selection.subtract(ids)
    }

    private func waitlistBinding(for ids: Set<MacWatchRow.ID>) -> Binding<Bool> {
        Binding(
            get: {
                let items = userData.watchlist.filter { ids.contains($0.id) }
                return !items.isEmpty && items.allSatisfy(\.notifyOnWaitlist)
            },
            set: { isOn in
                // Start from the stored items: a check may have updated their numbers since the table was drawn.
                for var item in userData.watchlist where ids.contains(item.id) {
                    item.notifyOnWaitlist = isOn
                    userData.updateWatchItem(item)
                }
            }
        )
    }

    /// Debug snapshots can select sections (`-MacSnapshotWatchRow 2`, or `all`), float the pane over a
    /// narrow window (`-MacSnapshotWatchPane float`) and close it (`-MacSnapshotHidePanes YES`).
    private func preselectForSnapshot() {
        #if DEBUG
        guard MacShellRun.isSnapshot else { return }
        let defaults = UserDefaults.standard
        let ordered = sortedRows
        if defaults.string(forKey: "MacSnapshotWatchRow") == "all" {
            selection = Set(ordered.map(\.id))
        } else if defaults.object(forKey: "MacSnapshotWatchRow") != nil {
            let position = defaults.integer(forKey: "MacSnapshotWatchRow")
            if ordered.indices.contains(position) { selection = [ordered[position].id] }
        }
        if defaults.string(forKey: "MacSnapshotWatchPane") == "float" { floatsDetails = true }
        if defaults.bool(forKey: "MacSnapshotHidePanes") { showsDetails = false }
        #endif
    }

    private func prepare() async {
        guard !MacShellRun.isSnapshot else { return }
        if !userData.watchlist.isEmpty {
            // The first time something is watched, ask once. Never at launch.
            await service.requestAuthorizationIfNeeded()
        } else {
            await service.refreshAuthorizationStatus()
        }
        await service.refreshIfStale()
    }
}

// MARK: - Rows

/// One watched section with what the table sorts and shows.
struct MacWatchRow: Identifiable {
    var item: WatchItem
    /// The section as the catalog lists it now (instructor, times); nil when it isn't loaded.
    var section: CourseSection?
    var status: WatchlistStatus
    var termName: String

    var id: String { item.id }
    var courseKey: CourseKey { item.courseKey }
    var sectionLabel: String { item.sectionLabel }
    /// `Lecture 02` for `Lecture · Section 02`, which is too long for a column.
    var sectionName: String { item.sectionLabel.replacingOccurrences(of: " · Section ", with: " ") }
    var crn: String { item.crn }

    var instructor: String {
        guard let section, section.instructors != nil else { return "—" }
        return section.instructorLabel
    }

    var times: String { section?.scheduleSummary ?? "—" }

    /// Where it meets (`SH 135`), `Online`, or a dash while the section isn't loaded.
    var location: String { places { $0.locationLabel } }
    /// The same with the building's name (`Shillman Hall 135`), for the tooltip.
    var longLocation: String { places { $0.longLocationLabel } }

    private func places(_ label: (Meeting) -> String) -> String {
        guard let section else { return "—" }
        let weekly = section.weeklyMeetings
        guard !weekly.isEmpty else { return section.isOnline ? "Online" : "—" }
        var seen = Set<String>()
        return weekly.map { $0.isOnline ? "Online" : label($0) }.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }

    /// Lectures first, then labs, recitations and the rest, as the iPhone's watchlist orders them.
    var sectionOrder: Int {
        if sectionLabel.hasPrefix("Lecture") { return 0 }
        if sectionLabel.hasPrefix("Lab") { return 1 }
        if sectionLabel.hasPrefix("Recitation") { return 2 }
        return 3
    }

    /// Open sections first, then waitlist, full, missing; more seats before fewer.
    var seatsRank: Int {
        let tier: Int
        switch status {
        case .open: tier = 3
        case .waitlist: tier = 2
        case .full: tier = 1
        case .missing: tier = 0
        }
        return tier * 100_000 + max(0, item.lastSeatsRemaining) * 100 + min(99, max(0, item.lastWaitlistRemaining))
    }

    var checkedAt: Date { item.lastCheckedAt ?? .distantPast }
    var lastOpening: Date { item.lastNotifiedAt ?? .distantPast }
    var alertsRank: Int { item.notifyOnWaitlist ? 1 : 0 }
}

// MARK: - Banners

/// A slim notice above the table asking for notification permission, or explaining how to turn
/// it back on.
private struct MacWatchlistPermissionBanner: View {
    var status: UNAuthorizationStatus
    var requestAction: () -> Void
    var openSettingsAction: () -> Void

    private var isDenied: Bool { status == .denied }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDenied ? "bell.slash.fill" : "bell.badge.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isDenied ? Color.red : Color.accentColor)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(isDenied ? "Notifications are turned off" : "Turn on notifications to get alerted when seats open")
                    .fontWeight(.semibold)
                Text(isDenied
                     ? "Term Organize can't tell you about open seats until notifications are allowed in System Settings."
                     : "Alerts are delivered on this Mac. No account or phone number needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(isDenied ? "Open Notification Settings…" : "Turn On Notifications") {
                (isDenied ? openSettingsAction : requestAction)()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Tells the user a check failed and that the table shows the last known numbers.
private struct MacWatchlistErrorBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Couldn't check seats")
                    .fontWeight(.semibold)
                Text(Self.detail(message))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    /// The error's own sentence followed by what the user is looking at instead.
    private static func detail(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Showing the last known numbers." }
        let sentence = ".!?".contains(last) ? trimmed : trimmed + "."
        return "\(sentence) Showing the last known numbers."
    }
}
