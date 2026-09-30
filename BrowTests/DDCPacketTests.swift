import XCTest
@testable import Brow

final class DDCPacketTests: XCTestCase {
    func testSetBrightnessPacket() {
        XCTAssertEqual(DDCPacket.setVCP(DDCVCP.brightness, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testSetPacketSplitsHighByte() {
        XCTAssertEqual(DDCPacket.setVCP(DDCVCP.brightness, value: 300), [0x84, 0x03, 0x10, 0x01, 0x2C, 0x85])
    }

    func testSetVolumePacket() {
        XCTAssertEqual(DDCPacket.setVCP(DDCVCP.volume, value: 30), [0x84, 0x03, 0x62, 0x00, 0x1E, 0xC4])
    }

    func testGetPackets() {
        XCTAssertEqual(DDCPacket.getVCP(DDCVCP.brightness), [0x82, 0x01, 0x10, 0xFD])
        XCTAssertEqual(DDCPacket.getVCP(DDCVCP.volume), [0x82, 0x01, 0x62, 0x8F])
    }

    func testParseValidBrightnessReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        XCTAssertEqual(DDCPacket.parseReply(reply), DDCReading(current: 50, max: 100))
    }

    func testParseValidVolumeReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x1E, 0xAC]
        XCTAssertEqual(DDCPacket.parseReply(reply), DDCReading(current: 30, max: 100))
    }

    func testParseRejectsBadChecksum() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF3]
        XCTAssertNil(DDCPacket.parseReply(reply))
    }

    func testParseRejectsShortReply() {
        XCTAssertNil(DDCPacket.parseReply([0x6E, 0x88, 0x02]))
    }

    func testParseRejectsAllZeros() {
        XCTAssertNil(DDCPacket.parseReply([UInt8](repeating: 0, count: DDCPacket.replyLength)))
    }

    func testParseRejectsZeroMax() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x32, 0x96]
        XCTAssertNil(DDCPacket.parseReply(reply))
    }
}
