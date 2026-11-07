//
//  ClipboardTests.swift
//  ArtemisUITests
//
//  The shared clipboard with Apollo on the app's real path (StreamFrameViewController,
//  StreamClipboard, HttpManager, UIPasteboard) against the stand-in PC TOWER
//  (-ArtemisTestFakePC), whose /actions/clipboard answers "PC got: <text>" once text reaches it.
//  TOWER never has a stream up, so -ArtemisTestFakePCSession starts the clipboard with the stream
//  screen. The decisions themselves (what's read, sent and written when) are in
//  Scripts/clipboard-tests.sh.
//

import XCTest

final class ClipboardTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// `copied`: what the app copies at launch, as if copied before the session (copied by this
    /// test, the app's read would need iOS's "Allow Paste", which the Simulator can't show: the
    /// read gets nothing).
    private func launch(share: Bool, copied: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisTestFakePCCopied", copied, "-ArtemisDemo", "NO", "-ArtemisTestFakePC", "YES", "-ArtemisTestFakePCAlone", "YES",
                               "-ArtemisTestFakePCAppsCached", "YES", "-ArtemisTestFakePCSession", "YES",
                               "-ArtemisTestFakePCClipboard", "on the PC before the session",
                               "-ArtemisShareClipboard", share ? "YES" : "NO",
                               "-ArtemisQuitAppAfterSession", "NO",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    /// The only PC opens by itself; its Desktop starts the stream screen.
    private func openStreamScreen(_ app: XCUIApplication) {
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 20), "TOWER's apps didn't open")
        desktopApp.tap()
        XCTAssertTrue(app.buttons["bar.disconnect"].waitForExistence(timeout: 10) || app.buttons["bar.unfold"].exists,
                      "no stream screen")
    }

    private func disconnect(_ app: XCUIApplication) {
        let button = app.buttons["bar.disconnect"]
        if !button.exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Disconnect")
        button.tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10), "didn't return to the apps")
    }

    /// Copied before the session: it reaches the PC, and the PC's copy during the session
    /// lands here, once (no echo); what was on the PC before the session doesn't come over.
    /// This test can't read what the app copied (the Simulator can't ask "Allow Paste" for it
    /// either), only see the pasteboard change: TOWER's clipboard changes only with the text the
    /// app sent ("PC got: …"), and the app writes only a change from what the PC had at first,
    /// so one write means the text went to the PC and came back. The text itself:
    /// Scripts/clipboard-tests.sh.
    func testTextGoesBothWaysWithThePC() {
        let app = launch(share: true, copied: "copied on the iPhone \(UUID().uuidString.prefix(8))\nsecond line")
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 20), "TOWER's apps didn't open")
        let start = UIPasteboard.general.changeCount
        openStreamScreen(app)

        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in UIPasteboard.general.changeCount > start }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 20), .completed, "the PC's copy didn't come over")
        // Several more polls (every 2 s): nothing more comes over, nothing goes back and forth
        sleep(7)
        XCTAssertEqual(UIPasteboard.general.changeCount, start + 1, "the pasteboard kept changing")
        XCTAssertTrue(UIPasteboard.general.hasStrings, "the PC's copy isn't text")
        disconnect(app)
        XCTAssertEqual(UIPasteboard.general.changeCount, start + 1, "the pasteboard changed when leaving")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a message after the session: \(app.alerts.firstMatch.label)")
        app.terminate()
    }

    /// Settings › Host PC › Share copied text with the host PC off: nothing is read or written.
    func testNothingSharedWhenOff() {
        let app = launch(share: false, copied: "not for the PC \(UUID().uuidString.prefix(8))")
        openStreamScreen(app)
        let count = UIPasteboard.general.changeCount
        // Several of the clipboard's polls (every 2 s) would have run by now
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            XCTAssertEqual(UIPasteboard.general.changeCount, count, "the pasteboard changed with sharing off")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        disconnect(app)
        XCTAssertEqual(UIPasteboard.general.changeCount, count, "the pasteboard changed after leaving with sharing off")
        app.terminate()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// The setting is on Settings › Host PC, on by default.
    func testSettingOnHostPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        let settings = app.buttons["computers.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let host = app.buttons["settings.host"]
        XCTAssertTrue(reveal(host, in: app), "no Host PC section")
        host.tap()
        let toggle = app.switches["settings.shareClipboard"]
        XCTAssertTrue(reveal(toggle, in: app), "no Share copied text switch")
        XCTAssertEqual(toggle.label, "Share copied text with the host PC")
        XCTAssertEqual(toggle.value as? String, "1", "off by default")
        app.terminate()
    }
}
