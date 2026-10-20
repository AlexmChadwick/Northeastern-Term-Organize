//
//  HTMLText.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Minimal, dependency-free helpers for the small HTML fragments Banner returns.
enum HTMLText {
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "hellip": "…", "eacute": "é", "egrave": "è", "aacute": "á", "iacute": "í",
        "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "ccedil": "ç", "uuml": "ü", "ouml": "ö",
        "auml": "ä", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·",
        "bull": "•", "times": "×", "frac12": "½",
    ]

    /// Decodes HTML character references such as `&amp;`, `&#39;` and `&#x27;`.
    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            let ch = input[index]
            guard ch == "&", let semicolon = input[index...].prefix(12).firstIndex(of: ";") else {
                output.append(ch)
                index = input.index(after: index)
                continue
            }
            let entity = input[input.index(after: index)..<semicolon]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let v = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(v) {
                    replacement = String(Character(scalar))
                }
            } else if entity.hasPrefix("#") {
                if let v = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(v) {
                    replacement = String(Character(scalar))
                }
            } else {
                replacement = namedEntities[String(entity).lowercased()]
            }
            if let replacement {
                output += replacement
                index = input.index(after: semicolon)
            } else {
                output.append(ch)
                index = input.index(after: index)
            }
        }
        return output
    }

    /// Removes comments and tags, converts `<br>` to newlines, decodes entities
    /// (twice, as Banner sometimes double-encodes) and collapses whitespace.
    static func plainText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        s = decodeEntities(decodeEntities(s))
        // Collapse runs of spaces, tabs and non-breaking spaces; keep single newlines.
        // The non-breaking space is a literal character: `\u{00A0}` is not valid in an ICU
        // regular expression, and swift-foundation on Linux replaces the whole string when
        // `replacingOccurrences` is given a pattern that does not compile.
        let lines = s.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "[ \\t\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the rows of the first `<tbody>` as arrays of plain-text cells.
    static func tableRows(_ html: String) -> [[String]]? {
        guard let bodyStart = html.range(of: "<tbody", options: .caseInsensitive),
              let bodyEnd = html.range(of: "</tbody>", options: .caseInsensitive, range: bodyStart.upperBound..<html.endIndex)
        else { return nil }
        let body = String(html[bodyStart.upperBound..<bodyEnd.lowerBound])
        return matches(of: "<tr[^>]*>([\\s\\S]*?)</tr>", in: body).map { row in
            matches(of: "<td[^>]*>([\\s\\S]*?)</td>", in: row).map(plainText)
        }
    }

    /// Returns capture group 1 of every match of `pattern`.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }
}
