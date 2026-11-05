//
//  MicrophoneTests.swift
//  ArtemisUITests
//
//  The microphone (Settings › Audio & Microphone and the session's control bar) against the
//  demo PCs. Where a microphone is needed, the test tone takes its place (-ArtemisTestMicTone
//  YES: the Simulator's Mac has none): Test microphone's meter moves with it, and a session
//  encodes it into 20 ms Opus packets (counted in the demo, not sent). The permission is the
//  real one: iOS asks once, a denial shows one quiet line and never an Artemis alert.
//

import XCTest

final class MicrophoneTests: XCTestCase {
    private var appearance: String {
        ProcessInfo.processInfo.environment["ARTEMIS_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "system"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String] = [], app: XCUIApplication = XCUIApplication()) -> XCUIApplication {
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["computer.WORKSTATION"].waitForExistence(timeout: 15), "no demo PCs")
        return app
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ARTEMIS_SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func wait(_ timeout: TimeInterval, for condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Scrolls the settings list until `element` is on screen.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func openAudioSettings(_ app: XCUIApplication) {
        app.buttons["computers.settings"].tap()
        let audio = app.buttons["settings.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        audio.tap()
        XCTAssertTrue(app.switches["settings.microphone"].waitForExistence(timeout: 5), "no microphone switch")
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    /// Taps the switch itself (at the row's trailing end: a tap on the label doesn't flip it in
    /// every iOS version), once more if the first didn't take.
    private func flip(_ toggle: XCUIElement) {
        let before = isOn(toggle)
        for _ in 0..<2 {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            if wait(2, for: { self.isOn(toggle) != before }) { return }
            // iOS's question may be up already: then the tap did take
            if springboard.alerts.firstMatch.exists { return }
        }
        XCTFail("the switch didn't flip")
    }

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// iOS's microphone question, if it's on screen within `timeout`.
    private func systemMicrophoneAlert(within timeout: TimeInterval) -> XCUIElement? {
        let alert = springboard.alerts.firstMatch
        return alert.waitForExistence(timeout: timeout) ? alert : nil
    }

    // MARK: Permission

    /// Never decided: turning the microphone on shows iOS's question (once). Don't Allow: one
    /// quiet line with Open Settings, no alert; turning it off and on again, testing, or a
    /// relaunch never ask again.
    func testDeniedShowsOneQuietLineAndNoAlert() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        _ = launch(app: app)
        openAudioSettings(app)
        let toggle = app.switches["settings.microphone"]
        if isOn(toggle) { flip(toggle) }
        XCTAssertFalse(isOn(toggle), "Enable microphone streaming should be off")
        XCTAssertNil(systemMicrophoneAlert(within: 1), "a question before the microphone was turned on")

        flip(toggle)
        guard let alert = systemMicrophoneAlert(within: 10) else {
            XCTFail("iOS didn't ask for the microphone when it was turned on")
            return
        }
        shot("\(appearance)-mic-1-system-question")
        let dontAllow = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        XCTAssertTrue(dontAllow.exists, "no Don't Allow in \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        dontAllow.tap()

        let denied = app.descendants(matching: .any)["settings.microphoneDenied"].firstMatch
        XCTAssertTrue(denied.waitForExistence(timeout: 5), "no line saying iOS doesn't allow the microphone")
        XCTAssertTrue(app.staticTexts["iOS doesn't allow Artemis to use the microphone."].exists)
        XCTAssertTrue(app.buttons["settings.microphoneOpenSettings"].exists, "no Open Settings")
        XCTAssertFalse(app.buttons["settings.microphoneTest"].exists, "Test microphone shown though it can't work")
        XCTAssertEqual(app.alerts.count, 0, "Artemis showed an alert")
        XCTAssertNil(systemMicrophoneAlert(within: 1), "iOS asked again")
        XCTAssertTrue(isOn(toggle), "the setting stays on (the line explains)")
        shot("\(appearance)-mic-2-denied-line")

        // Off and on again: no question, no alert, the line comes back
        flip(toggle)
        XCTAssertTrue(wait(3) { !denied.exists }, "the line stays with the microphone off")
        flip(toggle)
        XCTAssertNil(systemMicrophoneAlert(within: 2), "iOS asked a second time")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertTrue(denied.waitForExistence(timeout: 3))

        // A relaunch: still just the line
        app.terminate()
        _ = launch(app: app)
        openAudioSettings(app)
        XCTAssertTrue(denied.waitForExistence(timeout: 5))
        XCTAssertNil(systemMicrophoneAlert(within: 1))
        XCTAssertEqual(app.alerts.count, 0)

        // Leave the microphone off for the other tests
        flip(app.switches["settings.microphone"])
        XCTAssertTrue(wait(3) { !self.isOn(app.switches["settings.microphone"]) })
        app.terminate()
    }

    // MARK: Test microphone

    /// The meter moves with the input (the test tone here), turns green with a signal, and
    /// stops with the test. The input picker offers the three inputs.
    func testMeterMovesWithTheInput() {
        let app = launch(["-ArtemisTestMicTone", "YES", "-ArtemisMicrophoneEnabled", "YES"])
        openAudioSettings(app)
        XCTAssertTrue(isOn(app.switches["settings.microphone"]))
        let picker = app.buttons["settings.microphoneInput"]
        XCTAssertTrue(picker.exists, "no input picker")
        XCTAssertTrue(picker.label.contains("iPhone Microphone"), "default input: \(picker.label)")

        let test = app.buttons["settings.microphoneTest"]
        let meter = app.descendants(matching: .any)["settings.microphoneMeter"].firstMatch
        let status = app.staticTexts["settings.microphoneStatus"]
        XCTAssertTrue(reveal(test, in: app))
        XCTAssertEqual(test.label, "Test microphone")
        XCTAssertEqual(status.label, "Press Test microphone and speak to check your input.")
        XCTAssertEqual(meter.value as? String, "0 %")
        shot("\(appearance)-mic-3-meter-idle")

        test.tap()
        XCTAssertTrue(wait(10) { (meter.value as? String ?? "").hasSuffix("signal") },
                      "the meter didn't move: \(meter.value ?? "nil"), status \(status.label)")
        XCTAssertTrue(status.label.hasPrefix("Listening to the test tone"), "status: \(status.label)")
        XCTAssertEqual(test.label, "Stop test")
        // It follows the tone's syllables: different levels over a second
        var levels = Set<String>()
        for _ in 0..<10 {
            levels.insert(meter.value as? String ?? "")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(levels.count, 2, "the meter stood still: \(levels)")
        shot("\(appearance)-mic-4-meter-signal")

        test.tap()
        XCTAssertTrue(wait(5) { meter.value as? String == "0 %" }, "the meter didn't stop: \(meter.value ?? "nil")")
        XCTAssertEqual(test.label, "Test microphone")
        XCTAssertEqual(status.label, "Press Test microphone and speak to check your input.")

        // The inputs
        picker.tap()
        for title in ["iPhone Microphone", "Headset Microphone", "Bluetooth Microphone"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "no \(title) input")
        }
        shot("\(appearance)-mic-5-inputs")
        app.buttons["iPhone Microphone"].tap()
        app.terminate()
    }

    /// Off (the default): Test microphone and the input are disabled, no question is asked.
    func testOffByDefaultDisablesTheTest() {
        let app = launch(["-ArtemisMicrophoneEnabled", "NO"])
        openAudioSettings(app)
        XCTAssertFalse(isOn(app.switches["settings.microphone"]))
        XCTAssertFalse(app.buttons["settings.microphoneInput"].isEnabled)
        let test = app.buttons["settings.microphoneTest"]
        XCTAssertTrue(reveal(test, in: app))
        XCTAssertFalse(test.isEnabled)
        XCTAssertNil(systemMicrophoneAlert(within: 1))
        app.terminate()
    }

    // MARK: Session

    private func connect(_ app: XCUIApplication) -> XCUIElement {
        let workstation = app.buttons["computer.WORKSTATION"]
        workstation.tap()
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10))
        desktopApp.tap()
        let desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), "the desktop didn't open")
        return desktop
    }

    private func micState(_ desktop: XCUIElement) -> (state: String, packets: Int, samples: Int) {
        let line = (desktop.value as? String ?? "").components(separatedBy: "\n").first ?? ""
        let state = line.range(of: #"microphone (on|muted|off)"#, options: .regularExpression).map { String(line[$0].dropFirst(11)) } ?? "?"
        guard let range = line.range(of: #"mic packets (\d+) of (\d+) samples"#, options: .regularExpression) else { return (state, -1, -1) }
        let numbers = line[range].split(separator: " ").compactMap { Int($0) }
        return (state, numbers.first ?? -1, numbers.last ?? -1)
    }

    /// A session with the microphone on: the bar shows a microphone (icon only), the input goes
    /// out as 20 ms Opus packets; muting stops them (the icon struck through), unmuting resumes.
    func testSessionMicrophoneMutes() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let tag = "\(appearance)-\(orientation == .portrait ? "portrait" : "landscape")"
            let app = launch(["-ArtemisTestMicTone", "YES", "-ArtemisMicrophoneEnabled", "YES"])
            XCUIDevice.shared.orientation = orientation
            let desktop = connect(app)
            let mic = app.buttons["bar.microphone"]
            XCTAssertTrue(mic.waitForExistence(timeout: 5), "\(tag): no microphone in the bar")
            XCTAssertEqual(mic.label, "Mute Microphone")
            XCTAssertTrue(wait(5) { self.micState(desktop).packets > 20 }, "\(tag): no packets: \(micState(desktop))")
            let on = micState(desktop)
            XCTAssertEqual(on.state, "on")
            XCTAssertEqual(on.samples, 960, "\(tag): packets aren't 20 ms")
            // Real time: about 50 packets a second, not a flood
            sleep(2)
            let rate = Double(micState(desktop).packets - on.packets) / 2
            XCTAssertEqual(rate, 50, accuracy: 15, "\(tag): \(rate) packets a second")
            shot("\(tag)-mic-6-session-on")

            mic.tap()
            XCTAssertTrue(wait(3) { mic.label == "Unmute Microphone" }, "\(tag): not muted: \(mic.label)")
            XCTAssertTrue(wait(3) { self.micState(desktop).state == "muted" })
            let muted = micState(desktop).packets
            sleep(1)
            XCTAssertLessThanOrEqual(micState(desktop).packets - muted, 1, "\(tag): packets went out while muted")
            shot("\(tag)-mic-7-session-muted")

            mic.tap()
            XCTAssertTrue(wait(3) { mic.label == "Mute Microphone" })
            let resumed = micState(desktop).packets
            XCTAssertTrue(wait(3) { self.micState(desktop).packets > resumed + 20 }, "\(tag): unmuting didn't resume")

            app.buttons["bar.disconnect"].tap()
            XCTAssertTrue(app.buttons["computer.WORKSTATION"].waitForExistence(timeout: 10) || app.buttons["game.Desktop"].waitForExistence(timeout: 5))
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// The microphone off: the bar has no microphone button (it's unchanged).
    func testNoMicrophoneButtonWhenOff() {
        let app = launch(["-ArtemisTestMicTone", "YES", "-ArtemisMicrophoneEnabled", "NO"])
        let desktop = connect(app)
        XCTAssertTrue(app.buttons["bar.disconnect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bar.microphone"].exists)
        XCTAssertEqual(micState(desktop).state, "off")
        app.terminate()
    }
}
