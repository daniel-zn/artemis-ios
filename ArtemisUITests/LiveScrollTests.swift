//
//  LiveScrollTests.swift
//  ArtemisUITests
//
//  Against a real, paired PC (ARTEMIS_LIVE_SCROLL=<name>[/<app>]; skipped without it): a session,
//  then two-finger drags down and up on the upright trackpad and on the landscape desktop, with a
//  screenshot before and after each, so the stream shows which way the PC's content moved. The
//  PC's side (what Windows received) is read by the script that runs this.
//

import XCTest

final class LiveScrollTests: XCTestCase {
    func testRealSessionScrollDirection() throws {
        guard let spec = ProcessInfo.processInfo.environment["ARTEMIS_LIVE_SCROLL"], !spec.isEmpty else {
            throw XCTSkip("set ARTEMIS_LIVE_SCROLL=<name>[/<app>] (app: Virtual Display by default)")
        }
        let named = spec.split(separator: "/").map(String.init)
        let name = named[0]
        let appName = named.count > 1 ? named[1] : "Virtual Display"
        let settle = UInt32(ProcessInfo.processInfo.environment["ARTEMIS_LIVE_SCROLL_SETTLE"] ?? "") ?? 40
        let dir = ProcessInfo.processInfo.environment["ARTEMIS_SHOT_DIR"] ?? ""
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func log(_ text: String) { print("[live-scroll] \(stamp.string(from: Date())) \(text)") }
        func shot(_ label: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
            if !dir.isEmpty {
                try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("live-scroll-\(label).png"))
            }
            log("shot \(label)")
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "NO", "-ArtemisQuitAppAfterSession", "YES", "-ArtemisShowControlBar", "YES",
                               "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""]
        app.launch()
        XCUIDevice.shared.orientation = .portrait

        // The only computer may open by itself (its apps straight away)
        let row = app.buttons["computer.\(name)"]
        let anyGame = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'game.'")).firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !row.exists && !anyGame.exists && Date() < deadline { sleep(1) }
        if !anyGame.exists {
            XCTAssertTrue(row.exists, "\(name) didn't show up")
            let online = NSPredicate(format: "NOT (label CONTAINS 'Connecting') AND NOT (label CONTAINS 'Offline')")
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: online, object: row)], timeout: 60)
            log("row: \(row.label)")
            row.tap()
        }
        var game = app.buttons["game.\(appName)"]
        if !game.waitForExistence(timeout: 30) {
            game = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'game.'")).firstMatch
        }
        XCTAssertTrue(game.exists, "no apps on \(name) (paired?)")
        game.tap()

        let desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 60), "the session didn't open")
        log("session up: \(desktop.value as? String ?? "")")
        // The PC's side opens its window now
        sleep(settle)

        func drag(_ area: CGRect, _ label: String, dy: CGFloat, duration: TimeInterval = 0.8) {
            let distance = min(140, area.height * 0.6) * (dy < 0 ? -1 : 1)
            log("gesture \(label) begin (fingers \(dy < 0 ? "up" : "down") \(Int(abs(distance))) pt)")
            XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: area.midX - 25, y: area.midY - distance / 2),
                                                    CGPoint(x: area.midX + 25, y: area.midY - distance / 2)],
                                          by: CGVector(dx: 0, dy: distance), duration: duration, testCase: self), "\(label): no multi-touch")
            sleep(3)
            log("gesture \(label) end")
        }

        // Upright: the trackpad area under the desktop
        let trackpad = app.otherElements["trackpad"].frame
        XCTAssertFalse(trackpad.isEmpty, "no trackpad upright (trackpad mode?)")
        shot("1-portrait-start")
        drag(trackpad, "portrait-down", dy: 1)
        shot("2-portrait-after-fingers-down")
        drag(trackpad, "portrait-up", dy: -1)
        shot("3-portrait-after-fingers-up")

        // Landscape: on the desktop picture
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        let frame = desktop.frame
        var size = CGSize(width: frame.width, height: frame.width * 9 / 16)
        if size.height > frame.height { size = CGSize(width: frame.height * 16 / 9, height: frame.height) }
        let video = CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        shot("4-landscape-start")
        drag(video, "landscape-down", dy: 1)
        shot("5-landscape-after-fingers-down")
        drag(video, "landscape-up", dy: -1)
        shot("6-landscape-after-fingers-up")
        // A flick down: momentum after the fingers lift
        drag(video, "landscape-flick-down", dy: 1, duration: 0.1)
        shot("7-landscape-after-flick-down")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        log("disconnecting")
        app.buttons["bar.disconnect"].tap()
        XCTAssertTrue(game.waitForExistence(timeout: 30) || row.waitForExistence(timeout: 5), "the session didn't end")
        sleep(3)
        app.terminate()
    }
}
