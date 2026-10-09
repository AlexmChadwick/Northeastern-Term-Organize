//
//  SpotlightIndexer.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Makes the selected term's courses findable from iOS Spotlight. The index
/// lives on device; items are replaced whenever the indexed catalog changes.
enum SpotlightIndexer {
    private static let domain = "courses"
    private static let signatureKey = "SpotlightIndexer.signature"

    private struct Entry: Sendable {
        var id: String
        var title: String
        var description: String
        var keywords: [String]
    }

    /// Indexes a catalog's courses (skipped when that exact catalog is already indexed).
    @MainActor
    static func index(_ index: CatalogIndex) {
        let term = index.term
        let signature = "\(term.code)-\(Int(index.catalog.generatedAt.timeIntervalSince1970))-\(index.courses.count)"
        guard UserDefaults.standard.string(forKey: signatureKey) != signature else { return }

        let entries = index.courses.map { course -> Entry in
            let subjectName = index.subjectName(course.subject) ?? course.subject
            var description = "\(term.shortName) · \(course.creditsLabel) · \(subjectName)"
            if !course.description.isEmpty {
                description += "\n" + String(course.description.prefix(240))
            }
            return Entry(
                id: "\(term.code)|\(course.subject)|\(course.number)",
                title: "\(course.code) · \(course.title)",
                description: description,
                keywords: [course.code, "\(course.subject)\(course.number)", course.subject, subjectName]
                    + course.nupaths.flatMap { [$0.short, $0.name] }
            )
        }

        Task.detached(priority: .background) {
            let searchable = CSSearchableIndex.default()
            // Domains are hierarchical, so this also clears earlier terms.
            try? await searchable.deleteSearchableItems(withDomainIdentifiers: [domain])
            let items = entries.map { entry in
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = entry.title
                attributes.contentDescription = entry.description
                attributes.keywords = entry.keywords
                return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: "\(domain).\(term.code)", attributeSet: attributes)
            }
            var start = 0
            while start < items.count {
                let end = min(start + 500, items.count)
                do {
                    try await searchable.indexSearchableItems(Array(items[start..<end]))
                } catch {
                    return
                }
                start = end
            }
            await MainActor.run { UserDefaults.standard.set(signature, forKey: signatureKey) }
        }
    }

    /// Removes everything this app put in Spotlight.
    static func removeAll() {
        Task.detached(priority: .background) {
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            await MainActor.run { UserDefaults.standard.removeObject(forKey: signatureKey) }
        }
    }

    /// The course (and its term) a Spotlight result points to.
    static func course(for activity: NSUserActivity) -> (termCode: String, key: CourseKey)? {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], CourseKey(subject: parts[1], number: parts[2]))
    }
}
