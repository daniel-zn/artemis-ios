//
//  LiveMicTests.swift
//  ArtemisUITests
//
//  Against a real, paired Apollo PC (ARTEMIS_LIVE_MIC=<name>[/<app>][@<seconds>]; skipped
//  without it): a session with the microphone on, the test tone in its place
//  (-ArtemisTestMicTone YES), for <seconds> (40 by default), then Disconnect. The PC's side
//  (Apollo's log, the level in Steam Streaming Microphone) is read by the script that runs this.
//

import XCTest

final class LiveMicTests: XCTestCase {
    func testRealSessionSendsMicrophone() throws {
        guard let spec = ProcessInfo.processInfo.environment["ARTEMIS_LIVE_MIC"], !spec.isEmpty else {
            throw XCTSkip("set ARTEMIS_LIVE_MIC=<name>[/<app>][@<seconds>]")
        }
        let timed = spec.split(separator: "@").map(String.init)
        let named = timed[0].split(separator: "/").map(String.init)
        let name = named[0]
        let appName = named.count > 1 ? named[1] : "Desktop"
        let seconds = timed.count > 1 ? UInt32(timed[1]) ?? 40 : 40
        let dir = ProcessInfo.processInfo.environment["ARTEMIS_SHOT_DIR"] ?? ""
        func shot(_ label: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
            if !dir.isEmpty {
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-mic-\(label).png"))
            }
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "NO", "-ArtemisTestMicTone", "YES", "-ArtemisMicrophoneEnabled", "YES",
                               "-ArtemisQuitAppAfterSession", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["Allow"].waitForExistence(timeout: 5) {
            springboard.alerts.buttons["Allow"].tap()
        }

        let row = app.buttons["computer.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "\(name) didn't show up")
        let online = NSPredicate(format: "NOT (label CONTAINS 'Connecting') AND NOT (label CONTAINS 'Offline')")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: online, object: row)], timeout: 60)
        print("[live-mic] row: \(row.label)")
        shot("1-computers")
        row.tap()
        var game = app.buttons["game.\(appName)"]
        if !game.waitForExistence(timeout: 30) {
            // Another app if the PC has no such one
            game = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'game.'")).firstMatch
        }
        XCTAssertTrue(game.exists, "no apps on \(name) (paired?)")
        print("[live-mic] app: \(game.identifier)")
        shot("2-apps")
        game.tap()

        let mic = app.buttons["bar.microphone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the session has no microphone (did Apollo negotiate it?)")
        print("[live-mic] \(Date()) session up, microphone \(mic.label)")
        shot("3-session")
        sleep(seconds)
        shot("4-session-end")
        print("[live-mic] \(Date()) disconnecting")
        app.buttons["bar.disconnect"].tap()
        XCTAssertTrue(game.waitForExistence(timeout: 30) || row.waitForExistence(timeout: 5), "the session didn't end")
        sleep(3)
        app.terminate()
    }
}
