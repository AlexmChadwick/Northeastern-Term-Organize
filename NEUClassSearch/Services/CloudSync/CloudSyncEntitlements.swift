//
//  CloudSyncEntitlements.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//
//  Reads the running app's own entitlements so CloudKit is only touched by a build that is
//  signed for it. `CKContainer` raises an Objective-C exception (which Swift can't catch) in
//  a process without the iCloud entitlements, for example if the iCloud capability is
//  removed but the Info.plist key stays. This check turns that crash into "iCloud sync
//  isn't set up in this build". Only public APIs are used: the simulator's entitlements
//  section, and the code signature of the app's own executable file.
//

import Foundation
import MachO

enum CloudSyncEntitlements {
    enum Availability: Equatable, Sendable {
        /// The signature grants CloudKit and the container.
        case available
        /// The signature doesn't grant CloudKit for the container.
        case missing
        /// The entitlements couldn't be read; the Info.plist key is trusted.
        case unknown
    }

    static let servicesKey = "com.apple.developer.icloud-services"
    static let containersKey = "com.apple.developer.icloud-container-identifiers"

    /// Whether the running app may use CloudKit with `containerIdentifier`. Reads files, so
    /// call it off the main actor.
    static func cloudKitAvailability(containerIdentifier: String) -> Availability {
        guard let entitlements = currentEntitlements() else { return .unknown }
        return grantsCloudKit(entitlements, containerIdentifier: containerIdentifier) ? .available : .missing
    }

    /// Whether a set of entitlements includes the CloudKit service and the container.
    static func grantsCloudKit(_ entitlements: [String: Any], containerIdentifier: String) -> Bool {
        let services: [String]
        switch entitlements[servicesKey] {
        case let list as [String]: services = list
        case let single as String: services = [single]
        default: services = []
        }
        guard services.contains("CloudKit") || services.contains("*") else { return false }
        let containers = entitlements[containersKey] as? [String] ?? []
        return containers.contains(containerIdentifier)
    }

    /// The running app's entitlements, or nil if they can't be read.
    static func currentEntitlements() -> [String: Any]? {
        #if targetEnvironment(simulator)
        // Simulator builds carry their entitlements in a section of the executable; their
        // ad hoc signature may list fewer, so it isn't consulted.
        return simulatorEntitlements()
        #else
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return codeSignatureEntitlements(in: data)
        #endif
    }

    /// The `__TEXT,__entitlements` section of the app's executable (or a library inside the
    /// app, such as Xcode's debug dylib), as simulator builds embed it. A build without the
    /// section has no entitlements at all (it was built without signing), so it gets none,
    /// rather than "unknown": creating a CloudKit container without them stops the app.
    static func simulatorEntitlements() -> [String: Any]? {
        let bundleFolder = "/" + Bundle.main.bundleURL.lastPathComponent + "/"
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { continue }
            guard index == 0 || String(cString: cName).contains(bundleFolder) else { continue }
            var size: UInt = 0
            let mh = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            guard let bytes = getsectiondata(mh, "__TEXT", "__entitlements", &size), size > 0 else { continue }
            let data = Data(bytes: bytes, count: Int(size))
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        return [:]
    }

    // MARK: Code signature

    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let machOMagic64: UInt32 = 0xFEED_FACF
    private static let loadCommandCodeSignature: UInt32 = 0x1D
    private static let superBlobMagic: UInt32 = 0xFADE_0CC0
    private static let entitlementsBlobMagic: UInt32 = 0xFADE_7171
    private static let entitlementsSlot: UInt32 = 5
    #if arch(arm64)
    private static let cpuType: UInt32 = 0x0100_000C
    #else
    private static let cpuType: UInt32 = 0x0100_0007
    #endif

    /// The entitlements in a Mach-O file's code signature: nil if the file isn't a signed
    /// 64-bit Mach-O this code understands, empty if it is signed without entitlements.
    static func codeSignatureEntitlements(in data: Data) -> [String: Any]? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: Any]? in
            guard let slice = machOSlice(in: raw),
                  let signature = codeSignatureRange(in: raw, slice: slice) else { return nil }
            return entitlements(inSuperBlob: raw, range: signature)
        }
    }

    /// The byte range of this architecture's Mach-O inside a (possibly universal) file.
    private static func machOSlice(in raw: UnsafeRawBufferPointer) -> Range<Int>? {
        guard let magic = uint32(raw, at: 0, bigEndian: true) else { return nil }
        if magic == fatMagic || magic == fatMagic64 {
            let is64 = magic == fatMagic64
            guard let count = uint32(raw, at: 4, bigEndian: true), count < 64 else { return nil }
            for index in 0..<Int(count) {
                let entry = 8 + index * (is64 ? 32 : 20)
                guard let type = uint32(raw, at: entry, bigEndian: true) else { return nil }
                guard type == cpuType else { continue }
                let offset: Int?
                let size: Int?
                if is64 {
                    offset = uint64(raw, at: entry + 8).flatMap { Int(exactly: $0) }
                    size = uint64(raw, at: entry + 16).flatMap { Int(exactly: $0) }
                } else {
                    offset = uint32(raw, at: entry + 8, bigEndian: true).map { Int($0) }
                    size = uint32(raw, at: entry + 12, bigEndian: true).map { Int($0) }
                }
                guard let offset, let size, size > 0, offset <= raw.count - size else { return nil }
                return offset..<(offset + size)
            }
            return nil
        }
        guard uint32(raw, at: 0, bigEndian: false) == machOMagic64 else { return nil }
        return 0..<raw.count
    }

    /// The byte range of the code signature named by `LC_CODE_SIGNATURE`.
    private static func codeSignatureRange(in raw: UnsafeRawBufferPointer, slice: Range<Int>) -> Range<Int>? {
        let base = slice.lowerBound
        guard uint32(raw, at: base, bigEndian: false) == machOMagic64,
              let commandCount = uint32(raw, at: base + 16, bigEndian: false) else { return nil }
        var cursor = base + 32 // sizeof(mach_header_64)
        for _ in 0..<min(Int(commandCount), 4096) {
            guard let command = uint32(raw, at: cursor, bigEndian: false),
                  let size = uint32(raw, at: cursor + 4, bigEndian: false), size >= 8 else { return nil }
            if command == loadCommandCodeSignature {
                guard let offset = uint32(raw, at: cursor + 8, bigEndian: false),
                      let length = uint32(raw, at: cursor + 12, bigEndian: false) else { return nil }
                let start = base + Int(offset)
                let end = start + Int(length)
                guard start < end, end <= slice.upperBound else { return nil }
                return start..<end
            }
            cursor += Int(size)
            guard cursor < slice.upperBound else { return nil }
        }
        return nil
    }

    /// The XML entitlements blob in a code signature super blob (all fields big-endian).
    private static func entitlements(inSuperBlob raw: UnsafeRawBufferPointer, range: Range<Int>) -> [String: Any]? {
        let base = range.lowerBound
        guard uint32(raw, at: base, bigEndian: true) == superBlobMagic,
              let count = uint32(raw, at: base + 8, bigEndian: true), count < 64 else { return nil }
        for index in 0..<Int(count) {
            let entry = base + 12 + index * 8
            guard entry + 8 <= range.upperBound,
                  let type = uint32(raw, at: entry, bigEndian: true),
                  let offset = uint32(raw, at: entry + 4, bigEndian: true) else { return nil }
            guard type == entitlementsSlot else { continue }
            let blob = base + Int(offset)
            guard uint32(raw, at: blob, bigEndian: true) == entitlementsBlobMagic,
                  let length = uint32(raw, at: blob + 4, bigEndian: true), length >= 8,
                  blob + Int(length) <= range.upperBound else { return nil }
            let plist = Data(raw[(blob + 8)..<(blob + Int(length))])
            return (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
        }
        return [:]
    }

    private static func uint32(_ raw: UnsafeRawBufferPointer, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset <= raw.count - 4 else { return nil }
        let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    private static func uint64(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= raw.count - 8 else { return nil }
        return UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}
