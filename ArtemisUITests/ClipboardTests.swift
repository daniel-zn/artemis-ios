//
//  ClipboardTests.swift
//  ArtemisUITests
//
//  The shared clipboard with Apollo on the app's real path (StreamFrameViewController,
//  StreamClipboard, HttpManager, UIPasteboard) against the stand-in PC TOWER
//  (-ArtemisTestFakePC), whose /actions/clipboard answers "PC got: <text>" once text reaches it.
//  TOWER never has a stream up, so -ArtemisTestFakePCSession starts the clipboard with the stream
//  screen. The desktop's state line shows the app's pasteboard reads and writes, what the pastes did and
//  what TOWER's clipboard got. The decisions themselves (what's read, sent and written when) are
//  in Scripts/clipboard-tests.sh.
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

    /// The desktop's state line (DesktopViewController.updateAccessibilityValue).
    private func status(_ app: XCUIApplication) -> String {
        (app.otherElements["desktop"].value as? String ?? "").components(separatedBy: "\n").first ?? ""
    }

    /// Waits up to `timeout` for the state line to contain `text`.
    private func waitForStatus(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status(app).contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return status(app).contains(text)
    }

    /// iOS may ask before the app reads the pasteboard (⌘V, Ctrl+V): allowed.
    private func allowPasteIfAsked() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    /// The session starts without reading the pasteboard (so iOS never asks "Allow Paste" then;
    /// the home screen ends a session, and coming back from Control Center reads nothing either:
    /// Scripts/clipboard-tests.sh); the bar's Paste hands the copied text over without asking: it lands
    /// on the PC's clipboard, then Ctrl+V goes to the PC. The PC's copy (TOWER answers "PC got:
    /// <text>") comes back here once, no echo; what was on the PC before the session doesn't.
    func testPasteSendsTextThenCtrlV() {
        let copied = "copied on the iPhone \(UUID().uuidString.prefix(8))\nsecond line"
        let app = launch(share: true, copied: copied.replacingOccurrences(of: "\n", with: "⏎"))
        openStreamScreen(app)

        // Several of the clipboard's polls (every 2 s): nothing read, sent or written
        sleep(5)
        XCTAssertTrue(status(app).contains("pasteboard reads 0 · writes 0 · pastes none"), "read at the start: \(status(app))")
        XCTAssertTrue(status(app).contains("the PC's clipboard got []"), "sent at the start: \(status(app))")

        // Paste in the bar: no question, the text onto the PC's clipboard, then Ctrl+V
        let paste = app.buttons["bar.paste"]
        if !paste.exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the bar")
        XCTAssertTrue(paste.isEnabled, "Paste is dimmed with text copied")
        paste.tap()
        let wire = copied.replacingOccurrences(of: "\n", with: "⏎")
        XCTAssertTrue(waitForStatus(app, "pastes Ctrl+V after the PC got 1"), "no Ctrl+V after the text landed: \(status(app))")
        XCTAssertTrue(status(app).contains("the PC's clipboard got [\(wire)]"), "the PC didn't get the text: \(status(app))")
        XCTAssertTrue(status(app).contains("pasteboard reads 0"), "the app read the pasteboard itself: \(status(app))")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"].exists, "iOS asked")

        // The PC's clipboard changed ("PC got: …"): it comes over once (the app's count of writes,
        // not changeCount: the Simulator also takes whatever is copied on the Mac)
        XCTAssertTrue(waitForStatus(app, "writes 1 · ", timeout: 20), "the PC's copy didn't come over: \(status(app))")
        sleep(5)
        XCTAssertTrue(status(app).contains("writes 1 · "), "the pasteboard kept changing: \(status(app))")
        disconnect(app)
        XCTAssertFalse(app.alerts.firstMatch.exists, "a message after the session: \(app.alerts.firstMatch.label)")
        app.terminate()
    }

    /// A hardware keyboard: ⌘V reads the copied text then (only then), puts it on the PC's
    /// clipboard and sends Ctrl+V; Ctrl+V with nothing new copied is the PC's own paste, unread.
    func testKeyboardPasteReadsOnlyThen() {
        let copied = "typed with a keyboard \(UUID().uuidString.prefix(8))"
        let app = launch(share: true, copied: copied)
        openStreamScreen(app)
        sleep(3)
        XCTAssertTrue(status(app).contains("pasteboard reads 0 · writes 0 · pastes none"), "read at the start: \(status(app))")

        app.typeKey("v", modifierFlags: .command)
        allowPasteIfAsked()
        XCTAssertTrue(waitForStatus(app, "pastes Ctrl+V after the PC got 1"), "⌘V: no Ctrl+V after the text landed: \(status(app))")
        XCTAssertTrue(status(app).contains("the PC's clipboard got [\(copied)]"), "⌘V: the PC didn't get the text: \(status(app))")
        XCTAssertTrue(status(app).contains("pasteboard reads 1"), "⌘V: \(status(app))")

        // The PC's copy comes back here; Ctrl+V now pastes the PC's clipboard as it is
        XCTAssertTrue(waitForStatus(app, "writes 1 · ", timeout: 20), "the PC's copy didn't come over: \(status(app))")
        app.typeKey("v", modifierFlags: .control)
        XCTAssertTrue(waitForStatus(app, "Ctrl+V after the PC got 1, Ctrl+V after the PC got 1"), "Ctrl+V: \(status(app))")
        XCTAssertTrue(status(app).contains("pasteboard reads 1 · "), "Ctrl+V read the pasteboard again: \(status(app))")
        disconnect(app)
        app.terminate()
    }

    /// Sharing off: the bar's Paste types the text (as Type Clipboard), nothing goes to the PC's
    /// clipboard.
    func testPasteTypesWhenNotShared() {
        let copied = "typed instead \(UUID().uuidString.prefix(8))"
        let app = launch(share: false, copied: copied)
        openStreamScreen(app)
        let paste = app.buttons["bar.paste"]
        if !paste.exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the bar")
        paste.tap()
        XCTAssertTrue(waitForStatus(app, "pastes typed \(copied.count)"), "not typed: \(status(app))")
        XCTAssertTrue(status(app).contains("the PC's clipboard got []"), "sent with sharing off: \(status(app))")
        disconnect(app)
        app.terminate()
    }

    /// Settings › Host PC › Share copied text with the host PC off: nothing is read or written.
    func testNothingSharedWhenOff() {
        let app = launch(share: false, copied: "not for the PC \(UUID().uuidString.prefix(8))")
        openStreamScreen(app)
        // Several of the clipboard's polls (every 2 s) would have run by now. The app's own count of
        // writes, not changeCount: the Simulator also takes whatever is copied on the Mac.
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        XCTAssertTrue(status(app).contains("pasteboard reads 0 · writes 0 · pastes none"), "shared with sharing off: \(status(app))")
        XCTAssertTrue(status(app).contains("the PC's clipboard got []"), "the PC got text with sharing off: \(status(app))")
        disconnect(app)
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
