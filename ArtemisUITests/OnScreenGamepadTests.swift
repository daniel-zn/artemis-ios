//
//  OnScreenGamepadTests.swift
//  ArtemisUITests
//
//  The connected screen's layout and the on-screen controller (docs/TOUCH.md) against the
//  demo desktop, which records what would go to the PC: "gamepad connect", then each state as
//  "gamepad <buttons> lt <0–255> rt <0–255> ls <x> <y> rs <x> <y>" (sticks −32768…32767, up
//  positive), and "gamepad disconnect".
//

import XCTest

final class OnScreenGamepadTests: XCTestCase {
    private var appearance: String {
        ProcessInfo.processInfo.environment["ARTEMIS_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "system"
    }

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// Upright: the trackpad has no click buttons and the bar sits under it; system gestures
    /// aren't deferred; the bar has no right click, and its controller button swaps the
    /// trackpad for the gamepad, whose buttons and sticks reach the PC as a controller.
    func testGamepadUpright() {
        let tag = "\(appearance)-portrait-L-gamepad"
        let (app, desktop) = connect(orientation: .portrait)
        XCTAssertTrue(status(desktop).contains("edges all"), "\(tag): system gestures not deferred (\(status(desktop)))")

        let trackpad = app.otherElements["trackpad"].firstMatch
        let bar = app.buttons["bar.keyboard"]
        XCTAssertTrue(trackpad.exists, "\(tag): no trackpad")
        XCTAssertFalse(app.buttons["trackpad.left"].exists, "\(tag): the trackpad still has a left button")
        XCTAssertFalse(app.buttons["trackpad.right"].exists, "\(tag): the trackpad still has a right button")
        XCTAssertFalse(app.buttons["bar.rightClick"].exists, "\(tag): the bar still has a right click")
        XCTAssertGreaterThan(bar.frame.minY, trackpad.frame.maxY, "\(tag): the bar isn't under the trackpad")
        XCTAssertGreaterThan(trackpad.frame.minY, desktop.frame.maxY - 1, "\(tag): the trackpad isn't under the desktop")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(bar.frame.maxY, window.maxY - 140, "\(tag): the bar isn't at the bottom")
        shot("\(tag)-1-trackpad")

        // The controller: in the trackpad's place
        var count = state(desktop).count
        let toggle = app.buttons["bar.gamepad"]
        XCTAssertTrue(toggle.exists, "\(tag): no controller button")
        toggle.tap()
        let a = app.buttons["pad.A"]
        XCTAssertTrue(a.waitForExistence(timeout: 5), "\(tag): no gamepad")
        sleep(1)
        XCTAssertFalse(app.otherElements["trackpad"].firstMatch.exists, "\(tag): the trackpad is still there")
        XCTAssertEqual(events(desktop, since: count).first, "gamepad connect", "\(tag): \(events(desktop, since: count))")
        for id in ["pad.A", "pad.B", "pad.X", "pad.Y", "pad.LB", "pad.RB", "pad.LT", "pad.RT", "pad.Select", "pad.Start",
                   "pad.Guide", "pad.L3", "pad.R3", "pad.dpad", "pad.leftStick", "pad.rightStick"] {
            let element = control(app, id)
            XCTAssertTrue(element.exists, "\(tag): no \(id)")
            XCTAssertGreaterThan(element.frame.minY, desktop.frame.maxY - 1, "\(tag): \(id) over the desktop")
            XCTAssertLessThan(element.frame.maxY, bar.frame.minY + 1, "\(tag): \(id) under the bar")
            XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX, "\(tag): \(id) off screen")
            XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX, "\(tag): \(id) off screen")
        }
        shot("\(tag)-2-shown")
        controls(app, desktop, tag: tag)

        // Off again: the PC's controller goes away, the trackpad comes back
        count = state(desktop).count
        toggle.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["pad.A"].exists, "\(tag): the gamepad didn't hide")
        XCTAssertEqual(events(desktop, since: count).last, "gamepad disconnect", "\(tag): \(events(desktop, since: count))")
        XCTAssertTrue(app.otherElements["trackpad"].firstMatch.waitForExistence(timeout: 3), "\(tag): no trackpad after")
        app.terminate()
    }

    /// Landscape, the controller shown: a stick pushed from its bottom, next to the screen's bottom
    /// edge, reaches the stick, and a fast swipe up from the very bottom edge over it doesn't leave
    /// the app (the edges are deferred: a first swipe only shows the home indicator).
    func testStickNearBottomEdge() {
        let tag = "\(appearance)-landscape-L-gamepad-bottom-edge"
        let (app, desktop) = connect(orientation: .landscapeLeft)
        XCTAssertTrue(status(desktop).contains("edges all"), "\(tag): system gestures not deferred (\(status(desktop)))")
        app.buttons["bar.gamepad"].tap()
        XCTAssertTrue(app.buttons["pad.A"].waitForExistence(timeout: 5), "\(tag): no gamepad")
        sleep(1)
        let window = app.windows.firstMatch.frame
        for (id, label) in [("pad.leftStick", "ls"), ("pad.rightStick", "rs")] {
            let stick = control(app, id).frame
            print("EDGE \(tag) \(id) \(stick) in \(window)")
            // From the stick's bottom (as close to the edge as it goes), up and to the side
            var count = state(desktop).count
            let start = CGPoint(x: stick.midX, y: min(stick.maxY - 4, window.maxY - 4))
            XCTAssertTrue(MultiTouch.drag(fingers: [start], by: CGVector(dx: 40, dy: -40), duration: 0.5, testCase: self))
            sleep(1)
            var new = events(desktop, since: count)
            var values = new.compactMap { stickValue($0, label) }
            XCTAssertTrue(values.contains { $0.x > 8000 }, "\(tag) \(id) from its bottom: \(new)")
            XCTAssertEqual(values.last.map { [$0.x, $0.y] }, [0, 0], "\(tag) \(id) didn't return to the centre: \(new)")

            // From the very bottom edge, fast, as a swipe home would go
            count = state(desktop).count
            XCTAssertTrue(MultiTouch.drag(fingers: [CGPoint(x: stick.midX, y: window.maxY - 1)], by: CGVector(dx: 0, dy: -min(160, window.height * 0.45)),
                                          duration: 0.15, testCase: self))
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "\(tag) \(id): a swipe up from the bottom edge left the app")
            XCTAssertTrue(desktop.exists, "\(tag) \(id): the session is gone after a swipe from the bottom edge")
            new = events(desktop, since: count)
            values = new.compactMap { stickValue($0, label) }
            print("EDGE \(tag) \(id) swipe from the edge: \(new.suffix(6))")
            if app.state != .runningForeground { app.activate() }
        }
        shot("\(tag)")
        app.terminate()
    }

    /// Landscape: the gamepad lies over the desktop; touches away from its controls still
    /// move the pointer, touches on them don't.
    func testGamepadLandscape() {
        let tag = "\(appearance)-landscape-L-gamepad"
        let (app, desktop) = connect(orientation: .landscapeLeft)
        XCTAssertTrue(status(desktop).contains("edges all"), "\(tag): system gestures not deferred (\(status(desktop)))")
        XCTAssertFalse(app.buttons["bar.rightClick"].exists, "\(tag): the bar still has a right click")
        app.buttons["bar.gamepad"].tap()
        XCTAssertTrue(app.buttons["pad.A"].waitForExistence(timeout: 5), "\(tag): no gamepad")
        sleep(1)
        let screen = desktop.frame
        for id in ["pad.A", "pad.LT", "pad.RT", "pad.dpad", "pad.leftStick", "pad.rightStick", "pad.Start", "pad.L3", "pad.R3"] {
            let element = control(app, id)
            XCTAssertTrue(element.exists, "\(tag): no \(id)")
            XCTAssertTrue(screen.contains(element.frame), "\(tag): \(id) not over the desktop (\(element.frame) in \(screen))")
        }
        XCTAssertTrue(app.buttons["bar.keyboard"].isHittable, "\(tag): the bar is covered")
        shot("\(tag)-1-shown")
        controls(app, desktop, tag: tag)

        // The desktop between the controls: still the trackpad
        let count = state(desktop).count
        // Slowly, so a busy machine still delivers several moves
        point(desktop, 0.45, 0.45).press(forDuration: 0.05, thenDragTo: point(desktop, 0.6, 0.45), withVelocity: 150,
                                         thenHoldForDuration: 0.1)
        let new = events(desktop, since: count)
        XCTAssertGreaterThan(new.filter { $0.hasPrefix("move ") }.count, 2, "\(tag): the desktop didn't move the pointer (\(new))")
        XCTAssertFalse(new.contains { $0.hasPrefix("gamepad") }, "\(tag): the desktop drag pressed the gamepad (\(new))")

        // Disconnect with the gamepad up: one tap ends the session
        app.buttons["bar.disconnect"].tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10), "\(tag): one tap on Disconnect didn't return to the apps")
        app.terminate()
    }

    /// Large text: the bar, with the controller button, still fits; the gamepad too.
    func testGamepadLargeText() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            let tag = "\(appearance)-\(name)-AX5-gamepad"
            let (app, _) = connect(size: "UICTContentSizeCategoryAccessibilityXXXL", orientation: orientation)
            let window = app.windows.firstMatch.frame
            app.buttons["bar.gamepad"].tap()
            XCTAssertTrue(app.buttons["pad.A"].waitForExistence(timeout: 5), "\(tag): no gamepad")
            sleep(1)
            for id in ["bar.keyboard", "bar.gamepad", "bar.disconnect", "pad.A", "pad.LT", "pad.RT", "pad.Start", "pad.L3", "pad.R3"] {
                let element = control(app, id)
                XCTAssertTrue(element.exists, "\(tag): no \(id)")
                XCTAssertTrue(window.contains(element.frame), "\(tag): \(id) off screen")
            }
            shot("\(tag)-1-shown")
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// The layout, upright and in landscape at Small, Medium and Large: two columns at the screen's sides
    /// (the left stick over the D-pad, A B X Y over the right stick, each pair on one centre line),
    /// the shoulders above them with the stick clicks outside, Select / Xbox / Start in a row at the
    /// bottom centre.
    func testGamepadLayout() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            for (size, sizeName) in [(0.8, "Small"), (0.9, "Medium"), (1.0, "Large")] {
                let tag = "\(appearance)-\(name)-\(sizeName)-layout"
                let (app, desktop) = connect(orientation: orientation, extra: ["-ArtemisGamepadSize", "\(size)"])
                app.buttons["bar.gamepad"].tap()
                XCTAssertTrue(app.buttons["pad.A"].waitForExistence(timeout: 5), "\(tag): no gamepad")
                sleep(1)
                layout(app, desktop, tag: tag, portrait: orientation == .portrait)
                shot("\(tag)-1-shown")
                app.terminate()
                XCUIDevice.shared.orientation = .portrait
            }
        }
    }

    private func layout(_ app: XCUIApplication, _ desktop: XCUIElement, tag: String, portrait: Bool) {
        let window = app.windows.firstMatch.frame
        func pad(_ id: String) -> CGRect {
            let element = control(app, "pad.\(id)")
            XCTAssertTrue(element.exists, "\(tag): no pad.\(id)")
            return element.exists ? element.frame : .zero
        }
        let leftStick = pad("leftStick"), dpad = pad("dpad"), rightStick = pad("rightStick")
        let a = pad("A"), b = pad("B"), x = pad("X"), y = pad("Y")
        let face = CGRect(x: x.minX, y: y.minY, width: b.maxX - x.minX, height: a.maxY - y.minY)
        let select = pad("Select"), guide = pad("Guide"), start = pad("Start")

        // Labels
        for (id, label) in [("Select", "Select"), ("Start", "Start"), ("L3", "Left Stick Click"), ("R3", "Right Stick Click")] {
            let button = app.buttons["pad.\(id)"]
            XCTAssertEqual(button.exists ? button.label : nil, label, "\(tag): \(id)'s label")
        }

        // Each column on one centre line
        XCTAssertEqual(leftStick.midX, dpad.midX, accuracy: 1, "\(tag): left stick \(leftStick) and D-pad \(dpad) not in line")
        XCTAssertEqual(face.midX, rightStick.midX, accuracy: 1, "\(tag): A B X Y \(face) and right stick \(rightStick) not in line")
        XCTAssertLessThan(leftStick.midY, dpad.midY, "\(tag): the left stick isn't over the D-pad")
        XCTAssertLessThan(face.midY, rightStick.midY, "\(tag): A B X Y aren't over the right stick")
        // The columns mirror each other
        XCTAssertEqual(leftStick.midX - window.minX, window.maxX - rightStick.midX, accuracy: 2, "\(tag): the columns aren't mirrored")

        // At the sides: upright, the trackpad's area (12 pt in); in landscape, the safe area (at most
        // the Dynamic Island's 62 pt, plus a thumb's margin)
        let edge: CGFloat = portrait ? 30 : 100
        let leftEdge = min(leftStick.minX, dpad.minX), rightEdge = max(face.maxX, rightStick.maxX)
        XCTAssertLessThan(leftEdge - window.minX, edge, "\(tag): the left column isn't at the side (\(leftEdge))")
        XCTAssertLessThan(window.maxX - rightEdge, edge, "\(tag): the right column isn't at the side (\(rightEdge))")
        XCTAssertGreaterThanOrEqual(leftEdge, window.minX + 8, "\(tag): the left column touches the edge")
        XCTAssertLessThanOrEqual(rightEdge, window.maxX - 8, "\(tag): the right column touches the edge")

        // Shoulders over the columns, the stick clicks outside them
        let lt = pad("LT"), lb = pad("LB"), rb = pad("RB"), rt = pad("RT"), l3 = pad("L3"), r3 = pad("R3")
        for (shoulder, under, side) in [(lt, leftStick, "LT"), (lb, leftStick, "LB"), (rt, face, "RT"), (rb, face, "RB")] {
            XCTAssertLessThan(shoulder.maxY, under.minY + 1, "\(tag): \(side) isn't above its column")
        }
        XCTAssertLessThan(lt.maxX, lb.minX + 1, "\(tag): LT isn't outside LB")
        XCTAssertGreaterThan(rt.minX, rb.maxX - 1, "\(tag): RT isn't outside RB")
        XCTAssertLessThan(l3.maxX, lt.minX + 1, "\(tag): L3 isn't outside LT")
        XCTAssertGreaterThan(r3.minX, rt.maxX - 1, "\(tag): R3 isn't outside RT")
        XCTAssertEqual(l3.midY, lt.midY, accuracy: 1, "\(tag): L3 isn't level with the shoulders")
        XCTAssertEqual(r3.midY, rt.midY, accuracy: 1, "\(tag): R3 isn't level with the shoulders")

        // Select / Xbox / Start: a row, centred, at the bottom
        XCTAssertEqual(guide.midX, window.midX, accuracy: 1, "\(tag): the Xbox button isn't centred (\(guide))")
        XCTAssertEqual(select.midY, guide.midY, accuracy: 1, "\(tag): Select isn't in the row")
        XCTAssertEqual(start.midY, guide.midY, accuracy: 1, "\(tag): Start isn't in the row")
        XCTAssertEqual(guide.midX - select.midX, start.midX - guide.midX, accuracy: 1, "\(tag): the row isn't centred")
        XCTAssertLessThan(select.maxX, guide.minX, "\(tag): Select isn't left of the Xbox button")
        XCTAssertGreaterThan(start.minX, guide.maxX, "\(tag): Start isn't right of the Xbox button")
        for (other, id) in [(leftStick, "left stick"), (dpad, "D-pad"), (rightStick, "right stick"), (face, "A B X Y"), (lt, "LT")] {
            XCTAssertGreaterThan(guide.midY, other.midY, "\(tag): the row isn't below the \(id)")
        }
        if portrait {
            let bar = app.buttons["bar.keyboard"].frame
            XCTAssertLessThan(guide.maxY, bar.minY, "\(tag): the row is under the bar")
            XCTAssertGreaterThan(guide.maxY, bar.minY - 40, "\(tag): the row isn't at the bottom (\(guide), bar \(bar))")
        } else {
            XCTAssertGreaterThan(guide.maxY, window.maxY - 50, "\(tag): the row isn't at the bottom (\(guide))")
            XCTAssertLessThanOrEqual(guide.maxY, window.maxY - 20, "\(tag): the row is over the home indicator (\(guide))")
        }

        // Every control on its own, inside the safe area (and in landscape over the desktop's
        // picture, not out on the black bars beside it), at least 4 points from every other
        let status = self.status(desktop)
        func numbers(_ key: String) -> [CGFloat] {
            guard let range = status.range(of: key + #" [-0-9. ]+"#, options: .regularExpression) else { return [] }
            return status[range].dropFirst(key.count).split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
        }
        let insets = numbers("safe")  // top left bottom right
        XCTAssertEqual(insets.count, 4, "\(tag): no safe area in \(status)")
        var allowed = insets.count == 4
            ? CGRect(x: window.minX + insets[1], y: window.minY + insets[0], width: window.width - insets[1] - insets[3],
                     height: window.height - insets[0] - insets[2])
            : window
        if !portrait {
            let picture = numbers("picture")
            XCTAssertEqual(picture.count, 4, "\(tag): no picture in \(status)")
            if picture.count == 4 { allowed = allowed.intersection(CGRect(x: picture[0], y: picture[1], width: picture[2], height: picture[3])) }
        }
        let ids = ["leftStick", "dpad", "rightStick", "A", "B", "X", "Y", "Select", "Guide", "Start", "LT", "LB", "RB", "RT", "L3", "R3"]
        let round: Set<String> = ["leftStick", "rightStick", "A", "B", "X", "Y", "Guide", "L3", "R3"]
        let all = ids.map { ($0, pad($0)) }
        /// The gap between two controls' shapes (circles for the round ones), negative if they overlap.
        func gap(_ a: (String, CGRect), _ b: (String, CGRect)) -> CGFloat {
            func rectGap(_ r: CGRect, _ p: CGPoint) -> CGFloat {
                hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
            }
            let (ra, rb) = (round.contains(a.0), round.contains(b.0))
            let ca = CGPoint(x: a.1.midX, y: a.1.midY), cb = CGPoint(x: b.1.midX, y: b.1.midY)
            switch (ra, rb) {
            case (true, true): return hypot(ca.x - cb.x, ca.y - cb.y) - a.1.width / 2 - b.1.width / 2
            case (true, false): return rectGap(b.1, ca) - a.1.width / 2
            case (false, true): return rectGap(a.1, cb) - b.1.width / 2
            case (false, false):
                return max(max(a.1.minX - b.1.maxX, b.1.minX - a.1.maxX), max(a.1.minY - b.1.maxY, b.1.minY - a.1.maxY))
            }
        }
        for (index, control) in all.enumerated() {
            XCTAssertTrue(allowed.insetBy(dx: -0.5, dy: -0.5).contains(control.1),
                          "\(tag): \(control.0) \(control.1) outside the safe area / picture \(allowed)")
            if portrait {
                XCTAssertGreaterThan(control.1.minY, desktop.frame.maxY - 1, "\(tag): \(control.0) over the desktop")
            }
            for other in all.dropFirst(index + 1) {
                XCTAssertGreaterThanOrEqual(gap(control, other), 4, "\(tag): \(control.0) \(control.1) and \(other.0) \(other.1) closer than 4 points")
            }
        }
        if !portrait {
            // The bar, between the shoulders, covers nothing
            let bar = app.buttons["bar.keyboard"]
            XCTAssertTrue(bar.isHittable, "\(tag): the bar is covered")
        }
    }

    // MARK: The folded bar and the apps

    /// The apps have no search field; the folded control bar fades after 5 s untouched, a
    /// touch brings it back, and it fades again after another 5 s.
    func testFoldedBarFades() {
        let tag = "\(appearance)-landscape-folded-bar"
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", ""]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let workstation = app.buttons["computer.WORKSTATION"]
        XCTAssertTrue(workstation.waitForExistence(timeout: 15))
        workstation.tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertEqual(app.searchFields.count, 0, "\(tag): the apps have a search field")
        XCTAssertFalse(app.buttons["Search"].exists, "\(tag): the apps have a search button")
        XCTAssertTrue(app.buttons["More"].exists, "\(tag): no ⋯ menu on the apps")
        shot("\(appearance)-landscape-apps-no-search")
        app.buttons["game.Desktop"].tap()

        XCTAssertTrue(app.buttons["bar.fold"].waitForExistence(timeout: 10), "\(tag): no bar")
        app.buttons["bar.fold"].tap()
        let folded = control(app, "bar.unfold")
        XCTAssertTrue(folded.waitForExistence(timeout: 5), "\(tag): no folded bar")
        XCTAssertEqual(folded.value as? String ?? "", "", "\(tag): faded at once")
        shot("\(tag)-1-glass")
        sleep(7)
        XCTAssertEqual(folded.value as? String, "Faded", "\(tag): didn't fade after 5 s")
        XCTAssertTrue(folded.isHittable, "\(tag): not tappable faded")
        shot("\(tag)-2-faded")
        // A touch (a short drag that doesn't unfold it) brings the glass back, and the drag moves
        // the faded bar at once (not only a second drag after the glass came back)
        let desktop = app.otherElements["desktop"]
        let before = barState(desktop).bar
        let start = folded.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 0)))
        sleep(1)
        XCTAssertEqual(folded.value as? String ?? "", "", "\(tag): a touch didn't bring the glass back")
        let after = barState(desktop).bar
        XCTAssertLessThan(after.midX, before.midX - 80, "\(tag): the faded bar didn't move with the drag (\(before) → \(after))")
        // And VoiceOver finds it where it went
        checkBarAccessibility(desktop, bar: after, "\(tag) moved faded")
        sleep(7)
        XCTAssertEqual(folded.value as? String, "Faded", "\(tag): didn't fade again")
        // Faded, a tap still unfolds the bar
        folded.tap()
        XCTAssertTrue(app.buttons["bar.disconnect"].waitForExistence(timeout: 3), "\(tag): the faded bar didn't unfold")
        app.buttons["bar.fold"].tap()
        XCTAssertTrue(folded.waitForExistence(timeout: 3), "\(tag): didn't fold")
        XCTAssertEqual(folded.value as? String ?? "", "", "\(tag): folded again, it's still faded")
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    /// Landscape, in slow motion: folding the bar shrinks its glass capsule into the round button
    /// and unfolding grows it back out: one piece of glass whose size goes through the sizes in
    /// between, never a capsule and a circle swapped. Also when a tap wakes the faded button and
    /// unfolds it in one go.
    func testBarFoldMorphs() {
        let tag = "\(appearance)-landscape-bar-morph"
        let (app, _) = connect(orientation: .landscapeLeft, extra: ["-ArtemisDemoSlowMotion", "YES", "-ArtemisDemoGlassProbe", "YES"])
        // Every frame of it inside the screen's edges, as the bar
        let inside = app.windows.firstMatch.frame.insetBy(dx: barEdgeMargin - 1, dy: barEdgeMargin - 1)
        let probe = control(app, "demo.glass")
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "\(tag): no glass probe")
        var log: [String] = []
        /// The pieces of glass on the screen now.
        func glass() -> [CGRect] {
            (probe.value as? String ?? "").split(separator: "\n").compactMap { line in
                let n = line.split(separator: " ").compactMap { Double($0) }
                return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
            }
        }
        let capsule = glass()
        XCTAssertEqual(capsule.count, 1, "\(tag): open, the glass is \(capsule)")
        let wide = capsule.first?.width ?? 0
        XCTAssertGreaterThan(wide, 200, "\(tag): open, the glass is \(capsule)")
        func tapNow(_ id: String) {
            // (tap() would wait for the animation to end)
            let frame = control(app, id).frame
            XCTAssertTrue(MultiTouch.timed([(CGPoint(x: frame.midX, y: frame.midY), .zero, 0, 0.05, 0)], testCase: self), "\(tag): no tap")
        }
        /// Follows the glass after a tap until it settles at `width`: the sizes it went through.
        func follow(_ name: String, to width: CGFloat) {
            var widths: [CGFloat] = [], swapped: [CGRect] = []
            var shots = 0
            let start = Date()
            var settled = 0
            while Date().timeIntervalSince(start) < 12 && settled < 5 {
                let now = glass()
                log.append(String(format: "%@ %.2f: ", name, Date().timeIntervalSince(start)) + now.map { "\($0)" }.joined(separator: ", "))
                if now.count == 1, let piece = now.first {
                    widths.append(piece.width)
                    XCTAssertTrue(inside.contains(piece), "\(tag) \(name): the glass at \(piece) goes past the screen's edges \(inside)")
                    settled = abs(piece.width - width) < 1 ? settled + 1 : 0
                    // Mid-way (the glass between the two sizes): pictures for the record
                    if shots < 2, piece.width > 52 + 30, piece.width < wide - 30 {
                        shot("\(tag)-\(name)-mid-\(shots)")
                        shots += 1
                    }
                } else if now.count > 1, swapped.isEmpty {
                    swapped = now
                }
            }
            XCTAssertTrue(swapped.isEmpty, "\(tag) \(name): the glass swapped shapes instead of morphing: \(swapped)")
            let between = widths.filter { $0 > 52 + 10 && $0 < wide - 10 }
            XCTAssertFalse(between.isEmpty, "\(tag) \(name): no glass between the circle and the capsule's sizes, only \(Set(widths).sorted())")
            XCTAssertEqual(widths.last ?? 0, width, accuracy: 1, "\(tag) \(name): the glass settled at \(widths.last ?? 0)")
        }
        tapNow("bar.fold")
        follow("fold", to: 52)
        XCTAssertTrue(control(app, "bar.unfold").waitForExistence(timeout: 3), "\(tag): didn't fold")
        tapNow("bar.unfold")
        follow("unfold", to: wide)
        tapNow("bar.fold")
        follow("fold-again", to: 52)
        // Left alone, it fades; a tap wakes it and unfolds it, still growing out of it
        let folded = control(app, "bar.unfold")
        let deadline = Date().addingTimeInterval(15)
        while folded.value as? String != "Faded" && Date() < deadline { usleep(300_000) }
        XCTAssertEqual(folded.value as? String, "Faded", "\(tag): didn't fade")
        tapNow("bar.unfold")
        follow("wake-unfold", to: wide)
        XCTAssertTrue(app.buttons["bar.disconnect"].waitForExistence(timeout: 3), "\(tag): the faded bar didn't unfold")
        let text = log.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(tag)-glass"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ARTEMIS_SHOT_DIR"], !dir.isEmpty {
            try? text.write(toFile: dir + "/\(tag)-glass.txt", atomically: true, encoding: .utf8)
        }
        app.terminate()
    }

    // MARK: The bar at the edges

    /// The floating bar's margin from the screen's edges (DesktopViewController.barEdgeMargin).
    private let barEdgeMargin: CGFloat = 12

    /// Landscape: the bar goes all the way to each edge of the screen (12 pt in, clear of the
    /// rounded corners) and never past it, unfolded and folded, with the on-screen controller
    /// hidden and shown; beside the camera it stops at the safe area; unfolded next to an edge it
    /// shifts back inside.
    func testBarReachesEveryEdge() {
        let tag = "\(appearance)-landscape-bar-edges"
        let (app, desktop) = connect(orientation: .landscapeLeft)
        for gamepad in [false, true] {
            if gamepad {
                app.buttons["bar.gamepad"].tap()
                sleep(1)
            }
            for folded in [false, true] {
                let name = "\(tag)-\(gamepad ? "controller" : "plain")-\(folded ? "folded" : "open")"
                if folded {
                    app.buttons["bar.fold"].tap()
                    XCTAssertTrue(control(app, "bar.unfold").waitForExistence(timeout: 3), "\(name): didn't fold")
                }
                for edge in ["left", "top", "right", "bottom"] {
                    // The finger lifts on the screen's edge
                    dragBar(app, to: edge, folded: folded, inset: 3)
                    checkBar(desktop, at: [edge], "\(name) \(edge)")
                }
                // Halfway up: the camera's side (the left, the phone turned this way) keeps the bar
                // in the safe area; the other side doesn't
                dragBar(app, to: "middle", folded: folded)
                checkBar(desktop, at: ["right"], "\(name) middle right")
                dragBar(app, to: "left", folded: folded)
                checkBar(desktop, at: ["left"], "\(name) middle left (camera)")
                shot("\(name)-camera-side")
                // In the bottom right corner: both edges at once
                dragBar(app, to: "bottom", folded: folded)
                dragBar(app, to: "right", folded: folded)
                checkBar(desktop, at: ["right", "bottom"], "\(name) corner")
                shot("\(name)-corner")
                if folded {
                    // Unfolded in the corner: the wider bar shifts back inside, still at both edges
                    control(app, "bar.unfold").tap()
                    XCTAssertTrue(app.buttons["bar.fold"].waitForExistence(timeout: 3), "\(name): didn't unfold")
                    sleep(1)
                    checkBar(desktop, at: ["right", "bottom"], "\(name) unfolded in the corner")
                }
            }
        }
        app.terminate()
    }

    /// The bar in the top right corner stays there when the phone turns over to the other
    /// landscape, docks at the bottom upright, and comes back to the corner in landscape. Halfway
    /// up the right side, turning over puts the camera there: the bar moves into the safe area.
    func testBarEdgeAfterRotation() {
        let tag = "\(appearance)-landscape-bar-rotation"
        let (app, desktop) = connect(orientation: .landscapeLeft)
        dragBar(app, to: "right", folded: false)
        dragBar(app, to: "top", folded: false)
        checkBar(desktop, at: ["right", "top"], "\(tag) before")
        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)
        checkBar(desktop, at: ["right", "top"], "\(tag) turned over")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        let upright = barState(desktop)
        XCTAssertEqual(upright.bar.midX, upright.size.width / 2, accuracy: 1, "\(tag): not docked upright \(upright.bar)")
        XCTAssertGreaterThan(upright.bar.maxY, upright.size.height - upright.safe.bottom - 80, "\(tag): not at the bottom upright \(upright.bar)")
        XCTAssertLessThanOrEqual(upright.bar.maxY, upright.size.height - upright.safe.bottom + 0.5, "\(tag): upright \(upright.bar)")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        checkBar(desktop, at: ["right", "top"], "\(tag) back")
        shot("\(tag)-back")
        dragBar(app, to: "middle", folded: false)
        checkBar(desktop, at: ["right"], "\(tag) middle right")
        XCUIDevice.shared.orientation = .landscapeRight
        sleep(2)
        checkBar(desktop, at: ["right"], "\(tag) middle right turned over (camera)")
        shot("\(tag)-camera-side")
        app.terminate()
    }

    /// The screen's size, its safe area and the bar's frame, as the desktop reports them.
    private func barState(_ desktop: XCUIElement) -> (size: CGSize, safe: UIEdgeInsets, bar: CGRect) {
        let text = self.status(desktop)
        func numbers(after label: String, _ count: Int) -> [CGFloat] {
            guard let range = text.range(of: " " + label + " ") else { return [] }
            return text[range.upperBound...].split(separator: " ").prefix(count).compactMap { Double($0) }.map { CGFloat($0) }
        }
        let safe = numbers(after: "safe", 4), bar = numbers(after: "bar frame", 4), size = numbers(after: "screen", 2)
        guard safe.count == 4, bar.count == 4, size.count == 2 else {
            XCTFail("no layout in \(text)")
            return (.zero, .zero, .zero)
        }
        return (CGSize(width: size[0], height: size[1]), UIEdgeInsets(top: safe[0], left: safe[1], bottom: safe[2], right: safe[3]),
                CGRect(x: bar[0], y: bar[1], width: bar[2], height: bar[3]))
    }

    /// Drags the bar (by its grip, or the folded button) as far as the screen goes towards an
    /// edge, or to halfway up ("middle").
    private func dragBar(_ app: XCUIApplication, to edge: String, folded: Bool, inset: CGFloat = 20) {
        let handle = control(app, folded ? "bar.unfold" : "bar.grip")
        XCTAssertTrue(handle.waitForExistence(timeout: 3), "no bar handle")
        let from = center(handle)
        let window = app.windows.firstMatch.frame
        var to = from
        // The finger lifts `inset` from the screen's edge (3: on the edge), past where the bar stops
        switch edge {
        case "left": to.x = window.minX + inset
        case "right": to.x = window.maxX - inset
        case "top": to.y = window.minY + inset
        case "middle": to.y = window.midY
        default: to.y = window.maxY - inset
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: from.x, dy: from.y))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)), withVelocity: 1200, thenHoldForDuration: 0.1)
        sleep(1)
    }

    /// The camera's side in landscape: the left with the phone turned to the left.
    private var cameraSide: String? {
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: return "left"
        case .landscapeRight: return "right"
        default: return nil
        }
    }

    /// Where assistive technologies (and XCUITest) find the bar matches where the app has it:
    /// the folded button is the bar's frame, the open bar's grip lies at its left end. Waits up
    /// to 2 s for them to be told.
    private func checkBarAccessibility(_ desktop: XCUIElement, bar: CGRect, _ tag: String) {
        let app = XCUIApplication()
        let folded = status(desktop).contains("bar folded")
        let element = control(app, folded ? "bar.unfold" : "bar.grip")
        func matches() -> Bool {
            let frame = element.frame
            if folded {
                return abs(frame.minX - bar.minX) <= 1.5 && abs(frame.minY - bar.minY) <= 1.5
                    && abs(frame.width - bar.width) <= 1.5 && abs(frame.height - bar.height) <= 1.5
            }
            return bar.insetBy(dx: -1.5, dy: -1.5).contains(frame) && frame.minX - bar.minX < 20
        }
        let deadline = Date().addingTimeInterval(2)
        while !matches() && Date() < deadline {
            usleep(200_000)
        }
        XCTAssertTrue(matches(), "\(tag): \(folded ? "the folded bar" : "the grip") is at \(element.frame) for assistive technologies, the bar at \(bar)")
    }

    /// The bar on the screen, at least `barEdgeMargin` from each edge and out of the camera's
    /// safe-area inset beside it; and at these edges (within 2 pt): the margin from the screen's
    /// edge, or beside the camera, the safe area's edge.
    private func checkBar(_ desktop: XCUIElement, at edges: [String], _ tag: String) {
        let (size, safe, bar) = barState(desktop)
        checkBarAccessibility(desktop, bar: bar, tag)
        let besideCamera = abs(bar.midY - size.height / 2) < bar.height / 2 + 124
        func limit(_ edge: String) -> CGFloat {
            let inset = edge == "left" ? safe.left : edge == "right" ? safe.right : 0
            return edge == cameraSide && besideCamera ? max(inset, barEdgeMargin) : barEdgeMargin
        }
        let limits = CGRect(x: limit("left"), y: barEdgeMargin, width: size.width - limit("left") - limit("right"),
                            height: size.height - 2 * barEdgeMargin)
        XCTAssertTrue(limits.insetBy(dx: -0.5, dy: -0.5).contains(bar), "\(tag): \(bar) outside \(limits)")
        for edge in edges {
            let gap: CGFloat
            switch edge {
            case "left": gap = bar.minX - limits.minX
            case "right": gap = limits.maxX - bar.maxX
            case "top": gap = bar.minY - limits.minY
            default: gap = limits.maxY - bar.maxY
            }
            XCTAssertLessThanOrEqual(abs(gap), 2, "\(tag): \(gap) pt from the \(edge) edge (bar \(bar), limits \(limits), safe \(safe))")
        }
    }

    // MARK: Controls

    /// A, a trigger, the sticks, the D-pad, and several at once.
    private func controls(_ app: XCUIApplication, _ desktop: XCUIElement, tag: String) {
        // A: down and up, nothing else
        var count = state(desktop).count
        app.buttons["pad.A"].tap()
        sleep(1)
        var new = events(desktop, since: count)
        XCTAssertEqual(new, ["gamepad 0x1000 lt 0 rt 0 ls 0 0 rs 0 0", "gamepad 0x0000 lt 0 rt 0 ls 0 0 rs 0 0"], "\(tag) A: \(new)")

        // The right trigger: fully pulled while held
        count = state(desktop).count
        app.buttons["pad.RT"].press(forDuration: 0.3)
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new, ["gamepad 0x0000 lt 0 rt 255 ls 0 0 rs 0 0", "gamepad 0x0000 lt 0 rt 0 ls 0 0 rs 0 0"], "\(tag) RT: \(new)")

        // Xbox, Start (the Xbox controller's Start / Menu), Select (its Back / View) and the stick clicks
        count = state(desktop).count
        for id in ["Guide", "Start", "Select", "L3", "R3"] {
            app.buttons["pad.\(id)"].tap()
        }
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.filter { !$0.hasPrefix("gamepad 0x0000") },
                       ["0x0400", "0x0010", "0x0020", "0x0040", "0x0080"].map { "gamepad \($0) lt 0 rt 0 ls 0 0 rs 0 0" },
                       "\(tag) Xbox, Start, Select, L3, R3: \(new)")

        // The D-pad's top: up
        count = state(desktop).count
        let dpad = control(app, "pad.dpad")
        dpad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        sleep(1)
        new = events(desktop, since: count)
        XCTAssertEqual(new.first, "gamepad 0x0001 lt 0 rt 0 ls 0 0 rs 0 0", "\(tag) D-pad up: \(new)")
        XCTAssertEqual(new.last, "gamepad 0x0000 lt 0 rt 0 ls 0 0 rs 0 0", "\(tag) D-pad up: \(new)")

        // The left stick pushed right: x up to full, y about 0, back to the centre on release; the
        // right stick pushed up
        for (id, label) in [("pad.leftStick", "ls"), ("pad.rightStick", "rs")] {
            count = state(desktop).count
            let stick = control(app, id)
            let push = id == "pad.leftStick" ? CGVector(dx: 0.5 + 1.2, dy: 0.5) : CGVector(dx: 0.5, dy: 0.5 - 1.2)
            stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: stick.coordinate(withNormalizedOffset: push), withVelocity: 300, thenHoldForDuration: 0.3)
            sleep(1)
            new = events(desktop, since: count)
            let values = new.compactMap { stickValue($0, label) }
            XCTAssertTrue(values.contains { id == "pad.leftStick" ? $0.x > 30000 && abs($0.y) < 3000 : $0.y > 30000 && abs($0.x) < 3000 },
                          "\(tag) \(id): \(new)")
            XCTAssertEqual(values.last.map { [$0.x, $0.y] }, [0, 0], "\(tag) \(id) didn't return to the centre: \(new)")
            XCTAssertFalse(new.contains { $0.hasPrefix("move ") }, "\(tag) \(id) moved the pointer: \(new)")
        }

        // Several at once: A held, the left stick pushed left and the left trigger pulled
        count = state(desktop).count
        let aCenter = center(app.buttons["pad.A"])
        let stickCenter = center(control(app, "pad.leftStick"))
        let ltCenter = center(app.buttons["pad.LT"])
        // The fingers go down and lift together (the synthesizer mixes up fingers that start at
        // different times); the stick's waits, then moves
        XCTAssertTrue(MultiTouch.timed([(aCenter, .zero, 0, 1.0, 0), (ltCenter, .zero, 0, 1.0, 0),
                                        (stickCenter, CGVector(dx: -70, dy: 0), 0, 0.7, 0.3)], testCase: self),
                      "\(tag): couldn't synthesize several fingers")
        sleep(1)
        new = events(desktop, since: count)
        let together = new.contains { event in
            guard event.hasPrefix("gamepad 0x1000 lt 255"), let stick = stickValue(event, "ls") else { return false }
            return stick.x < -20000
        }
        XCTAssertTrue(together, "\(tag) A + LT + stick at once: \(new)")
        XCTAssertEqual(new.last, "gamepad 0x0000 lt 0 rt 0 ls 0 0 rs 0 0", "\(tag) several: not all released \(new)")
        XCTAssertFalse(new.contains { $0.hasPrefix("move ") || $0.hasPrefix("down ") }, "\(tag) several: mouse input \(new)")
        shot("\(tag)-3-after-controls")
    }

    // MARK: Helpers

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

    private func connect(size: String = "UICTContentSizeCategoryL", orientation: UIDeviceOrientation,
                         extra: [String] = []) -> (XCUIApplication, XCUIElement) {
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

    private func control(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func center(_ element: XCUIElement) -> CGPoint {
        CGPoint(x: element.frame.midX, y: element.frame.midY)
    }

    private func point(_ desktop: XCUIElement, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        desktop.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func status(_ desktop: XCUIElement) -> String {
        state(desktop).status
    }

    private func state(_ desktop: XCUIElement) -> (status: String, count: Int, events: [String]) {
        let lines = (desktop.value as? String ?? "").components(separatedBy: "\n")
        let count = lines.dropFirst().first.flatMap { Int($0.replacingOccurrences(of: "events ", with: "")) } ?? 0
        return (lines.first ?? "", count, Array(lines.dropFirst(2)))
    }

    private func events(_ desktop: XCUIElement, since count: Int) -> [String] {
        let now = state(desktop)
        let new = now.count - count
        return new <= 0 ? [] : Array(now.events.suffix(min(new, now.events.count)))
    }

    /// A stick's x and y in a gamepad event ("ls" or "rs").
    private func stickValue(_ event: String, _ label: String) -> (x: Int, y: Int)? {
        let words = event.split(separator: " ").map(String.init)
        guard words.first == "gamepad", let index = words.firstIndex(of: label), index + 2 < words.count,
              let x = Int(words[index + 1]), let y = Int(words[index + 2]) else { return nil }
        return (x, y)
    }
}
