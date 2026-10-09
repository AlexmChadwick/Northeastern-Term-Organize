//
//  MacScheduleGenerator.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Every conflict-free combination of a schedule's sections: the results on the left, as a list or,
/// when there is room, a grid of little weeks, and a week calendar of the selected one on the right,
/// in a pane the student resizes or closes. Star favorites, and apply one with "Use This Schedule".
/// Combinations are regenerated (debounced, off the main actor) whenever the filters, the preferences
/// ("your ideal week"), the sort order or the courses change.
struct MacScheduleGeneratorView: View {
    var planID: UUID
    var index: CatalogIndex?
    var indexLoadFinished: Bool
    /// The window's undo manager, so applying a schedule or loosening a rule can be undone with ⌘Z.
    var undoManager: UndoManager?
    var onEditPreferences: () -> Void
    /// Called after a combination was applied to the schedule.
    var onUse: () -> Void

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData

    @AppStorage("schedule.generator.sort") private var sortRaw = ScheduleSortOption.best.rawValue

    @State private var result: ScheduleGenerationResult?
    @State private var isGenerating = false
    @State private var noResults: ScheduleNoResults?
    /// The degree plan rearrangements found for the blocking courses; nil while they are being found.
    @State private var reorderResult: ScheduleReorderResult?
    @State private var toast: PlanToast?
    @State private var layout = ScheduleCarouselLayout()
    @State private var selectedID: String?
    @State private var showsFavoritesOnly = false
    /// The width of the results: a wide one shows them as a grid of little weeks, a narrow one as a list.
    @State private var resultsWidth: CGFloat = 400
    @FocusState private var gridHasFocus: Bool
    /// Whether the preview (the pane beside the results) is shown.
    @AppStorage("mac.generator.showsPreview") private var showsPreview = true

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var editor: MacSchedulePlanEditor {
        MacSchedulePlanEditor(userData: userData, planID: planID, undoManager: undoManager)
    }

    private var sort: ScheduleSortOption { ScheduleSortOption(rawValue: sortRaw) ?? .best }

    private var preferences: SchedulePreferences { plan?.preferences ?? SchedulePreferences() }

    /// Generating only matters to what is on screen when the generated results are on screen.
    private var isBusy: Bool { isGenerating && !showsFavoritesOnly }

    // MARK: Body

    var body: some View {
        Group {
            if let plan {
                content(plan)
            } else {
                ContentUnavailableView("Schedule not found", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .task(id: generationKey) { await regenerate() }
        .task(id: reorderKey) { await loadReorder() }
        .onChange(of: showsFavoritesOnly) { _, _ in resetPosition() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(ScheduleSortOption.allCases) { option in
                            Label(label(for: option), systemImage: option.symbol).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(shortLabel(for: sort), systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Sort order: \(label(for: sort))")
                Toggle(isOn: $showsFavoritesOnly) {
                    Label("Favorites", systemImage: showsFavoritesOnly ? "star.fill" : "star")
                }
                .help(showsFavoritesOnly ? "Show every schedule" : "Show only the schedules you starred")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showsPreview) {
                    Label("Preview", systemImage: "sidebar.trailing")
                }
                .help(showsPreview ? "Hide the preview" : "Show the selected schedule’s week")
            }
        }
        .planToast($toast)
    }

    @ViewBuilder
    private func content(_ plan: SchedulePlan) -> some View {
        if let index {
            let shown = displayedSchedules(plan: plan, index: index)
            if result == nil && !showsFavoritesOnly {
                ProgressView("Finding schedules…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                emptyState(plan: plan)
            } else {
                // Both sides fit in a half-screen window; a narrower one has the preview float over the results.
                MacSplitPane(
                    storageKey: "mac.split.generator",
                    paneEdge: .trailing,
                    defaultShare: 0.5,
                    paneMinWidth: 264,
                    primaryMinWidth: 290,
                    maxShare: 0.7,
                    isPaneShown: $showsPreview
                ) {
                    resultsPane(shown, plan: plan)
                } pane: {
                    previewPane(shown, plan: plan)
                }
                .focusedSceneValue(\.macSidePane, MacPaneToggle(title: "Preview", isShown: showsPreview) { showsPreview.toggle() })
            }
        } else if indexLoadFinished, catalog.loadState != .loading {
            ContentUnavailableView {
                Label("Course data unavailable", systemImage: "icloud.slash")
            } description: {
                Text("The catalog for this term isn’t on this device, so schedules can’t be generated.")
            }
        } else {
            ProgressView("Loading courses…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Sort labels

    /// "Best overall" becomes "Best match" once the student has said what they want.
    private func label(for option: ScheduleSortOption) -> String {
        option == .best && preferences.hasWishes ? "Best match" : option.label
    }

    private func shortLabel(for option: ScheduleSortOption) -> String {
        option == .best && preferences.hasWishes ? "Best match" : option.shortLabel
    }

    // MARK: Results

    /// Results wider than this are shown as a grid of little weeks instead of a list.
    private static let gridThreshold: CGFloat = 520
    private static let gridSpacing: CGFloat = 12
    private static let gridPadding: CGFloat = 14
    private static let gridCardWidth: CGFloat = 232

    private var usesGrid: Bool { resultsWidth >= Self.gridThreshold }

    private var gridColumnCount: Int {
        max(1, Int((resultsWidth - 2 * Self.gridPadding + Self.gridSpacing) / (Self.gridCardWidth + Self.gridSpacing)))
    }

    private func resultsPane(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        VStack(spacing: 0) {
            resultsHeader(schedules, plan: plan)
            Divider()
            if usesGrid {
                resultsGrid(schedules, plan: plan)
            } else {
                resultsList(schedules, plan: plan)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { resultsWidth = $0 }
    }

    private func resultsHeader(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summaryText(shownCount: schedules.count))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            Button(action: onEditPreferences) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.tint)
                    Text(preferences.hasWishes ? preferences.summary() : "Describe your ideal week")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Edit your ideal week")
            .accessibilityLabel("Your ideal week")
            .accessibilityValue(preferences.hasWishes ? preferences.summaryParts.joined(separator: ", ") : "Not set")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The combinations as rows: days, when it starts and ends, the gaps and the seats.
    private func resultsList(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selectedID) {
                ForEach(Array(schedules.enumerated()), id: \.element.id) { offset, schedule in
                    MacGeneratedScheduleRow(
                        schedule: schedule,
                        position: offset + 1,
                        isFavorite: plan.favoriteCombinations.contains(schedule.sortedCRNs),
                        showsMatch: preferences.hasWishes,
                        onToggleFavorite: { toggleFavorite(schedule) }
                    )
                    .tag(schedule.id)
                }
            }
            .listStyle(.inset)
            // A new set of schedules starts at the top, whatever the list was scrolled to.
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .opacity(isBusy ? 0.55 : 1)
            .animation(.snappy, value: isBusy)
            .contextMenu(forSelectionType: String.self) { ids in
                menu(for: ids, in: schedules, plan: plan)
            } primaryAction: { ids in
                if let id = ids.first, let schedule = schedules.first(where: { $0.id == id }) { use(schedule) }
            }
        }
    }

    /// The combinations as little weeks on a grid, all drawn to the same scale so they can be compared.
    /// Click to select (the preview follows), double-click or Return to use one, the arrow keys to
    /// move through them.
    private func resultsGrid(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.gridCardWidth, maximum: 360), spacing: Self.gridSpacing, alignment: .top)],
                    spacing: Self.gridSpacing
                ) {
                    ForEach(Array(schedules.enumerated()), id: \.element.id) { offset, schedule in
                        MacGeneratedScheduleCard(
                            schedule: schedule,
                            plan: plan,
                            layout: layout,
                            position: offset + 1,
                            isFavorite: plan.favoriteCombinations.contains(schedule.sortedCRNs),
                            isSelected: selectedID == schedule.id,
                            showsMatch: preferences.hasWishes,
                            onToggleFavorite: { toggleFavorite(schedule) }
                        )
                        .id(schedule.id)
                        .onTapGesture(count: 2) {
                            selectedID = schedule.id
                            use(schedule)
                        }
                        .onTapGesture {
                            gridHasFocus = true
                            selectedID = schedule.id
                        }
                        .contextMenu { menu(for: [schedule.id], in: schedules, plan: plan) }
                    }
                }
                .padding(Self.gridPadding)
            }
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .opacity(isBusy ? 0.55 : 1)
        .animation(.snappy, value: isBusy)
        .focusable()
        .focusEffectDisabled()
        .focused($gridHasFocus)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return]) { press in
            guard !schedules.isEmpty else { return .ignored }
            let current = schedules.firstIndex { $0.id == selectedID }
            if press.key == .return {
                guard let current else { return .ignored }
                use(schedules[current])
                return .handled
            }
            let step: Int
            switch press.key {
            case .leftArrow: step = -1
            case .rightArrow: step = 1
            case .upArrow: step = -gridColumnCount
            default: step = gridColumnCount
            }
            let start = current ?? (step > 0 ? -1 : schedules.count)
            selectedID = schedules[min(max(start + step, 0), schedules.count - 1)].id
            return .handled
        }
    }

    @ViewBuilder
    private func menu(for ids: Set<String>, in schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        if let id = ids.first, let schedule = schedules.first(where: { $0.id == id }) {
            Button("Use This Schedule", systemImage: "checkmark.circle") { use(schedule) }
            let isFavorite = plan.favoriteCombinations.contains(schedule.sortedCRNs)
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star") {
                toggleFavorite(schedule)
            }
            Divider()
            Button("Copy CRNs", systemImage: "doc.on.doc") { MacPasteboard.copy(schedule.crns.joined(separator: "\n")) }
        }
    }

    private func summaryText(shownCount: Int) -> String {
        if showsFavoritesOnly {
            return shownCount == 1 ? "1 favorite" : "\(shownCount) favorites"
        }
        guard let result else { return "Finding schedules…" }
        if result.totalFound == 0 { return "No schedules" }
        let total = result.totalFound.formatted()
        if !result.isTruncated {
            return result.totalFound == 1 ? "1 schedule" : "\(total) schedules"
        }
        let shown = result.schedules.count.formatted()
        if result.isExhaustive {
            return "Showing the best \(shown) of \(total) schedules"
        }
        return "Showing \(shown) of \(total)+ schedules"
    }

    // MARK: Preview

    private func previewPane(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        let current = schedules.first { $0.id == selectedID } ?? schedules[0]
        let position = (schedules.firstIndex(of: current) ?? 0) + 1
        return MacGeneratedSchedulePreview(
            schedule: current,
            plan: plan,
            layout: layout,
            position: position,
            total: schedules.count,
            isFavorite: plan.favoriteCombinations.contains(current.sortedCRNs),
            onToggleFavorite: { toggleFavorite(current) },
            onUse: { use(current) }
        )
        .id(current.id)
    }

    // MARK: Empty state

    @ViewBuilder
    private func emptyState(plan: SchedulePlan) -> some View {
        if showsFavoritesOnly {
            ContentUnavailableView {
                Label("No favorites yet", systemImage: "star")
            } description: {
                Text("Click the star on a schedule to keep it here, even after you change filters.")
            } actions: {
                Button("Show All Schedules") { showsFavoritesOnly = false }
            }
        } else if let result {
            MacScheduleNoResultsView(
                diagnostics: result.diagnostics,
                noResults: noResults,
                termName: index?.term.name ?? "this term",
                reorder: reorderState,
                onApply: { apply($0) },
                onMakeOptional: { makeOptional($0) },
                onApplyReorder: { applyReorder($0) }
            )
        }
    }

    // MARK: Data

    private func displayedSchedules(plan: SchedulePlan, index: CatalogIndex) -> [GeneratedSchedule] {
        guard showsFavoritesOnly else { return result?.schedules ?? [] }
        return GeneratedSchedule.favorites(of: plan, index: index, preferences: preferences)
    }

    private struct GenerationKey: Hashable {
        struct CourseSignature: Hashable {
            var key: CourseKey
            var isRequired: Bool
            var excluded: [String]
        }

        var termCode: String
        var courses: [CourseSignature]
        var filters: ScheduleFilters
        var preferences: SchedulePreferences
        var sort: ScheduleSortOption
        /// `CatalogStore.indexVersion`: changes with every sync, live refresh or term load.
        var dataVersion: Int
    }

    private var generationKey: GenerationKey? {
        // Nothing to generate until the plan's catalog is loaded.
        guard let plan, index != nil else { return nil }
        return GenerationKey(
            termCode: plan.termCode,
            courses: plan.courses.map { .init(key: $0.key, isRequired: $0.isRequired, excluded: $0.excludedCRNs.sorted()) },
            filters: plan.filters,
            preferences: plan.preferences ?? SchedulePreferences(),
            sort: sort,
            dataVersion: catalog.indexVersion
        )
    }

    private func regenerate() async {
        guard let plan, let index else { return }
        let courses = ScheduleCourseInput.inputs(for: plan, index: index)
        let filters = plan.filters
        let preferences = plan.preferences ?? SchedulePreferences()
        let sort = self.sort

        // Debounce rapid filter changes (the first run starts right away).
        if result != nil {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        isGenerating = true

        let work = Task.detached(priority: .userInitiated) {
            ScheduleGenerator.generate(courses: courses, filters: filters, preferences: preferences, sort: sort)
        }
        let output = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, !output.wasCancelled else { return }

        result = output
        noResults = nil
        isGenerating = false
        // Favorites don't depend on the generated results: leave the one being viewed alone.
        if !showsFavoritesOnly { resetPosition() }

        if output.schedules.isEmpty {
            let diagnostics = output.diagnostics
            // Without a complete search there is no telling which courses block.
            let isComplete = output.isExhaustive
            let helper = Task.detached(priority: .utility) {
                ScheduleGenerator.analyzeEmptyResult(
                    courses: courses, filters: filters, preferences: preferences,
                    diagnostics: diagnostics, includeBlockers: isComplete
                )
            }
            let analysis = await withTaskCancellationHandler {
                await helper.value
            } onCancel: {
                helper.cancel()
            }
            guard !Task.isCancelled else { return }
            noResults = analysis
        }
    }

    /// Starts again from the first schedule and refits the shared calendar grid.
    private func resetPosition() {
        guard let plan, let index else { return }
        let shown = displayedSchedules(plan: plan, index: index)
        selectedID = shown.first?.id
        layout = ScheduleCarouselLayout(schedules: shown, preferences: userData.preferences)
    }

    // MARK: Actions

    private func toggleFavorite(_ schedule: GeneratedSchedule) {
        guard let plan else { return }
        let isFavorite = plan.favoriteCombinations.contains(schedule.sortedCRNs)

        // Unstarring inside the favorites list removes the very row being viewed: pick its
        // neighbour first so the selection never points at one that is gone.
        var neighbour: String?
        var movesToNeighbour = false
        if showsFavoritesOnly, isFavorite, let index {
            let shown = displayedSchedules(plan: plan, index: index)
            if let i = shown.firstIndex(where: { $0.id == schedule.id }) {
                movesToNeighbour = true
                neighbour = i + 1 < shown.count ? shown[i + 1].id : (i > 0 ? shown[i - 1].id : nil)
            }
        }

        userData.updatePlan(id: planID) { PlanEditing.setFavorite(!isFavorite, sortedCRNs: schedule.sortedCRNs, in: &$0) }

        if movesToNeighbour, let plan = self.plan, let index {
            selectedID = neighbour
            layout = ScheduleCarouselLayout(schedules: displayedSchedules(plan: plan, index: index), preferences: userData.preferences)
        }
    }

    private func use(_ schedule: GeneratedSchedule) {
        editor.perform("Use Schedule") { $0.selectedCRNs = schedule.crns }
        onUse()
    }

    private func apply(_ relaxation: ScheduleRelaxation) {
        editor.perform("Loosen Rule", touching: [.courses, .filters, .preferences]) { PlanEditing.apply(relaxation, to: &$0) }
    }

    /// Lets the schedule work without courses that can't be combined: they stay in the schedule, but
    /// are only added when they fit.
    private func makeOptional(_ keys: [CourseKey]) {
        let wasRequired = keys.filter { plan?.course($0)?.isRequired == true }
        editor.perform("Make Optional") { PlanEditing.makeOptional(keys, in: &$0) }
        guard !wasRequired.isEmpty else { return }
        toast = .undoable(
            wasRequired.count == 1 ? "\(wasRequired[0]) is now optional" : "\(wasRequired.count) courses are now optional",
            systemImage: "circle.dashed", undoManager: undoManager
        )
    }

    // MARK: Rearranging the degree plan

    private struct ReorderKey: Hashable {
        var planID: UUID
        var termCode: String
        var degreePlanID: UUID
        var degreePlanUpdatedAt: Date
        var blocking: [CourseKey]
    }

    /// The semester of the primary degree plan that matches this schedule's term.
    private var degreePlanSemester: (plan: DegreePlan, term: Term)? {
        guard let plan else { return nil }
        return ScheduleReorderSuggestions.semester(for: plan, degreePlan: userData.primaryDegreePlan, terms: catalog.terms, index: index)
    }

    /// The courses whose removal would leave schedules: the ones worth moving to another semester.
    private var blockingCourses: [CourseKey] {
        Array((noResults?.blockers.allBlockingCourses ?? []).prefix(4))
    }

    /// Changes whenever there is a new set of blocking courses to find a way around.
    private var reorderKey: ReorderKey? {
        guard let plan, let semester = degreePlanSemester, !blockingCourses.isEmpty else { return nil }
        return ReorderKey(
            planID: plan.id, termCode: plan.termCode,
            degreePlanID: semester.plan.id, degreePlanUpdatedAt: semester.plan.updatedAt, blocking: blockingCourses
        )
    }

    private var reorderState: ScheduleReorderState {
        guard !blockingCourses.isEmpty else { return .unavailable(.notApplicable) }
        guard userData.primaryDegreePlan != nil else { return .unavailable(.noDegreePlan) }
        guard degreePlanSemester != nil else { return .unavailable(.notApplicable) }
        if let reorderResult { return .ready(reorderResult) }
        return .loading
    }

    /// Every catalog that is loaded, newest term first.
    private var loadedIndexes: [CatalogIndex] {
        var result = catalog.terms.compactMap { catalog.cachedIndex(for: $0.code) }
        if let index, !result.contains(where: { $0.term.code == index.term.code }) { result.append(index) }
        return result
    }

    private func loadReorder() async {
        reorderResult = nil
        guard let key = reorderKey, let semester = degreePlanSemester else { return }
        let loaded = await ScheduleReorderSuggestions.load(
            blocking: key.blocking, degreePlan: semester.plan, term: semester.term, indexes: loadedIndexes
        )
        guard !Task.isCancelled else { return }
        reorderResult = loaded
    }

    /// Applies a degree plan rearrangement. The courses it moves to another semester come out of this
    /// schedule, and the ones it brings into this semester are added when they are offered this term.
    /// "Undo" puts the degree plan and the schedule back as they were.
    private func applyReorder(_ option: ScheduleReorderOption) {
        switch ScheduleReorderApplication.apply(option, toPlan: planID, index: index, userData: userData) {
        case .stale:
            toast = PlanToast(text: "Your degree plan changed. Check the updated suggestions.", systemImage: "exclamationmark.circle")
        case .applied(let undo):
            toast = PlanToast(text: option.appliedText, systemImage: "checkmark.circle.fill", actionTitle: "Undo", action: { undo() })
        }
    }
}

// MARK: - Row

/// One combination in the list: its position, the days it uses, when it starts and ends, the gaps
/// and the seats, and a star when it is a favorite.
private struct MacGeneratedScheduleRow: View {
    var schedule: GeneratedSchedule
    var position: Int
    var isFavorite: Bool
    var showsMatch: Bool
    var onToggleFavorite: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                // The star shares the days' line, so the two lines below get the whole width.
                HStack(spacing: 8) {
                    ScheduleDayDots(days: dayDots, diameter: 16)
                    Spacer(minLength: 4)
                    favoriteButton
                }
                Text(ScheduleFormat.metricsLine(schedule))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(ScheduleFormat.detailLine(schedule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if showsMatch, !schedule.reasons.isEmpty {
                    reasonSummary
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule \(position). \(ScheduleFormat.metricsLine(schedule))")
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
    }

    private var reasonSummary: some View {
        MacWishSummary(schedule: schedule)
    }

    private var dayDots: DaySet {
        let campus = ScheduleFormat.campusDays(of: schedule.sections)
        return campus.isEmpty ? ScheduleFormat.classDays(of: schedule.sections) : campus
    }
}

// MARK: - Card

/// How many wishes a schedule meets, and how many it misses.
private struct MacWishSummary: View {
    var schedule: GeneratedSchedule

    var body: some View {
        let good = schedule.reasons.filter { !$0.isCaveat }.count
        let bad = schedule.reasons.filter(\.isCaveat).count
        HStack(spacing: 8) {
            if good > 0 {
                Label("\(good) \(good == 1 ? "wish" : "wishes") met", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if bad > 0 {
                Label("\(bad) not ideal", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}

/// One combination as a card on the results grid: its week as a thumbnail (drawn to the scale of
/// every other combination's), when it starts and ends, the gaps and the seats, and a star.
private struct MacGeneratedScheduleCard: View {
    var schedule: GeneratedSchedule
    var plan: SchedulePlan
    var layout: ScheduleCarouselLayout
    var position: Int
    var isFavorite: Bool
    var isSelected: Bool
    var showsMatch: Bool
    var onToggleFavorite: () -> Void

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let events = schedule.sections.flatMap { section in
            CalendarEvent.events(for: section, color: plan.course(section.courseKey).map { CourseColor.at($0.colorIndex) } ?? CourseColor.forCourse(section.courseKey))
        }
        VStack(alignment: .leading, spacing: 8) {
            MacMiniWeek(events: events, days: layout.days, hours: layout.hours)
                .aspectRatio(1.6, contentMode: .fit)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScheduleFormat.metricsLine(schedule))
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(ScheduleFormat.detailLine(schedule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showsMatch, !schedule.reasons.isEmpty {
                    MacWishSummary(schedule: schedule)
                }
                Spacer(minLength: 0)
                Text("#\(position)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .background {
            if isSelected {
                shape.fill(Color.accentColor.opacity(0.10))
            }
        }
        .overlay {
            shape.strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 0.5)
        }
        .shadow(color: .black.opacity(isHovered ? 0.14 : 0.04), radius: isHovered ? 6 : 2, y: 1)
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule \(position). \(ScheduleFormat.metricsLine(schedule))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Preview

/// One combination: its summary, the week calendar and a legend of its sections.
private struct MacGeneratedSchedulePreview: View {
    var schedule: GeneratedSchedule
    var plan: SchedulePlan
    var layout: ScheduleCarouselLayout
    var position: Int
    var total: Int
    var isFavorite: Bool
    var onToggleFavorite: () -> Void
    var onUse: () -> Void

    @Environment(UserDataStore.self) private var userData
    @Environment(\.openWindow) private var openWindow

    private func color(for key: CourseKey) -> CourseColor {
        plan.course(key).map { CourseColor.at($0.colorIndex) } ?? CourseColor.forCourse(key)
    }

    var body: some View {
        let events = schedule.sections.flatMap { CalendarEvent.events(for: $0, color: color(for: $0.courseKey)) }
        let hours = MacCalendarRange.hours(for: events, preferences: userData.preferences)
        let range = Self.merged(layout.hours, hours)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if !schedule.reasons.isEmpty {
                ScheduleReasonTags(reasons: schedule.reasons)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
            MacWeekCalendar(
                events: events,
                days: layout.days,
                hours: range,
                minHourHeight: 30,
                showsNowIndicator: false,
                extras: { event in
                    schedule.sections.first { $0.crn == event.payload }.map(MacCalendarBlockExtras.init(section:)) ?? MacCalendarBlockExtras()
                },
                popover: { event in
                    AnyView(sectionPopover(for: event))
                }
            )
            // The header and the legend keep their size; a short window shrinks the calendar down to this.
            .frame(minHeight: 140)
            Divider()
            legend
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule \(position) of \(total). \(ScheduleFormat.metricsLine(schedule))")
    }

    /// Both hour ranges, so the grid fits the schedule and keeps the other schedules' hours.
    private static func merged(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> ClosedRange<Int> {
        min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }

    private var header: some View {
        // Side by side while there is room; the buttons move under the text when there isn't.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                headerText
                Spacer(minLength: 8)
                favoriteButton
                useButton
            }
            VStack(alignment: .leading, spacing: 8) {
                headerText
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    favoriteButton
                    useButton
                }
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                positionLine("Schedule \(position.formatted()) of \(total.formatted())")
                positionLine("\(position.formatted()) of \(total.formatted())")
            }
            Text(ScheduleFormat.metricsLine(schedule))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(ScheduleFormat.detailLine(schedule))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    /// The days it uses and where it is in the list.
    private func positionLine(_ text: String) -> some View {
        HStack(spacing: 10) {
            ScheduleDayDots(days: dayDots, diameter: 20)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
    }

    private var useButton: some View {
        Button(action: onUse) {
            Label("Use This Schedule", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .help("Choose these sections for your schedule")
    }

    /// `Lecture 02`; `Online` or `Times TBA` for sections that are not on the calendar.
    private func legendDetail(for section: CourseSection) -> String {
        guard section.weeklyMeetings.isEmpty else { return ScheduleFormat.sectionTitle(section) }
        return section.isOnline ? "Online" : "Times TBA"
    }

    private var dayDots: DaySet {
        let campus = ScheduleFormat.campusDays(of: schedule.sections)
        return campus.isEmpty ? ScheduleFormat.classDays(of: schedule.sections) : campus
    }

    private var legend: some View {
        MacGeneratedLegend(entries: schedule.sections.map { section in
            .init(section: section, detail: legendDetail(for: section), color: color(for: section.courseKey))
        })
    }

    private func sectionPopover(for event: CalendarEvent) -> some View {
        Group {
            if let section = schedule.sections.first(where: { $0.crn == event.payload }) {
                MacGeneratedSectionPopover(section: section, termCode: plan.termCode, color: color(for: section.courseKey))
            }
        }
    }
}

/// The legend under a combination's calendar: each class with its section, CRN and seats. One line per
/// class while the pane is wide; the section and CRN move to a second line when it is not (for every
/// class at once, so the rows stay alike).
private struct MacGeneratedLegend: View {
    struct Entry: Identifiable {
        var section: CourseSection
        var detail: String
        var color: CourseColor
        var id: String { section.id }
    }

    var entries: [Entry]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            rows(twoLines: false)
            rows(twoLines: true)
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func rows(twoLines: Bool) -> some View {
        VStack(alignment: .leading, spacing: twoLines ? 8 : 6) {
            ForEach(entries) { entry in
                row(entry, twoLines: twoLines)
                    .padding(.leading, 12)
                    .background(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(entry.color.stroke)
                            .frame(width: 4)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(ScheduleFormat.fullLabel(entry.section)), \(ScheduleFormat.seatsText(entry.section))")
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: Entry, twoLines: Bool) -> some View {
        // Fixed sizes: an HStack offers its least flexible child an equal share, which would cut a badge
        // or a code short even when the whole row fits.
        let code = Text(entry.section.courseKey.description)
            .fontWeight(.semibold)
            .monospacedDigit()
            .fixedSize()
        let seats = SeatsBadge(section: entry.section).fixedSize()
        if twoLines {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    code
                    Spacer(minLength: 4)
                    seats
                }
                Text("\(entry.detail) · \(entry.section.crn)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        } else {
            HStack(spacing: 8) {
                code
                Text(entry.detail)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(entry.section.crn)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .fixedSize()
                seats
            }
        }
    }
}

/// The popover of a class in a generated schedule: its facts, the course window and the CRN.
private struct MacGeneratedSectionPopover: View {
    var section: CourseSection
    var termCode: String
    var color: CourseColor

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(color.stroke).frame(width: 9, height: 9)
                    Text(section.courseKey.description)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(color.text)
                }
                Text(section.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ScheduleFormat.sectionTitleWithCRN(section))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            MacSectionFacts(section: section)
            Divider()
            HStack(spacing: 8) {
                Button("View Course") {
                    openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: section.courseKey))
                }
                Button("Copy CRN") { MacPasteboard.copy(section.crn) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }
}
