//
//  ScheduleAssistantModel.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

// MARK: - Previewing

private struct ScheduleAssistantAvailabilityKey: EnvironmentKey {
    static let defaultValue: ScheduleAssistantAvailability? = nil
}

extension EnvironmentValues {
    /// What Apple Intelligence is taken to report. Nil (the default) asks the system; set it in previews
    /// and tests to see the survey with the description field offered, or with a note in its place.
    var scheduleAssistantAvailability: ScheduleAssistantAvailability? {
        get { self[ScheduleAssistantAvailabilityKey.self] }
        set { self[ScheduleAssistantAvailabilityKey.self] = newValue }
    }
}

// MARK: - Assistant state

/// The state of one "describe your ideal schedule" request, for the survey to show.
@MainActor
@Observable
final class ScheduleAssistantModel {
    enum State: Equatable {
        case idle
        case working(found: Int)
        /// The model's answers are in the survey, highlighted for review.
        case filled(count: Int)
        /// Nothing came of it: a message for the student.
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private var task: Task<Void, Never>?

    /// `state` is for previews and tests, to see the survey mid-request or after one.
    init(state: State = .idle) {
        self.state = state
    }

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    /// Sends `text` to the on-device model. `onUnderstood` gets what it understood, to merge into the survey
    /// for review (never applied on its own), and returns how many settings that changed.
    func start(
        _ text: String,
        onUnderstood: @escaping @MainActor @Sendable (ScheduleAssistant.Interpretation) -> Int
    ) {
        task?.cancel()
        state = .working(found: 0)
        task = Task { [weak self] in
            do {
                let interpretation = try await ScheduleAssistant.interpret(text) { [weak self] count in
                    self?.noteProgress(count)
                }
                guard !Task.isCancelled else { return }
                let changed = onUnderstood(interpretation)
                self?.state = changed > 0 ? .filled(count: changed) : .failed("Everything in that is already in your survey.")
            } catch is CancellationError {
                // The student stopped it; the survey is exactly as they left it.
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? ScheduleAssistant.Failure ?? .failed(error.localizedDescription)
                self?.state = .failed(failure.message)
            }
        }
    }

    private func noteProgress(_ count: Int) {
        if case .working = state { state = .working(found: count) }
    }

    /// Stops a request in flight.
    func cancel() {
        task?.cancel()
        task = nil
        if isWorking { state = .idle }
    }

    func reset() {
        cancel()
        state = .idle
    }
}
