//
//  ProfessorContent.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The scrolling body of an instructor's page.
struct ProfessorContent: View {
    var summary: InstructorSummary
    var index: CatalogIndex
    var termCode: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppRouter.self) private var router
    @State private var showsAllSections = false

    private static let collapsedSectionCount = 8

    // MARK: Derived data

    /// Their sections, ordered by course and section number.
    private var sections: [CourseSection] {
        ProfessorPage.sections(of: summary, in: index)
    }

    private var courses: [Course] {
        summary.courseKeys.compactMap { index.course($0) }
    }

    /// A color per course, so the calendar and legend are never ambiguous.
    private var courseColors: [CourseKey: CourseColor] {
        ProfessorPage.courseColors(for: summary.courseKeys)
    }

    private var calendarEvents: [CalendarEvent] {
        let colors = courseColors
        return sections.flatMap { section in
            CalendarEvent.events(for: section, color: colors[section.courseKey] ?? CourseColor.forCourse(section.courseKey))
        }
    }

    /// `Teaches 6 sections across 3 courses`, counted from the sections that
    /// still exist (a live refresh can drop sections the directory remembers).
    private var summaryText: String {
        ProfessorPage.summaryText(for: sections)
    }

    private var ratemyprofessorsURL: URL? {
        ProfessorPage.rateMyProfessorsURL(for: summary.displayName)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                    .padding(.horizontal, Theme.Spacing.l)
                scheduleBlock
                coursesBlock
                sectionsBlock
                ratingsBlock
            }
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xl)
            .courseReadableWidth()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Header

    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Spacing.l))
        return layout {
            ProfessorMonogram(name: summary.name, diameter: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.displayName)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let email = summary.email, let url = URL(string: "mailto:\(email)") {
                    Link(destination: url) {
                        Label(email, systemImage: "envelope")
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                    }
                    .accessibilityLabel("Email \(summary.displayName)")
                    .accessibilityValue(email)
                }
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Weekly schedule

    private var scheduleBlock: some View {
        let events = calendarEvents
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Weekly schedule")
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if events.isEmpty {
                    Label("None of these sections has set meeting times.", systemImage: "calendar.badge.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    WeekCalendarView(
                        events: events,
                        startHour: max(0, (events.map(\.start).min() ?? 0) / 60 - 1),
                        endHour: min(24, Int((Double(events.map(\.end).max() ?? 0) / 60).rounded(.up)) + 1),
                        hourHeight: 44,
                        showsNowIndicator: false
                    ) { event in
                        if let crn = event.payload {
                            router.navigate(to: .section(termCode: termCode, crn: crn))
                        }
                    }
                    legend
                }
            }
            .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private var legend: some View {
        let colors = courseColors
        return CourseFlowLayout(spacing: Theme.Spacing.m, lineSpacing: 6) {
            ForEach(summary.courseKeys, id: \.self) { key in
                HStack(spacing: 5) {
                    Circle()
                        .fill((colors[key] ?? CourseColor.forCourse(key)).stroke)
                        .frame(width: 9, height: 9)
                    Text(key.description)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Courses

    private var coursesBlock: some View {
        let courses = self.courses
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Courses")
            if courses.isEmpty {
                Text("None of these courses is in this term's catalog.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .courseCard()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(courses.enumerated()), id: \.element.key) { position, course in
                        if position > 0 { Divider() }
                        courseRow(course)
                    }
                }
                .courseCard()
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func courseRow(_ course: Course) -> some View {
        NavigationLink(value: AppRoute.course(termCode: termCode, key: course.key)) {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                CourseRow(course: course, stats: index.stats(for: course.key), note: sectionNote(for: course.key))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// `Section 02` / `Sections 01, 04`.
    private func sectionNote(for key: CourseKey) -> String {
        ProfessorPage.sectionNote(for: key, in: sections)
    }

    // MARK: Sections

    private var sectionsBlock: some View {
        let all = sections
        let colors = courseColors
        let limited = !showsAllSections && all.count > Self.collapsedSectionCount
        let visible = limited ? Array(all.prefix(Self.collapsedSectionCount)) : all
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            CourseBlockHeader(title: "Sections")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.crn) { position, section in
                    if position > 0 { Divider() }
                    sectionRow(section, color: colors[section.courseKey] ?? CourseColor.forCourse(section.courseKey))
                }
                if limited {
                    Divider()
                    Button("Show all \(all.count) sections") {
                        withAnimation(.snappy) { showsAllSections = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, Theme.Spacing.m)
                }
            }
            .courseCard()
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private func sectionRow(_ section: CourseSection, color: CourseColor) -> some View {
        NavigationLink(value: AppRoute.section(termCode: termCode, crn: section.crn)) {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color.stroke)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                        Text("\(section.courseKey.description) · Section \(section.sectionNumber)")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(index.course(section.courseKey)?.title ?? section.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(section.courseScheduleLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: Theme.Spacing.s)
                SeatsBadge(section: section)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sectionLabel(section))
        .accessibilityHint("Opens the section")
        .accessibilityAddTraits(.isLink)
    }

    private func sectionLabel(_ section: CourseSection) -> String {
        let title = index.course(section.courseKey)?.title ?? section.title
        return "\(section.courseKey.description) section \(section.sectionNumber), \(title), \(section.courseSpokenScheduleLine), \(section.courseSeatsSpoken)"
    }

    // MARK: Ratings

    @ViewBuilder
    private var ratingsBlock: some View {
        if let url = ratemyprofessorsURL {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Link(destination: url) {
                    Label("Search on Rate My Professors", systemImage: "star.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Text("Opens ratemyprofessors.com in your browser. Ratings and reviews there come from students and aren't affiliated with Northeastern or this app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.s)
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
    }
}
