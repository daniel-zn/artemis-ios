//
//  ComputerTests.swift
//  ArtemisUITests
//
//  The Computers list's actions against the demo PCs (-ArtemisDemo YES): waking an offline PC
//  (by a tap, which then opens it, or from its menu) and the status following the PC, a wake
//  that never comes up, and the PC actions the Mac app has (rename, Get Info, connect
//  automatically). Cancel on the "Connecting…" card also on the real path, against stand-in PCs
//  (-ArtemisTestFakePC YES: ComputerStore, discovery and HttpManager with a stand-in network).
//

import XCTest

final class ComputerTests: XCTestCase {
    private var appearance: String {
        ProcessInfo.processInfo.environment["ARTEMIS_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "system"
    }

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String] = [], size: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", size,
                               // Where the bar was left by another test doesn't carry over
                               "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""] + arguments
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

    @discardableResult
    private func waitForLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Long-presses a row (scrolled on screen first) and returns its menu's item (pressing again if
    /// the menu didn't open).
    /// A menu taller than the screen (landscape at the largest text size) scrolls, and lists only
    /// the items on screen: it's scrolled until the item shows.
    private func openMenu(_ row: XCUIElement, item label: String, in app: XCUIApplication) -> XCUIElement {
        let item = menuItem(app, label)
        // The menu: the collection view with a button that isn't a PC's or an app's row
        let menu = app.collectionViews.containing(NSPredicate(format: "elementType == %d AND NOT (identifier BEGINSWITH 'computer.') AND NOT (identifier BEGINSWITH 'game.')",
                                                              XCUIElement.ElementType.button.rawValue)).firstMatch
        for _ in 0..<3 {
            // A turn to landscape can leave the row scrolled under the navigation bar
            reveal(row, in: app)
            row.press(forDuration: 1.3)
            guard menu.waitForExistence(timeout: 3) else { continue }
            if item.waitForExistence(timeout: 1) { return item }
            for _ in 0..<4 where menu.exists && !item.exists {
                menu.swipeUp(velocity: .slow)
                _ = item.waitForExistence(timeout: 1)
            }
            if item.exists && item.isHittable { return item }
        }
        print("[tree] \(app.debugDescription)")
        return item
    }

    /// Scrolls the frontmost list until the element can be tapped: up first, then down.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 2)
        let list = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.collectionViews.firstMatch
        for attempt in 0..<12 {
            if element.exists && element.isHittable { return true }
            let up = attempt < 4
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.35))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.4 : 0.65)))
        }
        return element.exists && element.isHittable
    }

    /// Waits until an element is on screen and stays put (the same frame for half a second).
    private func settled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        var last = CGRect.null
        while Date() < end {
            let frame = element.exists && element.isHittable ? element.frame : .null
            if !frame.isNull && frame == last { return true }
            last = frame
            usleep(500_000)
        }
        return false
    }

    /// Sets the name in the open rename alert and confirms it. The alert focuses its field itself,
    /// with the cursor after the name: the old name's deletes and the new name go in one typing,
    /// with no tap on the field. Rename is tapped once the keyboard is back and it holds still.
    /// The waits are long (they end as soon as the alert gets there): on a loaded Mac the
    /// alert's field took over 5 s to be focused.
    private func rename(to name: String, in app: XCUIApplication, _ tag: String) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "\(tag): no rename alert")
        let field = alert.textFields.firstMatch
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 20), .completed, "\(tag): the name field isn't focused")
        let placeholder = field.placeholderValue ?? ""
        let old = field.value as? String ?? ""
        let count = old == placeholder ? 0 : old.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + name)
        // An emptied field reads as "" or as its placeholder, and the value follows the typing a
        // moment later: wait for it
        let typed = { () -> Bool in
            let value = field.value as? String ?? ""
            return name.isEmpty ? value.isEmpty || value == placeholder : value == name
        }
        let deadline = Date().addingTimeInterval(10)
        while !typed() && Date() < deadline { usleep(100_000) }
        XCTAssertTrue(typed(), "\(tag): the name field reads \"\(field.value as? String ?? "")\", not \"\(name)\"")
        if !name.isEmpty { shot("\(tag)-parity-2-rename") }
        // XCTest's typing hides the keyboard, which comes back a moment later and moves the alert
        let keyboard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboard], timeout: 20), .completed, "\(tag): the keyboard didn't come back after typing")
        let confirm = alert.buttons["rename.confirm"].firstMatch
        XCTAssertTrue(settled(confirm, timeout: 20), "\(tag): Rename doesn't hold still on screen")
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 20), .completed, "\(tag): the rename alert didn't close")
    }

    private func disconnect(_ app: XCUIApplication) {
        let button = app.buttons["bar.disconnect"]
        if !button.exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Disconnect")
        button.tap()
    }

    /// Tapping an offline PC wakes it, shows "Waking up…", and opens its apps once it's up.
    func testTapWakesThenOpens() {
        let app = launch(["-ArtemisDemoWakeDelay", "3"])
        let livingRoom = app.buttons["computer.Living Room PC"]
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 5))
        XCTAssertTrue(livingRoom.label.contains("Tap to wake"), "status: \(livingRoom.label)")
        livingRoom.tap()
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Waking up", timeout: 3), "no Waking up (\(livingRoom.label))")
        shot("\(appearance)-portrait-L-wake-1-waking")
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 15), "the PC woke but its apps didn't open")
        XCTAssertEqual(app.navigationBars.firstMatch.identifier, "Living Room PC")
        shot("\(appearance)-portrait-L-wake-2-opened")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Online", timeout: 5), "status after waking: \(livingRoom.label)")
        XCTAssertFalse(livingRoom.label.contains("Waking"), "still waking: \(livingRoom.label)")
        app.terminate()
    }

    /// Wake PC from the long-press menu: "Waking up…" turns into Online when the PC is up,
    /// and nothing opens by itself.
    func testMenuWakeFollowsThePC() {
        let app = launch(["-ArtemisDemoWakeDelay", "3"])
        let livingRoom = app.buttons["computer.Living Room PC"]
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 5))
        let wake = openMenu(livingRoom, item: "Wake PC", in: app)
        XCTAssertTrue(wake.exists, "no Wake PC in the menu")
        shot("\(appearance)-portrait-L-wake-3-menu")
        wake.tap()
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Waking up", timeout: 3), "no Waking up (\(livingRoom.label))")
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Online", timeout: 15), "stuck: \(livingRoom.label)")
        XCTAssertFalse(livingRoom.label.contains("Waking"), "still waking: \(livingRoom.label)")
        XCTAssertFalse(app.buttons["game.Desktop"].exists, "the menu's wake opened the PC")
        shot("\(appearance)-portrait-L-wake-4-online")
        app.terminate()
    }

    /// A PC that never comes up: back to Offline after the timeout, with a message.
    func testWakeTimesOut() {
        // The wake's time limit is longer than a tap can take to settle on a loaded Mac (a 5 s
        // one ran out before the tap returned, so "Waking up" was already over)
        let app = launch(["-ArtemisDemoWakeDelay", "9999", "-ArtemisWakeTimeout", "15"])
        let livingRoom = app.buttons["computer.Living Room PC"]
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 5))
        livingRoom.tap()
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Waking up", timeout: 5), "no Waking up (\(livingRoom.label))")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "no message after the wake timed out")
        XCTAssertTrue(alert.label.contains("Couldn't Wake Living Room PC"), "alert: \(alert.label)")
        shot("\(appearance)-portrait-L-wake-5-timeout")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Offline", timeout: 3), "status: \(livingRoom.label)")
        XCTAssertFalse(livingRoom.label.contains("Waking"), "still waking: \(livingRoom.label)")
        app.terminate()
    }

    /// Cancel on the "Connecting to WORKSTATION…" card (-ArtemisDemoConnectDelay: the PC takes
    /// 8 s to answer, longer than a tap takes to settle on a loaded Mac): the card goes, the Computers list stays, and nothing opens or complains
    /// once the PC would have answered. Opening it again still works.
    func testCancelConnecting() {
        let app = launch(["-ArtemisDemoConnectDelay", "8"])
        let workstation = app.buttons["computer.WORKSTATION"]
        let card = app.descendants(matching: .any)["busy"]
        let cancel = app.buttons["busy.cancel"]
        workstation.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no Connecting card")
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "no Cancel on the Connecting card")
        XCTAssertEqual(cancel.label, "Cancel")
        XCTAssertTrue(isRed(cancel), "Cancel isn't red")
        shot("\(appearance)-portrait-L-connect-1-cancel")
        cancel.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3), "the card stayed after Cancel")
        // Past the moment the PC answers: still on the Computers list, no apps, no message
        XCTAssertFalse(app.buttons["game.Desktop"].waitForExistence(timeout: 10), "the PC opened after Cancel")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a message after Cancel: \(app.alerts.firstMatch.label)")
        XCTAssertTrue(workstation.isHittable, "not back on the Computers list")

        workstation.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no Connecting card the second time")
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 20), "the PC didn't open after a cancelled try")
        XCTAssertFalse(card.exists, "the card stayed over the apps")
        app.terminate()
    }

    /// A tap that woke the PC connects once it's up; that card has Cancel too, at the largest text
    /// size, and Cancel leaves the PC online on the list without opening it.
    func testCancelConnectingAfterWakeLargeText() {
        let app = launch(["-ArtemisDemoWakeDelay", "1", "-ArtemisDemoConnectDelay", "8"],
                         size: "UICTContentSizeCategoryAccessibilityXXXL")
        let livingRoom = app.buttons["computer.Living Room PC"]
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 5))
        livingRoom.tap()
        let cancel = app.buttons["busy.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "no Cancel on the card once the PC woke")
        XCTAssertTrue(cancel.isHittable, "Cancel is off screen at the largest text size")
        shot("\(appearance)-portrait-AX5-connect-2-cancel")
        cancel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["busy"].waitForNonExistence(timeout: 3), "the card stayed after Cancel")
        XCTAssertFalse(app.buttons["game.Desktop"].waitForExistence(timeout: 10), "the PC opened after Cancel")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a message after Cancel: \(app.alerts.firstMatch.label)")
        XCTAssertTrue(waitForLabel(livingRoom, contains: "Online", timeout: 3), "status after Cancel: \(livingRoom.label)")
        app.terminate()
    }

    // MARK: Cancel on the real path (stand-in PCs, -ArtemisTestFakePC)

    /// The app on its real path (ComputerStore, discovery's polls, HttpManager) with stand-in PCs
    /// on a stand-in network: TOWER (paired, awake, its apps not known yet) and DEN (asleep).
    /// Waits until polls have found TOWER online.
    private func launchFake(_ arguments: [String] = [], waitsForOnline: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "NO", "-ArtemisTestFakePC", "YES",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"] + arguments
        app.launch()
        let tower = app.buttons["computer.TOWER"]
        XCTAssertTrue(tower.waitForExistence(timeout: 20), "no stand-in PC")
        guard waitsForOnline else { return app }
        XCTAssertTrue(waitForLabel(tower, contains: "Online", timeout: 15), "TOWER isn't online: \(tower.label)")
        return app
    }

    /// Cancel leaves the PC as it was: the card goes, nothing opens or complains when the PC's
    /// answer to the cancelled open arrives, and its row still says Online, not asleep.
    private func cancelAndCheck(_ app: XCUIApplication, _ tag: String) {
        let tower = app.buttons["computer.TOWER"]
        let card = app.descendants(matching: .any)["busy"]
        let cancel = app.buttons["busy.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "\(tag): no Cancel on the Connecting card (\(tower.label))")
        cancel.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 3), "\(tag): the card stayed after Cancel")
        XCTAssertTrue(waitForLabel(tower, contains: "Online", timeout: 3), "\(tag): status after Cancel: \(tower.label)")
        XCTAssertFalse(tower.label.contains("Waking") || tower.label.contains("wake"), "\(tag): an awake PC is asleep after Cancel: \(tower.label)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "\(tag): a message after Cancel: \(app.alerts.firstMatch.label)")
    }

    /// Tapping TOWER again after a Cancel does what the first tap did: it connects (the card,
    /// then its apps), and never wakes it.
    private func tapConnects(_ app: XCUIApplication, _ tag: String) {
        let tower = app.buttons["computer.TOWER"]
        XCTAssertTrue(tower.isHittable, "\(tag): not on the Computers list")
        tower.tap()
        let desktop = app.buttons["game.Desktop"]
        let end = Date().addingTimeInterval(20)
        while Date() < end && !desktop.exists {
            if tower.exists && tower.label.contains("Waking") {
                XCTFail("\(tag): the tap woke an awake PC: \(tower.label)")
                break
            }
            if app.alerts.firstMatch.exists {
                XCTFail("\(tag): \(app.alerts.firstMatch.label)")
                break
            }
            usleep(200_000)
        }
        XCTAssertTrue(desktop.exists, "\(tag): TOWER's apps didn't open (\(tower.exists ? tower.label : "-"))")
    }

    /// Daniel's case: an awake PC whose answer comes in after Cancel (-ArtemisTestFakePCHold: the
    /// open's serverinfo answer waits until just after Cancel). The row stays Online, and the
    /// next tap connects, it doesn't wake the PC. The Cancel button is red (destructive).
    func testCancelThenTapConnectsRealPath() {
        let app = launchFake(["-ArtemisTestFakePCHold", "4.5"])
        app.buttons["computer.TOWER"].tap()
        let cancel = app.buttons["busy.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no Cancel on the Connecting card")
        XCTAssertTrue(isRed(cancel), "Cancel isn't red")
        cancelAndCheck(app, "cancel")
        // Past the cancelled open's answer: still on the list
        XCTAssertFalse(app.buttons["game.Desktop"].waitForExistence(timeout: 3), "the PC opened after Cancel")
        cancelAndCheckStill(app)
        tapConnects(app, "tap after Cancel")
        app.terminate()
    }

    /// Cancel again and again, each time the moment the card shows, then a quick tap: TOWER
    /// stays online and that tap connects.
    func testRepeatedCancelsThenQuickTapRealPath() {
        let app = launchFake(["-ArtemisTestFakePCHold", "4.5"])
        let tower = app.buttons["computer.TOWER"]
        for round in 1...3 {
            tower.tap()
            cancelAndCheck(app, "round \(round)")
        }
        tapConnects(app, "tap after 3 Cancels")
        app.terminate()
    }

    /// The only PC opens by itself at launch (-ArtemisTestFakePCAlone): a tap and Cancel while
    /// that's still asking the PC stops it too, so nothing opens behind the user's Cancel, and
    /// the next tap connects.
    func testCancelStopsTheLaunchOpenRealPath() {
        // Tapped as soon as it shows: its status may not be known yet (the open waits for it),
        // and the launch's own open (no card) is still asking TOWER, which holds its answer
        let app = launchFake(["-ArtemisTestFakePCAlone", "YES", "-ArtemisTestFakePCHold", "4.8"], waitsForOnline: false)
        let tower = app.buttons["computer.TOWER"]
        XCTAssertFalse(app.buttons["game.Desktop"].exists, "TOWER opened before the tap")
        tower.tap()
        cancelAndCheck(app, "cancel at launch")
        XCTAssertFalse(app.buttons["game.Desktop"].waitForExistence(timeout: 4), "the PC opened after Cancel")
        tapConnects(app, "tap after Cancel at launch")
        app.terminate()
    }

    /// Still on the Computers list with TOWER online.
    private func cancelAndCheckStill(_ app: XCUIApplication) {
        let tower = app.buttons["computer.TOWER"]
        XCTAssertTrue(tower.isHittable, "not back on the Computers list")
        XCTAssertTrue(tower.label.contains("Online"), "status after the cancelled answer: \(tower.label)")
    }

    /// The button's text is drawn in red (systemRed, light or dark): most of its strongly coloured
    /// pixels are red, none blue.
    private func isRed(_ element: XCUIElement) -> Bool {
        let image = element.screenshot().image
        guard let cg = image.cgImage else { return false }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var red = 0, blue = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if r > 180 && g < 110 && b < 110 { red += 1 }
            if b > 180 && r < 110 { blue += 1 }
        }
        print("[isRed] red \(red) blue \(blue) of \(width * height)")
        return red > 20 && red > blue * 4
    }

    /// A paired PC that goes to sleep (-ArtemisDemoSleep: an answer over plain HTTP only, then
    /// none) stays paired: "Offline · Tap to wake", never "Not paired", and a tap wakes it
    /// instead of asking for a PIN. A wake that doesn't bring it up says so.
    func testSleepingPCStaysPaired() {
        let app = launch(["-ArtemisDemoSleep", "YES", "-ArtemisDemoWakeDelay", "9999", "-ArtemisWakeTimeout", "15"])
        let workstation = app.buttons["computer.WORKSTATION"]
        var seen: [String] = []
        // Several of its polls (one a second), each label it shows on the way
        let end = Date().addingTimeInterval(7)
        while Date() < end {
            let label = workstation.label
            if seen.last != label { seen.append(label) }
            usleep(200_000)
        }
        XCTAssertFalse(seen.contains { $0.contains("Not paired") }, "a sleeping paired PC showed as not paired: \(seen)")
        XCTAssertTrue(waitForLabel(workstation, contains: "Offline · Tap to wake", timeout: 3), "status: \(workstation.label) (\(seen))")
        shot("\(appearance)-portrait-L-sleep-1-offline")

        workstation.tap()
        XCTAssertTrue(waitForLabel(workstation, contains: "Waking up", timeout: 5), "no Waking up (\(workstation.label))")
        XCTAssertFalse(app.staticTexts["pairing.pin"].waitForExistence(timeout: 2), "a tap on a sleeping paired PC asked to pair")
        shot("\(appearance)-portrait-L-sleep-2-waking")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "no message after the wake timed out")
        XCTAssertTrue(alert.label.contains("Couldn't Wake WORKSTATION"), "alert: \(alert.label)")
        shot("\(appearance)-portrait-L-sleep-3-couldnt-wake")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForLabel(workstation, contains: "Offline · Tap to wake", timeout: 3), "status: \(workstation.label)")
        XCTAssertFalse(app.staticTexts["pairing.pin"].exists, "the PIN sheet came up")
        app.terminate()
    }

    // MARK: The Mac app's PC and app actions

    /// Rename… and Get Info from a PC's menu; an empty name goes back to the PC's own. Upright and
    /// in landscape, at the default and the largest text size (ARTEMIS_RENAME_VARIANT=landscape-AX5
    /// runs one). UIKit's animations are off: see `DemoData.disablesAnimations`.
    func testRenameAndGetInfo() {
        executionTimeAllowance = 360
        let only = ProcessInfo.processInfo.environment["ARTEMIS_RENAME_VARIANT"] ?? ""
        for (orientation, size, name) in [(UIDeviceOrientation.portrait, "UICTContentSizeCategoryL", "portrait-L"),
                                          (.landscapeLeft, "UICTContentSizeCategoryL", "landscape-L"),
                                          (.portrait, "UICTContentSizeCategoryAccessibilityXXXL", "portrait-AX5"),
                                          (.landscapeLeft, "UICTContentSizeCategoryAccessibilityXXXL", "landscape-AX5")]
            where only.isEmpty || only == name {
            let tag = "\(appearance)-\(name)"
            let app = launch(["-ArtemisNoAnimations", "YES"], size: size)
            XCUIDevice.shared.orientation = orientation
            let workstation = app.buttons["computer.WORKSTATION"]
            let rename = openMenu(workstation, item: "Rename…", in: app)
            XCTAssertTrue(rename.exists, "\(tag): no Rename…")
            XCTAssertTrue(menuItem(app, "Get Info").exists, "\(tag): no Get Info")
            XCTAssertTrue(menuItem(app, "Test Network…").exists, "\(tag): no Test Network…")
            shot("\(tag)-parity-1-pc-menu")
            rename.tap()
            self.rename(to: "Office PC", in: app, tag)
            let office = app.buttons["computer.Office PC"]
            XCTAssertTrue(office.waitForExistence(timeout: 5), "\(tag): the PC wasn't renamed")

            let info = openMenu(office, item: "Get Info", in: app)
            XCTAssertTrue(info.exists, "\(tag): no Get Info")
            info.tap()
            XCTAssertTrue(app.buttons["info.done"].waitForExistence(timeout: 5), "\(tag): Get Info didn't open")
            sleep(1)
            shot("\(tag)-parity-3-get-info")
            for text in ["PC's own name", "WORKSTATION", "02:00:5e:12:34:56", "Paired", "47984", "127.0.0.1"] {
                let value = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
                XCTAssertTrue(reveal(value, in: app), "\(tag): Get Info has no \(text)")
            }
            app.buttons["info.done"].tap()

            // Back to the PC's own name
            openMenu(office, item: "Rename…", in: app).tap()
            self.rename(to: "", in: app, tag)
            XCTAssertTrue(workstation.waitForExistence(timeout: 5), "\(tag): the empty name didn't restore WORKSTATION")
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Connect Automatically When Opening PC: opening the PC connects to that app; View All
    /// Apps, Including Hidden doesn't.
    func testConnectAutomatically() {
        let tag = "\(appearance)-portrait-L"
        let app = launch()
        let workstation = app.buttons["computer.WORKSTATION"]
        workstation.tap()
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10))
        let toggle = openMenu(desktopApp, item: "Connect Automatically When Opening PC", in: app)
        XCTAssertTrue(toggle.exists, "no Connect Automatically")
        XCTAssertTrue(menuItem(app, "Stop").exists, "no Stop in the active app's menu")
        shot("\(tag)-parity-4-app-menu")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["game.directLaunch"].waitForExistence(timeout: 5), "no Connects automatically note")
        sleep(1)
        shot("\(tag)-parity-5-connects-automatically")
        app.navigationBars.buttons.firstMatch.tap()

        workstation.tap()
        XCTAssertTrue(app.otherElements["desktop"].waitForExistence(timeout: 10), "opening the PC didn't connect")
        disconnect(app)
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10), "didn't return to the apps")
        app.navigationBars.buttons.firstMatch.tap()

        openMenu(workstation, item: "View All Apps, Including Hidden", in: app).tap()
        XCTAssertTrue(app.buttons["game.Old Virtual Display"].waitForExistence(timeout: 10), "hidden apps don't show")
        sleep(2)
        XCTAssertFalse(app.otherElements["desktop"].exists, "View All Apps connected by itself")
        app.terminate()
    }

    /// Settings › Host PC › Stop the app on the PC after a session.
    func testEndAppAfterSession() {
        let app = launch(["-ArtemisQuitAppAfterSession", "YES"])
        app.buttons["computer.WORKSTATION"].tap()
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["game.running"].exists, "Desktop isn't active to begin with")
        desktopApp.tap()
        XCTAssertTrue(app.otherElements["desktop"].waitForExistence(timeout: 10))
        disconnect(app)
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10), "didn't return to the apps")
        let ended = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ended, object: app.descendants(matching: .any)["game.running"])], timeout: 10),
                       .completed, "the app is still active after disconnecting")
        app.terminate()
    }

    /// The new and changed Settings pages.
    func testSettingsPages() {
        for (orientation, size, name) in [(UIDeviceOrientation.portrait, "UICTContentSizeCategoryL", "portrait-L"),
                                          (.landscapeLeft, "UICTContentSizeCategoryL", "landscape-L"),
                                          (.portrait, "UICTContentSizeCategoryAccessibilityXXXL", "portrait-AX5")] {
            let tag = "\(appearance)-\(name)"
            let app = launch(size: size)
            XCUIDevice.shared.orientation = orientation
            app.buttons["computers.settings"].tap()
            XCTAssertTrue(app.buttons["settings.video"].waitForExistence(timeout: 5))
            for (section, element) in [("audio", "settings.microphone"), ("keyboard", ""),
                                       ("controllers", "settings.gamepadMouse"), ("host", "settings.quitAfterSession")] {
                let row = app.buttons["settings.\(section)"]
                XCTAssertTrue(reveal(row, in: app), "\(tag): no \(section) section")
                row.tap()
                if !element.isEmpty {
                    XCTAssertTrue(reveal(app.switches[element], in: app), "\(tag): no \(element)")
                }
                sleep(1)
                shot("\(tag)-parity-6-settings-\(section)")
                app.navigationBars.buttons.firstMatch.tap()
                sleep(1)
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Settings › General shows Artemis's own version (1.0, not upstream Moonlight's 9.0.2)
    /// and the build number, and the GPL notice with the Moonlight credit and the source link.
    func testVersionRow() {
        let app = launch()
        app.buttons["computers.settings"].tap()
        let general = app.buttons["settings.general"]
        XCTAssertTrue(reveal(general, in: app), "no General section")
        general.tap()
        let row = app.descendants(matching: .any)["settings.version"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no Version row")
        let text = [row.label, row.value as? String ?? ""].joined(separator: " ")
        XCTAssertNotNil(text.range(of: #"1\.0 \(\d+\)"#, options: .regularExpression), "Version reads \(text)")
        XCTAssertFalse(text.contains("9.0"), "still upstream's version: \(text)")
        XCTAssertTrue(app.descendants(matching: .any)["settings.sourceCode"].firstMatch.exists, "no Source Code link")
        let license = app.descendants(matching: .any)["settings.license"].firstMatch
        XCTAssertTrue(license.exists, "no license notice")
        XCTAssertTrue(license.label.contains("GNU General Public License") && license.label.contains("Moonlight"), "notice: \(license.label)")
        shot("\(appearance)-portrait-L-version")
        app.terminate()
    }

    // MARK: Crashes

    /// A reported crash (build 1267): long-pressing Apollo's own apps (Steam Big Picture, Virtual
    /// Display), whose artwork arrives while the menu is open. The menu's artwork preview is
    /// drawn outside the list and lost the store when it re-rendered.
    func testLongPressAppsWhileArtworkArrives() {
        let app = launch()
        app.buttons["computer.WORKSTATION"].tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10))
        for name in ["Steam Big Picture", "Virtual Display", "Desktop"] {
            let row = app.buttons["game.\(name)"]
            XCTAssertTrue(reveal(row, in: app), "no \(name)")
            let connect = openMenu(row, item: name == "Desktop" ? "Resume" : "Connect", in: app)
            XCTAssertTrue(connect.exists, "\(name): no menu")
            // Artwork keeps arriving for a few seconds with the menu (and its preview) open
            sleep(4)
            XCTAssertEqual(app.state, .runningForeground, "\(name): the app crashed with the menu open")
            shot("\(appearance)-portrait-L-crash-menu-\(name)")
            // Close the menu
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            sleep(1)
            XCTAssertEqual(app.state, .runningForeground, "\(name): the app crashed closing the menu")
        }
        app.terminate()
    }

    /// A fresh install: there are no saved settings yet when the app moves the default to Native
    /// (before it has made its ID). The move sticks, and it's still Native after a relaunch.
    func testNativeResolutionFreshInstall() {
        let app = launch(["-ArtemisTestSettingsState", "fresh"])
        assertNative(app, "fresh install")
        app.terminate()
        assertNative(launch(), "fresh install, relaunched")
    }

    /// A phone where the move was marked done but didn't stick (builds up to 1273 on a fresh
    /// install: the settings stayed at 720p): it moves to Native now, and stays there.
    func testNativeResolutionAfterFailedSwitch() {
        let app = launch(["-ArtemisTestSettingsState", "failedSwitch"])
        assertNative(app, "after the failed switch")
        app.terminate()
        assertNative(launch(), "after the failed switch, relaunched")
    }

    private func assertNative(_ app: XCUIApplication, _ tag: String) {
        app.buttons["computers.settings"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sessions use Native at")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5),
                      "\(tag): not Native: \(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sessions use'")).firstMatch.label)")
        app.terminate()
    }

    /// Sessions default to the iPhone's own resolution: settings still at upstream's 1280 × 720
    /// move to Native once.
    func testNativeResolutionDefault() {
        let app = launch(["-ArtemisTestOldDefaultResolution", "YES"])
        app.buttons["computers.settings"].tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sessions use Native at")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "not Native: \(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sessions use'")).firstMatch.label)")
        app.buttons["settings.video"].tap()
        let picker = app.buttons["settings.resolution"].exists ? app.buttons["settings.resolution"] : app.otherElements["settings.resolution"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let text = "\(picker.label) \(picker.value as? String ?? "")"
        XCTAssertTrue(text.contains("Native") && !text.contains("Excluding"), "resolution picker: \(text)")
        sleep(1)
        shot("\(appearance)-portrait-L-native-resolution")
        app.terminate()
    }

    /// An active app's row: a green dot after the name (no Active badge), Resume and Stop on the
    /// line under the name, and the row no taller than an inactive one, upright and in landscape.
    func testActiveRowIsCompact() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let name = orientation == .portrait ? "portrait" : "landscape"
            let tag = "\(appearance)-\(name)"
            let app = launch()
            XCUIDevice.shared.orientation = orientation
            app.buttons["computer.WORKSTATION"].tap()
            let active = app.buttons["game.Desktop"]
            let inactive = app.buttons["game.File Explorer"]
            XCTAssertTrue(active.waitForExistence(timeout: 10) && inactive.waitForExistence(timeout: 5), "\(tag): the apps didn't open")
            sleep(1)

            // The dot: small, right after the name, on its line; it reads as Active
            let dot = app.descendants(matching: .any)["game.running"]
            XCTAssertTrue(dot.exists, "\(tag): no active dot")
            XCTAssertEqual(dot.label, "Active", "\(tag): the dot's label")
            let title = active.staticTexts["Desktop"]
            XCTAssertTrue(title.exists, "\(tag): no name")
            XCTAssertLessThanOrEqual(dot.frame.width, 14, "\(tag): the dot is \(dot.frame) (a badge?)")
            XCTAssertLessThanOrEqual(dot.frame.height, 14, "\(tag): the dot is \(dot.frame) (a badge?)")
            XCTAssertGreaterThanOrEqual(dot.frame.minX, title.frame.maxX, "\(tag): the dot \(dot.frame) isn't after the name \(title.frame)")
            XCTAssertLessThan(dot.frame.minX - title.frame.maxX, 12, "\(tag): the dot \(dot.frame) is far from the name \(title.frame)")
            XCTAssertTrue(dot.frame.midY > title.frame.minY && dot.frame.midY < title.frame.maxY,
                          "\(tag): the dot \(dot.frame) isn't on the name's line \(title.frame)")
            let actives = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Active")).allElementsBoundByIndex
            XCTAssertTrue(actives.allSatisfy { $0.frame.width <= 14 }, "\(tag): an Active badge shows (\(actives.map(\.frame)))")

            // Resume and Stop: under the name, beside the artwork, inside the row
            let resume = app.buttons["game.resume"], stop = app.buttons["game.end"]
            XCTAssertTrue(resume.exists && stop.exists, "\(tag): no Resume / Stop")
            for button in [resume, stop] {
                XCTAssertTrue(button.isHittable, "\(tag): \(button.identifier) isn't hittable")
                XCTAssertGreaterThanOrEqual(button.frame.minY, title.frame.maxY - 1, "\(tag): \(button.identifier) \(button.frame) isn't under the name \(title.frame)")
                XCTAssertGreaterThanOrEqual(button.frame.minX, title.frame.minX - 1, "\(tag): \(button.identifier) \(button.frame) isn't beside the artwork")
            }
            XCTAssertEqual(resume.frame.midY, stop.frame.midY, accuracy: 1, "\(tag): Resume and Stop aren't on one line")

            // The same height as an inactive row (the list cells holding each name)
            let cells = app.cells.allElementsBoundByIndex.map(\.frame)
            func cell(_ name: String) -> CGRect {
                let text = app.staticTexts[name].frame
                return cells.first { $0.contains(CGPoint(x: text.midX, y: text.midY)) } ?? .zero
            }
            let activeCell = cell("Desktop"), inactiveCell = cell("File Explorer")
            XCTAssertFalse(activeCell.isEmpty || inactiveCell.isEmpty, "\(tag): no cells (\(cells))")
            XCTAssertEqual(activeCell.height, inactiveCell.height, accuracy: 0.5,
                           "\(tag): the active row is \(activeCell.height), an inactive one \(inactiveCell.height)")
            for button in [resume, stop] {
                XCTAssertLessThanOrEqual(button.frame.maxY, activeCell.maxY, "\(tag): \(button.identifier) \(button.frame) hangs out of the cell \(activeCell)")
            }
            print("ACTIVE-ROW \(tag): cell \(activeCell.height) vs \(inactiveCell.height), name \(title.frame), dot \(dot.frame), resume \(resume.frame), stop \(stop.frame)")
            shot("\(tag)-L-active-row")

            // Resume still opens the session
            resume.tap()
            XCTAssertTrue(app.otherElements["desktop"].waitForExistence(timeout: 10), "\(tag): Resume didn't connect")
            app.terminate()
        }
    }
}
