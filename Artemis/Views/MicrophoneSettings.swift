//
//  MicrophoneSettings.swift
//  Artemis
//
//  Settings › Audio & Microphone › the microphone, as the Mac app's: Enable microphone
//  streaming (off by default), the input, Test microphone with a level meter. iOS asks for the
//  microphone once, when it's turned on or tested; Artemis shows no alert of its own: a denial
//  is one line with Open Settings.
//

import SwiftUI

struct MicrophoneSettings: View {
    @AppStorage(MicSettings.Keys.enabled) private var enabled = false
    @AppStorage(MicSettings.Keys.input) private var input = MicInputChoice.iPhone.rawValue
    @State private var tester = MicrophoneTester()
    @State private var permission = MicPermissionGate.shared.status
    @Environment(\.scenePhase) private var scenePhase

    private var choice: MicInputChoice { MicInputChoice(rawValue: input) ?? .iPhone }
    private var denied: Bool { enabled && permission == .denied && !SessionAudio.usesTestTone }

    var body: some View {
        Section {
            Toggle("Enable microphone streaming", isOn: Binding(
                get: { enabled },
                set: { on in
                    enabled = on
                    if on && !SessionAudio.usesTestTone {
                        // iOS's question, the first time only
                        MicPermissionGate.shared.ensureAccess { _ in refresh() }
                    } else {
                        tester.stop()
                    }
                }))
                .accessibilityIdentifier("settings.microphone")
            Picker("Input", selection: Binding(
                get: { input },
                set: { new in
                    input = new
                    if tester.running { tester.restart(input: choice) }
                })) {
                ForEach(MicInputChoice.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("settings.microphoneInput")
        } header: {
            Note("Microphone")
        } footer: {
            Note("Streams this iPhone's microphone to the PC when the PC supports microphone passthrough (Apollo). A Bluetooth microphone switches AirPods and other headsets to call-quality sound.")
        }
        Section {
            if denied {
                // Never an alert: this line
                VStack(alignment: .leading, spacing: 6) {
                    Text("iOS doesn't allow Artemis to use the microphone.")
                        .artemisFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .accessibilityIdentifier("settings.microphoneOpenSettings")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.microphoneDenied")
            } else {
                Button(tester.running ? "Stop test" : "Test microphone") {
                    if tester.running {
                        tester.stop()
                    } else {
                        tester.start(input: choice) { refresh() }
                    }
                }
                .disabled(!enabled)
                .accessibilityIdentifier("settings.microphoneTest")
                MicMeter(level: tester.level, signal: tester.signal)
                    .accessibilityIdentifier("settings.microphoneMeter")
                    .accessibilityValue(String(format: "%.0f %%%@", tester.level * 100, tester.signal ? ", signal" : ""))
                Text(tester.status)
                    .artemisFont(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.microphoneStatus")
            }
        } header: {
            Note("Microphone test")
        }
        .onAppear(perform: refresh)
        .onDisappear { tester.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Back from iOS Settings with the switch turned on, or off
            if phase == .active { refresh() } else { tester.stop() }
        }
    }

    private func refresh() {
        permission = MicPermissionGate.shared.status
        if denied { tester.stop() }
    }
}

/// The level bar: green once there's a signal (as the Mac's).
private struct MicMeter: View {
    let level: Double
    let signal: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().strokeBorder(signal ? Color.green : Color.primary.opacity(0.15), lineWidth: 1)
                if level > 0.001 {
                    Capsule()
                        .fill(signal ? Color.green : Color.accentColor)
                        .frame(width: max(6, proxy.size.width * level))
                }
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
    }
}

/// Test microphone: listens to the chosen input (Settings only, no session) and shows its level.
@Observable
final class MicrophoneTester {
    static let idleStatus = "Press Test microphone and speak to check your input."

    private(set) var running = false
    private(set) var level = 0.0
    private(set) var signal = false
    private(set) var status = MicrophoneTester.idleStatus

    @ObservationIgnored private var meter = MicLevelMeter()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var listening: SessionAudio.Listening?
    /// Bumped by each start and stop: an answer from an older start is ignored.
    @ObservationIgnored private var generation = 0
    /// The engine was asked to open (it may still be opening).
    @ObservationIgnored private var opened = false

    func start(input: MicInputChoice, permissionDecided: @escaping () -> Void = {}) {
        generation += 1
        let mine = generation
        if SessionAudio.usesTestTone {
            // No microphone is opened: nothing to ask
            open(input: input, generation: mine)
            return
        }
        status = "Waiting for microphone permission"
        MicPermissionGate.shared.ensureAccess { [weak self] granted in
            permissionDecided()
            guard let self, self.generation == mine else { return }
            guard granted || SessionAudio.usesTestTone else {
                self.status = Self.idleStatus
                return
            }
            self.open(input: input, generation: mine)
        }
    }

    func restart(input: MicInputChoice) {
        stop()
        start(input: input)
    }

    private func open(input: MicInputChoice, generation mine: Int) {
        status = "Opening the microphone…"
        opened = true
        SessionAudio.shared.startTest(input: input) { [weak self] listening in
            guard let self, self.generation == mine else { return }
            guard let listening else {
                self.status = "Couldn't open the microphone. Check that it's connected, or pick another input."
                return
            }
            self.listening = listening
            self.running = true
            self.meter = MicLevelMeter()
            self.started = Date()
            self.status = listening.fellBack
                ? "Couldn't open the \(input.title.lowercased()), listening to \(listening.name) instead. Speak now."
                : "Listening to \(listening.name). Speak now."
            logInfo("Microphone test started: \(listening.name)")
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        if opened {
            SessionAudio.shared.stopTest()
            opened = false
        }
        running = false
        level = 0
        signal = false
        status = Self.idleStatus
    }

    private func tick() {
        let heardBefore = meter.heardAnything
        meter.add(peak: SessionAudio.shared.takePeak())
        meter.tick()
        level = meter.level
        signal = meter.signalDetected
        guard let listening else { return }
        if meter.heardAnything && !heardBefore {
            status = "Listening to \(listening.name)."
        } else if !meter.heardAnything, Date().timeIntervalSince(started) > 3, SessionAudio.shared.inputCallbacks == 0 {
            // The meter is the feedback for a quiet input; only one that delivers nothing is a problem
            status = "No audio is arriving from \(listening.name). Check that it's connected, or pick another input."
        }
    }
}
