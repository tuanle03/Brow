//
//  GammaDimmer.swift
//  Brow
//
//  Software dimming for monitors without DDC/CI: scales the display's
//  original gamma transfer table. Can only dim, never exceed the monitor's
//  hardware brightness.
//

import CoreGraphics

struct GammaTable: Equatable {
    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]
}

protocol GammaApplying {
    func currentTable(for displayID: CGDirectDisplayID) -> GammaTable?
    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID)
    func restoreSystemTables()
}

final class GammaDimmer {
    static let minimumLevel = 0.1

    private let applier: GammaApplying
    private var originals: [CGDirectDisplayID: GammaTable] = [:]

    init(applier: GammaApplying) {
        self.applier = applier
    }

    func setLevel(_ level: Double, for displayID: CGDirectDisplayID) {
        let original: GammaTable
        if let cached = originals[displayID] {
            original = cached
        } else {
            guard let table = applier.currentTable(for: displayID) else { return }
            originals[displayID] = table
            original = table
        }
        applier.apply(level >= 1 ? original : Self.scaled(original, level: level), to: displayID)
    }

    func restoreAll() {
        guard !originals.isEmpty else { return }
        originals.removeAll()
        applier.restoreSystemTables()
    }

    static func scaled(_ table: GammaTable, level: Double) -> GammaTable {
        let factor = CGGammaValue(max(minimumLevel, min(1, level)))
        return GammaTable(
            red: table.red.map { $0 * factor },
            green: table.green.map { $0 * factor },
            blue: table.blue.map { $0 * factor }
        )
    }
}

struct CoreGraphicsGammaApplier: GammaApplying {
    func currentTable(for displayID: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return GammaTable(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) {
        _ = CGSetDisplayTransferByTable(displayID, UInt32(table.red.count), table.red, table.green, table.blue)
    }

    func restoreSystemTables() {
        CGDisplayRestoreColorSyncSettings()
    }
}
