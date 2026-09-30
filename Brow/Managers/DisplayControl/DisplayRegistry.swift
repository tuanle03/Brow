//
//  DisplayRegistry.swift
//  Brow
//
//  Matches online external CGDisplays to the DCPAVServiceProxy IORegistry
//  entries that carry their DDC/CI channel. Ported from MonitorControl's
//  `Arm64DDC.getServiceMatches` / `ioregMatchScore` (MIT): framebuffer
//  entries (AppleCLCD2 / IOMobileFramebufferShim) describe the panel, the
//  DCPAVServiceProxy that follows them is its I2C service.
//

import CoreGraphics
import Foundation
import IOKit

enum DisplayRegistry {
    private struct Candidate {
        var edidUUID = ""
        var productName = ""
        var serialNumber: Int64 = 0
        var ioDisplayLocation = ""
        var serviceLocation = 0
        var service: UnsafeMutableRawPointer?
    }

    private static let framebufferNames: Set<String> = ["AppleCLCD2", "IOMobileFramebufferShim"]
    private static let avServiceProxyName = "DCPAVServiceProxy"

    private typealias CoreDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let coreDisplayInfo: CoreDisplayInfoFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let sym = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(sym, to: CoreDisplayInfoFn.self)
    }()

    static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    static func match(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: Arm64DDCTransport] {
        guard Arm64DDCTransport.isSupported else { return [:] }
        let candidates = ioregCandidates()
        defer { candidates.forEach { if let s = $0.service { Unmanaged<AnyObject>.fromOpaque(s).release() } } }

        var scored: [(score: Int, order: Int, displayID: CGDirectDisplayID, candidate: Candidate)] = []
        for displayID in displayIDs {
            for candidate in candidates where candidate.service != nil {
                scored.append((matchScore(displayID: displayID, candidate: candidate), scored.count, displayID, candidate))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }

        var takenDisplays = Set<CGDirectDisplayID>()
        var takenLocations = Set<Int>()
        var result: [CGDirectDisplayID: Arm64DDCTransport] = [:]
        for entry in scored where entry.score > 0
            && !takenDisplays.contains(entry.displayID)
            && !takenLocations.contains(entry.candidate.serviceLocation) {
            takenDisplays.insert(entry.displayID)
            takenLocations.insert(entry.candidate.serviceLocation)
            let retained = Unmanaged<AnyObject>.fromOpaque(entry.candidate.service!).retain().toOpaque()
            result[entry.displayID] = Arm64DDCTransport(retainedService: retained)
        }
        return result
    }

    // MARK: - IORegistry walk

    private static func ioregCandidates() -> [Candidate] {
        var result: [Candidate] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { nameBuffer.deallocate() }

        var current = Candidate()
        var serviceLocation = 0
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, nameBuffer) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuffer)

            if framebufferNames.contains(name) {
                current = framebufferCandidate(entry)
                serviceLocation += 1
                current.serviceLocation = serviceLocation
            } else if name == avServiceProxyName {
                var candidate = current
                candidate.service = nil
                if property(entry, "Location") as? String == "External" {
                    candidate.service = Arm64DDCTransport.createService?(nil, entry)
                }
                result.append(candidate)
            }
        }
        return result
    }

    private static func framebufferCandidate(_ entry: io_registry_entry_t) -> Candidate {
        var candidate = Candidate()
        candidate.edidUUID = property(entry, "EDID UUID") as? String ?? ""
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { path.deallocate() }
        if IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS {
            candidate.ioDisplayLocation = String(cString: path)
        }
        if let attributes = property(entry, "DisplayAttributes") as? NSDictionary,
           let product = attributes["ProductAttributes"] as? NSDictionary {
            candidate.productName = product["ProductName"] as? String ?? ""
            candidate.serialNumber = (product["SerialNumber"] as? NSNumber)?.int64Value ?? 0
        }
        return candidate
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))?.takeRetainedValue()
    }

    // MARK: - Scoring (MonitorControl `ioregMatchScore`)

    private static func matchScore(displayID: CGDirectDisplayID, candidate: Candidate) -> Int {
        guard let coreDisplayInfo, let raw = coreDisplayInfo(displayID) else { return 0 }
        let info = raw.takeRetainedValue() as NSDictionary
        var score = 0

        func int64(_ key: String) -> Int64? { (info[key] as? NSNumber)?.int64Value }
        func hex2(_ v: Int64) -> String { String(format: "%02X", UInt8(clamping: v)) }

        if let year = int64(kDisplayYearOfManufacture), let week = int64(kDisplayWeekOfManufacture),
           let vendor = int64(kDisplayVendorID), let product = int64(kDisplayProductID),
           let vSize = int64(kDisplayVerticalImageSize), let hSize = int64(kDisplayHorizontalImageSize) {
            let productID = UInt16(clamping: product)
            let keys: [(key: String, location: Int)] = [
                (String(format: "%04X", UInt16(clamping: vendor)), 0),
                (hex2(Int64(productID & 0xFF)) + hex2(Int64(productID >> 8)), 4),
                (hex2(week) + hex2(year - 1990), 19),
                (hex2(hSize / 10) + hex2(vSize / 10), 30),
            ]
            for (key, location) in keys where key != "0000"
                && key == String(candidate.edidUUID.prefix(location + 4).suffix(4)) {
                score += 1
            }
        }
        if !candidate.ioDisplayLocation.isEmpty,
           let location = info[kIODisplayLocationKey] as? String, location == candidate.ioDisplayLocation {
            score += 10
        }
        if !candidate.productName.isEmpty,
           let names = info["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.first?.value,
           name.lowercased() == candidate.productName.lowercased() {
            score += 1
        }
        if candidate.serialNumber != 0, let serial = int64(kDisplaySerialNumber), serial == candidate.serialNumber {
            score += 1
        }
        return score
    }
}
