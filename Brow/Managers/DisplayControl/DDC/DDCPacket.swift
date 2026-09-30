//
//  DDCPacket.swift
//  Brow
//
//  DDC/CI framing for Apple Silicon IOAVService I2C writes. Framing and
//  checksum seeds are copied from MonitorControl's
//  `Arm64DDC.performDDCCommunication` (MIT) — do not "fix" the get seed.
//

import Foundation

enum DDCVCP {
    static let brightness: UInt8 = 0x10
    static let volume: UInt8 = 0x62
}

struct DDCReading: Equatable {
    let current: UInt16
    let max: UInt16
}

enum DDCPacket {
    static let replyLength = 11

    static func setVCP(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        frame([vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func getVCP(_ vcp: UInt8) -> [UInt8] {
        frame([vcp])
    }

    /// Parses an 11-byte "VCP feature reply": bytes 6-7 max, 8-9 current,
    /// byte 10 checksum seeded with 0x50.
    static func parseReply(_ reply: [UInt8]) -> DDCReading? {
        guard reply.count == replyLength,
              checksum(seed: 0x50, reply.dropLast()) == reply[replyLength - 1] else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0 else { return nil }
        return DDCReading(current: min(current, max), max: max)
    }

    static func checksum<S: Sequence>(seed: UInt8, _ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    private static func frame(_ send: [UInt8]) -> [UInt8] {
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send
        let seed: UInt8 = send.count == 1 ? 0x6E : 0x6E ^ 0x51
        packet.append(checksum(seed: seed, packet))
        return packet
    }
}
