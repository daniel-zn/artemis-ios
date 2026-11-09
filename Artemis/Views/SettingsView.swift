//
//  SettingsView.swift
//  Artemis
//
//  Settings in the Mac app's sections and wording, as an iOS settings list.
//  Every change is saved as it's made.
//

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case video = "Video & Display"
    case audio = "Audio & Microphone"
    case keyboard = "Keyboard & Mouse"
    case controllers = "Controllers"
    case touch = "Touch & Pointer"
    case host = "Host PC"
    case general = "General"
    case advanced = "Advanced"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .video: "display"
        case .audio: "speaker.wave.2.fill"
        case .keyboard: "keyboard.fill"
        case .controllers: "gamecontroller.fill"
        case .touch: "hand.point.up.left.fill"
        case .host: "desktopcomputer"
        case .general: "gearshape.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .video: .blue
        case .audio: .pink
        case .keyboard: .teal
        case .controllers: .green
        case .touch: .orange
        case .host: .indigo
        case .general: .gray
        case .advanced: .gray
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = StreamSettings.load()
    @State private var pointer = PointerSettings.load()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        NavigationLink(value: section) {
                            SettingsRowLabel(section: section)
                        }
                        .accessibilityIdentifier("settings.\(section)")
                    }
                } footer: {
                    Note("Sessions use \(settings.resolutionSummary) at \(settings.framerate) FPS, \(settings.bitrateText).")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsSection.self) { section in
                SettingsPage(section: section, settings: $settings, pointer: $pointer)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
        .onChange(of: settings) { _, new in
            new.save()
        }
        .onChange(of: pointer) { _, new in
            new.save()
        }
    }
}

/// A section header or footer in the app's typeface.
struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .artemisFont(.footnote)
    }
}

/// A section's row: its icon beside the name, or above it at the accessibility text sizes
/// (where the wide typeface needs the row's whole width).
struct SettingsRowLabel: View {
    let section: SettingsSection
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                SettingsIcon(symbol: section.symbol, color: section.color)
                Text(section.rawValue)
            }
            .padding(.vertical, 4)
        } else {
            Label {
                Text(section.rawValue)
            } icon: {
                SettingsIcon(symbol: section.symbol, color: section.color)
            }
        }
    }
}

/// The colored rounded-square icons of the iOS Settings app.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .rect(cornerRadius: size * 0.24))
    }
}

struct SettingsPage: View {
    let section: SettingsSection
    @Binding var settings: StreamSettings
    @Binding var pointer: PointerSettings
    @State private var resolutions = StreamSettings.presetResolutions
    @State private var customWidth = ""
    @State private var customHeight = ""
    @State private var askingCustomResolution = false
    @State private var customResolutionNote = false
    @AppStorage(AppPreferences.Keys.gamepadMouse) private var gamepadMouse = true
    @AppStorage(AppPreferences.Keys.onScreenGamepadSize) private var onScreenGamepadSize = PadLayout.defaultSize
    @AppStorage(AppPreferences.Keys.onScreenGamepadOpacity) private var onScreenGamepadOpacity = 0.75
    @AppStorage(AppPreferences.Keys.swapMouseButtons) private var swapMouseButtons = false
    @AppStorage(AppPreferences.Keys.quitAppAfterSession) private var quitAppAfterSession = false
    @AppStorage(AppPreferences.Keys.shareClipboard) private var shareClipboard = true

    var body: some View {
        Form {
            switch section {
            case .video: video
            case .audio: audio
            case .keyboard: keyboard
            case .controllers: controllers
            case .touch: touch
            case .host: host
            case .general: general
            case .advanced: advanced
            }
        }
        .navigationTitle(section.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Video & Display

    private var resolutionChoice: Binding<String> {
        Binding(
            get: {
                resolutions.first { $0.width == settings.width && $0.height == settings.height }?.id ?? "custom"
            },
            set: { id in
                if id == "custom" {
                    customWidth = String(settings.width)
                    customHeight = String(settings.height)
                    askingCustomResolution = true
                } else if let choice = resolutions.first(where: { $0.id == id }) {
                    settings.width = choice.width
                    settings.height = choice.height
                    settings.resetBitrate()
                }
            })
    }

    @ViewBuilder
    private var video: some View {
        Section {
            Picker("Resolution", selection: resolutionChoice) {
                ForEach(resolutions) { resolution in
                    Text(resolution.name).tag(resolution.id)
                        .selectionDisabled(!resolution.isEnabled)
                }
                Text(isCustom ? "Custom (\(settings.width) × \(settings.height))" : "Custom…").tag("custom")
            }
            .accessibilityIdentifier("settings.resolution")
            Picker("Frame rate", selection: Binding(
                get: { settings.framerate },
                set: { settings.framerate = $0; settings.resetBitrate() }
            )) {
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
                if StreamSettings.supports120FPS || settings.framerate == 120 {
                    Text("120 FPS").tag(120)
                }
            }
            LabeledContent("PC resolution", value: "\(settings.width) × \(settings.height)")
        } header: {
            Note("Resolution and FPS")
        } footer: {
            Note("Native, the default, is this iPhone's own resolution, so the PC's virtual display matches it. Values too high for your PC or network connection may cause lag, stuttering, or errors.")
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Video bitrate", value: settings.bitrateText)
                Slider(
                    value: Binding(
                        get: { Double(StreamSettings.notch(for: settings.bitrate)) },
                        set: { settings.bitrate = StreamSettings.bitrateTable[Int($0.rounded())] }
                    ),
                    in: 0...Double(StreamSettings.bitrateTable.count - 1),
                    step: 1
                ) {
                    Text("Video bitrate")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                .accessibilityValue(settings.bitrateText)
                .accessibilityIdentifier("settings.bitrate")
            }
        } footer: {
            Note("Lower the bitrate on slower connections. Raise the bitrate to increase image quality.")
        }

        Section {
            Toggle("Enable HDR", isOn: $settings.enableHdr)
                .disabled(!ArtemisBridge.isHdrSupported())
        } footer: {
            Note(ArtemisBridge.isHdrSupported()
                 ? "The session will be HDR-capable, but some apps need an HDR display on the PC to turn HDR on."
                 : "HDR isn't supported on this iPhone.")
        }

        Section {
            Toggle("Frame pacing", isOn: $settings.useFramePacing)
        } footer: {
            Note("Frame pacing reduces micro-stutter by delaying frames that come in too early, for the smoothest video at the cost of a little latency.")
        }

        Section {
            Toggle("Show performance stats during a session", isOn: $settings.statsOverlay)
        } footer: {
            Note("Shows real-time video and network performance over the desktop.")
        }
        .alert("Enter a custom resolution:", isPresented: $askingCustomResolution) {
            TextField("Video width", text: $customWidth)
                .keyboardType(.numberPad)
            TextField("Video height", text: $customHeight)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("OK") { applyCustomResolution() }
        }
        .alert("Custom Resolution Selected", isPresented: $customResolutionNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Not every host sets the PC's display to a custom resolution, so you may need to set it on the PC yourself.\n\nResolutions your iPhone or PC don't support may cause connection errors.")
        }
    }

    private var isCustom: Bool {
        !resolutions.contains { $0.width == settings.width && $0.height == settings.height }
    }

    private func applyCustomResolution() {
        guard let width = Int(customWidth), let height = Int(customHeight), width > 0, height > 0 else { return }
        // Cap to the decoder's maximum and a sensible minimum
        let maximum = StreamSettings.maxResolutionDimension
        settings.width = max(256, min(width, maximum))
        settings.height = max(256, min(height, maximum))
        settings.resetBitrate()
        customResolutionNote = true
    }

    // MARK: Other sections

    @ViewBuilder
    private var audio: some View {
        Section {
            Toggle("Mute the PC's speakers during a session", isOn: Binding(
                get: { !settings.playAudioOnPC },
                set: { settings.playAudioOnPC = !$0 }
            ))
        } header: {
            Note("Audio Settings")
        } footer: {
            Note("The PC's audio plays on this iPhone. Turn this off to hear it on the PC too.")
        }
        MicrophoneSettings()
    }

    @ViewBuilder
    private var keyboard: some View {
        Section {
            Toggle("Citrix X1 mouse support", isOn: $settings.btMouseSupport)
        } footer: {
            Note("Use a Citrix X1 Bluetooth mouse during a session. Other mice and keyboards work without this.")
        }
        Section {
            Toggle("Swap left and right mouse buttons", isOn: $swapMouseButtons)
        } footer: {
            Note("For a mouse connected to this iPhone. Touch controls are set in Touch & Pointer.")
        }
    }

    @ViewBuilder
    private var controllers: some View {
        Section {
            Toggle("Multiple controllers", isOn: $settings.multiController)
        } header: {
            Note("Controller Settings")
        } footer: {
            Note("On: each connected controller is its own player. Off: every controller controls player 1.")
        }
        Section {
            Toggle("Swap A/B and X/Y controller buttons", isOn: $settings.swapABXYButtons)
        } footer: {
            Note("This switches controllers into a Nintendo-style button layout.")
        }
        Section {
            Toggle("Mouse control with a controller", isOn: $gamepadMouse)
                .accessibilityIdentifier("settings.gamepadMouse")
        } header: {
            Note("Controller as a Mouse")
        } footer: {
            Note("During a session, hold Start (Menu) for a moment to switch the controller between gamepad and mouse. As a mouse: the left stick moves the pointer, the right stick scrolls, A clicks, B right-clicks, X middle-clicks, LB and RB go back and forward, the D-pad scrolls a step, and Y shows the keyboard.")
        }
        Section {
            Picker("Size", selection: $onScreenGamepadSize) {
                ForEach(PadLayout.sizes, id: \.scale) { size in
                    Text(size.name).tag(size.scale)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.gamepadSize")
            VStack(alignment: .leading, spacing: 6) {
                Text("Opacity")
                Slider(value: $onScreenGamepadOpacity, in: 0.3...1) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.dotted").accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "circle.fill").accessibilityHidden(true)
                }
                .accessibilityValue("\(Int((onScreenGamepadOpacity * 100).rounded())) percent")
                .accessibilityIdentifier("settings.gamepadOpacity")
            }
        } header: {
            Note("On-Screen Controller")
        } footer: {
            Note("The control bar's controller button shows a game controller on the screen; the PC sees it as an Xbox controller. Upright it takes the trackpad's place; in landscape it lies over the desktop.")
        }
        Section {
            Text("Xbox, PlayStation and MFi controllers connected to this iPhone work during a session: the PC sees them as gamepads. Press Start, Select, LB and RB together to disconnect.")
                .artemisFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var touch: some View {
        Section {
            Picker("Default mode", selection: $settings.absoluteTouchMode) {
                Text("Trackpad").tag(false)
                Text("Direct").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.pointerMode")
        } header: {
            Note("Pointer")
        } footer: {
            Note(settings.absoluteTouchMode
                 ? "Direct: tap or drag where things are on the desktop. Press and hold to right-click."
                 : "Trackpad: drag one finger to move the pointer and tap to click, like a laptop's trackpad. Two fingers tap to right-click and drag to scroll.")
        }
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Pointer speed", value: String(format: "%.1f×", pointer.pointerSpeed))
                Slider(value: $pointer.pointerSpeed, in: PointerSettings.speedRange, step: 0.1) {
                    Text("Pointer speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
                .accessibilityValue(String(format: "%.1f×", pointer.pointerSpeed))
                .accessibilityIdentifier("settings.pointerSpeed")
            }
            Picker("Scroll direction", selection: $pointer.naturalScrolling) {
                Text("Natural").tag(true)
                Text("Reversed").tag(false)
            }
            .accessibilityIdentifier("settings.scrollDirection")
        } footer: {
            Note(pointer.naturalScrolling
                 ? "Natural, like a Mac's trackpad and iPhone: two fingers up scroll further down the page, two fingers left scroll right."
                 : "Reversed: two fingers up scroll back up the page, two fingers left scroll left, like a mouse's scroll wheel.")
        }
        Section {
            Toggle("Show control bar", isOn: $pointer.showControlBar)
        } footer: {
            Note("The bar with the keyboard, shortcuts and Disconnect. When off, a session starts with it folded into a small button you can drag anywhere.")
        }
    }

    @ViewBuilder
    private var host: some View {
        Section {
            Toggle("Optimize app settings for the session", isOn: $settings.optimizeGames)
        } header: {
            Note("Host Settings")
        } footer: {
            Note("Lets the host change an app's settings to suit the session.")
        }
        Section {
            Toggle("Stop the app on the PC after a session", isOn: $quitAppAfterSession)
                .accessibilityIdentifier("settings.quitAfterSession")
        } footer: {
            Note("When you disconnect, the app closes on the PC too. Unsaved work in it may be lost.")
        }
        Section {
            Toggle("Share copied text with the host PC", isOn: $shareClipboard)
                .accessibilityIdentifier("settings.shareClipboard")
        } footer: {
            Note("During a session with Apollo, Paste in the shortcuts menu (⌘ in the control bar, or Ctrl+V or ⌘V on a keyboard) pastes the text you copied here on the PC, and text you copy on the PC can be pasted here.")
        }
    }

    @ViewBuilder
    private var general: some View {
        Section {
            LabeledContent("Version", value: Self.version)
                .accessibilityIdentifier("settings.version")
            Link(destination: Links.sourceCode) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("settings.sourceCode")
            Link(destination: Links.license) {
                Label("License (GPLv3)", systemImage: "doc.text")
            }
        } header: {
            Note("About")
        } footer: {
            Note("Artemis is based on Moonlight by the Moonlight developers. It is free software: you can redistribute it and change it under the terms of the GNU General Public License, version 3. It comes with no warranty.")
                .accessibilityIdentifier("settings.license")
        }
        Section {
            Link(destination: Links.setupGuide) {
                Label("Setup Guide", systemImage: "book")
            }
            Link(destination: Links.troubleshooting) {
                Label("Troubleshooting", systemImage: "questionmark.circle")
            }
        } header: {
            Note("Help")
        }
    }

    @ViewBuilder
    private var advanced: some View {
        Section {
            Picker("Video codec", selection: $settings.codec) {
                Text("Automatic (Recommended)").tag(0)
                Text("H.264").tag(1)
                if ArtemisBridge.isHevcSupported() || settings.codec == 2 {
                    Text("HEVC (H.265)").tag(2)
                }
                if ArtemisBridge.isAv1Supported() || settings.codec == 3 {
                    Text("AV1").tag(3)
                }
            }
        } header: {
            Note("Advanced Settings")
        } footer: {
            Note("Automatic picks the most efficient codec this iPhone decodes in hardware.")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

extension StreamSettings {
    var resolutionSummary: String {
        StreamSettings.presetResolutions.first { $0.width == width && $0.height == height }?.name ?? "\(width) × \(height)"
    }
}
