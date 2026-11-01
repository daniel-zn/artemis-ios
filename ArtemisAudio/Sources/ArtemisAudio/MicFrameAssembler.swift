// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MicFrameAssembler.swift
//  Artemis
//
//  Turns the microphone's audio, at whatever rate and channel count the iPhone's input runs,
//  into what Apollo takes: 48 kHz mono 16-bit, in 20 ms (960-sample) frames for Opus.
//

import AVFAudio

enum MicChannelMix {
    /// The channels' average (a plain multi-channel input).
    case average
    /// The first channel only: voice processing puts its cleaned-up signal there and can add others.
    case firstChannel
}

final class MicFrameAssembler {
    static let sampleRate = 48000.0
    /// 20 ms at 48 kHz.
    static let frameSamples = 960

    private let inputFormat: AVAudioFormat
    private let mix: MicChannelMix
    private let monoFormat: AVAudioFormat
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: MicFrameAssembler.sampleRate, channels: 1)!
    /// Nil when the input already runs at 48 kHz.
    private let converter: AVAudioConverter?
    private var pending: [Int16] = []

    /// Samples waiting for the rest of their frame.
    var pendingSamples: Int { pending.count }

    init(inputFormat: AVAudioFormat, mix: MicChannelMix = .average) {
        self.inputFormat = inputFormat
        self.mix = mix
        monoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1)!
        converter = inputFormat.sampleRate == Self.sampleRate ? nil : AVAudioConverter(from: monoFormat, to: outputFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        pending.reserveCapacity(Self.frameSamples * 4)
    }

    /// Adds captured audio (in `inputFormat`); returns the whole frames it completes.
    func append(_ buffer: AVAudioPCMBuffer) -> [[Int16]] {
        guard buffer.frameLength > 0, let mono = mixToMono(buffer) else { return [] }
        let resampled: AVAudioPCMBuffer
        if let converter {
            let capacity = AVAudioFrameCount((Double(mono.frameLength) * Self.sampleRate / inputFormat.sampleRate).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
            var supplied = false
            var error: NSError?
            // The converter keeps its filter state between calls, so the pieces join without clicks
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return mono
            }
            guard status != .error else { return [] }
            resampled = out
        } else {
            resampled = mono
        }
        let samples = resampled.floatChannelData![0]
        for i in 0..<Int(resampled.frameLength) {
            // Clip, never wrap
            let value = max(-1, min(1, samples[i]))
            pending.append(Int16(value * 32767))
        }
        var frames: [[Int16]] = []
        var start = 0
        while pending.count - start >= Self.frameSamples {
            frames.append(Array(pending[start..<start + Self.frameSamples]))
            start += Self.frameSamples
        }
        pending.removeFirst(start)
        return frames
    }

    /// The buffer as one float channel at its own rate.
    private func mixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard channels > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return nil }
        mono.frameLength = buffer.frameLength
        let out = mono.floatChannelData![0]
        let used = mix == .firstChannel ? 1 : channels
        let scale = 1 / Float(used)
        if let floats = buffer.floatChannelData {
            let stride = buffer.stride
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<used {
                    sum += buffer.format.isInterleaved ? floats[0][i * stride + c] : floats[c][i]
                }
                out[i] = sum * scale
            }
        } else if let ints = buffer.int16ChannelData {
            let stride = buffer.stride
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<used {
                    sum += Float(buffer.format.isInterleaved ? ints[0][i * stride + c] : ints[c][i]) / 32768
                }
                out[i] = sum * scale
            }
        } else {
            return nil
        }
        return mono
    }
}
