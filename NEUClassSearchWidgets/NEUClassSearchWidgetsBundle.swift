//
//  NEUClassSearchWidgetsBundle.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import WidgetKit

@main
struct NEUClassSearchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        TodayScheduleWidget()
    }
}
