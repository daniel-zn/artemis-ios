// SPDX-License-Identifier: GPL-3.0-or-later
import AVFAudio
import XCTest
@testable import ArtemisAudio

/// What the PC gets from the microphone: 48 kHz mono, 20 ms (960-sample) frames, whatever the
/// iPhone's input runs at.
final class MicFrameAssemblerTests: XCTestCase {
    /// A sine as an input buffer: `channels` deinterleaved channels, the n-th scaled by `gains[n]`.
    private func sine(rate: Double, channels: Int, seconds: Double, frequency: Double,
                      amplitude: Float = 0.5, gains: [Float]? = nil, interleavedInt16: Bool = false) -> AVAudioPCMBuffer {
        let format = interleavedInt16
            ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: true)!
            : Self.floatFormat(rate: rate, channels: channels)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * .pi * frequency * Double(i) / rate))
            for c in 0..<channels {
                let v = value * (gains?[c] ?? 1)
                if interleavedInt16 {
                    buffer.int16ChannelData![0][i * channels + c] = Int16(v * 32767)
                } else {
                    buffer.floatChannelData![c][i] = v
                }
            }
        }
        return buffer
    }

    /// Deinterleaved float; more than 2 channels need a layout (discrete, as voice processing's).
    static func floatFormat(rate: Double, channels: Int) -> AVAudioFormat {
        if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))! }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
    }

    /// Feeds `buffer` in chunks of `chunk` frames (as the audio thread delivers it), returns every frame out.
    private func run(_ assembler: MicFrameAssembler, _ buffer: AVAudioPCMBuffer, chunk: Int) -> [[Int16]] {
        var frames: [[Int16]] = []
        var start = 0
        let total = Int(buffer.frameLength)
        while start < total {
            let count = min(chunk, total - start)
            let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))!
            part.frameLength = AVAudioFrameCount(count)
            let channels = Int(buffer.format.channelCount)
            if buffer.format.commonFormat == .pcmFormatInt16 {
                for i in 0..<(count * channels) {
                    part.int16ChannelData![0][i] = buffer.int16ChannelData![0][start * channels + i]
                }
            } else {
                for c in 0..<channels {
                    for i in 0..<count { part.floatChannelData![c][i] = buffer.floatChannelData![c][start + i] }
                }
            }
            frames += assembler.append(part)
            start += count
        }
        return frames
    }

    /// Upward zero crossings per second.
    private func frequency(of samples: [Int16]) -> Double {
        var crossings = 0
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(samples.count) / 48000)
    }

    private func peak(of samples: [Int16]) -> Int { samples.map { abs(Int($0)) }.max() ?? 0 }

    func testFramesAre20msAt48kHzFromEveryInputRate() {
        for rate in [48000.0, 44100, 24000, 16000, 8000] {
            let assembler = MicFrameAssembler(inputFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!)
            let frames = run(assembler, sine(rate: rate, channels: 1, seconds: 2, frequency: 440), chunk: Int(rate / 100))
            XCTAssertFalse(frames.isEmpty, "\(rate) Hz gave no frames")
            XCTAssertTrue(frames.allSatisfy { $0.count == 960 }, "\(rate) Hz: frame sizes \(Set(frames.map(\.count)))")
            // 2 s of input is 100 frames of 20 ms; the resampler may hold back a few samples
            XCTAssertTrue((98...100).contains(frames.count), "\(rate) Hz: \(frames.count) frames for 2 s")
            let audio = Array(frames.dropFirst(5).joined())
            XCTAssertEqual(frequency(of: audio), 440, accuracy: 3, "\(rate) Hz: the tone's pitch changed")
            XCTAssertEqual(Double(peak(of: audio)), 0.5 * 32767, accuracy: 0.05 * 32767, "\(rate) Hz: the level changed")
        }
    }

    func testStereoIsMixedToMono() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        // Left full, right silent: the average is half
        let assembler = MicFrameAssembler(inputFormat: format, mix: .average)
        let frames = run(assembler, sine(rate: 44100, channels: 2, seconds: 1, frequency: 300, gains: [1, 0]), chunk: 512)
        let audio = Array(frames.dropFirst(3).joined())
        XCTAssertEqual(Double(peak(of: audio)), 0.25 * 32767, accuracy: 0.03 * 32767)
        XCTAssertEqual(frequency(of: audio), 300, accuracy: 3)
    }

    func testVoiceProcessingTakesTheFirstChannel() {
        // Voice processing can hand over extra channels (references); its output is the first
        let format = Self.floatFormat(rate: 48000, channels: 3)
        let assembler = MicFrameAssembler(inputFormat: format, mix: .firstChannel)
        let frames = run(assembler, sine(rate: 48000, channels: 3, seconds: 1, frequency: 500, gains: [1, 0, 0]), chunk: 480)
        let audio = Array(frames.dropFirst(2).joined())
        XCTAssertEqual(Double(peak(of: audio)), 0.5 * 32767, accuracy: 0.03 * 32767)
    }

    func testInterleavedInt16Input() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 2, interleaved: true)!
        let assembler = MicFrameAssembler(inputFormat: format)
        let frames = run(assembler, sine(rate: 16000, channels: 2, seconds: 1, frequency: 250, interleavedInt16: true), chunk: 160)
        XCTAssertTrue(frames.allSatisfy { $0.count == 960 })
        let audio = Array(frames.dropFirst(3).joined())
        XCTAssertEqual(frequency(of: audio), 250, accuracy: 3)
        XCTAssertEqual(Double(peak(of: audio)), 0.5 * 32767, accuracy: 0.05 * 32767)
    }

    func testOddChunksMakeWholeFramesAndKeepTheRest() {
        // 48 kHz in 7 ms pieces: frames come out whole, nothing lost or duplicated
        let assembler = MicFrameAssembler(inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
        let input = sine(rate: 48000, channels: 1, seconds: 1, frequency: 440)
        let frames = run(assembler, input, chunk: 336)
        XCTAssertEqual(frames.count, 50)
        XCTAssertEqual(assembler.pendingSamples, 0)
        let partial = MicFrameAssembler(inputFormat: input.format)
        XCTAssertEqual(run(partial, sine(rate: 48000, channels: 1, seconds: 0.03, frequency: 440), chunk: 100).count, 1)
        XCTAssertEqual(partial.pendingSamples, 480)
    }

    func testLoudInputIsClippedNotWrapped() {
        let assembler = MicFrameAssembler(inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!)
        let frames = run(assembler, sine(rate: 48000, channels: 1, seconds: 0.1, frequency: 100, amplitude: 2), chunk: 480)
        let audio = Array(frames.joined())
        XCTAssertEqual(audio.max(), Int16.max)
        XCTAssertEqual(audio.min(), -Int16.max)
        // A wrapped sample would flip sign in the middle of a crest: there are only 2 crossings per period
        XCTAssertEqual(frequency(of: audio), 100, accuracy: 15)
    }
}
