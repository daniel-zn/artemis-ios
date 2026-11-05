//
//  TryDemoTests.swift
//  ArtemisUITests
//
//  Someone without a PC (App Review) can try the app: the empty Computers screen has
//  Try the Demo, which opens the demo PCs and their desktop; Exit Demo brings the empty
//  screen back. -ArtemisTestNoPCs YES starts without saved PCs or discovery, so the
//  Simulator's own paired PCs and the network don't fill the list.
//

import XCTest

final class TryDemoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTryTheDemoFromTheEmptyScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "NO", "-ArtemisTestNoPCs", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}"]
        app.launch()

        let tryDemo = app.buttons["computers.tryDemo"]
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 15), "no Try the Demo on the empty Computers screen")
        XCTAssertTrue(app.buttons["Add PC Manually"].exists)
        tryDemo.tap()

        let workstation = app.buttons["computer.WORKSTATION"]
        XCTAssertTrue(workstation.waitForExistence(timeout: 10), "the demo PCs didn't open")
        XCTAssertFalse(tryDemo.exists, "Try the Demo stays only on the empty screen")
        workstation.tap()
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10), "the demo PC's apps didn't open")
        desktopApp.tap()
        let desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), "the demo desktop didn't open")
        let disconnect = app.buttons["bar.disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5), "no control bar on the demo desktop")
        disconnect.tap()

        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10), "didn't come back from the demo desktop")
        app.navigationBars.buttons.firstMatch.tap()
        let exit = app.buttons["computers.exitDemo"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "no Exit Demo")
        exit.tap()
        XCTAssertTrue(tryDemo.waitForExistence(timeout: 5), "Exit Demo didn't bring the empty screen back")
        XCTAssertFalse(workstation.exists, "the demo PCs stayed after Exit Demo")
    }
}
