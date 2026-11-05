//
//  ScreenshotTests.swift
//  ArtemisUITests
//
//  Every screen with the demo PCs (-ArtemisDemo YES), upright and in landscape, at the
//  default text size and a large accessibility size, with layout checks.
//  Scripts/ui-tests.sh runs them in light and dark mode and collects the screenshots.
//

import XCTest

final class ScreenshotTests: XCTestCase {
    /// The default size and the largest accessibility size.
    private let textSizes = ["L": "UICTContentSizeCategoryL", "AX5": "UICTContentSizeCategoryAccessibilityXXXL"]

    private var appearance: String {
        ProcessInfo.processInfo.environment["ARTEMIS_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "system"
    }

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(size: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", textSizes[size]!,
                               // Where the bar was left by another test doesn't carry over
                               "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""] + arguments
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
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

    /// The element is on screen, inside the window horizontally.
    private func assertOnScreen(_ element: XCUIElement, in app: XCUIApplication, _ tag: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        XCTAssertTrue(element.exists, "\(tag): \(element) missing", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 1, "\(tag): \(element.identifier) starts off screen (\(frame))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1, "\(tag): \(element.identifier) runs off screen (\(frame))", file: file, line: line)
    }

    /// Tappable and clear of the navigation bar.
    private func isVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.isHittable })
        return element.frame.minY >= (bar?.frame.maxY ?? 0) - 1
    }

    /// Scrolls the frontmost list (a sheet's comes after the one behind it) in short drags
    /// until the element is fully usable; lists only hold the rows on screen. In a sheet only
    /// upward: pulling down at the top would close it.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 5, inSheet: Bool = false) -> Bool {
        _ = element.waitForExistence(timeout: timeout)
        if isVisible(element, in: app) { return true }
        let lists = app.collectionViews.allElementsBoundByIndex
        let list = lists.last(where: { $0.isHittable }) ?? app.collectionViews.firstMatch
        func drag(_ from: CGFloat, _ to: CGFloat) {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
        }
        let upward = inSheet || !element.exists || element.frame.minY > list.frame.midY
        for _ in 0..<16 {
            if upward { drag(0.7, 0.45) } else { drag(0.45, 0.7) }
            if isVisible(element, in: app) { return true }
        }
        if !inSheet {
            for _ in 0..<24 {
                drag(0.45, 0.7)
                if isVisible(element, in: app) { return true }
            }
        }
        if !element.exists { shot(app, "debug-reveal") }
        return element.exists
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"]
        if back.exists {
            back.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    /// Cancel on an alert; at large text it's further down the alert's scrolling buttons.
    private func dismissDialog(_ app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        let cancel = alert.buttons["Cancel"]
        for _ in 0..<4 where !(cancel.exists && cancel.isHittable) {
            alert.swipeUp()
        }
        cancel.tap()
        _ = alert.waitForNonExistence(timeout: 5)
    }

    func testEveryScreenUprightDefaultText() { sweep(size: "L", orientation: "portrait") }
    func testEveryScreenLandscapeDefaultText() { sweep(size: "L", orientation: "landscape") }
    func testEveryScreenUprightLargeText() { sweep(size: "AX5", orientation: "portrait") }
    func testEveryScreenLandscapeLargeText() { sweep(size: "AX5", orientation: "landscape") }

    /// Computers, Apps (with the Stop dialog), the connected desktop, pairing, Add PC,
    /// Settings and its pages.
    private func sweep(size: String, orientation orientationName: String) {
        do {
            do {
                let orientation: UIDeviceOrientation = orientationName == "portrait" ? .portrait : .landscapeLeft
                let tag = "\(appearance)-\(orientationName)-\(size)"
                let app = launch(size: size)
                XCUIDevice.shared.orientation = orientation

                // Computers: a paired PC, an offline one, one not paired
                let workstation = app.buttons["computer.WORKSTATION"]
                XCTAssertTrue(workstation.waitForExistence(timeout: 15), "\(tag): no demo PCs")
                for name in ["WORKSTATION", "Living Room PC", "STUDIO"] {
                    let row = app.buttons["computer.\(name)"]
                    XCTAssertTrue(reveal(row, in: app, timeout: 1), "\(tag): no \(name)")
                    assertOnScreen(row, in: app, tag)
                }
                reveal(workstation, in: app, timeout: 1)
                XCTAssertTrue(app.buttons["computers.add"].isHittable, "\(tag): no + button")
                XCTAssertTrue(app.buttons["computers.settings"].isHittable, "\(tag): no Settings button")
                sleep(1)
                shot(app, "\(tag)-1-computers")

                // Apps: artwork rows, Desktop active with Resume / Stop
                workstation.tap()
                let running = app.buttons["game.Desktop"]
                XCTAssertTrue(running.waitForExistence(timeout: 10), "\(tag): the apps didn't open")
                XCTAssertTrue(reveal(app.buttons["game.end"], in: app, timeout: 1), "\(tag): no Stop button")
                let dot = app.descendants(matching: .any)["game.running"]
                XCTAssertTrue(dot.exists, "\(tag): no active dot")
                XCTAssertEqual(dot.label, "Active", "\(tag): the dot doesn't read Active")
                let resume = app.buttons["game.resume"]
                XCTAssertTrue(resume.exists, "\(tag): no Resume button")
                assertOnScreen(resume, in: app, tag)
                assertOnScreen(app.buttons["game.end"], in: app, tag)
                XCTAssertFalse(app.buttons["game.Old Virtual Display"].exists, "\(tag): a hidden app shows")
                sleep(1)
                shot(app, "\(tag)-2-apps")

                app.buttons["game.end"].tap()
                let endAlert = app.alerts.firstMatch
                XCTAssertTrue(endAlert.buttons["Stop"].waitForExistence(timeout: 5), "\(tag): no Stop confirmation")
                XCTAssertTrue(endAlert.label.contains("Stop Desktop on WORKSTATION?"), "\(tag): confirmation title \(endAlert.label)")
                sleep(1)
                shot(app, "\(tag)-3-stop")
                dismissDialog(app)
                sleep(1)

                // The connected desktop (the demo's picture), with the control bar
                running.tap()
                let desktop = app.otherElements["desktop"]
                XCTAssertTrue(desktop.waitForExistence(timeout: 10), "\(tag): the desktop didn't open")
                let disconnect = app.buttons["bar.disconnect"]
                if !disconnect.exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
                XCTAssertTrue(disconnect.waitForExistence(timeout: 5), "\(tag): no control bar")
                assertOnScreen(disconnect, in: app, tag)
                sleep(1)
                shot(app, "\(tag)-3b-desktop")
                disconnect.tap()
                XCTAssertTrue(running.waitForExistence(timeout: 10), "\(tag): didn't return to the apps")
                sleep(1)

                // Hidden apps on request
                let showHidden = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Show All Apps, Including Hidden")).firstMatch
                // The first tap can land while the dialog is still going away
                for _ in 0..<3 where !showHidden.exists {
                    app.buttons["games.more"].tap()
                    _ = showHidden.waitForExistence(timeout: 2)
                }
                XCTAssertTrue(showHidden.waitForExistence(timeout: 5), "\(tag): no Show All Apps item")
                if !showHidden.exists { print("[tree] \(app.debugDescription)"); shot(app, "\(tag)-debug-menu") }
                showHidden.tap()
                let hidden = app.buttons["game.Old Virtual Display"]
                XCTAssertTrue(reveal(hidden, in: app), "\(tag): hidden app doesn't show")
                goBack(app)

                // Pairing: the PIN, large, on one line
                let studio = app.buttons["computer.STUDIO"]
                XCTAssertTrue(reveal(studio, in: app), "\(tag): no STUDIO to pair")
                studio.tap()
                let pin = app.staticTexts["pairing.pin"]
                XCTAssertTrue(pin.waitForExistence(timeout: 5), "\(tag): no PIN")
                assertOnScreen(pin, in: app, tag)
                XCTAssertLessThan(pin.frame.height, 140, "\(tag): the PIN wraps (\(pin.frame))")
                sleep(1)
                shot(app, "\(tag)-4-pairing")
                app.buttons["pairing.cancel"].tap()
                XCTAssertTrue(app.buttons["computers.add"].waitForExistence(timeout: 5))

                // Add PC
                app.buttons["computers.add"].tap()
                let address = app.textFields["add.address"]
                XCTAssertTrue(address.waitForExistence(timeout: 5), "\(tag): Add PC didn't open")
                sleep(1)
                shot(app, "\(tag)-5-add-pc")
                app.buttons["Cancel"].firstMatch.tap()
                XCTAssertTrue(app.buttons["computers.add"].waitForExistence(timeout: 5))
                sleep(1)

                // Settings and its Video & Display page
                app.buttons["computers.settings"].tap()
                let video = app.buttons["settings.video"]
                XCTAssertTrue(video.waitForExistence(timeout: 5), "\(tag): Settings didn't open")
                sleep(1)
                shot(app, "\(tag)-6-settings")
                video.tap()
                XCTAssertTrue(app.buttons["settings.resolution"].waitForExistence(timeout: 5) || app.otherElements["settings.resolution"].exists, "\(tag): no resolution picker")
                sleep(1)
                shot(app, "\(tag)-7-settings-video")
                XCTAssertTrue(reveal(app.sliders["settings.bitrate"], in: app, timeout: 1, inSheet: true), "\(tag): no bitrate slider")
                goBack(app)
                for section in ["audio", "keyboard", "controllers", "touch", "host", "general", "advanced"] {
                    XCTAssertTrue(reveal(app.buttons["settings.\(section)"], in: app, timeout: 1, inSheet: true), "\(tag): no \(section) section")
                    if section == "touch" {
                        // Touch & Pointer
                        app.buttons["settings.touch"].tap()
                        XCTAssertTrue(app.navigationBars["Touch & Pointer"].waitForExistence(timeout: 5), "\(tag): Touch & Pointer didn't open")
                        XCTAssertTrue(reveal(app.sliders["settings.pointerSpeed"], in: app, timeout: 1, inSheet: true), "\(tag): no pointer speed")
                        sleep(1)
                        shot(app, "\(tag)-7b-settings-touch")
                        goBack(app)
                    }
                }
                app.buttons["settings.done"].tap()
                XCTAssertTrue(app.buttons["computers.add"].waitForExistence(timeout: 5))

                // Waking the offline PC
                let livingRoom = app.buttons["computer.Living Room PC"]
                XCTAssertTrue(reveal(livingRoom, in: app))
                livingRoom.tap()
                let waking = NSPredicate(format: "label CONTAINS %@", "Waking up")
                XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: waking, object: livingRoom)], timeout: 5) == .completed,
                              "\(tag): no Waking up status (\(livingRoom.label))")
                sleep(1)
                shot(app, "\(tag)-8-waking")
                app.terminate()
            }
        }
    }

    /// Opening another app while one is active: confirm, end the active one, the real stream
    /// screen opens (with -ArtemisDemoRealStream YES) with its controls, can't reach the demo
    /// host, and its error's OK returns to the apps list.
    func testStreamStartsAndReturns() {
        let app = launch(size: "L", arguments: ["-ArtemisDemoRealStream", "YES"])
        XCUIDevice.shared.orientation = .portrait
        let workstation = app.buttons["computer.WORKSTATION"]
        XCTAssertTrue(workstation.waitForExistence(timeout: 15))
        workstation.tap()
        let blender = app.buttons["game.Blender"]
        XCTAssertTrue(blender.waitForExistence(timeout: 10))
        blender.tap()
        let endAndOpen = app.buttons["Stop It and Open Blender"]
        XCTAssertTrue(endAndOpen.waitForExistence(timeout: 5), "no end-and-open confirmation")
        shot(app, "\(appearance)-portrait-L-9-switch-app")
        endAndOpen.tap()

        // The stream screen, upright: the desktop on top, the controls under it
        let starting = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Connecting to Blender")).firstMatch
        let failed = app.alerts.firstMatch
        XCTAssertTrue(starting.waitForExistence(timeout: 10) || failed.waitForExistence(timeout: 1), "the session didn't start")
        XCTAssertTrue(app.buttons["bar.disconnect"].exists || failed.exists, "no control bar on the stream screen")
        // The real stream screen defers system gestures on every edge, as the demo's does
        let desktop = app.otherElements["desktop"]
        if desktop.exists, !failed.exists {
            let status = (desktop.value as? String ?? "").components(separatedBy: "\n").first ?? ""
            XCTAssertTrue(status.contains("edges all"), "stream screen: \(status)")
        }
        XCTAssertEqual(XCUIDevice.shared.orientation, .portrait)
        shot(app, "\(appearance)-stream-starting")

        XCTAssertTrue(failed.waitForExistence(timeout: 30), "no connection error from the demo host")
        shot(app, "\(appearance)-stream-error")
        failed.buttons["OK"].tap()

        // Back on the apps list; nothing is active any more
        XCTAssertTrue(app.buttons["game.Blender"].waitForExistence(timeout: 10), "didn't return to the apps")
        sleep(2)
        XCTAssertFalse(app.descendants(matching: .any)["game.running"].exists, "Desktop still shows as active")
        shot(app, "\(appearance)-portrait-L-10-after-session")
    }
}
