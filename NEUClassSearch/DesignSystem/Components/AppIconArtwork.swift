//
//  AppIconArtwork.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The app icon's original artwork (a magnifying glass over schedule bars),
/// drawn in SwiftUI so it can appear inside the app. Mirrors the vector layers
/// in `Resources/AppIcon.icon` (1024-unit canvas). SF Symbols are deliberately
/// not used here: Apple's terms don't allow them in app icons or logos.
struct AppIconArtwork: View {
    var size: CGFloat = 96

    var body: some View {
        let scale = size / 1024
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Color.accentColor.gradient)

            // Schedule bars.
            ForEach(Array([(330.0, 228.0, 1.0), (404.0, 160.0, 0.85), (478.0, 196.0, 0.7)].enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(.white.opacity(bar.2))
                    .frame(width: bar.1 * scale, height: 52 * scale)
                    .position(x: (316 + bar.1 / 2) * scale, y: (bar.0 + 26) * scale)
            }

            // Lens and handle.
            Circle()
                .stroke(.white, lineWidth: 84 * scale)
                .frame(width: 464 * scale, height: 464 * scale)
                .position(x: 430 * scale, y: 430 * scale)
            Path { path in
                path.move(to: CGPoint(x: 606 * scale, y: 606 * scale))
                path.addLine(to: CGPoint(x: 780 * scale, y: 780 * scale))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 112 * scale, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    AppIconArtwork(size: 180)
        .padding()
}
