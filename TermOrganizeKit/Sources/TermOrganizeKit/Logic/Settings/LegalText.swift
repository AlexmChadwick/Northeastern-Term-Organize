//
//  LegalText.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// The wording of the app's legal notices and the loader for the bundled license text.
///
/// The About and Licenses screens are the app's "Appropriate Legal Notices" under
/// the GNU AGPL v3 (sections 0 and 5d): a copyright notice, a statement that there
/// is no warranty, a statement that the app may be conveyed under the license, and
/// a way to read the license itself.
enum LegalText {
    static let appName = "Term Organize"

    static let appCopyright = "Copyright (C) 2026 Term Organize contributors."

    static let upstreamCopyright = "Copyright (C) Sandbox at Northeastern University and the SearchNEU contributors"

    static let licenseName = "GNU Affero General Public License v3.0"

    /// What licensees may do (AGPL section 0: "licensees may convey the work under this License").
    static let licenseGrant = "Term Organize is free software: you can redistribute it and modify it under the terms of the GNU Affero General Public License, version 3, as published by the Free Software Foundation."

    static let noWarranty = "This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more details."

    static let licenseNotice = "You should have received a copy of the GNU Affero General Public License along with this program. If not, see https://www.gnu.org/licenses/."

    /// Where the complete corresponding source can be downloaded (AGPL-3.0 §§6, 13). If a
    /// build is distributed from a fork, point this at that fork's repository; while nil, the
    /// app explains that the source accompanies the build.
    static let sourceCodeURL: URL? = URL(string: "https://github.com/AlexmChadwick/Northeastern-Term-Organize")

    /// The offer of corresponding source (AGPL-3.0 §§6, 13).
    static var sourceOffer: String {
        let lead = "Term Organize is free software licensed under the GNU Affero General Public License v3.0."
        if let sourceCodeURL {
            return "\(lead) Its complete corresponding source code is available at \(sourceCodeURL.absoluteString)."
        }
        return "\(lead) This copy was built from the Term Organize project, whose files are its complete corresponding source code. If someone else gave you this app, they must also give you that source code under the same license."
    }

    static let unofficialNotice = "Not affiliated with, endorsed by, or sponsored by Northeastern University or Sandbox."

    /// The platform this build runs on, as the legal text names it.
    static var platformName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    static var searchNEUSummary: String {
        "This app is an independent \(platformName) adaptation of SearchNEU, the course search built by Sandbox at Northeastern University (sandboxnu). Portions of this app — including the Banner scraping logic, requisite parsing and schedule generation — are derived from SearchNEU's source code."
    }

    static let privacyNotice = "No accounts, no analytics, no tracking. Your schedules, degree plans and watchlist are stored on this device and, if iCloud sync is on, in your private iCloud database so they sync between your devices. Degree audit PDFs are read on the device, and the student name and ID they contain aren't synced. Schedule descriptions you type are processed on the device with Apple Intelligence. The app only contacts nubanner.neu.edu and catalog.northeastern.edu to fetch public course and degree-requirement information, and, if iCloud sync is on, your private iCloud database."

    static let dataNotice = "Course information is © Northeastern University and is retrieved from its public class search. Northeastern University and its marks belong to their owners and are used only to say where the data comes from."

    static let searchNEURepositoryURL = URL(string: "https://github.com/sandboxnu/searchneu")!
    static let searchNEUWebsiteURL = URL(string: "https://searchneu.com")!
    /// The full license text on gnu.org, for where the bundled copy can't be read.
    static let licenseURL = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!

    // MARK: License text

    /// The bundled `LICENSE.txt`, wherever the build placed it.
    static func licenseFileURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "LICENSE", withExtension: "txt")
            ?? bundle.url(forResource: "LICENSE", withExtension: "txt", subdirectory: "Legal")
            ?? bundle.url(forResource: "LICENSE", withExtension: "txt", subdirectory: "Resources/Legal")
    }

    /// Reads the full GNU AGPL v3 text, re-wrapped for the screen, off the main actor.
    /// Returns nil when the resource is missing or unreadable.
    static func loadLicenseText() async -> String? {
        guard let url = licenseFileURL() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return reflow(raw)
        }.value
    }

    /// The license file is hard-wrapped at about 70 columns, which breaks badly on a
    /// phone. This joins the lines of each paragraph so the text wraps to the screen
    /// width. Only line breaks and indentation change; every word stays as is.
    static func reflow(_ raw: String) -> String {
        var paragraphs: [String] = []
        var lines: [String] = []

        func flush() {
            guard !lines.isEmpty else { return }
            let indent = lines[0].prefix { $0 == " " }.count
            let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if indent >= 10 {
                // Centered headings keep their own line breaks.
                paragraphs.append(trimmed.joined(separator: "\n"))
            } else if indent >= 4 {
                // List items ("a) ...") are indented in the original; keep a hint of that.
                paragraphs.append("    " + trimmed.joined(separator: " "))
            } else {
                paragraphs.append(trimmed.joined(separator: " "))
            }
            lines.removeAll()
        }

        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
            } else {
                lines.append(line)
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: App version

    /// `1.0 (1)` from the bundle's version and build numbers.
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}
