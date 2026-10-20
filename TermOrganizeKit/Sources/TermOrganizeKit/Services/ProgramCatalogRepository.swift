//
//  ProgramCatalogRepository.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Fetches degree requirements from Northeastern's academic catalog and keeps them on device.
///
/// Archived editions never change, so their pages are fetched once. The current edition is
/// re-read weekly. Which editions exist is read from the site itself (its header names the
/// current edition, its archive page lists the rest), so a new catalog year works without an
/// app update. Every request is a plain GET to catalog.northeastern.edu.
actor ProgramCatalogRepository {
    static let shared = ProgramCatalogRepository()

    enum FetchError: LocalizedError {
        case notFound
        case noRequirements
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notFound: "That page isn't in this catalog year."
            case .noRequirements: "This page doesn't list program requirements the app can read."
            case .http(let code): "The catalog site returned an error (\(code))."
            }
        }
    }

    /// How long a copy of the current edition (and the list of editions) is used before
    /// checking the site again.
    static let currentEditionMaxAge: TimeInterval = 7 * 24 * 3600

    private let session: URLSession
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL = AppPaths.programCatalogDirectory) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"]
        session = URLSession(configuration: config)
        self.directory = directory
    }

    // MARK: Editions

    /// The catalog editions. Uses the saved copy when it's recent, else asks the site;
    /// offline with nothing saved, an estimate from today's date.
    func editions(forceRefresh: Bool = false) async -> CatalogEditions {
        let saved: CatalogEditions? = load(editionsURL)
        if let saved, !forceRefresh, Date.now.timeIntervalSince(saved.fetchedAt) < Self.currentEditionMaxAge {
            return saved
        }
        do {
            let html = try await fetch(CatalogEditions.siteURL.appendingPathComponent("archive/", isDirectory: true))
            let archived = ProgramCatalogParser.archivedEditions(fromHTML: html)
            guard let current = ProgramCatalogParser.currentEdition(fromHTML: html)
                    ?? archived.first.map({ CatalogYear(startYear: $0.startYear + 1) }) else {
                return saved ?? .estimated()
            }
            let editions = CatalogEditions(current: current, archived: archived.filter { $0 != current }, fetchedAt: .now)
            save(editions, to: editionsURL)
            return editions
        } catch {
            return saved ?? .estimated()
        }
    }

    func savedEditions() -> CatalogEditions? {
        load(editionsURL)
    }

    // MARK: Programs

    /// The degree programs of an edition, from its A–Z index.
    func programs(for year: CatalogYear, forceRefresh: Bool = false) async throws -> [CatalogProgram] {
        let url = programsURL(year)
        let editions = await editions()
        if let saved: SavedPrograms = load(url), !forceRefresh, isFresh(saved.fetchedAt, year: year, editions: editions) {
            return saved.programs
        }
        do {
            let html = try await fetchPage(year: year, path: "azindex/", editions: editions)
            let programs = ProgramCatalogParser.programs(fromAZIndexHTML: html)
            guard !programs.isEmpty else { throw FetchError.notFound }
            save(SavedPrograms(programs: programs, fetchedAt: .now), to: url)
            return programs
        } catch {
            if let saved: SavedPrograms = load(url) { return saved.programs }
            throw error
        }
    }

    // MARK: Requirements

    /// A program's requirements in an edition.
    func requirements(for program: CatalogProgram, year: CatalogYear, forceRefresh: Bool = false) async throws -> ProgramRequirements {
        let url = requirementsURL(year: year, path: program.path)
        let editions = await editions()
        if var saved: ProgramRequirements = load(url), !forceRefresh, isFresh(saved.fetchedAt, year: year, editions: editions) {
            // Copies saved before the universitywide minimums were read get them now.
            if saved.universitywide == nil,
               let minimums = await universitywide(year: year, path: nil, editions: editions, forceRefresh: false) {
                saved.universitywide = minimums
                save(saved, to: url)
            }
            return saved
        }
        do {
            let html = try await fetchPage(year: year, path: program.path, editions: editions)
            guard var requirements = ProgramCatalogParser.requirements(fromHTML: html, year: year, program: program) else {
                throw FetchError.noRequirements
            }
            requirements.universitywide = await universitywide(
                year: year, path: ProgramCatalogParser.universitywideLink(in: html), editions: editions, forceRefresh: forceRefresh
            )
            save(requirements, to: url)
            return requirements
        } catch {
            if var saved: ProgramRequirements = load(url) {
                if saved.universitywide == nil {
                    saved.universitywide = await universitywide(year: year, path: nil, editions: editions, forceRefresh: false)
                }
                return saved
            }
            throw error
        }
    }

    /// The edition's universitywide minimums (shared by its programs, so read once per edition and
    /// kept like its pages). Nil when the page can't be read or states none.
    ///
    /// - Parameter path: the page as the program page links it; the usual path when nil.
    private func universitywide(year: CatalogYear, path: String?, editions: CatalogEditions, forceRefresh: Bool) async -> UniversitywideRequirements? {
        let url = yearDirectory(year).appendingPathComponent("universitywide.json")
        if let saved: UniversitywideRequirements = load(url), !forceRefresh, isFresh(saved.fetchedAt, year: year, editions: editions) {
            return saved
        }
        let path = path ?? "undergraduate/university-academics/university-wide-requirements/"
        guard let html = try? await fetchPage(year: year, path: path, editions: editions),
              let requirements = ProgramCatalogParser.universitywideRequirements(fromHTML: html) else {
            return load(url)
        }
        save(requirements, to: url)
        return requirements
    }

    /// The saved copy, without going online.
    func savedRequirements(year: CatalogYear, path: String) -> ProgramRequirements? {
        load(requirementsURL(year: year, path: path))
    }

    // MARK: Fetching

    /// A page of an edition. If the site has moved the edition (a new catalog year was
    /// published since the editions were read), refreshes the editions and tries again.
    private func fetchPage(year: CatalogYear, path: String, editions: CatalogEditions) async throws -> String {
        do {
            return try await fetch(editions.url(for: year, path: path))
        } catch FetchError.notFound {
            let refreshed = await self.editions(forceRefresh: true)
            guard refreshed.baseURL(for: year) != editions.baseURL(for: year) else { throw FetchError.notFound }
            return try await fetch(refreshed.url(for: year, path: path))
        }
    }

    private func fetch(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 404 ? FetchError.notFound : FetchError.http(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Archived editions don't change; the current one is re-read weekly.
    private func isFresh(_ fetchedAt: Date, year: CatalogYear, editions: CatalogEditions) -> Bool {
        year != editions.current || Date.now.timeIntervalSince(fetchedAt) < Self.currentEditionMaxAge
    }

    // MARK: Files

    private struct SavedPrograms: Codable {
        var programs: [CatalogProgram]
        var fetchedAt: Date
    }

    private var editionsURL: URL { directory.appendingPathComponent("editions.json") }

    private func yearDirectory(_ year: CatalogYear) -> URL {
        let url = directory.appendingPathComponent(year.slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func programsURL(_ year: CatalogYear) -> URL {
        yearDirectory(year).appendingPathComponent("programs.json")
    }

    private func requirementsURL(year: CatalogYear, path: String) -> URL {
        let name = path.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return yearDirectory(year).appendingPathComponent("\(name).json")
    }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
