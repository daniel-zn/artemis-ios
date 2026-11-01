// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MicSettings.swift
//  Artemis
//
//  Settings › Audio & Microphone, in UserDefaults (the settings screen binds @AppStorage to the
//  same keys).
//

import Foundation

/// Which microphone a session uses.
enum MicInputChoice: String, CaseIterable, Identifiable {
    /// The iPhone's own, even with headphones connected: AirPods keep their full-quality sound.
    case iPhone = "iphone"
    /// A wired or USB-C headset's.
    case headset
    /// AirPods' or another Bluetooth headset's: iOS switches them to the call link (lower quality sound).
    case bluetooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iPhone: "iPhone Microphone"
        case .headset: "Headset Microphone"
        case .bluetooth: "Bluetooth Microphone"
        }
    }

    /// Bluetooth microphones only work over the headset's call link (HFP).
    var usesBluetoothCallLink: Bool { self == .bluetooth }
}

struct MicSettings: Equatable {
    enum Keys {
        /// Enable microphone streaming (off by default).
        static let enabled = "ArtemisMicrophoneEnabled"
        /// MicInputChoice.rawValue.
        static let input = "ArtemisMicrophoneInput"
    }

    var enabled = false
    var input = MicInputChoice.iPhone

    static var current: MicSettings { load(from: .standard) }

    static func load(from defaults: UserDefaults) -> MicSettings {
        MicSettings(enabled: defaults.bool(forKey: Keys.enabled),
                    input: defaults.string(forKey: Keys.input).flatMap(MicInputChoice.init(rawValue:)) ?? .iPhone)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(input.rawValue, forKey: Keys.input)
    }
}
