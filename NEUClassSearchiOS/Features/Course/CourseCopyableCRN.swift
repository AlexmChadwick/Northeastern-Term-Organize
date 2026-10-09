//
//  CourseCopyableCRN.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI
import UIKit
import Accessibility

/// A CRN chip that copies the number when tapped, with haptic feedback and a
/// brief "Copied" confirmation.
struct CourseCopyableCRN: View {
    var crn: String

    @State private var copyCount = 0
    @State private var showsCopied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                    .contentTransition(.symbolEffect(.replace))
                Text(showsCopied ? "Copied" : "CRN \(crn)")
                    .monospacedDigit()
                    .contentTransition(.interpolate)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(showsCopied ? Color.green : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((showsCopied ? Color.green : Color.secondary).opacity(0.14), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copyCount)
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { showsCopied = false }
        }
        .accessibilityLabel("CRN \(crn)")
        .accessibilityHint("Copies the CRN")
        .accessibilityAddTraits(.isButton)
    }

    private func copy() {
        UIPasteboard.general.string = crn
        withAnimation(.snappy) {
            showsCopied = true
        }
        copyCount += 1
        AccessibilityNotification.Announcement("CRN \(crn) copied").post()
    }
}
