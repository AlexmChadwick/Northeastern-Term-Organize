//
//  ProgramCatalogStore.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation
import Observation

/// Degree requirements from the academic catalog, for the UI: catalog editions, each
/// edition's programs, and the requirements of the programs degree plans use. Loads go
/// through `ProgramCatalogRepository`, which keeps copies on device.
@MainActor
@Observable
final class ProgramCatalogStore {
    enum LoadState: Equatable {
        case idle, loading, failed(String)
    }

    /// Starts as the saved copy (or an estimate) and is refreshed from the site.
    private(set) var editions: CatalogEditions
    private(set) var programsByYear: [Int: [CatalogProgram]] = [:]
    private(set) var requirementsByKey: [String: ProgramRequirements] = [:]
    private(set) var states: [String: LoadState] = [:]

    private let repository: ProgramCatalogRepository

    init(repository: ProgramCatalogRepository = .shared) {
        self.repository = repository
        let saved = Self.readSavedEditions()
        editions = saved ?? .estimated()
    }

    // MARK: Editions

    func loadEditions(forceRefresh: Bool = false) async {
        states["editions"] = .loading
        editions = await repository.editions(forceRefresh: forceRefresh)
        states["editions"] = .idle
    }

    // MARK: Programs

    func programs(for year: CatalogYear) -> [CatalogProgram]? {
        programsByYear[year.startYear]
    }

    func loadPrograms(for year: CatalogYear, forceRefresh: Bool = false) async {
        let key = "programs|\(year.slug)"
        guard states[key] != .loading else { return }
        states[key] = .loading
        do {
            programsByYear[year.startYear] = try await repository.programs(for: year, forceRefresh: forceRefresh)
            states[key] = .idle
        } catch {
            states[key] = .failed(Self.message(for: error))
        }
    }

    func programsState(for year: CatalogYear) -> LoadState {
        states["programs|\(year.slug)"] ?? .idle
    }

    // MARK: Requirements

    nonisolated static func key(year: CatalogYear, path: String) -> String { "\(year.slug)|\(path)" }

    /// The loaded requirements for a plan, if it has a program and catalog year.
    func requirements(for plan: DegreePlan) -> ProgramRequirements? {
        guard let year = plan.requirementsYear, let path = plan.catalogProgramPath else { return nil }
        return requirementsByKey[Self.key(year: year, path: path)]
    }

    func requirementsState(for plan: DegreePlan) -> LoadState {
        guard let year = plan.requirementsYear, let path = plan.catalogProgramPath else { return .idle }
        return states[Self.key(year: year, path: path)] ?? .idle
    }

    /// Loads a plan's requirements: the saved copy right away, then the site when needed.
    func loadRequirements(for plan: DegreePlan, forceRefresh: Bool = false) async {
        guard let year = plan.requirementsYear, let path = plan.catalogProgramPath else { return }
        let program = CatalogProgram(title: plan.catalogProgramTitle ?? path, path: path)
        await loadRequirements(for: program, year: year, forceRefresh: forceRefresh)
    }

    func loadRequirements(for program: CatalogProgram, year: CatalogYear, forceRefresh: Bool = false) async {
        let key = Self.key(year: year, path: program.path)
        guard states[key] != .loading else { return }
        if requirementsByKey[key] == nil, let saved = await repository.savedRequirements(year: year, path: program.path) {
            requirementsByKey[key] = saved
        }
        states[key] = .loading
        do {
            requirementsByKey[key] = try await repository.requirements(for: program, year: year, forceRefresh: forceRefresh)
            states[key] = .idle
        } catch {
            states[key] = requirementsByKey[key] == nil ? .failed(Self.message(for: error)) : .idle
        }
    }

    // MARK: Suggestions

    /// Programs matching a degree audit program code such as `CS-B-CSCI-BSCS` (by its degree,
    /// `BSCS`), Boston and campus-less listings first. Empty when nothing matches.
    nonisolated static func suggestedPrograms(forAuditCode code: String?, in programs: [CatalogProgram]) -> [CatalogProgram] {
        guard let degree = code?.split(separator: "-").last.map(String.init), degree.count >= 2 else { return [] }
        return programs
            .filter { $0.degree?.caseInsensitiveCompare(degree) == .orderedSame }
            .sorted { lhs, rhs in
                func rank(_ program: CatalogProgram) -> Int {
                    switch program.campus {
                    case nil: 0
                    case "Boston": 1
                    default: 2
                    }
                }
                return (rank(lhs), lhs.title) < (rank(rhs), rhs.title)
            }
    }

    /// A guess at the catalog year a student entered under: about 32 credits a year before
    /// the current edition. Only a starting point; the student confirms it.
    nonisolated static func suggestedYear(completedCredits: Double, editions: CatalogEditions) -> CatalogYear {
        let yearsDone = max(0, Int(completedCredits / 32))
        let guess = CatalogYear(startYear: editions.current.startYear - yearsDone)
        return editions.all.contains(guess) ? guess : (editions.all.last ?? editions.current)
    }

    // MARK: Helpers

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
            return "You're offline. Connect to the internet to load the catalog."
        }
        return (error as? LocalizedError)?.errorDescription ?? "The catalog couldn't be loaded."
    }

    private static func readSavedEditions() -> CatalogEditions? {
        let url = AppPaths.programCatalogDirectory.appendingPathComponent("editions.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CatalogEditions.self, from: data)
    }
}
