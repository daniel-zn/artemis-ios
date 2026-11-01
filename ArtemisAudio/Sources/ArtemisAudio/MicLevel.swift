// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MicLevel.swift
//  Artemis
//
//  The Test microphone meter and the test tone that stands in for a voice where there's no
//  microphone (the Simulator on a Mac without one; UI tests; the end-to-end check with a PC).
//

import AVFAudio

/// As the Mac app's meter: the loudest sample since the last tick (0…1), falling back by 0.72
/// per tick (ticked ~20 times a second); a signal from 2 %.
struct MicLevelMeter {
    private(set) var level = 0.0
    private var peak: Int32 = 0
    /// Something other than digital silence has arrived since the meter started.
    private(set) var heardAnything = false

    var signalDetected: Bool { level >= 0.02 }

    mutating func add(_ samples: [Int16]) {
        for sample in samples {
            peak = max(peak, abs(Int32(sample)))
        }
    }

    /// A peak measured elsewhere (the encoder thread's), 0…32768.
    mutating func add(peak value: Int) {
        peak = max(peak, Int32(clamping: value))
    }

    mutating func tick() {
        if peak > 0 { heardAnything = true }
        level = max(min(Double(peak) / 32767, 1), level * 0.72)
        peak = 0
    }
}

/// A voice-like test signal: a 330 Hz tone with four "syllables" a second (never silent),
/// generated at an iPhone-like input rate other than 48 kHz so the conversion runs too.
struct TestTone {
    static let frequency = 330.0
    static let syllablesPerSecond = 4.0

    let format: AVAudioFormat
    private var position = 0

    init(sampleRate: Double = 44100, channels: Int = 2) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
    }

    mutating func next(frames: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let rate = format.sampleRate
        for i in 0..<frames {
            let t = Double(position + i) / rate
            let envelope = 0.55 + 0.45 * sin(2 * .pi * Self.syllablesPerSecond * t)
            let value = Float(0.4 * envelope * sin(2 * .pi * Self.frequency * t))
            for c in 0..<Int(format.channelCount) {
                buffer.floatChannelData![c][i] = value
            }
        }
        position += frames
        return buffer
    }
}
