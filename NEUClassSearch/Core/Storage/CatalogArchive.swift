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
    enum Error: Swift.Error, LocalizedError {
        /// Linux builds of the snapshot tool have no Apple Compression framework.
        /// The build script compresses the JSON with the lzfse reference library instead.
        case lzfseUnavailable

        var errorDescription: String? {
            "LZFSE decompression isn't available in this build."
        }
    }

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
        // Apple's Compression framework (LZFSE) is what the bundled `.catalog` files use.
        // On platforms without it, the JSON is returned as-is; `decode` accepts that, and
        // `Tools/build-catalog-snapshot.sh` compresses it with the lzfse reference library
        // so the file on disk matches the Apple format.
        #if canImport(Compression)
        return try (json as NSData).compressed(using: .lzfse) as Data
        #else
        return json
        #endif
    }

    static func decode(_ data: Data) throws -> TermCatalog {
        let json: Data
        if data.first == UInt8(ascii: "{") {
            json = data
        } else {
            #if canImport(Compression)
            json = try (data as NSData).decompressed(using: .lzfse) as Data
            #else
            throw Error.lzfseUnavailable
            #endif
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
