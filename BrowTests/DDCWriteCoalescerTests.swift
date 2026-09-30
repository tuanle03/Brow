import XCTest
@testable import Brow

private final class RecordingChannel: DDCChanneling {
    var result = true
    var onWrite: ((UInt16) -> Void)?
    private(set) var written: [UInt16] = []

    func write(vcp: UInt8, value: UInt16) -> Bool {
        written.append(value)
        onWrite?(value)
        return result
    }

    func read(vcp: UInt8) -> DDCReading? { nil }
}

/// Holds scheduled blocks until the test runs them.
private final class ManualExecutor {
    private(set) var blocks: [() -> Void] = []
    func schedule(_ block: @escaping () -> Void) { blocks.append(block) }
    func runAll() {
        let pending = blocks
        blocks.removeAll()
        pending.forEach { $0() }
    }
}

final class DDCWriteCoalescerTests: XCTestCase {
    func testRapidSubmitsCollapseToLatestValue() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: channel, executor: executor.schedule)

        for value in UInt16(1)...10 { writer.submit(value) }
        XCTAssertEqual(executor.blocks.count, 1, "only one drain is scheduled while one is pending")

        executor.runAll()
        XCTAssertEqual(channel.written, [10])
    }

    func testSubmitDuringWriteIsDrainedInSamePass() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: channel, executor: executor.schedule)
        channel.onWrite = { value in if value == 1 { writer.submit(2) } }

        writer.submit(1)
        executor.runAll()

        XCTAssertEqual(channel.written, [1, 2])
        XCTAssertTrue(executor.blocks.isEmpty, "no extra drain scheduled while draining")
    }

    func testNewSubmitAfterDrainSchedulesAgain() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: channel, executor: executor.schedule)

        writer.submit(5)
        executor.runAll()
        writer.submit(6)
        XCTAssertEqual(executor.blocks.count, 1)
        executor.runAll()
        XCTAssertEqual(channel.written, [5, 6])
    }

    func testReportsEachWriteResult() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.volume, channel: channel, executor: executor.schedule)
        var results: [Bool] = []
        writer.onResult = { results.append($0) }

        writer.submit(1)
        executor.runAll()
        channel.result = false
        writer.submit(2)
        executor.runAll()

        XCTAssertEqual(results, [true, false])
    }
}
