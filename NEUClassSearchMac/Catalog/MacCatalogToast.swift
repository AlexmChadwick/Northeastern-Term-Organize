//
//  MacCatalogToast.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// A short confirmation at the bottom of a window: "Added CS 3000 to Plan A", with an optional
/// button ("View").
struct MacCatalogToast: Identifiable {
    let id = UUID()
    var message: String
    var systemImage: String
    var tint: Color = .green
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
}

/// Shows a toast in the window it is called from. Read it with `@Environment(\.catalogToast)` below a
/// view that applies `.catalogToastHost()`.
struct MacCatalogToastPresenter {
    fileprivate var present: @MainActor (MacCatalogToast) -> Void

    @MainActor
    func callAsFunction(
        _ message: String,
        systemImage: String = "checkmark.circle.fill",
        tint: Color = .green,
        actionTitle: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        present(MacCatalogToast(message: message, systemImage: systemImage, tint: tint, actionTitle: actionTitle, action: action))
    }
}

extension EnvironmentValues {
    @Entry var catalogToast = MacCatalogToastPresenter(present: { _ in })
}

extension View {
    /// Lets the views below show toasts at the bottom of this one.
    func catalogToastHost() -> some View {
        modifier(MacCatalogToastHost())
    }
}

private struct MacCatalogToastHost: ViewModifier {
    @State private var toast: MacCatalogToast?

    func body(content: Content) -> some View {
        content
            .environment(\.catalogToast, MacCatalogToastPresenter { toast = $0 })
            .overlay(alignment: .bottom) {
                if let toast {
                    MacCatalogToastView(toast: toast) { self.toast = nil }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: toast?.id)
            .task(id: toast?.id) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(toast?.action == nil ? 3 : 5))
                guard !Task.isCancelled else { return }
                toast = nil
            }
    }
}

private struct MacCatalogToastView: View {
    var toast: MacCatalogToast
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.systemImage)
                .foregroundStyle(toast.tint)
                .accessibilityHidden(true)
            Text(toast.message)
                .lineLimit(2)
            if let actionTitle = toast.actionTitle, let action = toast.action {
                Button(actionTitle) {
                    action()
                    dismiss()
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}
