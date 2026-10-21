//
//  ScheduleGeneratorView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Browse every conflict-free schedule for a plan as a swipeable carousel of
/// week calendars, star favorites, and apply one with "Use This Schedule".
/// Schedules are regenerated (debounced, off the main actor) whenever the
/// filters, preferences ("your ideal week"), sort order or courses change.
struct ScheduleGeneratorView: View {
    var planID: UUID

    @Environment(CatalogStore.self) private var catalog
    @Environment(UserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("schedule.generator.sort") private var sortRaw = ScheduleSortOption.best.rawValue

    @State private var loadedIndex: CatalogIndex?
    @State private var indexLoadFinished = false
    @State private var result: ScheduleGenerationResult?
    @State private var isGenerating = false
    @State private var generation = 0
    @State private var noResults: ScheduleNoResults?
    /// The degree plan rearrangements found for the blocking courses; nil while they are being found.
    @State private var reorderResult: ScheduleReorderResult?
    @State private var showsPreferences = false
    @State private var toast: PlanToast?
    @State private var layout = ScheduleCarouselLayout()
    @State private var currentID: String?
    @State private var showsFavoritesOnly = false
    @State private var showsFilters = false
    @State private var haptic = PlanHaptic()

    private var plan: SchedulePlan? { userData.plan(id: planID) }

    private var index: CatalogIndex? {
        guard let plan else { return nil }
        return catalog.planIndex(for: plan.termCode, fallback: loadedIndex)
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
        .loadPlanIndex(termCode: plan?.termCode, into: $loadedIndex, finished: $indexLoadFinished)
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(plan?.name ?? "")
        .task(id: generationKey) { await regenerate() }
        .task(id: reorderKey) { await loadReorder() }
        .onChange(of: showsFavoritesOnly) { _, _ in resetPosition() }
        .sheet(isPresented: $showsFilters) {
            if let plan {
                ScheduleFiltersSheet(planID: planID, campusNames: index?.campusNames ?? [], courseCount: plan.courses.count)
            }
        }
        .sheet(isPresented: $showsPreferences) {
            if let plan {
                SchedulePreferencesSheet(
                    planID: planID,
                    initial: plan.preferences ?? SchedulePreferences(),
                    context: SchedulePreferencesContext(plan: plan, index: index)
                )
            }
        }
        .planToast($toast)
        .planHaptic(haptic)
    }

    @ViewBuilder
    private func content(_ plan: SchedulePlan) -> some View {
        if let index {
            let shown = displayedSchedules(plan: plan, index: index)
            VStack(spacing: 0) {
                if result == nil && !showsFavoritesOnly {
                    ProgressView("Finding schedules…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    emptyState(plan: plan)
                } else {
                    carousel(shown, plan: plan)
                }
            }
            .background { Color(.systemGroupedBackground).ignoresSafeArea() }
            .safeAreaBar(edge: .top) { topBar(plan: plan, shownCount: shown.count) }
            .safeAreaBar(edge: .bottom) {
                if !shown.isEmpty { bottomBar(shown, plan: plan) }
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

    // MARK: Top bar

    private func topBar(plan: SchedulePlan, shownCount: Int) -> some View {
        VStack(spacing: 4) {
            GlassChipBar {
                GlassChip(
                    title: preferences.activeCount == 0 ? "Ideal week" : "Ideal week · \(preferences.activeCount)",
                    systemImage: "calendar.badge.clock",
                    isOn: preferences.hasWishes
                ) {
                    showsPreferences = true
                }
                .accessibilityLabel("Ideal week")
                .accessibilityValue(preferences.hasWishes ? "\(preferences.activeCount) wishes" : "Not set")

                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(ScheduleSortOption.allCases) { option in
                            Label(label(for: option), systemImage: option.symbol).tag(option.rawValue)
                        }
                    }
                } label: {
                    GlassChipLabel(title: shortLabel(for: sort), systemImage: "arrow.up.arrow.down", isOn: false, showsChevron: true)
                }
                .glassChipStyle(isOn: false)
                .accessibilityLabel("Sort order: \(label(for: sort))")

                GlassChip(
                    title: "Favorites",
                    systemImage: showsFavoritesOnly ? "star.fill" : "star",
                    isOn: showsFavoritesOnly
                ) {
                    showsFavoritesOnly.toggle()
                }

                GlassChip(
                    title: plan.filters.activeCount == 0 ? "Filters" : "Filters · \(plan.filters.activeCount)",
                    systemImage: "line.3.horizontal.decrease",
                    isOn: plan.filters.activeCount > 0
                ) {
                    showsFilters = true
                }
            }

            summaryLine(shownCount: shownCount)
                .padding(.horizontal, Theme.Spacing.l)

            if preferences.hasWishes {
                SchedulePreferencesSummaryRow(preferences: preferences) { showsPreferences = true }
                    .padding(.horizontal, Theme.Spacing.l)
            }
        }
        .padding(.bottom, 2)
    }

    /// "Best overall" becomes "Best match" once the student has said what they want.
    private func label(for option: ScheduleSortOption) -> String {
        option == .best && preferences.hasWishes ? "Best match" : option.label
    }

    private func shortLabel(for option: ScheduleSortOption) -> String {
        option == .best && preferences.hasWishes ? "Best match" : option.shortLabel
    }

    private func summaryLine(shownCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(summaryText(shownCount: shownCount))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.snappy, value: isBusy)
        .accessibilityElement(children: .combine)
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

    // MARK: Carousel

    private func carousel(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        GeometryReader { proxy in
            let margin = max(Theme.Spacing.l, (proxy.size.width - 680) / 2)
            let pageWidth = max(240, proxy.size.width - 2 * margin)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(schedules) { schedule in
                        SchedulePageView(
                            schedule: schedule,
                            plan: plan,
                            layout: layout,
                            height: max(260, proxy.size.height - 12),
                            isFavorite: plan.favoriteCombinations.contains(schedule.sortedCRNs),
                            position: (schedules.firstIndex(of: schedule) ?? 0) + 1,
                            total: schedules.count,
                            onToggleFavorite: { toggleFavorite(schedule) }
                        )
                        .frame(width: pageWidth)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $currentID)
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .padding(.top, 4)
            .id(generation)
            .opacity(isBusy ? 0.55 : 1)
            .animation(.snappy, value: isBusy)
        }
    }

    // MARK: Bottom bar

    private func bottomBar(_ schedules: [GeneratedSchedule], plan: SchedulePlan) -> some View {
        let currentIndex = schedules.firstIndex { $0.id == currentID } ?? 0
        let current = schedules[min(currentIndex, schedules.count - 1)]
        return GlassEffectContainer(spacing: 12) {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    Button {
                        step(-1, in: schedules)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(currentIndex == 0)
                    .accessibilityLabel("Previous schedule")

                    Text("\((currentIndex + 1).formatted()) of \(schedules.count.formatted())")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 96)
                        .accessibilityLabel("Schedule \(currentIndex + 1) of \(schedules.count)")

                    Button {
                        step(1, in: schedules)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(currentIndex >= schedules.count - 1)
                    .accessibilityLabel("Next schedule")
                }

                Button {
                    use(current)
                } label: {
                    Label("Use This Schedule", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
    }

    // MARK: Empty state

    @ViewBuilder
    private func emptyState(plan: SchedulePlan) -> some View {
        if showsFavoritesOnly {
            ContentUnavailableView {
                Label("No favorites yet", systemImage: "star")
            } description: {
                Text("Tap the star on a schedule to keep it here, even after you change filters.")
            } actions: {
                Button("Show All Schedules") { showsFavoritesOnly = false }
                    .buttonStyle(.glass)
            }
        } else if let result {
            ScheduleNoResultsView(
                diagnostics: result.diagnostics,
                noResults: noResults,
                termName: index?.term.name ?? "this term",
                reorder: reorderState,
                onApply: { apply($0, plan: plan) },
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
            var pinnedCRN: String?
        }

        var termCode: String
        var courses: [CourseSignature]
        /// Chosen sections. A change has to regenerate, or a pin would keep the old combinations.
        var pinnedCRNs: [String]
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
            courses: plan.courses.map { .init(key: $0.key, isRequired: $0.isRequired, excluded: $0.excludedCRNs.sorted(), pinnedCRN: $0.pinnedCRN) },
            pinnedCRNs: plan.selectedCRNs.sorted(),
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
            try? await Task.sleep(nanoseconds: 250_000_000)
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
        // Favorites don't depend on the generated results: leave the page being viewed alone.
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

    /// Starts again from the first page and refits the shared calendar grid.
    private func resetPosition() {
        generation += 1
        guard let plan, let index else { return }
        let shown = displayedSchedules(plan: plan, index: index)
        currentID = shown.first?.id
        layout = ScheduleCarouselLayout(schedules: shown, preferences: userData.preferences)
    }

    // MARK: Actions

    private func step(_ delta: Int, in schedules: [GeneratedSchedule]) {
        guard !schedules.isEmpty else { return }
        let current = schedules.firstIndex { $0.id == currentID } ?? 0
        let next = min(max(current + delta, 0), schedules.count - 1)
        if reduceMotion {
            currentID = schedules[next].id
        } else {
            withAnimation(.snappy) { currentID = schedules[next].id }
        }
    }

    private func toggleFavorite(_ schedule: GeneratedSchedule) {
        guard let plan else { return }
        let isFavorite = plan.favoriteCombinations.contains(schedule.sortedCRNs)

        // Unstarring inside the favorites list removes the very page being viewed:
        // pick its neighbour first so the carousel never points at a page that is gone.
        var movesToNeighbour = false
        var neighbour: String?
        if showsFavoritesOnly, isFavorite, let index {
            let shown = displayedSchedules(plan: plan, index: index)
            if let i = shown.firstIndex(where: { $0.id == schedule.id }) {
                movesToNeighbour = true
                neighbour = i + 1 < shown.count ? shown[i + 1].id : (i > 0 ? shown[i - 1].id : nil)
            }
        }

        userData.updatePlan(id: planID) { PlanEditing.setFavorite(!isFavorite, sortedCRNs: schedule.sortedCRNs, in: &$0) }
        haptic.fire(isFavorite ? .impact : .success)

        if movesToNeighbour, let plan = self.plan, let index {
            currentID = neighbour
            layout = ScheduleCarouselLayout(schedules: displayedSchedules(plan: plan, index: index), preferences: userData.preferences)
        }
    }

    private func use(_ schedule: GeneratedSchedule) {
        guard let index else { return }
        userData.updatePlan(id: planID) { PlanEditing.adoptGeneratedSchedule(schedule.crns, into: &$0, index: index) }
        haptic.fire(.success)
        dismiss()
    }

    private func apply(_ relaxation: ScheduleRelaxation, plan: SchedulePlan) {
        userData.updatePlan(id: planID) { PlanEditing.apply(relaxation, to: &$0) }
        haptic.fire(.selection)
    }

    /// Lets the schedule work without courses that can't be combined: they stay in the plan, but are
    /// only added when they fit.
    private func makeOptional(_ keys: [CourseKey]) {
        let wasRequired = keys.filter { plan?.course($0)?.isRequired == true }
        userData.updatePlan(id: planID) { PlanEditing.makeOptional(keys, in: &$0) }
        haptic.fire(.selection)
        guard !wasRequired.isEmpty else { return }
        toast = PlanToast(
            text: wasRequired.count == 1 ? "\(wasRequired[0]) is now optional" : "\(wasRequired.count) courses are now optional",
            systemImage: "circle.dashed",
            actionTitle: "Undo",
            action: {
                userData.updatePlan(id: planID) { plan in
                    for key in wasRequired { PlanEditing.setRequired(true, for: key, in: &plan) }
                }
            }
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
            haptic.fire(.warning)
            toast = PlanToast(text: "Your degree plan changed. Check the updated suggestions.", systemImage: "exclamationmark.circle")
        case .applied(let undo):
            haptic.fire(.success)
            toast = PlanToast(
                text: option.appliedText,
                systemImage: "checkmark.circle.fill",
                actionTitle: "Undo",
                action: { undo() }
            )
        }
    }
}

// MARK: - Page

/// One generated schedule: summary, week calendar and a legend of its sections.
private struct SchedulePageView: View {
    var schedule: GeneratedSchedule
    var plan: SchedulePlan
    var layout: ScheduleCarouselLayout
    var height: CGFloat
    var isFavorite: Bool
    var position: Int
    var total: Int
    var onToggleFavorite: () -> Void

    @ScaledMetric(relativeTo: .caption) private var dayHeaderHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var legendRowHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var headerHeight: CGFloat = 66
    @ScaledMetric(relativeTo: .caption) private var tagLineHeight: CGFloat = 26
    /// The tags wrap, so their height is measured once they are laid out.
    @State private var measuredTagsHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func color(for key: CourseKey) -> CourseColor {
        plan.course(key).map { CourseColor.at($0.colorIndex) } ?? CourseColor.forCourse(key)
    }

    var body: some View {
        let events = schedule.sections.flatMap { CalendarEvent.events(for: $0, color: color(for: $0.courseKey)) }
        let legendHeight = CGFloat(schedule.sections.count) * (legendRowHeight + 4)
        let hasTags = !schedule.reasons.isEmpty
        let tagsHeight = hasTags ? (measuredTagsHeight ?? tagLineHeight) : 0
        // Card padding (28), the gaps between the blocks (10 each), header, tags, day-name row, legend.
        let chrome = 28 + (hasTags ? 30 : 20) + headerHeight + tagsHeight + dayHeaderHeight + legendHeight
        let range = PlanCalendarSupport.hourRange(events: events, startHour: layout.hours.lowerBound, endHour: layout.hours.upperBound, compact: false)
        let gridHeight = max(168, height - chrome)

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if hasTags {
                    ScheduleReasonTags(reasons: schedule.reasons)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredTagsHeight = $0 }
                }
                WeekCalendarView(
                    events: events,
                    days: layout.days,
                    startHour: layout.hours.lowerBound,
                    endHour: layout.hours.upperBound,
                    hourHeight: PlanCalendarSupport.hourHeight(fitting: gridHeight, range: range),
                    showsNowIndicator: false
                )
                legend
            }
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(height: height)
        .cardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule \(position) of \(total). \(ScheduleFormat.metricsLine(schedule))")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                ScheduleDayDots(days: dayDots)
                Text(ScheduleFormat.metricsLine(schedule))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(ScheduleFormat.detailLine(schedule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: reduceMotion ? false : isFavorite)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        }
        .frame(minHeight: headerHeight - 4, alignment: .center)
    }

    /// `Lecture 02`; `Online` or `Times TBA` for sections that are not on the calendar
    /// (the CRN already identifies the section).
    private func legendDetail(for section: CourseSection) -> String {
        guard section.weeklyMeetings.isEmpty else { return ScheduleFormat.sectionTitle(section) }
        return section.isOnline ? "Online" : "Times TBA"
    }

    private var dayDots: DaySet {
        let campus = ScheduleFormat.campusDays(of: schedule.sections)
        return campus.isEmpty ? ScheduleFormat.classDays(of: schedule.sections) : campus
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(schedule.sections) { section in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: section.courseKey).stroke)
                        .frame(width: 4, height: 16)
                    Text(section.courseKey.description)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                    Text(legendDetail(for: section))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(section.crn)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    SeatsBadge(section: section)
                }
                .frame(minHeight: legendRowHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(ScheduleFormat.fullLabel(section)), \(ScheduleFormat.seatsText(section))")
            }
        }
    }
}
