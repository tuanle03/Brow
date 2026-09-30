import XCTest
@testable import Brow

private final class FakeTransport: DDCTransport {
    var writeResults: [Bool] = []          // consumed in order; empty → true
    var readResult: [UInt8]?
    private(set) var writes: [[UInt8]] = []
    private(set) var readCount = 0

    func write(_ packet: [UInt8]) -> Bool {
        writes.append(packet)
        return writeResults.isEmpty ? true : writeResults.removeFirst()
    }

    func read(count: Int) -> [UInt8]? {
        readCount += 1
        return readResult
    }
}

final class DDCChannelTests: XCTestCase {
    private var sleeps: [UInt32] = []
    private func channel(_ t: FakeTransport) -> DDCChannel {
        DDCChannel(transport: t, sleep: { [unowned self] in self.sleeps.append($0) })
    }

    private let validReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]

    func testWriteSucceedsOnFirstAttemptWithTwoWriteCycles() {
        let t = FakeTransport()
        XCTAssertTrue(channel(t).write(vcp: DDCVCP.brightness, value: 50))
        XCTAssertEqual(t.writes, [DDCPacket.setVCP(0x10, value: 50), DDCPacket.setVCP(0x10, value: 50)])
    }

    func testWriteRetriesAfterFailedAttempt() {
        let t = FakeTransport()
        t.writeResults = [false, false, true, true]
        XCTAssertTrue(channel(t).write(vcp: DDCVCP.brightness, value: 50))
        XCTAssertEqual(t.writes.count, 4)
        XCTAssertTrue(sleeps.contains(DDCChannel.retrySleep))
    }

    func testWriteGivesUpAfterThreeAttempts() {
        let t = FakeTransport()
        t.writeResults = Array(repeating: false, count: 20)
        XCTAssertFalse(channel(t).write(vcp: DDCVCP.brightness, value: 50))
        XCTAssertEqual(t.writes.count, DDCChannel.attempts * DDCChannel.writeCycles)
    }

    func testReadReturnsParsedReply() {
        let t = FakeTransport()
        t.readResult = validReply
        XCTAssertEqual(channel(t).read(vcp: DDCVCP.brightness), DDCReading(current: 50, max: 100))
        XCTAssertEqual(t.writes.first, DDCPacket.getVCP(0x10))
        XCTAssertTrue(sleeps.contains(DDCChannel.readSleep))
    }

    func testReadGivesUpOnGarbageReplies() {
        let t = FakeTransport()
        t.readResult = [UInt8](repeating: 0, count: DDCPacket.replyLength)
        XCTAssertNil(channel(t).read(vcp: DDCVCP.brightness))
        XCTAssertEqual(t.readCount, DDCChannel.attempts)
    }

    func testReadDoesNotReadWhenRequestWriteFails() {
        let t = FakeTransport()
        t.writeResults = Array(repeating: false, count: 20)
        t.readResult = validReply
        XCTAssertNil(channel(t).read(vcp: DDCVCP.brightness))
        XCTAssertEqual(t.readCount, 0)
    }
}
