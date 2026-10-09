//
//  SectionDetailContent.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The scrolling body of the section page once the section has been found.
struct SectionDetailContent: View {
    var section: CourseSection
    var course: Course?
    var index: CatalogIndex
    var termCode: String
    /// Whether lazily loaded details (instructors, topic description) may still arrive.
    var isLoadingDetails: Bool
    var refreshFailed: Bool
    var onRetryDetails: () -> Void
    var onRefresh: () async -> Void

    @Environment(CatalogStore.self) private var catalog
    @Environment(AppRouter.self) private var router
    @Environment(UserDataStore.self) private var userData
    @State private var showsAllAttributes = false

    private static let attributeLimit = 8

    private var key: CourseKey { section.courseKey }

    private var displayTitle: String {
        if let course, !(course.specialTopics && !section.title.isEmpty) { return course.title }
        return section.title.isEmpty ? (course?.title ?? key.description) : section.title
    }

    private var lastUpdated: Date? {
        catalog.liveRefreshedAt[key] ?? index.catalog.sectionsUpdatedAt
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                    .padding(.horizontal, Theme.Spacing.l)
                SectionActionBar(section: section, course: course, term: index.term) { router.navigate(to: $0) }
                    .padding(.horizontal, Theme.Spacing.l)
                SectionSeatsSummary(
                    section: section,
                    lastUpdated: lastUpdated,
                    isRefreshing: catalog.refreshingCourses.contains(key),
                    refreshFailed: refreshFailed,
                    onRefresh: { Task { await onRefresh() } }
                )
                scheduleBlock
                instructorsBlock
                aboutBlock
                detailsBlock
                crossListedBlock
                attributesBlock
            }
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xl)
            .courseReadableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await onRefresh() }
        .courseLoadsEquivalents(for: namedCourses)
    }

    /// The course and the ones its prerequisites name: whether the user's completed courses count
    /// for them (the status line below the title) depends on equivalences the course store looks up.
    private var namedCourses: [CourseKey] {
        [key] + (course?.prereqs?.referencedCourses ?? [])
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            courseLink
            Text("Section \(section.sectionNumber) · \(section.classType)")
                .font(.headline)
                .foregroundStyle(.secondary)
            tags
            CourseCopyableCRN(crn: section.crn)
                .padding(.top, 2)
            if showsPrerequisiteStatus {
                CoursePrerequisiteStatusLine(prereqs: course?.prereqs)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the primary degree plan can say something about this course's
    /// prerequisites: a plan exists, and the course's requisites are loaded and non-empty.
    private var showsPrerequisiteStatus: Bool {
        guard let course, course.detailsLoaded, course.prereqs?.simplified() != nil else { return false }
        return userData.primaryDegreePlan != nil
    }

    @ViewBuilder
    private var courseLink: some View {
        let titleBlock = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(key.description)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.tint)
                if course != nil {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            Text(displayTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if course != nil {
            NavigationLink(value: AppRoute.course(termCode: termCode, key: key)) {
                titleBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(key.description), \(displayTitle)")
            .accessibilityHint("Opens the course page")
            .accessibilityAddTraits(.isLink)
        } else {
            titleBlock
        }
    }

    @ViewBuilder
    private var tags: some View {
        let hasTags = section.honors || !section.crossListCRNs.isEmpty || section.isOnline || index.term.isViewOnly
        if hasTags {
            CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                if section.honors {
                    TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
                }
                if !section.crossListCRNs.isEmpty {
                    TagLabel(text: "Cross-listed", systemImage: "link")
                }
                if section.isOnline {
                    TagLabel(text: "Online", systemImage: "wifi", tint: .blue)
                }
                if index.term.isViewOnly {
                    TagLabel(text: "View only term", systemImage: "lock.fill")
                }
            }
        }
    }

    // MARK: Schedule

    private var calendarEvents: [CalendarEvent] {
        CalendarEvent.events(for: section, color: CourseColor.forCourse(key), title: "Sec \(section.sectionNumber)")
    }

    private var scheduleBlock: some View {
        let events = calendarEvents
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Schedule")
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                CourseScheduleList(section: section, showsDates: true, roomTermCode: termCode)
                if !events.isEmpty {
                    WeekCalendarView(
                        events: events,
                        startHour: max(0, (events.map(\.start).min() ?? 0) / 60 - 1),
                        endHour: min(24, Int((Double(events.map(\.end).max() ?? 0) / 60).rounded(.up)) + 1),
                        hourHeight: 46
                    )
                }
                if let exam = section.courseFinalExamPattern {
                    Divider()
                    Label(finalExamText(exam), systemImage: "pencil.and.list.clipboard")
                        .font(.subheadline)
                        .labelStyle(CourseInfoLabelStyle())
                }
            }
            .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func finalExamText(_ exam: CourseMeetingPattern) -> String {
        var parts = ["Final exam"]
        if let date = CourseFormat.shortDate(exam.startDate) { parts.append(date) }
        if exam.start != nil { parts.append(exam.timeLabel) }
        parts.append(exam.locationLabel(long: true))
        return parts.joined(separator: " · ")
    }

    // MARK: Instructors

    private var instructorsBlock: some View {
        let instructors = section.courseSortedInstructors
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: (instructors?.count ?? 0) > 1 ? "Instructors" : "Instructor")
            VStack(alignment: .leading, spacing: 0) {
                if let instructors {
                    if instructors.isEmpty {
                        Label("To be announced", systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(instructors.enumerated()), id: \.element.name) { position, instructor in
                            if position > 0 { Divider() }
                            instructorRow(instructor)
                        }
                    }
                } else if isLoadingDetails {
                    HStack(spacing: Theme.Spacing.m) {
                        Circle()
                            .fill(.quaternary)
                            .frame(width: 40, height: 40)
                        Text("Instructor Name")
                            .font(.body.weight(.semibold))
                    }
                    .courseShimmer(isActive: true)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Label("Instructor information isn't available yet.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                        Button("Try Again", action: onRetryDetails)
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .font(.subheadline)
            .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func instructorRow(_ instructor: Instructor) -> some View {
        NavigationLink(value: AppRoute.professor(termCode: termCode, name: instructor.name)) {
            HStack(spacing: Theme.Spacing.m) {
                ProfessorMonogram(name: instructor.name, font: .subheadline.weight(.semibold), diameter: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(instructor.displayName)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    if let subtitle = instructorSubtitle(instructor) {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: Theme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(instructor.displayName)\(instructor.primary ? ", primary instructor" : "")")
        .accessibilityHint("Opens the instructor's page")
        .accessibilityAddTraits(.isLink)
    }

    private func instructorSubtitle(_ instructor: Instructor) -> String? {
        let parts = [instructor.primary ? "Primary instructor" : nil, instructor.email].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: About (special topics)

    @ViewBuilder
    private var aboutBlock: some View {
        if let course, course.specialTopics {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                CourseBlockHeader(title: "About this section")
                Group {
                    if let text = section.courseTopicDescription {
                        Text(text)
                            .font(.body)
                    } else if section.description == nil && isLoadingDetails {
                        Text("Loading the description for this special topics section from Northeastern.")
                            .font(.body)
                            .courseShimmer(isActive: true)
                    } else {
                        Text("No description available.")
                            .foregroundStyle(.secondary)
                    }
                }
                .courseCard()
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }

    // MARK: Details

    private var detailRows: [(title: String, value: String)] {
        var rows: [(String, String)] = [("Class type", section.classType)]
        if let campus = section.courseDisplayCampus { rows.append(("Campus", campus)) }
        if let method = section.courseInstructionLabel { rows.append(("Format", method)) }
        rows.append(("Part of term", partOfTermText))
        if let course { rows.append(("Credits", course.creditsLabel)) }
        return rows
    }

    private var partOfTermText: String {
        let code = section.partOfTerm.trimmingCharacters(in: .whitespaces)
        let range = CourseFormat.dateRange(
            start: section.meetings.compactMap(\.startDate).min(),
            end: section.meetings.compactMap(\.endDate).max()
        )
        let name = (code == "1" || code.isEmpty) ? "Full term" : code
        return [name, range].compactMap { $0 }.joined(separator: " · ")
    }

    private var detailsBlock: some View {
        let rows = detailRows
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Details")
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Array(rows.enumerated()), id: \.offset) { position, row in
                    if position > 0 { Divider() }
                    CourseKeyValueRow(title: row.title, value: row.value)
                }
            }
            .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    // MARK: Cross-listed sections

    @ViewBuilder
    private var crossListedBlock: some View {
        let crns = section.courseCrossListedCRNs
        if !crns.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                CourseBlockHeader(title: "Cross-listed sections")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(crns.enumerated()), id: \.element) { position, crn in
                        if position > 0 { Divider() }
                        crossListedRow(crn: crn)
                    }
                }
                .courseCard()
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }

    @ViewBuilder
    private func crossListedRow(crn: String) -> some View {
        if let other = index.section(crn: crn) {
            NavigationLink(value: AppRoute.section(termCode: termCode, crn: crn)) {
                HStack(alignment: .center, spacing: Theme.Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(other.courseKey.description) · Section \(other.sectionNumber)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(index.course(other.courseKey)?.title ?? other.title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Text("\(other.classType) · CRN \(other.crn)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    SeatsBadge(section: other)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Theme.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(other.courseKey.description) section \(other.sectionNumber), \(other.classType), \(other.courseSeatsSpoken)")
            .accessibilityHint("Opens the section")
            .accessibilityAddTraits(.isLink)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("CRN \(crn)")
                    .font(.subheadline.weight(.semibold))
                Text("Not in this term's catalog")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Attributes

    @ViewBuilder
    private var attributesBlock: some View {
        let nupaths = NUPath.from(attributeCodes: section.attributes)
        let nupathCodes = Set(nupaths.map(\.attributeCode))
        let others = section.courseUniqueAttributes.filter { !nupathCodes.contains($0) }
        if !nupaths.isEmpty || !others.isEmpty {
            let limited = !showsAllAttributes && others.count > Self.attributeLimit
            let visibleOthers = limited ? Array(others.prefix(Self.attributeLimit)) : others
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                CourseBlockHeader(title: "Attributes")
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    CourseFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(nupaths) { nupath in
                            NUPathChip(nupath: nupath, showsName: true)
                        }
                        ForEach(visibleOthers, id: \.self) { code in
                            TagLabel(text: index.attributeName(code))
                        }
                    }
                    if limited {
                        Button("Show all \(others.count + nupaths.count)") {
                            withAnimation(.snappy) { showsAllAttributes = true }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .courseCard()
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }
}
