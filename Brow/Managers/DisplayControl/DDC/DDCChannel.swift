//
//  DDCChannel.swift
//  Brow
//
//  Retrying VCP read/write over a raw I2C transport. Timings follow
//  MonitorControl's Arm64DDC defaults (2 write cycles 10 ms apart, 50 ms
//  before reading a reply, 20 ms between attempts).
//

import Foundation

protocol DDCTransport: AnyObject {
    func write(_ packet: [UInt8]) -> Bool
    func read(count: Int) -> [UInt8]?
}

protocol DDCChanneling {
    func write(vcp: UInt8, value: UInt16) -> Bool
    func read(vcp: UInt8) -> DDCReading?
}

struct DDCChannel: DDCChanneling {
    static let attempts = 3
    static let writeCycles = 2
    static let writeSleep: UInt32 = 10_000
    static let readSleep: UInt32 = 50_000
    static let retrySleep: UInt32 = 20_000

    let transport: DDCTransport
    let sleep: (UInt32) -> Void

    init(transport: DDCTransport, sleep: @escaping (UInt32) -> Void = { usleep($0) }) {
        self.transport = transport
        self.sleep = sleep
    }

    func write(vcp: UInt8, value: UInt16) -> Bool {
        let packet = DDCPacket.setVCP(vcp, value: value)
        for attempt in 0..<Self.attempts {
            if send(packet) { return true }
            if attempt < Self.attempts - 1 { sleep(Self.retrySleep) }
        }
        return false
    }

    func read(vcp: UInt8) -> DDCReading? {
        let packet = DDCPacket.getVCP(vcp)
        for attempt in 0..<Self.attempts {
            if send(packet) {
                sleep(Self.readSleep)
                if let bytes = transport.read(count: DDCPacket.replyLength),
                   let reading = DDCPacket.parseReply(bytes) {
                    return reading
                }
            }
            if attempt < Self.attempts - 1 { sleep(Self.retrySleep) }
        }
        return nil
    }

    /// One attempt = `writeCycles` writes; the attempt succeeds if the last one did.
    private func send(_ packet: [UInt8]) -> Bool {
        var ok = false
        for _ in 0..<Self.writeCycles {
            sleep(Self.writeSleep)
            ok = transport.write(packet)
        }
        return ok
    }
}
