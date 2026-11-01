// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ArtemisAudio

/// The hand-over between the audio threads (decoder → speaker, microphone → encoder).
final class AudioRingTests: XCTestCase {
    func testKeepsOrderAcrossTheWrap() {
        let ring = AudioRing<Int16>(capacity: 10)
        var next: Int16 = 0
        var expected: Int16 = 0
        for _ in 0..<50 {
            let chunk = (0..<7).map { _ -> Int16 in defer { next += 1 }; return next }
            XCTAssertEqual(chunk.withUnsafeBufferPointer { ring.write($0) }, 7)
            var out = [Int16](repeating: -1, count: 7)
            XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0) }, 7)
            for value in out { XCTAssertEqual(value, expected); expected += 1 }
        }
    }

    func testFullRingDropsTheNewestAndSaysSo() {
        let ring = AudioRing<Int16>(capacity: 8)
        XCTAssertEqual([Int16](1...6).withUnsafeBufferPointer { ring.write($0) }, 6)
        XCTAssertEqual([Int16](7...12).withUnsafeBufferPointer { ring.write($0) }, 2)
        XCTAssertEqual(ring.count, 8)
        var out = [Int16](repeating: 0, count: 8)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0) }, 8)
        XCTAssertEqual(out, [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testEmptyRingReadsNothing() {
        let ring = AudioRing<Float>(capacity: 4)
        var out = [Float](repeating: 9, count: 4)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0) }, 0)
        XCTAssertEqual(out, [9, 9, 9, 9])
    }

    func testClearEmpties() {
        let ring = AudioRing<Float>(capacity: 4)
        _ = [Float](repeating: 1, count: 3).withUnsafeBufferPointer { ring.write($0) }
        ring.clear()
        XCTAssertEqual(ring.count, 0)
    }

    func testOneWriterOneReaderOnTwoThreads() {
        let ring = AudioRing<Int16>(capacity: 256)
        let total = 200_000
        let done = expectation(description: "writer")
        DispatchQueue.global().async {
            var value = 0
            while value < total {
                let chunk = (0..<min(37, total - value)).map { Int16(truncatingIfNeeded: value + $0) }
                let written = chunk.withUnsafeBufferPointer { ring.write($0) }
                value += written
            }
            done.fulfill()
        }
        var read = 0
        var out = [Int16](repeating: 0, count: 50)
        let deadline = Date().addingTimeInterval(20)
        while read < total && Date() < deadline {
            let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            for i in 0..<n { XCTAssertEqual(out[i], Int16(truncatingIfNeeded: read + i)); if out[i] != Int16(truncatingIfNeeded: read + i) { return } }
            read += n
        }
        XCTAssertEqual(read, total)
        wait(for: [done], timeout: 5)
    }
}
