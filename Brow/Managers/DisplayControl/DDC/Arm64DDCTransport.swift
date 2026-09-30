//
//  Arm64DDCTransport.swift
//  Brow
//
//  I2C over Apple Silicon's private IOAVService API (same calls as
//  MonitorControl's Arm64DDC, MIT). Symbols are resolved at runtime; if
//  they are missing (Intel, future macOS) no transport is created and the
//  display falls back to gamma dimming.
//

import Foundation
import IOKit

final class Arm64DDCTransport: DDCTransport {
    typealias CreateFn = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias I2CFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let createService: CreateFn? = symbol("IOAVServiceCreateWithService")
    private static let writeI2C: I2CFn? = symbol("IOAVServiceWriteI2C")
    private static let readI2C: I2CFn? = symbol("IOAVServiceReadI2C")

    static var isSupported: Bool { createService != nil && writeI2C != nil && readI2C != nil }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private let service: UnsafeMutableRawPointer

    /// Takes ownership of a +1 IOAVService reference.
    init(retainedService: UnsafeMutableRawPointer) {
        service = retainedService
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(service).release()
    }

    func write(_ packet: [UInt8]) -> Bool {
        guard let writeI2C = Self.writeI2C else { return false }
        var bytes = packet
        let result = bytes.withUnsafeMutableBytes { buffer in
            writeI2C(service, Self.chipAddress, Self.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        return result == kIOReturnSuccess
    }

    func read(count: Int) -> [UInt8]? {
        guard let readI2C = Self.readI2C else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            readI2C(service, Self.chipAddress, 0, buffer.baseAddress!, UInt32(buffer.count))
        }
        return result == kIOReturnSuccess ? bytes : nil
    }

    private static func symbol<T>(_ name: String) -> T? {
        // RTLD_DEFAULT — IOKit is already linked into the process.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
