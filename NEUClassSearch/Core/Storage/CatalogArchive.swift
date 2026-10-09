//
//  CatalogArchive.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Serializes term catalogs as LZFSE-compressed JSON (`.catalog` files).
enum CatalogArchive {
    static let fileExtension = "catalog"

    static func fileName(forTerm code: String) -> String { "term-\(code).\(fileExtension)" }

    /// Extracts the term code from a file name such as `term-202710.catalog`.
    static func termCode(fromFileName name: String) -> String? {
        guard name.hasPrefix("term-"), name.hasSuffix(".\(fileExtension)") else { return nil }
        let code = name.dropFirst(5).dropLast(fileExtension.count + 1)
        return code.count == 6 && code.allSatisfy(\.isNumber) ? String(code) : nil
    }

    static func encode(_ catalog: TermCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = try encoder.encode(catalog)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) throws -> TermCatalog {
        let json: Data
        if data.first == UInt8(ascii: "{") {
            json = data
        } else {
            json = try (data as NSData).decompressed(using: .lzfse) as Data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(TermCatalog.self, from: json)
    }

    static func read(from url: URL) throws -> TermCatalog {
        try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func write(_ catalog: TermCatalog, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(catalog).write(to: url, options: .atomic)
    }
}
