// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import XCTest
@testable import ArtemisAudio

final class MicLevelAndToneTests: XCTestCase {
    func testMeterFollowsThePeakAndFallsBackSlowly() {
        // As the Mac's meter: the peak over the last tick, falling by 0.72 per tick, signal from 2 %
        var meter = MicLevelMeter()
        meter.add([0, 16384, -8000])
        meter.tick()
        XCTAssertEqual(meter.level, 0.5, accuracy: 0.001)
        XCTAssertTrue(meter.signalDetected)
        meter.tick()
        XCTAssertEqual(meter.level, 0.36, accuracy: 0.001)
        for _ in 0..<12 { meter.tick() }
        XCTAssertLessThan(meter.level, 0.02)
        XCTAssertFalse(meter.signalDetected)
        XCTAssertTrue(meter.heardAnything)
    }

    func testSilenceIsNoSignal() {
        var meter = MicLevelMeter()
        meter.add([Int16](repeating: 0, count: 960))
        meter.tick()
        XCTAssertEqual(meter.level, 0)
        XCTAssertFalse(meter.heardAnything)
    }

    func testNegativeFullScaleDoesNotOverflow() {
        var meter = MicLevelMeter()
        meter.add([Int16.min])
        meter.tick()
        XCTAssertEqual(meter.level, 1, accuracy: 0.001)
    }

    func testToneSoundsLikeSpeechAtAnUntypicalRate() {
        // The stand-in for a voice in tests: 44.1 kHz stereo (so the conversion runs), a pitch
        // with syllables (loud and quiet parts), never silent for long
        var tone = TestTone(sampleRate: 44100, channels: 2)
        let buffer = tone.next(frames: 44100)
        XCTAssertEqual(buffer.format.sampleRate, 44100)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertEqual(buffer.frameLength, 44100)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 44100))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: 44100))
        XCTAssertEqual(left, right)
        let peak = left.map(abs).max()!
        XCTAssertGreaterThan(peak, 0.2)
        XCTAssertLessThanOrEqual(peak, 0.5)
        // Loud and quiet stretches of 50 ms
        let blocks = stride(from: 0, to: 44100 - 2205, by: 2205).map { start in left[start..<start + 2205].map(abs).max()! }
        XCTAssertGreaterThan(blocks.max()! / max(blocks.min()!, 0.0001), 2)
        // Continuous across calls: no click at the seam
        let more = tone.next(frames: 10)
        XCTAssertEqual(more.floatChannelData![0][0], left[44099], accuracy: 0.05)
    }

    func testToneThroughTheAssemblerKeepsItsPitch() {
        var tone = TestTone(sampleRate: 44100, channels: 2)
        let assembler = MicFrameAssembler(inputFormat: tone.format)
        var frames: [[Int16]] = []
        for _ in 0..<100 { frames += assembler.append(tone.next(frames: 441)) }
        XCTAssertTrue(frames.allSatisfy { $0.count == 960 })
        let audio = Array(frames.dropFirst(2).joined())
        var crossings = 0
        for i in 1..<audio.count where audio[i - 1] < 0 && audio[i] >= 0 { crossings += 1 }
        XCTAssertEqual(Double(crossings) / (Double(audio.count) / 48000), TestTone.frequency, accuracy: 5)
    }
}
