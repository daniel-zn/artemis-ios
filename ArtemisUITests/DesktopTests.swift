//
//  DesktopTests.swift
//  ArtemisUITests
//
//  The remote desktop's touch controls (docs/TOUCH.md) against the demo desktop
//  (-ArtemisDemo YES), which records the input events the gestures produce in the desktop's
//  accessibility value. Each gesture is checked for its events, upright and in landscape,
//  with screenshots of the connected screen, the control bar, the key row and the zoom.
//

import XCTest

final class DesktopTests: XCTestCase {
    private var appearance: String {
        ProcessInfo.processInfo.environment["ARTEMIS_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "system"
    }

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    func testGesturesUpright() { gestures(orientation: .portrait, name: "portrait") }
    func testGesturesLandscape() { gestures(orientation: .landscapeLeft, name: "landscape") }
    func testLargeTextUpright() { largeText(orientation: .portrait, name: "portrait") }
    func testLargeTextLandscape() { largeText(orientation: .landscapeLeft, name: "landscape") }

    /// Two-finger scrolling with Natural on: fingers up = wheel up (positive), fingers left =
    /// wheel left (negative), which on the PC moves the content with the fingers (reported from
    /// a real phone; the Mac-trackpad convention, the other sign, scrolled backwards there). Momentum
    /// carries on the same way after a flick. Upright on the trackpad area, in landscape on the
    /// desktop. Reversed reverses it.
    func testScrollDirectionFollowsFingers() {
        for natural in [true, false] {
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                scrollDirection(orientation: orientation, natural: natural)
            }
        }
    }

    /// Trackpad: one finger resting, another dragging = a click and drag (move a window): the
    /// left button goes down as the second finger moves, the pointer follows it, and the button
    /// comes up when the resting finger lifts, after the moving one. Upright on the trackpad
    /// area, in landscape on the desktop.
    func testHoldAndDragWithSecondFinger() {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let tag = orientation == .portrait ? "portrait trackpad" : "landscape desktop"
            let (app, desktop) = connect(orientation: orientation)
            let area = orientation == .portrait ? app.otherElements["trackpad"].frame : videoFrame(desktop)
            XCTAssertFalse(area.isEmpty, "\(tag): no surface")
            let count = state(desktop).count
            // The resting finger: down 1.4 s; the other lands 0.3 s later, rests 0.1 s, moves 0.6 s, lifts
            let rest = CGPoint(x: area.minX + area.width * 0.2, y: area.midY)
            let mover = CGPoint(x: area.midX - 40, y: area.midY)
            XCTAssertTrue(MultiTouch.timed([(rest, .zero, 0, 1.4, 0),
                                            (mover, CGVector(dx: min(120, area.width * 0.35), dy: 0), 0.3, 0.6, 0.1)], testCase: self),
                          "\(tag): couldn't synthesize two fingers")
            let deadline = Date().addingTimeInterval(5)
            var new = events(desktop, since: count)
            while !new.contains("up left") && Date() < deadline {
                usleep(200_000)
                new = events(desktop, since: count)
            }
            let buttons = new.filter { $0.hasPrefix("down") || $0.hasPrefix("up") }
            XCTAssertEqual(buttons, ["down left", "up left"], "\(tag): \(new) (\(state(desktop).status))")
            if let down = new.firstIndex(of: "down left"), let up = new.lastIndex(of: "up left"), down < up {
                let held = moves(Array(new[down..<up]))
                XCTAssertGreaterThan(held.count, 2, "\(tag): no moves while held (\(new))")
                if let first = held.first, let last = held.last {
                    XCTAssertGreaterThan(last.0, first.0, "\(tag): the pointer didn't follow the finger right (\(held))")
                }
                XCTAssertTrue(moves(Array(new[..<down])).isEmpty, "\(tag): moved before the button went down (\(new))")
            }
            XCTAssertFalse(new.contains { $0.hasPrefix("scroll") || $0.hasSuffix("right") }, "\(tag): scrolled or right-clicked (\(new))")
            app.terminate()
        }
    }

    /// A phone with Reversed stored from before moves to Natural once; choosing Reversed in
    /// Settings › Touch & Pointer › Scroll direction afterwards stays across launches.
    func testScrollDirectionMovesToNaturalOnce() {
        // Reversed stored, not yet moved: it scrolls the Mac's way
        scrollDirection(orientation: .portrait, natural: true, extra: ["-ArtemisTestReversedScrolling", "YES"], quick: true)

        // Choose Reversed in Settings
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["computers.settings"].waitForExistence(timeout: 15))
        app.buttons["computers.settings"].tap()
        XCTAssertTrue(app.buttons["settings.touch"].waitForExistence(timeout: 5))
        app.buttons["settings.touch"].tap()
        let picker = app.buttons["settings.scrollDirection"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no Scroll direction")
        XCTAssertTrue(picker.label.contains("Scroll direction"), "picker: \(picker.label)")
        XCTAssertTrue("\(picker.label) \(picker.value as? String ?? "")".contains("Natural"), "not Natural after the move: \(picker.label) \(picker.value ?? "")")
        sleep(1)
        shot("\(appearance)-portrait-L-scroll-direction")
        picker.tap()
        let reversed = app.buttons["Reversed"].firstMatch
        XCTAssertTrue(reversed.waitForExistence(timeout: 5), "no Reversed choice")
        reversed.tap()
        sleep(1)
        XCTAssertTrue("\(picker.label) \(picker.value as? String ?? "")".contains("Reversed"), "didn't choose Reversed: \(picker.label)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reversed:")).firstMatch.exists, "no Reversed footer")
        app.terminate()

        // A later launch keeps Reversed (the move happens once)
        scrollDirection(orientation: .portrait, natural: false, extra: [], quick: true)

        // Back to Natural for the other tests (the test hook stores Reversed and moves again)
        let reset = XCUIApplication()
        reset.launchArguments = ["-ArtemisDemo", "YES", "-ArtemisTestReversedScrolling", "YES"]
        reset.launch()
        XCTAssertTrue(reset.buttons["computers.settings"].waitForExistence(timeout: 15))
        reset.terminate()
    }

    private func scrollDirection(orientation: UIDeviceOrientation, natural: Bool, extra: [String]? = nil, quick: Bool = false) {
        let tag = "\(orientation == .portrait ? "portrait trackpad" : "landscape desktop"), natural \(natural ? "on" : "off")"
        let (app, desktop) = connect(orientation: orientation, extra: extra ?? (natural ? [] : ["-ArtemisNaturalScrolling", "NO"]))
        let area = orientation == .portrait ? app.otherElements["trackpad"].frame : videoFrame(desktop)
        XCTAssertFalse(area.isEmpty, "\(tag): no surface")
        let sign = natural ? -1 : 1
        func scrolls(_ new: [String]) -> [(Int, Int)] {
            new.filter { $0.hasPrefix("scroll") }.compactMap { event in
                let parts = event.split(separator: " ")
                guard parts.count == 3, let v = Int(parts[1]), let h = Int(parts[2]) else { return nil }
                return (v, h)
            }
        }
        func twoFingers(by delta: CGVector, duration: TimeInterval) -> [(Int, Int)] {
            let count = state(desktop).count
            XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: area.midX - 25 - delta.dx / 2, y: area.midY - delta.dy / 2),
                                                    CGPoint(x: area.midX + 25 - delta.dx / 2, y: area.midY - delta.dy / 2)],
                                          by: delta, duration: duration, testCase: self), "\(tag): couldn't synthesize two fingers")
            sleep(2)
            let new = events(desktop, since: count)
            XCTAssertTrue(moves(new).isEmpty, "\(tag): scrolling moved the pointer (\(new))")
            return scrolls(new)
        }

        // Fingers up, slowly (Natural): wheel up (positive), nothing sideways
        let up = twoFingers(by: CGVector(dx: 0, dy: -min(100, area.height * 0.6)), duration: 0.8)
        print("SCROLL \(tag) fingers up: \(up.map { "\($0.0) \($0.1)" })")
        XCTAssertFalse(up.isEmpty, "\(tag) fingers up: no scroll")
        XCTAssertLessThan(up.map(\.0).reduce(0, +) * sign, -120, "\(tag) fingers up: \(up)")
        XCTAssertTrue(up.allSatisfy { $0.0 * sign <= 0 && $0.1 == 0 }, "\(tag) fingers up: \(up)")
        if quick {
            app.terminate()
            return
        }

        // Fingers down (Natural): wheel down
        let down = twoFingers(by: CGVector(dx: 0, dy: min(100, area.height * 0.6)), duration: 0.8)
        XCTAssertGreaterThan(down.map(\.0).reduce(0, +) * sign, 120, "\(tag) fingers down: \(down)")

        // Fingers left (Natural): wheel left (negative)
        let left = twoFingers(by: CGVector(dx: -min(140, area.width * 0.5), dy: 0), duration: 0.8)
        print("SCROLL \(tag) fingers left: \(left.map { "\($0.0) \($0.1)" })")
        XCTAssertGreaterThan(left.map(\.1).reduce(0, +) * sign, 120, "\(tag) fingers left: \(left)")
        XCTAssertTrue(left.allSatisfy { $0.1 * sign >= 0 && $0.0 == 0 }, "\(tag) fingers left: \(left)")

        // A flick up: momentum carries on the same way after the fingers lift
        let flickDistance = min(90, area.height * 0.6)
        let flick = twoFingers(by: CGVector(dx: 0, dy: -flickDistance), duration: 0.1)
        print("SCROLL \(tag) flick up: \(flick.map { "\($0.0) \($0.1)" })")
        XCTAssertTrue(flick.allSatisfy { $0.0 * sign <= 0 }, "\(tag) flick: momentum turned around (\(flick))")
        // The fingers alone travel flickDistance (5 units a point): momentum adds to it
        XCTAssertLessThan(flick.map(\.0).reduce(0, +) * sign, -Int(flickDistance * 5) - 120, "\(tag) flick: no momentum (\(flick))")
        app.terminate()
    }

    /// Windows' sign-in screen takes only key events, not Unicode text: a password typed on the
    /// iOS keyboard, or typed from the clipboard, goes as keys (Shift for capitals and "!").
    func testTypedPassword() {
        let tag = "\(appearance)-portrait-L-password"
        // The app puts it on the clipboard (the test runner can't from the background)
        let (app, desktop) = connect(orientation: .portrait, extra: ["-ArtemisDemoClipboard", "Pa55word!"])
        let video = videoFrame(desktop)
        XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: video.midX - 40, y: video.midY), CGPoint(x: video.midX, y: video.midY),
                                                CGPoint(x: video.midX + 40, y: video.midY)], by: .zero, duration: 0.1, testCase: self))
        XCTAssertTrue(app.buttons["key.Esc"].waitForExistence(timeout: 5), "\(tag): the three-finger tap didn't open the keyboard")
        let password = ["key 0x50 +shift", "key 0x41", "key 0x35", "key 0x35", "key 0x57", "key 0x4F", "key 0x52", "key 0x44",
                        "key 0x31 +shift"]

        var count = state(desktop).count
        typeKeys(app, "Pa55word!")
        shot("\(tag)-1-typed")
        XCTAssertEqual(events(desktop, since: count), password, "\(tag) typed")

        // Type Clipboard, from the shortcuts menu (iOS asks before the app reads the clipboard).
        // Upright the bar is at the bottom, under the keyboard: close the keyboard first
        closeKeyboard(app)
        count = state(desktop).count
        app.buttons["bar.shortcuts"].tap()
        let typeClipboard = app.buttons["Type Clipboard"].firstMatch
        XCTAssertTrue(typeClipboard.waitForExistence(timeout: 5), "\(tag): no Type Clipboard")
        typeClipboard.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(1)
        XCTAssertEqual(events(desktop, since: count), password, "\(tag) clipboard")
        app.terminate()
    }

    /// The keyboard lies over the session: the desktop, the trackpad area and the control bar
    /// keep their frames while it's up and after it closes, upright and in landscape.
    func testKeyboardOverlays() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            let tag = "\(appearance)-\(name)-L-keyboard-overlay"
            let (app, desktop) = connect(orientation: orientation)
            sleep(1)
            var watched: [(String, XCUIElement)] = [("desktop", desktop), ("bar.disconnect", app.buttons["bar.disconnect"]),
                                                    ("bar.mode", app.buttons["bar.mode"])]
            if orientation == .portrait {
                watched.append(("trackpad", app.otherElements["trackpad"].firstMatch))
            }
            func frames() -> [String: CGRect] {
                Dictionary(uniqueKeysWithValues: watched.map { ($0.0, $0.1.frame) })
            }
            // System gestures deferred on every edge: a first swipe only shows the system's tab
            let status = (desktop.value as? String ?? "").components(separatedBy: "\n").first ?? ""
            XCTAssertTrue(status.contains("edges all"), "\(tag): \(status)")
            let before = frames()
            for (key, frame) in before {
                XCTAssertFalse(frame.isEmpty, "\(tag): \(key) not on screen")
            }
            shot("\(tag)-1-before")

            app.buttons["bar.keyboard"].tap()
            XCTAssertTrue(app.buttons["key.Esc"].waitForExistence(timeout: 5), "\(tag): the keyboard didn't open")
            sleep(2)
            XCTAssertEqual(frames(), before, "\(tag): the layout changed with the keyboard up")
            shot("\(tag)-2-keyboard")

            // Closed with the key row's hide button (the bar's button may be under the keyboard now)
            closeKeyboard(app)
            let gone = NSPredicate(format: "exists == false")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.buttons["key.Esc"])], timeout: 5),
                           .completed, "\(tag): the keyboard didn't close")
            sleep(2)
            XCTAssertEqual(frames(), before, "\(tag): the layout changed after the keyboard closed")
            shot("\(tag)-3-after")
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    // MARK: Control bar and layout

    /// The bar shows icons only (no captions), upright and in landscape, at the default and the
    /// largest text size: each button still has its name for VoiceOver and a 44-point target.
    func testBarShowsIconsOnly() {
        let names = ["bar.keyboard": "Keyboard", "bar.mode": "Trackpad Mode", "bar.gamepad": "Controller",
                     "bar.shortcuts": "Shortcuts", "bar.disconnect": "Disconnect"]
        for (size, sizeName) in [("UICTContentSizeCategoryL", "L"), ("UICTContentSizeCategoryAccessibilityXXXL", "AX5")] {
            for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
                let tag = "\(appearance)-\(name)-\(sizeName)-bar-icons"
                let (app, _) = connect(size: size, orientation: orientation)
                for (id, label) in names.sorted(by: { $0.key < $1.key }) {
                    let button = app.buttons[id]
                    XCTAssertTrue(button.exists, "\(tag): no \(id)")
                    XCTAssertEqual(button.label, label, "\(tag): \(id)'s name")
                    XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(tag): \(id) narrower than 44 points")
                    XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(tag): \(id) lower than 44 points")
                    let ink = inkUnderIcon(button)
                    XCTAssertLessThan(ink, 0.01, "\(tag): \(id) shows a caption under its icon (\(Int(ink * 100)) % ink)")
                }
                shot("\(tag)-1-bar")
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
        }
    }

    /// The share of a button's bottom fifth that differs strongly from its background: a
    /// caption's strokes (an icon alone sits in the middle and leaves it empty).
    private func inkUnderIcon(_ button: XCUIElement) -> Double {
        let image = button.screenshot().image
        guard let cg = image.cgImage else { return 1 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Rows of the bottom fifth (the bitmap's first rows are the image's top), clear of the sides
        let rows = Int(Double(height) * 0.8)..<height
        let columns = width / 10..<(width - width / 10)
        var luminances: [Double] = []
        for y in rows {
            for x in columns {
                let i = (y * width + x) * 4
                luminances.append(0.2126 * Double(pixels[i]) / 255 + 0.7152 * Double(pixels[i + 1]) / 255 + 0.0722 * Double(pixels[i + 2]) / 255)
            }
        }
        guard !luminances.isEmpty else { return 1 }
        let median = luminances.sorted()[luminances.count / 2]
        return Double(luminances.filter { abs($0 - median) > 0.3 }.count) / Double(luminances.count)
    }

    /// Upright in direct mode there's no trackpad: the desktop sits centred between the top of
    /// the safe area and the bar, a tap lands where the finger is, the keyboard lies over it and
    /// the on-screen controller still takes the trackpad's place. Back in trackpad mode, the
    /// trackpad comes back and the desktop goes back to the top.
    func testDirectModeUprightCentresDesktop() {
        let tag = "\(appearance)-portrait-L-direct-mode"
        let (app, desktop) = connect(orientation: .portrait)
        let trackpad = app.otherElements["trackpad"].firstMatch
        XCTAssertTrue(trackpad.exists, "\(tag): no trackpad to start with")
        // In trackpad mode the desktop starts at the safe area's top
        let safeTop = settledFrame(desktop).minY

        func assertCentred(_ step: String) {
            let frame = settledFrame(desktop), barTop = barFrame(desktop).minY
            let above = frame.minY - safeTop, below = barTop - frame.maxY
            XCTAssertGreaterThan(above, 20, "\(tag) \(step): the desktop isn't moved down (\(frame))")
            XCTAssertEqual(above, below, accuracy: 1, "\(tag) \(step): not centred (\(above) above, \(below) below; \(frame), bar at \(barTop))")
        }

        app.buttons["bar.mode"].tap()
        XCTAssertTrue(state(desktop).status.contains("direct"), "\(tag): \(state(desktop).status)")
        XCTAssertTrue(gone(trackpad), "\(tag): the trackpad is still there in direct mode")
        assertCentred("direct")
        shot("\(tag)-1-centred")

        // A tap lands on the desktop where the finger is
        let video = videoFrame(desktop)
        var count = state(desktop).count
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: video.minX + video.width * 0.25, dy: video.minY + video.height * 0.75)).tap()
        sleep(1)
        var new = events(desktop, since: count)
        if let landing = moves(new).last {
            XCTAssertEqual(Double(landing.0), 480, accuracy: 20, "\(tag) tap x: \(new)")
            XCTAssertEqual(Double(landing.1), 810, accuracy: 20, "\(tag) tap y: \(new)")
        } else {
            XCTFail("\(tag) tap: no move (\(new))")
        }
        XCTAssertEqual(new.filter { $0.hasSuffix("left") }, ["down left", "up left"], "\(tag) tap: \(new)")

        // The keyboard lies over it: nothing moves
        let centred = desktop.frame
        openKeyboard(app, tag: tag)
        XCTAssertEqual(desktop.frame, centred, "\(tag): the desktop moved with the keyboard up")
        closeKeyboard(app)
        sleep(1)
        XCTAssertEqual(desktop.frame, centred, "\(tag): the desktop moved after the keyboard closed")

        // The on-screen controller takes the trackpad's place under the desktop, then gives it back
        app.buttons["bar.gamepad"].tap()
        let padA = app.buttons["pad.A"].firstMatch
        XCTAssertTrue(padA.waitForExistence(timeout: 5), "\(tag): no controller")
        XCTAssertEqual(settledFrame(desktop).minY, safeTop, accuracy: 1, "\(tag): the desktop isn't at the top with the controller")
        XCTAssertGreaterThan(padA.frame.minY, desktop.frame.maxY, "\(tag): the controller isn't under the desktop")
        count = state(desktop).count
        padA.press(forDuration: 0.2)
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertTrue(new.contains { $0.hasPrefix("gamepad 0x1000") }, "\(tag) controller A: \(new)")
        XCTAssertFalse(trackpad.exists, "\(tag): a trackpad with the controller in direct mode")
        shot("\(tag)-2-controller")
        app.buttons["bar.gamepad"].tap()
        XCTAssertTrue(gone(padA), "\(tag): the controller didn't hide")
        XCTAssertFalse(trackpad.exists, "\(tag): the trackpad came back in direct mode")
        assertCentred("controller hidden")

        // Trackpad mode again: the trackpad comes back under the desktop at the top
        app.buttons["bar.mode"].tap()
        XCTAssertTrue(state(desktop).status.contains("trackpad"), "\(tag): \(state(desktop).status)")
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3), "\(tag): the trackpad didn't come back")
        XCTAssertEqual(settledFrame(desktop).minY, safeTop, accuracy: 1, "\(tag): the desktop didn't go back to the top")
        XCTAssertGreaterThan(trackpad.frame.minY, desktop.frame.maxY - 1, "\(tag): the trackpad isn't under the desktop")
        shot("\(tag)-3-trackpad")
        app.terminate()
    }

    /// Upright, switching modes moves the desktop down to the centre and back while the trackpad
    /// fades: the desktop goes in front of the trackpad both ways, never behind it.
    func testModeSwitchMovesDesktopInFrontOfTrackpad() {
        let tag = "\(appearance)-portrait-L-mode-switch"
        let (app, desktop) = connect(orientation: .portrait)
        XCTAssertTrue(state(desktop).status.contains("desktop over trackpad yes"), "\(tag) trackpad mode: \(state(desktop).status)")
        app.buttons["bar.mode"].tap()
        // Mid-move (the spring takes 0.4 s)
        shot("\(tag)-1-to-direct")
        XCTAssertTrue(state(desktop).status.contains("desktop over trackpad yes"), "\(tag) to direct: \(state(desktop).status)")
        _ = settledFrame(desktop)
        app.buttons["bar.mode"].tap()
        shot("\(tag)-2-to-trackpad")
        XCTAssertTrue(state(desktop).status.contains("desktop over trackpad yes"), "\(tag) to trackpad: \(state(desktop).status)")
        // The trackpad still takes its touches: a drag on it moves the pointer
        let trackpad = app.otherElements["trackpad"].firstMatch
        XCTAssertTrue(trackpad.waitForExistence(timeout: 3), "\(tag): no trackpad")
        _ = settledFrame(desktop)
        let count = state(desktop).count
        trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        sleep(1)
        XCTAssertFalse(moves(events(desktop, since: count)).isEmpty, "\(tag): a drag on the trackpad didn't move the pointer")
        app.terminate()

        // In slow motion, a picture of the move: the desktop half way down, in front of the fading trackpad
        let (slow, slowDesktop) = connect(orientation: .portrait, extra: ["-ArtemisDemoSlowMotion", "YES"])
        // (tap() would wait for the move to end)
        let mode = slow.buttons["bar.mode"].frame
        XCTAssertTrue(MultiTouch.timed([(CGPoint(x: mode.midX, y: mode.midY), .zero, 0, 0.05, 0)], testCase: self))
        usleep(800_000)
        shot("\(tag)-3-mid-move-slow-motion")
        XCTAssertTrue(state(slowDesktop).status.contains("desktop over trackpad yes"), "\(tag) slow motion: \(state(slowDesktop).status)")
        slow.terminate()
    }

    /// The upright bar hugs its icons: the same icon size and spacing as the landscape bar,
    /// centred at the bottom, at the default and the largest text size.
    func testUprightBarSpacedLikeLandscape() {
        let ids = ["bar.keyboard", "bar.mode", "bar.gamepad", "bar.shortcuts", "bar.disconnect"]
        for (size, sizeName) in [("UICTContentSizeCategoryL", "L"), ("UICTContentSizeCategoryAccessibilityXXXL", "AX5")] {
            var measured: [String: (widths: [CGFloat], gaps: [CGFloat], bar: CGRect, screen: CGFloat)] = [:]
            for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
                let (app, desktop) = connect(size: size, orientation: orientation)
                let frames = ids.map { app.buttons[$0].frame }.sorted { $0.minX < $1.minX }
                let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
                measured[name] = (frames.map(\.width), gaps, barFrame(desktop), app.windows.firstMatch.frame.width)
                if name == "portrait" { shot("\(appearance)-portrait-\(sizeName)-bar-hugs") }
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
            guard let land = measured["landscape"], let up = measured["portrait"] else { XCTFail("not measured"); continue }
            let tag = "\(appearance)-\(sizeName)-bar-spacing"
            for (a, b) in zip(up.widths, land.widths) {
                XCTAssertEqual(a, b, accuracy: 1, "\(tag): upright icon widths \(up.widths), landscape \(land.widths)")
                XCTAssertGreaterThanOrEqual(a, 44, "\(tag): an icon narrower than 44 points")
            }
            for (a, b) in zip(up.gaps, land.gaps) {
                XCTAssertEqual(a, b, accuracy: 1, "\(tag): upright gaps \(up.gaps), landscape \(land.gaps)")
            }
            XCTAssertLessThan(up.bar.width, land.bar.width, "\(tag): the upright bar (\(up.bar)) is wider than the landscape one (\(land.bar))")
            XCTAssertEqual(up.bar.midX, up.screen / 2, accuracy: 1, "\(tag): the upright bar isn't centred (\(up.bar))")
        }
    }

    /// The bar's frame, as the desktop's state line reports it ("bar frame x y width height").
    private func barFrame(_ desktop: XCUIElement) -> CGRect {
        let status = state(desktop).status
        guard let range = status.range(of: " bar frame ") else { return .null }
        let n = status[range.upperBound...].split(separator: " ").prefix(4).compactMap { Double($0) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .null
    }

    /// Waits (up to 3 s) until the element is gone.
    private func gone(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
                       timeout: 3) == .completed
    }

    /// The hide-keyboard button sits at the right end of the key row on its own glass; the keys
    /// run on under it (no cut-off to its left) and the last one still scrolls fully into view
    /// beside it. A swipe down on the row doesn't close the keyboard; the button does, and
    /// nothing else on screen moves. Upright and in landscape.
    func testHideButtonClosesKeyboard() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            let tag = "\(appearance)-\(name)-L-keyboard-hide"
            let (app, desktop) = connect(orientation: orientation)
            sleep(1)
            var watched: [(String, XCUIElement)] = [("desktop", desktop), ("bar.disconnect", app.buttons["bar.disconnect"]),
                                                    ("bar.mode", app.buttons["bar.mode"])]
            if orientation == .portrait {
                watched.append(("trackpad", app.otherElements["trackpad"].firstMatch))
            }
            func frames() -> [String: CGRect] {
                Dictionary(uniqueKeysWithValues: watched.map { ($0.0, $0.1.frame) })
            }
            let before = frames()
            let count = state(desktop).count
            let gone = NSPredicate(format: "exists == false")
            let window = app.windows.firstMatch.frame

            openKeyboard(app, tag: tag)
            let hide = app.buttons["key.hide"]
            XCTAssertTrue(hide.exists, "\(tag): the row has no hide button")
            let hideFrame = hide.frame
            XCTAssertGreaterThan(hideFrame.maxX, window.maxX - 80, "\(tag): the hide button isn't at the right end (\(hideFrame))")
            let esc = app.buttons["key.Esc"]
            XCTAssertEqual(esc.frame.midY, hideFrame.midY, accuracy: 1, "\(tag): the hide button isn't in the row")

            // The keys run on under the button: one of them reaches under it
            let names = ["page", "Esc", "Tab", "Ctrl", "Alt", "Win", "Shift", "Left", "Up", "Down", "Right", "Del", "Home", "End", "PgUp", "PgDn"]
            func under() -> [String] {
                names.filter { name in
                    let frame = app.buttons["key.\(name)"].frame
                    return frame.maxX > hideFrame.minX + 4 && frame.minX < hideFrame.maxX
                }
            }
            XCTAssertFalse(under().isEmpty, "\(tag): no key reaches under the hide button (keys cut off to its left)")
            shot("\(tag)-1-open")

            // Scrolled to the end, the last key sits whole beside the button, which hasn't moved
            for _ in 0..<4 {
                XCTAssertTrue(MultiTouch.timed([(CGPoint(x: window.midX + 60, y: hideFrame.midY), CGVector(dx: -260, dy: 0), 0, 0.25, 0)], testCase: self))
            }
            let last = settledFrame(app.buttons["key.PgDn"])
            XCTAssertLessThanOrEqual(last.maxX, hideFrame.minX, "\(tag): the last key stays under the button (\(last), button \(hideFrame))")
            XCTAssertGreaterThan(last.maxX, hideFrame.minX - 40, "\(tag): a gap after the last key (\(last), button \(hideFrame))")
            XCTAssertEqual(hide.frame, hideFrame, "\(tag): the hide button moved with the keys")
            shot("\(tag)-2-scrolled-to-end")

            // A swipe down on the row leaves the keyboard up
            let tab = app.buttons["key.Tab"].exists && app.buttons["key.Tab"].isHittable ? app.buttons["key.Tab"] : app.buttons["key.End"]
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 220)))
            XCTAssertTrue(MultiTouch.timed([(CGPoint(x: window.midX, y: hideFrame.midY), CGVector(dx: 0, dy: 90), 0, 0.1, 0)], testCase: self))
            sleep(2)
            XCTAssertTrue(esc.exists, "\(tag): a swipe down on the key row closed the keyboard")
            XCTAssertTrue(state(desktop).status.contains("keyboard on"), "\(tag): \(state(desktop).status)")

            // The button closes it; nothing else moved
            hide.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: esc)], timeout: 5),
                           .completed, "\(tag): the hide button didn't close the keyboard")
            sleep(1)
            XCTAssertTrue(state(desktop).status.contains("keyboard off"), "\(tag): \(state(desktop).status)")
            XCTAssertEqual(frames(), before, "\(tag): the layout changed")
            XCTAssertEqual(events(desktop, since: count), [], "\(tag): input was sent")
            shot("\(tag)-3-closed")

            // Typing still works afterwards
            openKeyboard(app, tag: tag)
            let typed = state(desktop).count
            typeKeys(app, "hi")
            XCTAssertEqual(events(desktop, since: typed), ["key 0x48", "key 0x49"], "\(tag) typing after closing")
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// Fn is the first key in the row and scrolls sideways with the other keys; a finger that
    /// lands on a key and swipes the row along neither presses nor lights up that key.
    func testKeyRowScrolls() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            let tag = "\(appearance)-\(name)-L-key-row"
            let (app, desktop) = connect(orientation: orientation)
            openKeyboard(app, tag: tag)
            let fn = app.buttons["key.page"], esc = app.buttons["key.Esc"], ctrl = app.buttons["key.Ctrl"]
            let fnFrame = fn.frame, escFrame = esc.frame
            let count = state(desktop).count
            let lit = highlights(desktop), grown = keyCount(desktop, "key growths")

            // Swipe the row left, starting on Ctrl, quickly and slowly
            let ctrlFrame = ctrl.frame
            XCTAssertTrue(MultiTouch.timed([(CGPoint(x: ctrlFrame.midX, y: ctrlFrame.midY), CGVector(dx: -220, dy: 0), 0, 0.25, 0)], testCase: self))
            let escScrolled = settledFrame(esc)
            XCTAssertLessThan(escScrolled.minX, escFrame.minX - 50, "\(tag): the row didn't scroll (Esc \(escFrame) → \(escScrolled))")
            // Fn is an ordinary key at the start of the row: it scrolls away with the others
            XCTAssertEqual(fn.frame.minX - fnFrame.minX, escScrolled.minX - escFrame.minX, accuracy: 1,
                           "\(tag): Fn didn't scroll with the keys (Fn \(fnFrame) → \(fn.frame))")
            shot("\(tag)-1-scrolled")
            XCTAssertEqual(events(desktop, since: count), [], "\(tag): scrolling the row sent keys")
            XCTAssertEqual(highlights(desktop), lit, "\(tag): a key lit up while the row scrolled")
            XCTAssertEqual(keyCount(desktop, "key growths"), grown, "\(tag): a key's glass grew while the row scrolled")
            XCTAssertTrue(state(desktop).status.contains("key down none"), "\(tag): \(state(desktop).status)")
            XCTAssertEqual(ctrl.value as? String ?? "", "", "\(tag): Ctrl got pressed by the swipe")

            // Back, slowly this time (twice, to get all the way), starting on whichever key is just
            // right of where Fn was
            for _ in 0..<2 {
                XCTAssertTrue(MultiTouch.timed([(CGPoint(x: fnFrame.maxX + 50, y: fnFrame.midY), CGVector(dx: 240, dy: 0), 0, 0.9, 0)], testCase: self))
            }
            XCTAssertEqual(settledFrame(fn), fnFrame, "\(tag): Fn isn't back at the start of the row")
            XCTAssertEqual(events(desktop, since: count), [], "\(tag): scrolling the row back sent keys")
            XCTAssertEqual(highlights(desktop), lit, "\(tag): a key lit up while the row scrolled back")
            XCTAssertEqual(keyCount(desktop, "key growths"), grown, "\(tag): a key's glass grew while the row scrolled back")
            XCTAssertTrue(state(desktop).status.contains("key down none"), "\(tag): \(state(desktop).status)")

            // A real tap still lights the key up and sends it
            esc.tap()
            sleep(1)
            XCTAssertEqual(events(desktop, since: count), ["key 0x1B"], "\(tag): Esc after scrolling")
            XCTAssertGreaterThan(highlights(desktop), lit, "\(tag): a tap didn't light the key")
            XCTAssertGreaterThan(keyCount(desktop, "key growths"), grown, "\(tag): a tap didn't show the key's press")
            XCTAssertTrue(state(desktop).status.contains("key down none"), "\(tag): \(state(desktop).status)")

            // The function keys scroll the same way, Fn (now Back) going along with them
            fn.tap()
            XCTAssertTrue(app.buttons["key.F1"].waitForExistence(timeout: 3), "\(tag): no function keys")
            let f1 = app.buttons["key.F1"].frame
            XCTAssertTrue(MultiTouch.timed([(CGPoint(x: f1.midX + 120, y: f1.midY), CGVector(dx: -200, dy: 0), 0, 0.3, 0)], testCase: self))
            let f1Scrolled = settledFrame(app.buttons["key.F1"])
            if orientation == .portrait {
                // (In landscape all twelve fit, so there's nothing to scroll)
                XCTAssertLessThan(f1Scrolled.minX, f1.minX - 50, "\(tag): the function keys didn't scroll (F1 \(f1) → \(f1Scrolled))")
            }
            XCTAssertEqual(fn.frame.minX - fnFrame.minX, f1Scrolled.minX - f1.minX, accuracy: 1,
                           "\(tag): Back didn't scroll with the function keys (\(fnFrame) → \(fn.frame))")
            XCTAssertEqual(events(desktop, since: count), ["key 0x1B"], "\(tag): scrolling the function keys sent keys")
            shot("\(tag)-2-function-keys-scrolled")
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    // MARK: Helpers

    /// The element's frame once a scroll has come to rest (unchanged for half a second).
    private func settledFrame(_ element: XCUIElement) -> CGRect {
        var frame = element.frame
        for _ in 0..<12 {
            usleep(500_000)
            let now = element.frame
            if now == frame { break }
            frame = now
        }
        return frame
    }

    private func openKeyboard(_ app: XCUIApplication, tag: String) {
        if !app.buttons["key.Esc"].exists {
            if !app.buttons["bar.keyboard"].exists, app.buttons["bar.unfold"].exists { app.buttons["bar.unfold"].tap() }
            app.buttons["bar.keyboard"].tap()
        }
        XCTAssertTrue(app.buttons["key.Esc"].waitForExistence(timeout: 5), "\(tag): the keyboard didn't open")
        sleep(1)
        // The keyboard's one-time "slide to type" intro, if a fresh Simulator shows it anyway
        let intro = app.buttons["Continue"]
        if intro.exists {
            intro.tap()
            sleep(1)
        }
    }

    /// Closes the keyboard with the key row's hide button.
    private func closeKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["key.hide"]
        guard hide.exists else { return }
        hide.tap()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["key.Esc"])],
                           timeout: 5)
    }

    /// Keys tapped fast, one tap after another: each tap goes out and shows its press, and
    /// nothing of a key (a second title, glass past its edges) is drawn outside it at any frame.
    func testRapidKeyTapsLeaveNoGhost() {
        let tag = "\(appearance)-portrait-L-rapid-keys"
        let (app, desktop) = connect(orientation: .portrait)
        openKeyboard(app, tag: tag)
        let count = state(desktop).count, grown = keyCount(desktop, "key growths")
        for (id, taps) in [("key.Esc", 12), ("key.Tab", 8), ("key.Up", 8)] {
            let f = app.buttons[id].frame
            XCTAssertTrue(MultiTouch.timed((0..<taps).map { (CGPoint(x: f.midX, y: f.midY), .zero, Double($0) * 0.09, 0.04, 0) }, testCase: self))
        }
        shot("\(tag)-1-after-taps")
        sleep(1)
        let sent = events(desktop, since: count)
        XCTAssertEqual(sent.filter { $0 == "key 0x1B" }.count, 12, "\(tag): Esc taps \(sent)")
        XCTAssertEqual(sent.filter { $0 == "key 0x09" }.count, 8, "\(tag): Tab taps \(sent)")
        XCTAssertGreaterThan(keyCount(desktop, "key growths"), grown, "\(tag): the taps showed no press")
        XCTAssertEqual(keyCount(desktop, "key strays"), 0, "\(tag): something of a key was drawn outside it")
        app.terminate()
    }

    /// A count in the desktop's state line ("<label> N").
    private func keyCount(_ desktop: XCUIElement, _ label: String) -> Int {
        let status = state(desktop).status
        guard let range = status.range(of: label + #" ([0-9]+)"#, options: .regularExpression) else { return -1 }
        return Int(status[range].replacingOccurrences(of: label + " ", with: "")) ?? -1
    }

    /// How many times a key in the row has lit up.
    private func highlights(_ desktop: XCUIElement) -> Int {
        let status = state(desktop).status
        guard let range = status.range(of: #"key highlights ([0-9]+)"#, options: .regularExpression) else { return -1 }
        return Int(status[range].replacingOccurrences(of: "key highlights ", with: "")) ?? -1
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

    /// Opens the demo PC's active Desktop app: the connected screen.
    private func connect(size: String = "UICTContentSizeCategoryL", orientation: UIDeviceOrientation, extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", size,
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""] + extra
        app.launch()
        XCUIDevice.shared.orientation = orientation
        let workstation = app.buttons["computer.WORKSTATION"]
        XCTAssertTrue(workstation.waitForExistence(timeout: 15))
        workstation.tap()
        let desktopApp = app.buttons["game.Desktop"]
        XCTAssertTrue(desktopApp.waitForExistence(timeout: 10))
        desktopApp.tap()
        let desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), "the desktop didn't open")
        sleep(1)
        return (app, desktop)
    }

    /// The desktop's state line and its recorded events.
    private func state(_ desktop: XCUIElement) -> (status: String, count: Int, events: [String]) {
        let lines = (desktop.value as? String ?? "").components(separatedBy: "\n")
        let count = lines.dropFirst().first.flatMap { Int($0.replacingOccurrences(of: "events ", with: "")) } ?? 0
        return (lines.first ?? "", count, Array(lines.dropFirst(2)))
    }

    /// The events recorded since `count`.
    private func events(_ desktop: XCUIElement, since count: Int) -> [String] {
        let now = state(desktop)
        let new = now.count - count
        return new <= 0 ? [] : Array(now.events.suffix(min(new, now.events.count)))
    }

    private func zoom(_ desktop: XCUIElement) -> Double {
        let status = state(desktop).status
        guard let range = status.range(of: #"zoom ([0-9.]+)"#, options: .regularExpression) else { return 0 }
        return Double(status[range].replacingOccurrences(of: "zoom ", with: "")) ?? 0
    }

    private func point(_ desktop: XCUIElement, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        desktop.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// The desktop picture's rectangle on screen (the canvas letterboxes it to 16:9).
    private func videoFrame(_ desktop: XCUIElement) -> CGRect {
        let frame = desktop.frame
        var size = CGSize(width: frame.width, height: frame.width * 9 / 16)
        if size.height > frame.height { size = CGSize(width: frame.height * 16 / 9, height: frame.height) }
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func moves(_ events: [String]) -> [(Int, Int)] {
        events.compactMap { event in
            let parts = event.split(separator: " ")
            guard parts.count == 3, parts[0] == "move", let x = Int(parts[1]), let y = Int(parts[2]) else { return nil }
            return (x, y)
        }
    }

    /// Types on the iOS keyboard's keys (the desktop's key capture isn't a text field, so
    /// typeText has no focused element to type into): Shift for a capital, the 123 layer for
    /// digits and punctuation.
    private func typeKeys(_ app: XCUIApplication, _ text: String) {
        let keyboard = app.keyboards.firstMatch
        for character in text {
            let key = keyboard.keys[String(character)]
            if !key.waitForExistence(timeout: 1) {
                if character.isUppercase {
                    keyboard.buttons["shift"].tap()
                } else {
                    // Letters ↔ numbers and punctuation
                    keyboard.keys["more"].tap()
                }
            }
            if key.waitForExistence(timeout: 3) {
                key.tap()
            } else {
                app.typeText(String(character))
            }
        }
    }

    private func disconnectMenuItem(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Disconnect", "bar.disconnect")).firstMatch
    }

    // MARK: Gestures

    private func gestures(orientation: UIDeviceOrientation, name: String) {
        let tag = "\(appearance)-\(name)-L-desktop"
        let (app, desktop) = connect(orientation: orientation)
        XCTAssertTrue(state(desktop).status.contains("trackpad"), "\(tag): doesn't start in trackpad mode (\(state(desktop).status))")
        XCTAssertTrue(app.buttons["bar.keyboard"].exists, "\(tag): no control bar")
        if orientation == .portrait {
            XCTAssertTrue(app.otherElements["trackpad"].exists, "\(tag): no trackpad area upright")
            XCTAssertLessThan(desktop.frame.maxY, app.buttons["bar.keyboard"].frame.minY + 1, "\(tag): the bar covers the desktop")
        }
        shot("\(tag)-1-connected")

        // One finger drag: the pointer moves right, without clicking
        var count = state(desktop).count
        point(desktop, 0.4, 0.5).press(forDuration: 0.05, thenDragTo: point(desktop, 0.7, 0.5))
        var new = events(desktop, since: count)
        let moved = moves(new)
        XCTAssertGreaterThan(moved.count, 2, "\(tag) drag: no pointer moves (\(new))")
        if let first = moved.first, let last = moved.last {
            XCTAssertGreaterThan(last.0, first.0, "\(tag) drag: the pointer didn't move right (\(moved))")
        }
        XCTAssertFalse(new.contains("down left"), "\(tag) drag: it clicked (\(new))")

        // Tap: a left click (the release follows a moment later)
        count = state(desktop).count
        point(desktop, 0.5, 0.5).tap()
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.filter { $0.hasSuffix("left") }, ["down left", "up left"], "\(tag) tap: \(new)")

        // Press and hold, then drag: a left drag
        count = state(desktop).count
        point(desktop, 0.5, 0.5).press(forDuration: 0.9, thenDragTo: point(desktop, 0.3, 0.4))
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.first { $0.hasSuffix("left") }, "down left", "\(tag) hold-drag: \(new)")
        XCTAssertEqual(new.last { $0.hasSuffix("left") }, "up left", "\(tag) hold-drag: \(new)")
        if let down = new.firstIndex(of: "down left"), let up = new.lastIndex(of: "up left") {
            XCTAssertFalse(moves(Array(new[down..<up])).isEmpty, "\(tag) hold-drag: no moves while held (\(new))")
        }

        // Tap, then touch again and drag (moving only after the tap's release would have come):
        // one left drag, the button held from the tap to the end of the drag
        count = state(desktop).count
        let video0 = videoFrame(desktop)
        XCTAssertTrue(MultiTouch.tapThenDrag(at: CGPoint(x: video0.midX, y: video0.midY), by: CGVector(dx: 70, dy: 20),
                                             gap: 0.12, hold: 0.2, testCase: self))
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.filter { $0.hasSuffix("left") }, ["down left", "up left"], "\(tag) tap-drag: \(new)")
        if let down = new.firstIndex(of: "down left"), let up = new.lastIndex(of: "up left") {
            XCTAssertGreaterThan(moves(Array(new[down..<up])).count, 2, "\(tag) tap-drag: no moves while held (\(new))")
        }

        // Press and hold without moving: a right click
        count = state(desktop).count
        point(desktop, 0.5, 0.5).press(forDuration: 0.9)
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.filter { $0.hasSuffix("right") }, ["down right", "up right"], "\(tag) hold: \(new)")

        // Two-finger tap: a right click
        count = state(desktop).count
        let video = videoFrame(desktop)
        XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: video.midX - 30, y: video.midY), CGPoint(x: video.midX + 30, y: video.midY)],
                                      by: .zero, duration: 0.08, testCase: self), "\(tag): couldn't synthesize two fingers")
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.filter { $0.hasSuffix("right") }, ["down right", "up right"], "\(tag) two-finger tap: \(new)")

        // Two-finger drag: scroll (Natural: fingers down = wheel down, negative)
        count = state(desktop).count
        XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: video.midX - 30, y: video.midY - 40), CGPoint(x: video.midX + 30, y: video.midY - 40)],
                                      by: CGVector(dx: 0, dy: 80), duration: 0.5, testCase: self), "\(tag): couldn't synthesize two fingers")
        sleep(2)
        new = events(desktop, since: count)
        let scrolls = new.filter { $0.hasPrefix("scroll") }
        XCTAssertFalse(scrolls.isEmpty, "\(tag) two-finger drag: no scroll (\(new))")
        let vertical = scrolls.compactMap { Int($0.split(separator: " ")[1]) }.reduce(0, +)
        XCTAssertLessThan(vertical, -120, "\(tag) two-finger drag: scrolled \(vertical) (\(scrolls.prefix(5)))")
        XCTAssertTrue(moves(new).isEmpty, "\(tag) two-finger drag moved the pointer (\(new))")

        // Pinch: zooms the view; the bar offers to reset it
        let spread = min(video.width, video.height) * 0.3
        XCTAssertTrue(MultiTouch.paths([(CGPoint(x: video.midX - 20, y: video.midY), CGVector(dx: -spread, dy: 0)),
                                        (CGPoint(x: video.midX + 20, y: video.midY), CGVector(dx: spread, dy: 0))],
                                       duration: 0.6, testCase: self))
        sleep(1)
        XCTAssertGreaterThan(zoom(desktop), 1.3, "\(tag) pinch: \(state(desktop).status)")
        let reset = app.buttons["bar.resetZoom"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3), "\(tag): no reset zoom button")
        shot("\(tag)-2-zoomed")
        // Three-finger drag pans the zoomed view without input
        count = state(desktop).count
        _ = MultiTouch.drag(fingers: [CGPoint(x: video.midX - 40, y: video.midY), CGPoint(x: video.midX, y: video.midY),
                                      CGPoint(x: video.midX + 40, y: video.midY)], by: CGVector(dx: 60, dy: 0), duration: 0.4, testCase: self)
        sleep(1)
        XCTAssertTrue(events(desktop, since: count).isEmpty, "\(tag) three-finger pan sent input (\(events(desktop, since: count)))")
        reset.tap()
        sleep(1)
        XCTAssertEqual(zoom(desktop), 1, accuracy: 0.01, "\(tag) reset zoom: \(state(desktop).status)")

        // Three-finger tap: the keyboard
        XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: video.midX - 40, y: video.midY), CGPoint(x: video.midX, y: video.midY),
                                                CGPoint(x: video.midX + 40, y: video.midY)], by: .zero, duration: 0.1, testCase: self))
        XCTAssertTrue(app.buttons["key.Esc"].waitForExistence(timeout: 5), "\(tag): the three-finger tap didn't open the keyboard")
        XCTAssertTrue(state(desktop).status.contains("keyboard on"), "\(tag): \(state(desktop).status)")

        // The key row: Esc, sticky Ctrl + a typed c, F5, typed text
        count = state(desktop).count
        app.buttons["key.Esc"].tap()
        app.buttons["key.Ctrl"].tap()
        XCTAssertEqual(app.buttons["key.Ctrl"].value as? String, "Held", "\(tag): Ctrl isn't held")
        shot("\(tag)-3-keyboard")
        typeKeys(app, "c")
        typeKeys(app, "hi")
        new = events(desktop, since: count)
        XCTAssertEqual(new, ["key 0x1B", "key 0x43 +ctrl", "key 0x48", "key 0x49"], "\(tag) keys: \(new)")
        XCTAssertEqual(app.buttons["key.Ctrl"].value as? String ?? "", "", "\(tag): Ctrl stayed held")
        // A locked modifier stays for several keys
        app.buttons["key.Shift"].doubleTap()
        XCTAssertEqual(app.buttons["key.Shift"].value as? String, "Locked", "\(tag): Shift didn't lock")
        count = state(desktop).count
        app.buttons["key.Left"].tap()
        app.buttons["key.Left"].tap()
        app.buttons["key.Shift"].tap()
        new = events(desktop, since: count)
        XCTAssertEqual(new, ["key 0x25 +shift", "key 0x25 +shift"], "\(tag) locked shift: \(new)")
        app.buttons["key.page"].tap()
        XCTAssertTrue(app.buttons["key.F5"].waitForExistence(timeout: 3), "\(tag): no function keys")
        count = state(desktop).count
        app.buttons["key.F5"].tap()
        XCTAssertEqual(events(desktop, since: count), ["key 0x74"], "\(tag) F5")
        shot("\(tag)-4-function-keys")
        app.buttons["key.page"].tap()
        closeKeyboard(app)
        sleep(1)
        XCTAssertTrue(state(desktop).status.contains("keyboard off"), "\(tag): the keyboard didn't hide")

        // Shortcuts
        count = state(desktop).count
        app.buttons["bar.shortcuts"].tap()
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "\(tag): no shortcuts menu")
        shot("\(tag)-5-shortcuts")
        copy.tap()
        sleep(1)
        let taskManager = app.buttons["Task Manager"].firstMatch
        // The first tap can land while the menu is still going away
        for _ in 0..<3 where !app.buttons["Windows"].firstMatch.exists {
            app.buttons["bar.shortcuts"].tap()
            _ = app.buttons["Windows"].firstMatch.waitForExistence(timeout: 2)
        }
        app.buttons["Windows"].firstMatch.tap()
        XCTAssertTrue(taskManager.waitForExistence(timeout: 5), "\(tag): no Windows submenu")
        shot("\(tag)-5b-windows-shortcuts")
        taskManager.tap()
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new, ["key 0x43 +ctrl", "key 0x1B +ctrl +shift"], "\(tag) shortcuts: \(new)")

        // Direct mode: a tap clicks where it lands
        app.buttons["bar.mode"].tap()
        XCTAssertTrue(state(desktop).status.contains("direct"), "\(tag): \(state(desktop).status)")
        count = state(desktop).count
        // Upright the desktop moves to the middle (no trackpad in direct mode): measured again
        _ = settledFrame(desktop)
        let directVideo = videoFrame(desktop)
        let target = XCUIApplication().coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: directVideo.minX + directVideo.width * 0.25, dy: directVideo.minY + directVideo.height * 0.75))
        target.tap()
        sleep(1)
        new = events(desktop, since: count)
        if let landing = moves(new).last {
            XCTAssertEqual(Double(landing.0), 480, accuracy: 40, "\(tag) direct tap x: \(new)")
            XCTAssertEqual(Double(landing.1), 810, accuracy: 40, "\(tag) direct tap y: \(new)")
        } else {
            XCTFail("\(tag) direct tap: no move (\(new))")
        }
        XCTAssertEqual(new.filter { $0.hasSuffix("left") }, ["down left", "up left"], "\(tag) direct tap: \(new)")
        app.buttons["bar.mode"].tap()

        // Landscape: the bar folds into a button and back
        if orientation != .portrait {
            app.buttons["bar.fold"].tap()
            XCTAssertTrue(app.buttons["bar.unfold"].waitForExistence(timeout: 3) || app.otherElements["bar.unfold"].exists, "\(tag): no folded bar")
            shot("\(tag)-6-folded")
            let unfold = app.buttons["bar.unfold"].exists ? app.buttons["bar.unfold"] : app.otherElements["bar.unfold"]
            unfold.tap()
            XCTAssertTrue(app.buttons["bar.disconnect"].waitForExistence(timeout: 3), "\(tag): the bar didn't unfold")
        }

        // Disconnect: one tap goes straight back to the apps (no menu with a second Disconnect)
        app.buttons["bar.disconnect"].tap()
        XCTAssertFalse(disconnectMenuItem(app).waitForExistence(timeout: 1), "\(tag): Disconnect opened a menu")
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10), "\(tag): didn't return to the apps")
        app.terminate()
    }

    /// Large text: the bar and the key row still fit.
    private func largeText(orientation: UIDeviceOrientation, name: String) {
        let tag = "\(appearance)-\(name)-AX5-desktop"
        let (app, desktop) = connect(size: "UICTContentSizeCategoryAccessibilityXXXL", orientation: orientation)
        let window = app.windows.firstMatch.frame
        for id in ["bar.keyboard", "bar.mode", "bar.gamepad", "bar.shortcuts", "bar.disconnect"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.exists, "\(tag): no \(id)")
            XCTAssertGreaterThanOrEqual(button.frame.minX, window.minX - 1, "\(tag): \(id) off screen")
            XCTAssertLessThanOrEqual(button.frame.maxX, window.maxX + 1, "\(tag): \(id) off screen")
        }
        shot("\(tag)-1-connected")
        app.buttons["bar.keyboard"].tap()
        XCTAssertTrue(app.buttons["key.Esc"].waitForExistence(timeout: 5), "\(tag): no key row")
        sleep(1)
        shot("\(tag)-2-keyboard")
        XCTAssertTrue(desktop.exists)
        app.terminate()
    }
}

/// Several fingers at once, through XCTest's event synthesizer (the private API that
/// WebDriverAgent uses: XCTest has no public multi-finger drag).
enum MultiTouch {
    static func drag(fingers: [CGPoint], by delta: CGVector, duration: TimeInterval, testCase: XCTestCase) -> Bool {
        paths(fingers.map { ($0, delta) }, duration: duration, testCase: testCase)
    }

    /// Each finger from its start point by its own movement (apart: a pinch).
    static func paths(_ fingers: [(CGPoint, CGVector)], duration: TimeInterval, testCase: XCTestCase) -> Bool {
        timed(fingers.map { ($0.0, $0.1, 0, duration, 0) }, testCase: testCase)
    }

    /// One finger along points, evenly in time, then lifted.
    static func polyline(_ points: [CGPoint], duration: TimeInterval, testCase: XCTestCase) -> Bool {
        guard points.count >= 2 else { return false }
        let leg = duration / Double(points.count - 1)
        // Each leg as a touch of its own would lift in between: one touch, its legs as moves
        return timed([(points[0], .zero, 0, 0, 0)], legs: Array(points.dropFirst()), legDuration: leg, testCase: testCase)
    }

    /// Tap, touch again `gap` seconds later, hold still for `hold`, then drag: one finger, two touches.
    static func tapThenDrag(at point: CGPoint, by delta: CGVector, gap: TimeInterval, hold: TimeInterval, testCase: XCTestCase) -> Bool {
        timed([(point, .zero, 0, 0.05, 0), (point, delta, 0.05 + gap, 0.4, hold)], testCase: testCase)
    }

    /// Touches, each from a point by a movement: down at `start`, still for `hold`, then moving
    /// for `duration` (seconds from the start of the event).
    static func timed(_ touches: [(CGPoint, CGVector, TimeInterval, TimeInterval, TimeInterval)], holdAfter: TimeInterval = 0,
                      legs: [CGPoint] = [], legDuration: TimeInterval = 0, testCase: XCTestCase) -> Bool {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else { return false }
        // The synthesizer takes points in the upright screen's coordinates, while element
        // frames are in the app's (landscape) ones: rotate them
        let window = XCUIApplication().windows.firstMatch.frame
        let short = min(window.width, window.height), long = max(window.width, window.height)
        let deviceOrientation = XCUIDevice.shared.orientation
        func upright(_ point: CGPoint) -> CGPoint {
            switch deviceOrientation {
            case .landscapeLeft: CGPoint(x: short - point.y, y: point.x)
            case .landscapeRight: CGPoint(x: point.y, y: long - point.x)
            default: point
            }
        }
        func upright(_ vector: CGVector) -> CGVector {
            let a = upright(CGPoint.zero), b = upright(CGPoint(x: vector.dx, y: vector.dy))
            return CGVector(dx: b.x - a.x, dy: b.y - a.y)
        }
        let fingers = touches.map { (upright($0.0), upright($0.1), $0.2, $0.3, $0.4) }
        let total = (touches.map { $0.2 + $0.3 + $0.4 }.max() ?? 0) + holdAfter + legDuration * Double(legs.count)
        let orientation = UIInterfaceOrientation.portrait.rawValue

        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        let recordAlloc = recordClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        guard recordAlloc.responds(to: initRecord) else { return false }
        let record = unsafeBitCast(recordAlloc.method(for: initRecord), to: InitRecord.self)(recordAlloc, initRecord, "Artemis multi-touch", orientation)

        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
        let move = NSSelectorFromString("moveToPoint:atOffset:")
        let lift = NSSelectorFromString("liftUpAtOffset:")
        let add = NSSelectorFromString("addPointerEventPath:")
        for (finger, delta, start, duration, hold) in fingers {
            let pathAlloc = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            guard pathAlloc.responds(to: initPath) else { return false }
            let path = unsafeBitCast(pathAlloc.method(for: initPath), to: InitPath.self)(pathAlloc, initPath, finger, start)
            let moveFunction = unsafeBitCast(path.method(for: move), to: Move.self)
            let steps = delta == .zero ? 0 : 12
            for step in stride(from: 1, through: steps, by: 1) {
                let fraction = Double(step) / Double(steps)
                moveFunction(path, move, CGPoint(x: finger.x + delta.dx * fraction, y: finger.y + delta.dy * fraction),
                             start + hold + duration * fraction)
            }
            // Further legs (polyline): from where the finger is, to each point in turn
            var from = CGPoint(x: finger.x + delta.dx, y: finger.y + delta.dy)
            var time = start + hold + duration
            for leg in legs.map(upright) {
                for step in 1...12 {
                    let fraction = Double(step) / 12
                    moveFunction(path, move, CGPoint(x: from.x + (leg.x - from.x) * fraction, y: from.y + (leg.y - from.y) * fraction),
                                 time + legDuration * fraction)
                }
                from = leg
                time += legDuration
            }
            unsafeBitCast(path.method(for: lift), to: Lift.self)(path, lift, time + (legs.isEmpty ? max(duration, 0.05) - duration : 0) + 0.02 + holdAfter)
            _ = record.perform(add, with: path)
        }

        guard let synthesizer = XCUIDevice.shared.perform(NSSelectorFromString("eventSynthesizer"))?.takeUnretainedValue() else { return false }
        typealias Synthesize = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void
        let synthesize = NSSelectorFromString("synthesizeEvent:completion:")
        guard synthesizer.responds(to: synthesize) else { return false }
        let done = testCase.expectation(description: "multi-touch")
        var failure: NSError?
        unsafeBitCast(synthesizer.method(for: synthesize), to: Synthesize.self)(synthesizer, synthesize, record) { _, error in
            failure = error
            done.fulfill()
        }
        testCase.wait(for: [done], timeout: total + 10)
        return failure == nil
    }
}
