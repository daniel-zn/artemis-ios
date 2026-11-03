//
//  Gestures.swift
//  ArtemisTouchTests
//
//  The trackpad's gestures other than scrolling (docs/TOUCH.md's table), played on the
//  interpreter's own clock: one finger resting while another drags (click and drag), and the
//  gestures next to it that it must leave alone (taps, holds, two-finger taps, pinches,
//  three-finger taps, direct mode).
//

import CoreGraphics
import Foundation

/// A finger along points in time, (seconds, point): still before the first and after the last,
/// straight lines between.
func finger(_ down: Double, _ up: Double, _ points: [(Double, CGPoint)]) -> FingerPath {
    FingerPath(down: down, up: up) { t in
        guard let first = points.first else { return .zero }
        if t <= first.0 { return first.1 }
        for (a, b) in zip(points, points.dropFirst()) where t <= b.0 {
            let f = CGFloat((t - a.0) / (b.0 - a.0))
            return CGPoint(x: a.1.x + (b.1.x - a.1.x) * f, y: a.1.y + (b.1.y - a.1.y) * f)
        }
        return points.last!.1
    }
}

func still(_ down: Double, _ up: Double, at point: CGPoint) -> FingerPath {
    finger(down, up, [(down, point)])
}

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The buttons and clicks the PC got.
private func buttons(_ r: Recorder) -> [String] {
    r.other.filter { $0.hasPrefix("down") || $0.hasPrefix("up") || $0.hasPrefix("click") }
}

private func moves(between first: String, and last: String, in timeline: [String]) -> Bool {
    guard let a = timeline.firstIndex(of: first), let b = timeline.lastIndex(of: last), a < b else { return false }
    return timeline[a..<b].contains("move")
}

func runGestureTests() {
    let anchor = p(100, 500), other = p(220, 500)

    // MARK: Hold one finger, drag another: click and drag

    var r = play([still(0, 1.5, at: anchor),
                  finger(0.3, 1.0, [(0.4, other), (0.9, p(340, 500))])])
    check("hold + drag: the button goes down as the other finger moves, up when the resting finger lifts",
          r.timeline == ["down left", "move", "lift 1", "lift 0", "up left"], "\(r.timeline)")
    check("hold + drag: the pointer follows the moving finger", r.pointer.dx > 90 && abs(r.pointer.dy) < 1, "pointer \(r.pointer)")
    check("hold + drag: no scroll, no click", r.scrolled == .zero && !r.other.contains { $0.hasPrefix("click") },
          "scrolled \(r.scrolled), \(r.other)")

    r = play([still(0, 2.0, at: anchor),
              finger(1.0, 1.7, [(1.1, other), (1.6, p(340, 500))])])
    check("hold + drag, the second finger landing after the hold's 0.45 s: a drag, no right click",
          r.timeline == ["down left", "move", "lift 1", "lift 0", "up left"], "\(r.timeline)")
    check("hold + drag, landing late: a hold's haptic, then the drag's", r.haptics == [.medium, .light], "\(r.haptics)")

    r = play([still(0, 2.0, at: anchor),
              finger(0.3, 0.65, [(0.4, other), (0.6, p(300, 520))]),
              finger(0.8, 1.3, [(0.9, other), (1.2, p(280, 440))])])
    check("hold + drag, the moving finger lifts and lands again: the button stays down, the pointer carries on",
          r.timeline == ["down left", "move", "lift 1", "move", "lift 2", "lift 0", "up left"], "\(r.timeline)")
    check("hold + drag, landing again: both strokes move the pointer", r.pointer.dx > 110 && r.pointer.dy < -40, "pointer \(r.pointer)")

    r = play([still(0, 0.8, at: anchor),
              finger(0.3, 1.3, [(0.4, other), (1.2, p(370, 500))])])
    check("hold + drag, the resting finger lifts mid-drag: released then, the other finger then moves nothing",
          r.timeline == ["down left", "move", "lift 0", "up left", "lift 1"], "\(r.timeline)")

    r = play([still(0, 1.5, at: anchor),
              finger(0.3, 1.0, [(0.4, other), (1.0, p(340, 500))])], cancelAt: 0.7)
    check("hold + drag, cancelled by the system: released", r.timeline == ["down left", "move", "cancel", "up left"], "\(r.timeline)")

    r = play([finger(0, 1.0, [(0.38, anchor), (0.93, p(100, 600))]),
              finger(0.3, 1.0, [(0.35, other), (0.9, p(220, 600))])])
    check("resting finger that moves with the other (30 ms behind): a scroll, not a drag",
          buttons(r).isEmpty && !r.other.contains("move") && r.scrolled.dy > 50, "\(r.other), scrolled \(r.scrolled)")

    r = play([finger(0, 1.5, [(0.4, anchor), (0.9, p(103, 501))]),
              finger(0.3, 1.0, [(0.4, other), (0.9, p(340, 500))])])
    check("resting finger that drifts 3 points: still a drag",
          r.timeline == ["down left", "move", "lift 1", "lift 0", "up left"], "\(r.timeline)")

    r = play([still(0, 1.0, at: anchor),
              finger(0, 1.0, [(0.1, other), (0.6, p(340, 500))])])
    check("both fingers landing together, one still, the other moving: not a drag (the resting finger lands first)",
          buttons(r).isEmpty, "\(r.other)")

    r = play([still(0, 1.5, at: anchor), still(0, 0, at: other),
              finger(0.3, 1.0, [(0.4, other), (0.9, p(340, 500))])])
    check("hold + drag as XCTest synthesizes it (a touch landing and lifting with the first): still a drag",
          r.timeline == ["lift 1", "down left", "move", "lift 2", "lift 0", "up left"], "\(r.timeline)")

    r = play([still(0, 0.8, at: anchor), still(0, 0, at: other)])
    check("press and hold beside a touch that lands and lifts at once: still a right click", r.other == ["click right"], "\(r.other)")

    r = play([still(0, 1.5, at: anchor),
              still(1.0, 1.1, at: other)])
    check("hold, a second finger taps: nothing (no right click from the hold)", r.other.isEmpty, "\(r.other)")

    r = play([still(0, 1.5, at: p(100, 300)),
              finger(0.3, 1.0, [(0.4, p(220, 300)), (0.9, p(340, 300))])], mode: .direct, area: false)
    check("direct mode: a resting finger and a moving one don't press the button",
          !r.other.contains("down left") && !r.other.contains { $0.hasPrefix("click") }, "\(r.other)")

    // MARK: The gestures next to it

    r = play([still(0, 0.05, at: anchor)])
    check("tap: a left click, released a moment later", r.timeline == ["lift 0", "down left", "up left"], "\(r.timeline)")

    r = play([still(0, 0.05, at: anchor), still(0.15, 0.2, at: anchor)])
    check("double tap: a double click", buttons(r) == ["down left", "up left", "click left"], "\(r.other)")

    r = play([still(0, 0.8, at: anchor)])
    check("press and hold, lift without moving: a right click", r.other == ["click right"] && r.haptics.first == .medium,
          "\(r.other) \(r.haptics)")

    r = play([finger(0, 1.3, [(0.6, anchor), (1.2, p(200, 450))])])
    check("press and hold, then drag: a left drag", buttons(r) == ["down left", "up left"]
          && moves(between: "down left", and: "up left", in: r.timeline), "\(r.timeline)")

    r = play([still(0, 0.05, at: anchor), finger(0.15, 0.9, [(0.4, anchor), (0.8, p(200, 500))])])
    check("tap, then touch again and drag: one left drag from the tap", buttons(r) == ["down left", "up left"]
          && moves(between: "down left", and: "up left", in: r.timeline), "\(r.timeline)")

    r = play([finger(0, 0.5, [(0.05, anchor), (0.45, p(250, 400))])])
    check("one finger drag: moves the pointer, no button", buttons(r).isEmpty && r.pointer.dx > 100, "\(r.other)")

    r = play([still(0, 0.1, at: anchor), still(0, 0.1, at: other)])
    check("two-finger tap: a right click", r.other == ["click right"], "\(r.other)")

    r = play([still(0, 0.25, at: anchor), still(0.15, 0.25, at: other)])
    check("two-finger tap, the second finger 0.15 s later: a right click", r.other == ["click right"], "\(r.other)")

    r = play([still(0, 0.1, at: anchor), still(0, 0.1, at: other)], zoomed: true)
    check("two-finger tap when zoomed: a right click after the wait", r.other == ["click right"], "\(r.other)")

    r = play([still(0, 0.08, at: anchor), still(0, 0.08, at: other), still(0.15, 0.23, at: anchor), still(0.15, 0.23, at: other)],
             zoomed: true)
    check("two-finger double tap when zoomed: resets the zoom, no right click", r.other == ["reset zoom"], "\(r.other)")

    r = play([finger(0, 0.7, [(0.05, p(180, 500)), (0.6, p(100, 500))]),
              finger(0, 0.7, [(0.05, p(220, 500)), (0.6, p(300, 500))])])
    check("pinch: zooms, no button, no scroll", r.other.contains("zoom") && buttons(r).isEmpty
          && r.scrolled == .zero, "\(r.other)")

    r = play([finger(0, 1.0, [(0.3, p(180, 500))]),
              finger(0.3, 1.0, [(0.35, p(220, 500)), (0.9, p(320, 500))])])
    check("resting finger, the other moving straight away from it: a drag (not a pinch)",
          r.timeline == ["down left", "move", "lift 0", "up left"] || r.timeline == ["down left", "move", "lift 1", "lift 0", "up left"]
          || r.timeline == ["down left", "move", "lift 0", "lift 1", "up left"], "\(r.timeline)")

    r = play([still(0, 0.1, at: p(100, 500)), still(0, 0.1, at: p(160, 500)), still(0, 0.1, at: p(220, 500))])
    check("three-finger tap: the keyboard", r.other == ["keyboard"], "\(r.other)")

    r = play([finger(0, 0.6, [(0.05, p(100, 300)), (0.5, p(100, 420))]),
              finger(0, 0.6, [(0.05, p(160, 300)), (0.5, p(160, 420))])])
    check("two-finger drag, landing together: a scroll down, nothing else", r.other.isEmpty && r.scrolled.dy > 60, "\(r.other) \(r.scrolled)")

    r = play([finger(0, 0.16, [(0.05, p(100, 300)), (0.16, p(100, 380))]),
              finger(0, 0.16, [(0.05, p(160, 300)), (0.16, p(160, 380))])])
    check("two-finger flick: momentum the fingers' way", (r.momentum?.dy ?? 0) > 150 && r.scrolled.dy > 100, "\(String(describing: r.momentum))")
}
