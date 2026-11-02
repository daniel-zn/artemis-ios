//
//  main.swift
//  ArtemisTouchTests
//
//  Two-finger scrolling the way real fingers do it, which the UI tests' synthesized drags
//  don't: fingers landing and lifting a few frames apart, a swipe slowing down before the lift,
//  and the contact point rolling back a few points as the fingers come off the glass. Whatever
//  happens at the edges, the scroll (with its momentum) must go the way the fingers went.
//  Run: Scripts/touch-tests.sh
//

import CoreGraphics
import Foundation

var failures = 0
var count = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
    count += 1
    if condition {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name): \(detail())")
    }
}

/// A swipe along `axis` (a unit vector) by `distance` points between t0 and t1, linear or
/// slowing to a stop; then `rolls`: (time, points) jumps against the swipe (a lift's roll).
func swipe(from start: CGPoint, axis: CGVector, distance: CGFloat, t0: Double, t1: Double,
           easeOut: Bool = false, rolls: [(Double, CGFloat)] = []) -> (Double) -> CGPoint {
    return { t in
        var f = min(max((t - t0) / (t1 - t0), 0), 1)
        if easeOut { f = 1 - pow(1 - f, 3) }
        var along = distance * CGFloat(f)
        for (at, back) in rolls where t >= at - 1e-9 { along -= back }
        return CGPoint(x: start.x + axis.dx * along, y: start.y + axis.dy * along)
    }
}

struct Case {
    var name: String
    var distance: CGFloat = 120
    var duration: Double = 0.8
    var easeOut = false
    /// When each finger lands and lifts, after the swipe's start / end.
    var aDown = 0.0, bDown = 0.0
    var aUp = 0.01, bUp = 0.01
    /// Points the contact rolls back, and how many frames before the lift.
    var roll: CGFloat = 0
    var rollFrames = 1
    var hz = 120.0
    /// A finger landing later may move the pointer first.
    var pointerMayMove = false
}

let cases: [Case] = [
    Case(name: "together, steady"),
    Case(name: "together, slowing to a stop", easeOut: true),
    Case(name: "a flick", duration: 0.12),
    Case(name: "B lifts 30 ms after A", bUp: 0.04),
    Case(name: "B lifts 100 ms after A", bUp: 0.11),
    Case(name: "A lifts while still moving, B 60 ms later", aUp: -0.05, bUp: 0.01),
    Case(name: "B lands 40 ms late", bDown: 0.04),
    Case(name: "B lands 120 ms late", bDown: 0.12, pointerMayMove: true),
    Case(name: "short slow swipe", distance: 40),
    Case(name: "short slow swipe, 60 Hz", distance: 40, hz: 60),
]
let rolls: [(CGFloat, Int)] = [(2, 1), (4, 1), (6, 1), (8, 1), (12, 1), (6, 2), (10, 3)]

let axes: [(String, CGVector)] = [("down", CGVector(dx: 0, dy: 1)), ("up", CGVector(dx: 0, dy: -1)),
                                  ("right", CGVector(dx: 1, dy: 0)), ("left", CGVector(dx: -1, dy: 0))]

func run(_ c: Case, axis: CGVector, label: String) {
    let t0 = 0.02, t1 = t0 + c.duration
    let frame = 1 / c.hz
    let lift = min(t1 + c.aUp, t1 + c.bUp)
    // The roll: in the frames just before the first finger lifts, spread over rollFrames
    let rollSteps = c.roll == 0 ? [] : (1...c.rollFrames).map { (lift - Double($0) * frame, c.roll / CGFloat(c.rollFrames)) }
    func path(_ start: CGPoint, down: Double, up: Double) -> FingerPath {
        FingerPath(down: t0 + down, up: t1 + up,
                   at: swipe(from: start, axis: axis, distance: c.distance, t0: t0, t1: t1, easeOut: c.easeOut, rolls: rollSteps))
    }
    let recorder = play([path(CGPoint(x: 180, y: 300), down: c.aDown, up: c.aUp),
                         path(CGPoint(x: 230, y: 305), down: c.bDown, up: c.bUp)], hz: c.hz)
    let along = recorder.scrolled.dx * axis.dx + recorder.scrolled.dy * axis.dy
    let across = abs(recorder.scrolled.dx * axis.dy) + abs(recorder.scrolled.dy * axis.dx)
    let momentum = recorder.momentum.map { $0.dx * axis.dx + $0.dy * axis.dy }
    let name = "fingers \(label): \(c.name)" + (c.roll == 0 ? "" : ", rolls back \(Int(c.roll)) pt over \(c.rollFrames) frame\(c.rollFrames == 1 ? "" : "s")")
    let detail = String(format: "scrolled %+.0f pt along (%.0f across), momentum %@", along, across,
                        momentum.map { String(format: "%+.0f pt/s", $0) } ?? "none")
    // At least half of the fingers' net travel, the fingers' way, and no momentum against them
    let net = c.distance - c.roll
    check(name, along >= net * 0.5 && (momentum ?? 0) >= 0, detail)
    if c.name == "a flick" && c.roll <= 6 {
        // A flick still coasts on after the lift
        check(name + " (momentum)", (momentum ?? 0) > 150 && along > c.distance + 20, detail)
    }
    check(name + " (nothing else)", c.pointerMayMove ? !recorder.other.contains { $0 != "move" } : recorder.other.isEmpty,
          "also \(recorder.other)")
}

for (label, axis) in axes {
    for c in cases {
        run(c, axis: axis, label: label)
        for (roll, frames) in rolls {
            var rolled = c
            rolled.roll = roll
            rolled.rollFrames = frames
            run(rolled, axis: axis, label: label)
        }
    }
}

print(failures == 0 ? "\nall \(count) checks passed" : "\n\(failures) of \(count) checks failed")
exit(failures == 0 ? 0 : 1)
