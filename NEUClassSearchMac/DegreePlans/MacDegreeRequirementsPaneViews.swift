//
//  MacDegreeRequirementsPaneViews.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import SwiftUI

/// The top of the requirements pane beside a degree plan: its title (or, with one requirement's
/// details open, a way back to the list), a menu for the catalog year and program, reloading and
/// the full page, a button that hides the pane, and the filter that picks which requirements
/// the list shows.
struct MacDegreeRequirementsPaneHeader: View {
    /// A requirement's details replace the list.
    var isShowingDetails: Bool
    /// The filter only applies to the list, once the requirements have loaded.
    var showsFilter: Bool
    @Binding var filter: DegreeRequirementsFilter
    var canChangeSetup: Bool
    var onBack: () -> Void
    var onChangeSetup: () -> Void
    var onReload: () -> Void
    var onOpenPage: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if isShowingDetails {
                    Button(action: onBack) {
                        Label("Requirements", systemImage: "chevron.backward")
                            .font(.headline)
                    }
                    .buttonStyle(.borderless)
                    .help("Back to the list of requirements")
                    .keyboardShortcut("[", modifiers: .command)
                } else {
                    Text("Requirements")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Catalog Year and Program…", systemImage: "slider.horizontal.3", action: onChangeSetup)
                        .disabled(!canChangeSetup)
                    Button("Reload Requirements", systemImage: "arrow.clockwise", action: onReload)
                    if let onOpenPage {
                        Button("Open as Full Page", systemImage: "arrow.up.left.and.arrow.down.right", action: onOpenPage)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for the requirements")
                .accessibilityLabel("Requirements options")
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide the requirements (⌥⌘0)")
                    .accessibilityLabel("Hide requirements")
                }
            }
            if showsFilter, !isShowingDetails {
                Picker("Show", selection: $filter.animation(.snappy)) {
                    ForEach(DegreeRequirementsFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .help("Show all requirements, the ones still open, or the ones that are done")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.background)
    }
}
