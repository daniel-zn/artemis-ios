// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The microphone's audio core, without UI or the streaming library: 48 kHz mono 20 ms framing,
// the permission gate, the settings, the ring buffers between audio threads, the level meter and
// the test tone. The app compiles these same files (Moonlight target); this package exists so
// they run under `swift test` on the Mac.

import PackageDescription

let package = Package(
    name: "ArtemisAudio",
    platforms: [.macOS(.v15), .iOS(.v18)],
    targets: [
        .target(name: "ArtemisAudio"),
        .testTarget(name: "ArtemisAudioTests", dependencies: ["ArtemisAudio"]),
    ],
    // As the app target (SWIFT_VERSION 5.0)
    swiftLanguageModes: [.v5]
)
