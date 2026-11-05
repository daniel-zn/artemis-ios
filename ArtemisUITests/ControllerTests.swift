//
//  ControllerTests.swift
//  ArtemisUITests
//
//  A game controller as the mouse (GamepadMouse) on the demo desktop: the demo plays a
//  scripted controller (-ArtemisDemoGamepad) into the same mapping ControllerSupport feeds,
//  and the desktop records what reaches the PC: mouse events, or "pad <buttons>" for states
//  sent as a gamepad.
//

import XCTest

final class ControllerTests: XCTestCase {
    private var appearance: String {
        ProcessInfo.processInfo.environment["ARTEMIS_APPEARANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "system"
    }

    override func setUp() {
        continueAfterFailure = true
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
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Opens the demo desktop with a controller script; returns its recorded events once it ran.
    private func run(_ script: String, orientation: UIDeviceOrientation, extra: [String] = []) -> (XCUIApplication, String, [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", "",
                               "-ArtemisDemoGamepad", script] + extra
        app.launch()
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(app.buttons["computer.WORKSTATION"].waitForExistence(timeout: 15))
        app.buttons["computer.WORKSTATION"].tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10))
        app.buttons["game.Desktop"].tap()
        let desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), "the desktop didn't open")
        // The script runs a second after the desktop opens; the notice shows for 2.5 s after it
        sleep(2)
        let lines = (desktop.value as? String ?? "").components(separatedBy: "\n")
        return (app, lines.first ?? "", Array(lines.dropFirst(2)))
    }

    /// Off: gamepad. Hold Start: mouse (stick moves, A/B click, right stick and D-pad scroll),
    /// with nothing sent as a gamepad. Hold Start again: gamepad again.
    func testControllerMouseMapping() {
        let script = "press a;hold start 0.8;left 1 0 0.25;press a;press b;right 0 1 0.25;press up;hold start 0.8;press a"
        let (app, status, events) = run(script, orientation: .portrait)
        let moves = events.filter { $0.hasPrefix("move ") }
        let stickScrolls = events.filter { $0.hasPrefix("scroll ") && $0 != "scroll 120 0" }
        let others = events.filter { !$0.hasPrefix("move ") && !stickScrolls.contains($0) }
        XCTAssertEqual(others, ["pad 0x1000", "pad 0x0000", // A as a gamepad button
                                "pad 0x0010", "pad 0x0000", // Start held, then up: mouse on
                                "down left", "up left", "down right", "up right", "scroll 120 0",
                                "pad 0x0000", // Start held again: mouse off, the PC sees the controller at rest
                                "pad 0x1000", "pad 0x0000"], "events: \(events)")
        // The left stick, full right for 0.25 s: the pointer goes right from the middle
        XCTAssertGreaterThanOrEqual(moves.count, 10, "moves: \(moves)")
        let last = moves.last?.split(separator: " ").compactMap { Int($0) } ?? []
        XCTAssertEqual(last.count, 2)
        if last.count == 2 {
            XCTAssertTrue((1290...1340).contains(last[0]), "pointer x \(last[0])")
            XCTAssertEqual(last[1], 540, "pointer y")
        }
        // The right stick, up: scrolls up in quarter notches
        XCTAssertGreaterThanOrEqual(stickScrolls.count, 8, "scrolls: \(stickScrolls)")
        XCTAssertTrue(stickScrolls.allSatisfy { $0.hasPrefix("scroll ") && $0.hasSuffix(" 0") && !$0.contains("-") }, "scrolls: \(stickScrolls)")
        XCTAssertTrue(status.contains("gamepad mouse off"), "status: \(status)")
        shot("\(appearance)-portrait-L-controller-1-off")
        app.terminate()
    }

    /// The mouse on, upright and in landscape (the notice and the moved pointer).
    func testControllerMouseOn() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            let (app, status, events) = run("hold start 0.8;left -0.7 0.7 0.4", orientation: orientation)
            XCTAssertTrue(status.contains("gamepad mouse on"), "\(name) status: \(status)")
            XCTAssertTrue(events.contains { $0.hasPrefix("move ") }, "\(name): no pointer movement")
            XCTAssertTrue(status.contains("notices 1"), "\(name): no notice (\(status))")
            shot("\(appearance)-\(name)-L-controller-2-on")
            app.terminate()
        }
    }

    /// Start held together with another button (Start+LB, as upstream's Select emulation uses)
    /// is a combo, not a long press: the mouse stays off and everything goes to the PC.
    func testControllerComboDoesNotToggle() {
        let (app, status, events) = run("down start;wait 0.4;press lb;wait 0.6;up start;press a", orientation: .portrait)
        XCTAssertEqual(events, ["pad 0x0010", "pad 0x0110", "pad 0x0010", "pad 0x0000", "pad 0x1000", "pad 0x0000"])
        XCTAssertTrue(status.contains("gamepad mouse off"), "status: \(status)")
        app.terminate()
    }

    /// With the setting off, holding Start does nothing: every state goes to the PC.
    func testControllerMouseSettingOff() {
        let (app, status, events) = run("hold start 0.8;press a", orientation: .portrait, extra: ["-ArtemisGamepadMouse", "NO"])
        XCTAssertEqual(events, ["pad 0x0010", "pad 0x0000", "pad 0x1000", "pad 0x0000"])
        XCTAssertTrue(status.contains("gamepad mouse off"), "status: \(status)")
        app.terminate()
    }

    // MARK: A connected controller, end to end

    /// Opens the demo desktop with a connected (virtual) controller pressed by a script; the
    /// arrival and what went to the PC once the script has finished, consecutive repeats merged.
    private func connected(_ script: String, orientation: UIDeviceOrientation = .portrait) -> (XCUIApplication, String, String?, [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-ArtemisDemo", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                               "-ArtemisShowControlBar", "YES", "-ArtemisBarCenter", "{0.5, 0.92}", "-ArtemisGamepadBarCenter2", "",
                               "-ArtemisGamepadMouse", "YES", "-ArtemisDemoController", script]
        app.launch()
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(app.buttons["computer.WORKSTATION"].waitForExistence(timeout: 15))
        app.buttons["computer.WORKSTATION"].tap()
        XCTAssertTrue(app.buttons["game.Desktop"].waitForExistence(timeout: 10))
        app.buttons["game.Desktop"].tap()
        let desktop = app.otherElements["desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10), "the desktop didn't open")
        let finished = NSPredicate { _, _ in
            let value = desktop.value as? String ?? ""
            return value.contains("controller done") || value.contains("controller error")
        }
        let done = expectation(for: finished, evaluatedWith: nil)
        wait(for: [done], timeout: 30)
        let lines = (desktop.value as? String ?? "").components(separatedBy: "\n")
        let events = Array(lines.dropFirst(2))
        XCTAssertFalse(events.contains { $0.hasPrefix("controller error") }, "events: \(events)")
        let arrival = events.first { $0.hasPrefix("arrival ") }
        var sent: [String] = []
        for event in events.drop(while: { $0 != "controller ready" }).dropFirst()
        where event != "controller done" && !event.hasPrefix("move ") && event != sent.last {
            sent.append(event)
        }
        return (app, lines.first ?? "", arrival, sent)
    }

    /// Select (the Xbox controller's View, a PlayStation controller's Share / Create) reaches the
    /// PC as the Xbox Back button, as do Start / Menu and A, each on its own; during the session
    /// controller buttons go to the GameController framework only, not to UIKit's navigation.
    /// (The virtual controller has no Xbox / Home button to press, nor stick clicks it reports.)
    func testConnectedControllerButtons() {
        let (app, status, arrival, sent) = connected("press options;press menu;press a")
        // The PC is told the controller has a Back button (0x0020) and Start (0x0010)
        let flags = arrival.flatMap { UInt32($0.split(separator: " ").last?.dropFirst(2) ?? "", radix: 16) } ?? 0
        XCTAssertEqual(flags & 0x0020, 0x0020, "no Back in the arrival: \(arrival ?? "none")")
        XCTAssertEqual(flags & 0x0010, 0x0010, "no Start in the arrival: \(arrival ?? "none")")
        XCTAssertEqual(sent, ["pad 0x0020", "pad 0x0000", // Select: Back
                              "pad 0x0010", "pad 0x0000", // Start / Menu
                              "pad 0x1000", "pad 0x0000"], // A
                       "sent: \(sent)")
        XCTAssertTrue(status.contains("gamepad mouse off"), "status: \(status)")
        XCTAssertTrue(status.contains("controller events game controller only"), "status: \(status)")
        shot("\(appearance)-portrait-L-controller-3-select")
        app.terminate()
    }

    /// Select held, then Start: on a controller without an Xbox / Home button (as this one) the
    /// pair is the Guide button, upstream's stand-in; Select alone is Back again after.
    func testConnectedControllerStartAndSelect() {
        let (app, _, _, sent) = connected("down options;down menu;up menu;up options;press options")
        XCTAssertEqual(sent, ["pad 0x0020", "pad 0x0420", "pad 0x0020", "pad 0x0000", "pad 0x0020", "pad 0x0000"], "sent: \(sent)")
        app.terminate()
    }

    /// The controller as the mouse, end to end: hold Menu turns it on (the PC sees the controller
    /// at rest), A clicks, the stick moves the pointer and Select stays with the mouse (nothing
    /// reaches the PC, as in the Mac app); hold Menu again turns it off and Select is Back again.
    func testConnectedControllerMouseMode() {
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            let (app, status, _, sent) = connected("hold menu 0.9;press options;press a;left 1 0 0.3;hold menu 0.9;press options",
                                                   orientation: orientation)
            XCTAssertEqual(sent, ["pad 0x0010", "pad 0x0000", // Menu held, then up: the mouse on, the PC sees it at rest
                                  "down left", "up left", // A clicks; Select sent nothing
                                  "pad 0x0000", // Menu held again: the mouse off
                                  "pad 0x0020", "pad 0x0000"], // Select is Back again
                           "\(name) sent: \(sent)")
            XCTAssertTrue(status.contains("gamepad mouse off"), "\(name) status: \(status)")
            app.terminate()
        }
    }
}

