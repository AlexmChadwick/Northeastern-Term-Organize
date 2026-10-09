//
//  MacCourseSectionDetails.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// What the table doesn't have room for, for the one section selected under it: every meeting with its
/// room and dates, where and how it is taught, the part of the term, the final exam, seats and
/// waitlist, the instructors' addresses, cross-listed sections, attributes and, for a special topic,
/// what it is about.
struct MacCourseSectionDetails: View {
    var section: CourseSection
    var course: Course
    var termCode: String
    var isLoadingDetails: Bool

    @Environment(CatalogStore.self) private var catalog
    @Environment(\.openWindow) private var openWindow

    private var index: CatalogIndex? { catalog.cachedIndex(for: termCode) }

    var body: some View {
        ScrollView {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 7) {
                row("Section") { sectionTitle }
                row("Meets") { meetings }
                if let place = whereLabel {
                    row("Where") { Text(place) }
                }
                if let term = termLabel {
                    row("Term") { Text(term) }
                }
                if let exam = section.courseFinalExamPattern {
                    row("Final Exam") { Text(examText(exam)) }
                }
                row("Seats") { seats }
                if let instructors = section.courseSortedInstructors, !instructors.isEmpty {
                    row(instructors.count > 1 ? "Instructors" : "Instructor") { instructorList(instructors) }
                }
                let crossListed = section.courseCrossListedCRNs
                if !crossListed.isEmpty {
                    row("Cross-Listed") { crossListedList(crossListed) }
                }
                let attributes = attributeCodes
                if !attributes.nupaths.isEmpty || !attributes.others.isEmpty {
                    row("Attributes") { attributeChips(attributes) }
                }
                if course.specialTopics {
                    row("About") { topic }
                }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 190)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Rows

    private var sectionTitle: some View {
        CourseFlowLayout(spacing: 8, lineSpacing: 4) {
            Text("Section \(section.sectionNumber) · \(section.classType)")
                .fontWeight(.semibold)
            if section.honors {
                TagLabel(text: "Honors", systemImage: "star.fill", tint: .purple)
            }
            if section.isOnline {
                TagLabel(text: "Online", systemImage: "wifi", tint: .blue)
            }
            MacSectionCRNButton(crn: section.crn)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var meetings: some View {
        let patterns = section.courseMeetingPatterns
        if patterns.isEmpty {
            Text(section.isOnline ? "Online · asynchronous" : (section.meetings.isEmpty ? "No scheduled meetings" : "Times to be announced"))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(patterns) { pattern in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pattern.days.isEmpty ? "–" : pattern.days.shortLabel)
                            .fontWeight(.medium)
                            .frame(minWidth: 96, alignment: .leading)
                        Text(pattern.timeLabel)
                            .monospacedDigit()
                        Text(pattern.locationLabel(long: true))
                            .foregroundStyle(.secondary)
                        if let dates = pattern.datesLabel, pattern.isDatedList || sectionIsPartial {
                            Text(dates)
                                .foregroundStyle(.secondary)
                        }
                        if pattern.kind.caseInsensitiveCompare("Class") != .orderedSame, !pattern.kind.isEmpty {
                            TagLabel(text: pattern.kind)
                        }
                    }
                }
            }
        }
    }

    /// Whether the section runs for only part of the term, so its meetings' dates are worth showing.
    private var sectionIsPartial: Bool { section.coursePartOfTermLabel != nil }

    private var whereLabel: String? {
        // A bare "Online" repeats what the meetings already say.
        guard let label = section.courseWhereLabel, label.caseInsensitiveCompare("Online") != .orderedSame else { return nil }
        return label
    }

    private var termLabel: String? {
        let code = section.partOfTerm.trimmingCharacters(in: .whitespaces)
        let range = CourseFormat.dateRange(
            start: section.meetings.compactMap(\.startDate).min(),
            end: section.meetings.compactMap(\.endDate).max()
        )
        let name = (code == "1" || code.isEmpty) ? "Full term" : "Part of term \(code)"
        return [name, range].compactMap { $0 }.joined(separator: " · ")
    }

    private func examText(_ exam: CourseMeetingPattern) -> String {
        var parts: [String] = []
        if let date = CourseFormat.shortDate(exam.startDate) { parts.append(date) }
        if exam.start != nil { parts.append(exam.timeLabel) }
        parts.append(exam.locationLabel(long: true))
        return parts.joined(separator: " · ")
    }

    private var seats: some View {
        VStack(alignment: .leading, spacing: 4) {
            if section.seatCapacity > 0 || section.seatsRemaining > 0 {
                HStack(spacing: 10) {
                    Text("\(max(0, section.seatsRemaining)) of \(section.seatCapacity) open")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.seatColor(for: section))
                        .monospacedDigit()
                    Text("\(section.enrollment) enrolled")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    SeatMeter(remaining: section.seatsRemaining, capacity: section.seatCapacity)
                        .frame(width: 120)
                }
                if section.seatsRemaining < 0 {
                    Label("Over capacity by \(-section.seatsRemaining)", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if section.hasWaitlist {
                    Text("Waitlist: \(section.waitlistCount) of \(section.waitlistCapacity) filled · \(CourseFormat.count(max(0, section.waitlistRemaining), "spot")) open")
                        .foregroundStyle(.secondary)
                } else if section.isFull {
                    Text("No waitlist")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No seat limit is listed for this section.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func instructorList(_ instructors: [Instructor]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(instructors, id: \.name) { instructor in
                HStack(spacing: 8) {
                    Button(instructor.displayName) {
                        openWindow(id: MacWindowID.professor, value: ProfessorWindowValue(termCode: termCode, name: instructor.name))
                    }
                    .buttonStyle(.link)
                    if instructor.primary && instructors.count > 1 {
                        Text("Primary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let email = instructor.email, let url = URL(string: "mailto:\(email)") {
                        Link(email, destination: url)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func crossListedList(_ crns: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(crns, id: \.self) { crn in
                if let other = index?.section(crn: crn) {
                    Button {
                        openWindow(id: MacWindowID.course, value: CourseWindowValue(termCode: termCode, key: other.courseKey))
                    } label: {
                        Text("\(other.courseKey.description) · Section \(other.sectionNumber) · \(other.classType) · CRN \(other.crn)")
                    }
                    .buttonStyle(.link)
                } else {
                    Text("CRN \(crn) · not in this term's catalog")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var attributeCodes: (nupaths: [NUPath], others: [String]) {
        let nupaths = NUPath.from(attributeCodes: section.attributes)
        let codes = Set(nupaths.map(\.attributeCode))
        return (nupaths, section.courseUniqueAttributes.filter { !codes.contains($0) })
    }

    private func attributeChips(_ attributes: (nupaths: [NUPath], others: [String])) -> some View {
        CourseFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(attributes.nupaths) { nupath in
                NUPathChip(nupath: nupath, showsName: true)
            }
            ForEach(attributes.others, id: \.self) { code in
                TagLabel(text: index?.attributeName(code) ?? code)
            }
        }
    }

    @ViewBuilder
    private var topic: some View {
        if let text = section.courseTopicDescription {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if section.description == nil && isLoadingDetails {
            Text("Loading the description for this special topics section.")
                .foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
        } else {
            Text("No description available.")
                .foregroundStyle(.secondary)
        }
    }
}
