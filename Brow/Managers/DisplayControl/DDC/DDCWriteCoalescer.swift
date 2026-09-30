//
//  DDCWriteCoalescer.swift
//  Brow
//
//  A DDC write takes ~50 ms; key autorepeat fires ~30×/s. Only the most
//  recent target value is ever written — intermediate values are dropped.
//

import Foundation

protocol LevelWriter: AnyObject {
    func submit(_ value: UInt16)
}

final class DDCWriteCoalescer: LevelWriter {
    typealias Executor = (@escaping () -> Void) -> Void

    /// Called on the executor's thread after every write.
    var onResult: ((Bool) -> Void)?

    private let vcp: UInt8
    private let channel: DDCChanneling
    private let executor: Executor
    private let lock = NSLock()
    private var pending: UInt16?
    private var draining = false

    init(vcp: UInt8, channel: DDCChanneling, executor: @escaping Executor) {
        self.vcp = vcp
        self.channel = channel
        self.executor = executor
    }

    func submit(_ value: UInt16) {
        lock.lock()
        pending = value
        let shouldSchedule = !draining
        draining = true
        lock.unlock()

        if shouldSchedule {
            executor { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let ok = channel.write(vcp: vcp, value: value)
            onResult?(ok)
        }
    }
}
