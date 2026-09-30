import XCTest
@testable import Brow

private final class FakeGammaApplier: GammaApplying {
    var table: GammaTable? = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
    private(set) var currentTableCalls = 0
    private(set) var applied: [(GammaTable, CGDirectDisplayID)] = []
    private(set) var restoreCalls = 0

    func currentTable(for displayID: CGDirectDisplayID) -> GammaTable? {
        currentTableCalls += 1
        return table
    }
    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) { applied.append((table, displayID)) }
    func restoreSystemTables() { restoreCalls += 1 }
}

final class GammaDimmerTests: XCTestCase {
    private func assertChannel(_ actual: [CGGammaValue], _ expected: [CGGammaValue], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 0.0001, file: file, line: line) }
    }

    func testScaledHalvesTable() {
        let t = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
        let s = GammaDimmer.scaled(t, level: 0.5)
        assertChannel(s.red, [0, 0.25, 0.5])
        assertChannel(s.blue, [0, 0.25, 0.5])
    }

    func testScaledNeverGoesBelowFloor() {
        let t = GammaTable(red: [1], green: [1], blue: [1])
        assertChannel(GammaDimmer.scaled(t, level: 0).red, [0.1])
    }

    func testFullLevelAppliesOriginal() {
        let applier = FakeGammaApplier()
        let dimmer = GammaDimmer(applier: applier)
        dimmer.setLevel(1, for: 7)
        XCTAssertEqual(applier.applied.last?.0, applier.table)
        XCTAssertEqual(applier.applied.last?.1, 7)
    }

    func testOriginalTableCapturedOnce() {
        let applier = FakeGammaApplier()
        let dimmer = GammaDimmer(applier: applier)
        dimmer.setLevel(0.5, for: 7)
        applier.table = GammaTable(red: [0, 0.25, 0.5], green: [0, 0.25, 0.5], blue: [0, 0.25, 0.5]) // what the screen now reports
        dimmer.setLevel(0.5, for: 7)

        XCTAssertEqual(applier.currentTableCalls, 1)
        assertChannel(applier.applied.last!.0.red, [0, 0.25, 0.5]) // scales the original, not the dimmed table
    }

    func testRestoreAllRestoresAndForgetsOriginals() {
        let applier = FakeGammaApplier()
        let dimmer = GammaDimmer(applier: applier)
        dimmer.setLevel(0.5, for: 7)
        dimmer.restoreAll()
        XCTAssertEqual(applier.restoreCalls, 1)

        dimmer.setLevel(0.5, for: 7)
        XCTAssertEqual(applier.currentTableCalls, 2, "original re-captured after restore")
    }

    func testRestoreAllWithoutDimmingDoesNothing() {
        let applier = FakeGammaApplier()
        GammaDimmer(applier: applier).restoreAll()
        XCTAssertEqual(applier.restoreCalls, 0, "must not reset other apps' gamma (f.lux) when we never dimmed")
    }

    func testMissingTableAppliesNothing() {
        let applier = FakeGammaApplier()
        applier.table = nil
        GammaDimmer(applier: applier).setLevel(0.5, for: 7)
        XCTAssertTrue(applier.applied.isEmpty)
    }
}
