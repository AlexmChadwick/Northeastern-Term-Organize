//
//  ScheduleGeneratorRouteView.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// Destination for `AppRoute.planGenerator(id:)`: the schedule generator for a plan,
/// pushed onto the tab's navigation path like every other screen.
struct ScheduleGeneratorRouteView: View {
    var planID: UUID

    var body: some View {
        ScheduleGeneratorView(planID: planID)
    }
}
