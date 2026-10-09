//
//  MacSnapshot.swift
//  Term Organize (macOS)
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

#if DEBUG
import AppKit
import SwiftUI

/// Debug-only visual checks without screen-recording permission. Launch the built binary with
///
///     -MacSnapshot name.png [-MacSnapshotSelection search|subjects|saved|professors|rooms|
///       schedules|schedule:<uuid>|schedule:first|degreePlans|degreePlan:<uuid>|degreePlan:first|
///       degreeRequirements:first|watchlist] [-MacSnapshotView <name>] [-MacSnapshotSampleData YES]
///       [-MacSnapshotDelay 6] [-MacSnapshotAppearance dark|light] [-MacSnapshotSize 1180x760]
///
/// and the app (off screen, without a Dock icon or focus) selects that sidebar item, waits,
/// renders the main window into a PNG and quits. `-MacSnapshotView` renders a view that isn't in
/// the main window instead (a course window, the menu bar extra…), by a name an area registers in
/// its `Mac…Samples.swift`. The app is sandboxed, so the PNG lands in its container
/// (`~/Library/Containers/com.alexchadwick.neuclasssearch/Data/tmp/MacSnapshots/`) and is also
/// printed to standard output as a `MacSnapshotPNG:` line in base64, for tools that may not read
/// the container (macOS protects it once the app is signed with a team).
///
/// `-MacSnapshotSampleData YES` runs on throwaway sample data (`MacSampleData`) kept in that same
/// folder instead of the user's own, with iCloud sync off, so nothing reaches their devices. A run
/// leaves the app's settings as it found them: window frames, split positions, menu bar items and
/// table columns it changes (the window sits off screen) are put back before it quits, and its
/// windows aren't restored next launch.
enum MacSnapshot {
    static var isRequested: Bool { UserDefaults.standard.string(forKey: "MacSnapshot") != nil }

    /// Where snapshots and the sample data live, inside the app's container.
    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var usesSampleData: Bool { isRequested && UserDefaults.standard.bool(forKey: "MacSnapshotSampleData") }

    /// A fresh store for the sample data, replacing the user's data for this run (one file per
    /// snapshot name, so runs side by side don't share it).
    @MainActor
    static func sampleUserDataStore() -> UserDataStore? {
        guard usesSampleData, let name = UserDefaults.standard.string(forKey: "MacSnapshot") else { return nil }
        let url = directory.appendingPathComponent("SampleUserData-\(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent).json")
        try? FileManager.default.removeItem(at: url)
        return UserDataStore(fileURL: url)
    }

    @MainActor
    static func runIfRequested(navigator: MacNavigator, catalog: CatalogStore, userData: UserDataStore, programCatalog: ProgramCatalogStore) async {
        guard let name = UserDefaults.standard.string(forKey: "MacSnapshot") else { return }
        let defaults = UserDefaults.standard
        rememberSettings()
        NSApp.setActivationPolicy(.accessory)
        // Off screen and click-through, so the user never sees or hits it.
        for window in NSApp.windows where !(window is NSPanel) { hide(window) }
        if let appearance = defaults.string(forKey: "MacSnapshotAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        let delay = defaults.double(forKey: "MacSnapshotDelay")
        let deadline = ContinuousClock.now + .seconds(delay > 0 ? delay : 6)

        // Sample data needs the term's catalog, which is ready once bootstrapping ends.
        if usesSampleData {
            while catalog.readyIndex == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            MacSampleData.seed(userData: userData, catalog: catalog)
        }
        if let selection = defaults.string(forKey: "MacSnapshotSelection") {
            navigator.selection = parse(selection, userData: userData)
        }
        let size = defaults.string(forKey: "MacSnapshotSize")?.split(separator: "x").compactMap { Double($0) }
        let requestedSize = size?.count == 2 ? NSSize(width: size![0], height: size![1]) : nil
        let url = directory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)

        if let viewName = defaults.string(forKey: "MacSnapshotView") {
            if let view = MacSampleData.snapshotView(named: viewName, catalog: catalog, userData: userData) {
                let content = view.macEnvironment(catalog: catalog, userData: userData, programCatalog: programCatalog, navigator: navigator)
                await render(content, size: requestedSize, until: deadline, to: url)
                print("MacSnapshot: \(url.path)")
            } else {
                print("MacSnapshot: no view named \(viewName)")
            }
            finish()
            return
        }
        try? await Task.sleep(until: deadline)

        guard let window = NSApp.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) && $0.identifier?.rawValue.hasPrefix(MacWindowID.main) != false }) else {
            finish()
            return
        }
        if let requestedSize {
            window.setContentSize(requestedSize)
            try? await Task.sleep(for: .seconds(1))
        }
        write(view: window.contentView?.superview ?? window.contentView, to: url)
        print("MacSnapshot: \(url.path)")
        finish()
    }

    /// The app's settings when the run started, put back when it ends.
    @MainActor private static var originalSettings: [String: Any]?

    @MainActor
    private static func rememberSettings() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        originalSettings = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        // Also when the app quits some other way, after windows save their frames.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { restoreSettings() }
        }
    }

    @MainActor
    private static func restoreSettings() {
        guard let domain = Bundle.main.bundleIdentifier, let originalSettings else { return }
        UserDefaults.standard.setPersistentDomain(originalSettings, forName: domain)
    }

    @MainActor
    private static func finish() {
        for window in NSApp.windows {
            window.isRestorable = false
            window.setFrameAutosaveName("")
        }
        restoreSettings()
        NSApp.terminate(nil)
    }

    /// Renders a view in an invisible window of its own (its fitting size unless one is given).
    @MainActor
    private static func render(_ view: some View, size: NSSize?, until deadline: ContinuousClock.Instant, to url: URL) async {
        let hosting = NSHostingView(rootView: view.background(.background))
        let fitting = hosting.fittingSize
        let frame = NSRect(origin: .zero, size: size ?? NSSize(width: max(fitting.width, 200), height: max(fitting.height, 100)))
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hide(window)
        window.orderFront(nil)
        // Give `.task` work (loading a course, the clock) time to land.
        try? await Task.sleep(until: max(deadline, ContinuousClock.now + .seconds(1)))
        if size == nil {
            let settled = hosting.fittingSize
            window.setContentSize(NSSize(width: max(settled.width, 200), height: max(settled.height, 100)))
            try? await Task.sleep(for: .milliseconds(300))
        }
        write(view: hosting, to: url)
        window.orderOut(nil)
    }

    @MainActor
    private static func hide(_ window: NSWindow) {
        // Never remembered: not its frame, not for the next launch.
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.ignoresMouseEvents = true
    }

    /// Draws the views into a bitmap. Window-server effects aren't included: vibrant sidebar
    /// text and glass come out blank (snapshot the sidebar on its own with
    /// `-MacSnapshotView sidebar`). Capturing the composited window would need the screen
    /// recording permission, which snapshots never ask for.
    @MainActor
    private static func write(view: NSView?, to url: URL) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print("MacSnapshotPNG:" + png.base64EncodedString())
        fflush(stdout)
    }

    @MainActor
    private static func parse(_ text: String, userData: UserDataStore) -> MacSidebarItem? {
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : nil
        func plan(_ ids: [UUID]) -> UUID? {
            argument == "first" ? ids.first : argument.flatMap(UUID.init(uuidString:))
        }
        let schedule = plan(userData.plans.map(\.id))
        let degreePlan = plan(userData.sortedDegreePlans.map(\.id))
        switch parts[0] {
        case "search": return .search
        case "subjects": return .subjects
        case "saved": return .saved
        case "professors": return .professors
        case "rooms": return .rooms
        case "schedules": return .schedules
        case "schedule": return schedule.map(MacSidebarItem.schedule) ?? .schedules
        case "degreePlans": return .degreePlans
        case "degreePlan": return degreePlan.map(MacSidebarItem.degreePlan) ?? .degreePlans
        case "degreeRequirements": return degreePlan.map(MacSidebarItem.degreeRequirements) ?? .degreePlans
        case "watchlist": return .watchlist
        default: return .search
        }
    }
}
#endif
