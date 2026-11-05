//
//  StoreShotsTests.swift
//  ArtemisUITests
//
//  The App Store screenshots, from the demo PCs: Computers, a PC's apps, the desktop with the
//  control bar (upright and in landscape), the on-screen controller, and Settings. Not in the
//  usual runs; on the store's Simulator size, with the status bar set to 9:41:
//    ONLY=StoreShotsTests APPEARANCES=light SIM=<udid> Scripts/ui-tests.sh
//  writes build/ui-tests/shots/store-<n>-<screen>.png.
//

import XCTest

final class StoreShotsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ARTEMIS_SHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("store-\(name).png"))
        }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""]
        app.launch()
        XCTAssertTrue(app.buttons["computer.WORKSTATION"].waitForExistence(timeout: 15), "no demo PCs")
        return app
    }

    private func openDesktop(_ app: XCUIApplication) {
        app.buttons["computer.WORKSTATION"].tap()
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10))
        desktopApp.tap()
        XCTAssertTrue(app.otherElements["desktop"].waitForExistence(timeout: 10), "the desktop didn't open")
        if !app.buttons["bar.disconnect"].exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
        XCTAssertTrue(app.buttons["bar.disconnect"].waitForExistence(timeout: 5), "no control bar")
    }

    func testStoreScreens() {
        let app = launch()
        sleep(2)
        shot("1-computers")

        app.buttons["computer.WORKSTATION"].tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10))
        sleep(3) // the late artwork
        shot("2-apps")
        app.navigationBars.buttons.firstMatch.tap()

        openDesktop(app)
        sleep(2)
        shot("3-desktop")
        app.buttons["bar.disconnect"].tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["computers.settings"].tap()
        XCTAssertTrue(app.buttons["settings.video"].waitForExistence(timeout: 5))
        sleep(1)
        shot("6-settings")
        app.buttons["settings.touch"].tap()
        XCTAssertTrue(app.navigationBars["Touch & Pointer"].waitForExistence(timeout: 5))
        sleep(1)
        shot("7-settings-touch")
        app.terminate()

        // Landscape: the desktop, then the on-screen controller over it
        let wide = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        openDesktop(wide)
        sleep(2)
        shot("4-desktop-landscape")
        wide.buttons["bar.gamepad"].tap()
        XCTAssertTrue(wide.buttons["pad.A"].waitForExistence(timeout: 5), "no on-screen controller")
        sleep(2)
        shot("5-controller")
        wide.terminate()
    }
}
