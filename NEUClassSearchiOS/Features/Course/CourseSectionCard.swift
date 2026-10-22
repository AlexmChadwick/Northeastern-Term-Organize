//
//  CourseSectionCard.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit

/// A content card for one section: seats, instructors, meetings and actions.
/// Tapping the card opens the section; instructors, the CRN and the buttons
/// are separate controls layered above that tap target.
struct CourseSectionCard: View {
    var section: CourseSection
    var course: Course
    var termCode: String
    /// Whether lazily loaded details (instructors, topic description) may still arrive.
    var isLoadingDetails: Bool
    /// The calendar color while "Compare times" is showing.
    var compareColor: CourseColor?
    var isHighlighted = false
    /// Pushes a destination from the context menu.
    var onNavigate: (AppRoute) -> Void = { _ in }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(UserDataStore.self) private var userData
    @Environment(AppRouter.self) private var router

    private var isWatching: Bool {
        userData.isWatching(crn: section.crn, termCode: termCode)
    }

    /// Special-topics sections carry their own title.
    private var showsSectionTitle: Bool {
        course.specialTopics && !section.title.isEmpty && section.title != course.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header.courseDecorative()
            meterBlock.courseDecorative()
            instructorsRow
            CourseScheduleList(section: section, roomTermCode: termCode, isEmbedded: true)
            detailsBlock.courseDecorative()
            Divider()
            footer
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { detailsLink }
        .cardBackground()
        .overlay { highlight }
        .contextMenu { menuContent }
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let compareColor {
                        Circle()
                            .fill(compareColor.stroke)
                            .frame(width: 10, height: 10)
                    }
                    Text("Section \(section.sectionNumber)")
                        .font(.headline)
                }
                CourseFlowLayout(spacing: 6, lineSpacing: 4) {
                    Text(section.classType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if section.honors {
                        TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
                    }
                    if !section.crossListCRNs.isEmpty {
                        TagLabel(text: "Cross-listed", systemImage: "link")
                    }
                }
                if showsSectionTitle {
                    Text(section.title)
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 2)
                }
                if CPSNote.isCPSOnly(section.restrictions) == true {
                    CatalogCaption(text: CPSNote.only)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            seatsBadge
        }
    }

    private var seatsBadge: some View {
        SeatsBadge(section: section, style: .detailed)
    }

    @ViewBuilder
    private var meterBlock: some View {
        if section.seatCapacity > 0 {
            VStack(alignment: .leading, spacing: 6) {
                SeatMeter(remaining: section.seatsRemaining, capacity: section.seatCapacity)
                if section.hasWaitlist {
                    Text("Waitlist: \(section.waitlistCount) of \(section.waitlistCapacity) filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: Instructors

    @ViewBuilder
    private var instructorsRow: some View {
        if let instructors = section.courseSortedInstructors {
            if instructors.isEmpty {
                Label("Instructor TBA", systemImage: "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                CourseFlowLayout(spacing: 14, lineSpacing: 0) {
                    ForEach(instructors, id: \.name) { instructor in
                        NavigationLink(value: AppRoute.professor(termCode: termCode, name: instructor.name)) {
                            HStack(spacing: 5) {
                                Image(systemName: "person.fill")
                                    .imageScale(.small)
                                Text(instructor.displayName)
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Instructor \(instructor.displayName)")
                        .accessibilityHint("Opens the instructor's page")
                    }
                }
            }
        } else if isLoadingDetails {
            Label("Instructor Name", systemImage: "person.fill")
                .font(.subheadline.weight(.medium))
                .courseShimmer(isActive: true)
        } else {
            Label("Instructor unavailable", systemImage: "person.fill.questionmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Details

    @ViewBuilder
    private var detailsBlock: some View {
        // A bare "Online" repeats what the schedule rows already say.
        let whereLabel = section.courseWhereLabel.flatMap { label in
            label.caseInsensitiveCompare("Online") == .orderedSame ? nil : label
        }
        let partOfTerm = section.coursePartOfTermLabel
        let exam = section.courseFinalExamPattern
        let hasTopic = course.specialTopics
            && (section.courseTopicDescription != nil || (section.description == nil && isLoadingDetails))
        if whereLabel != nil || partOfTerm != nil || exam != nil || hasTopic {
            VStack(alignment: .leading, spacing: 6) {
                if let whereLabel {
                    Label(whereLabel, systemImage: section.isOnline ? "wifi" : "building.2")
                }
                if let partOfTerm {
                    Label(partOfTerm, systemImage: "calendar")
                }
                if let exam {
                    Label(finalExamText(exam), systemImage: "pencil.and.list.clipboard")
                }
                if hasTopic {
                    topicDescription
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(CourseInfoLabelStyle())
        }
    }

    @ViewBuilder
    private var topicDescription: some View {
        if let text = section.courseTopicDescription {
            Text(text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        } else if section.description == nil && isLoadingDetails {
            Text("Loading the description for this special topics section.")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .courseShimmer(isActive: true)
        }
    }

    private func finalExamText(_ exam: CourseMeetingPattern) -> String {
        var parts = ["Final exam"]
        if let date = CourseFormat.shortDate(exam.startDate) { parts.append(date) }
        if exam.start != nil { parts.append(exam.timeLabel) }
        parts.append(exam.locationLabel(long: false))
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var crnChip: some View {
        CourseCopyableCRN(crn: section.crn)
    }

    private var watchButton: some View {
        CourseWatchButton(section: section, courseTitle: course.title, termCode: termCode, style: .card)
    }

    private var addButton: some View {
        CourseAddButton(
            termCode: termCode,
            key: section.courseKey,
            crn: section.crn,
            sectionNumber: section.sectionNumber,
            style: .card
        )
    }

    /// One row when the CRN and both buttons fit; otherwise the CRN above the
    /// buttons; and at the largest text sizes one control per line, so no label
    /// ever wraps mid-word or truncates.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                crnChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                watchButton
                addButton
            }
            VStack(alignment: .leading, spacing: 8) {
                crnChip
                HStack(spacing: 8) {
                    watchButton
                    addButton
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                crnChip
                watchButton
                addButton
            }
        }
    }

    // MARK: Link, highlight, menu

    /// The card-sized tap target behind the content.
    private var detailsLink: some View {
        NavigationLink(value: AppRoute.section(termCode: termCode, crn: section.crn)) {
            Color.clear
        }
        .buttonStyle(CourseCardLinkStyle())
        .accessibilityLabel(summaryLabel)
        .accessibilityHint("Opens section details")
    }

    @ViewBuilder
    private var highlight: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(compareColor?.stroke ?? Color.accentColor, lineWidth: 2.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        Button {
            UIPasteboard.general.string = section.crn
        } label: {
            Label("Copy CRN", systemImage: "doc.on.doc")
        }
        Button {
            userData.toggleWatch(section, courseTitle: course.title, termCode: termCode)
        } label: {
            Label(isWatching ? "Stop Watching" : "Watch for Open Seats", systemImage: isWatching ? "bell.slash" : "bell")
        }
        Button {
            router.addToSchedule(termCode: termCode, key: section.courseKey, crn: section.crn)
        } label: {
            if userData.courseIsInSchedule(termCode: termCode, key: section.courseKey, crn: section.crn) {
                Label("In Schedule · Add to Another", systemImage: "checkmark.circle")
            } else {
                Label("Add to Schedule", systemImage: "calendar.badge.plus")
            }
        }
        if let instructors = section.courseSortedInstructors, !instructors.isEmpty {
            Divider()
            ForEach(instructors, id: \.name) { instructor in
                Button {
                    onNavigate(.professor(termCode: termCode, name: instructor.name))
                } label: {
                    Label("View \(instructor.displayName)", systemImage: "person")
                }
            }
        }
    }

    private var summaryLabel: String {
        var parts = ["Section \(section.sectionNumber)", section.classType]
        if showsSectionTitle { parts.append(section.title) }
        if section.honors { parts.append("Honors") }
        parts.append(section.courseSeatsSpoken)
        parts.append(CourseScheduleList.spokenSummary(for: section))
        if let place = section.courseWhereLabel { parts.append(place) }
        return parts.joined(separator: ", ")
    }
}

/// An icon and text on one line, with the text allowed to wrap beneath itself.
struct CourseInfoLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .imageScale(.small)
                .frame(width: 16)
            configuration.title
        }
    }
}
