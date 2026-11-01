// SPDX-License-Identifier: GPL-3.0-or-later
//
//  AudioRing.swift
//  Artemis
//
//  A fixed-size ring of samples between two audio threads: one writer, one reader, no locks
//  (the real-time audio thread must never wait). Full: the newest samples are dropped.
//

import Synchronization

final class AudioRing<Element: BitwiseCopyable>: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Element>
    /// Total samples written / read; their difference is what's waiting.
    private let written = Atomic<Int>(0)
    private let readCount = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Samples waiting to be read.
    var count: Int {
        written.load(ordering: .acquiring) - readCount.load(ordering: .acquiring)
    }

    /// Writer's side. Returns how many fit.
    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Element>) -> Int {
        guard let base = samples.baseAddress else { return 0 }
        let w = written.load(ordering: .relaxed)
        let r = readCount.load(ordering: .acquiring)
        let n = min(samples.count, capacity - (w - r))
        guard n > 0 else { return 0 }
        let start = w % capacity
        let first = min(n, capacity - start)
        (storage + start).update(from: base, count: first)
        if n > first {
            storage.update(from: base + first, count: n - first)
        }
        written.store(w + n, ordering: .releasing)
        return n
    }

    /// Reader's side. Returns how many were read (fewer than asked when the ring runs short).
    @discardableResult
    func read(into destination: UnsafeMutableBufferPointer<Element>) -> Int {
        guard let base = destination.baseAddress else { return 0 }
        let r = readCount.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        let n = min(destination.count, w - r)
        guard n > 0 else { return 0 }
        let start = r % capacity
        let first = min(n, capacity - start)
        base.update(from: storage + start, count: first)
        if n > first {
            (base + first).update(from: storage, count: n - first)
        }
        readCount.store(r + n, ordering: .releasing)
        return n
    }

    /// Reader's side: drops what's waiting.
    func clear() {
        readCount.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}
