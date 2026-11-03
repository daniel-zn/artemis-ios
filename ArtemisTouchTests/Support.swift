//
//  Support.swift
//  ArtemisTouchTests
//
//  What TouchInterpreter needs from the rest of the app, and a recording delegate. Built with
//  Artemis/Desktop/TouchInterpreter.swift for the Mac by Scripts/touch-tests.sh.
//

import CoreGraphics
import Foundation

enum MouseButton { case left, right, middle }

/// Records what the interpreter asks for. Scroll amounts are the fingers' movement in points
/// (DesktopViewController turns them into wheel events); momentum is played out the way
/// DesktopViewController does (60 frames a second, 0.93 a frame, until under 40 points/s).
/// `other` is everything but scrolling ("move", "down left", "up left", "click right", …);
/// `timeline` is the same with "scroll" and the fingers' lifts ("lift 0" for the first finger)
/// in order, repeats folded into one.
final class Recorder: TouchInterpreterDelegate {
    var mode = PointerMode.trackpad
    var zoomed = false
    var scrolled = CGVector.zero
    var pointer = CGVector.zero
    var momentum: CGVector?
    var other: [String] = []
    var timeline: [String] = []
    var haptics: [TouchHaptic] = []

    func note(_ event: String, other isOther: Bool = true) {
        if isOther { other.append(event) }
        if timeline.last != event { timeline.append(event) }
    }

    func pointerMode(onTrackpadArea: Bool) -> PointerMode { onTrackpadArea ? .trackpad : mode }
    var isZoomed: Bool { zoomed }
    func movePointer(by delta: CGVector, interval: TimeInterval) {
        pointer.dx += delta.dx
        pointer.dy += delta.dy
        note("move")
    }
    func movePointer(to desktop: CGPoint) { note("move") }
    func desktopPoint(at location: CGPoint) -> CGPoint? { CGPoint(x: location.x / 400, y: location.y / 800) }
    func setButton(_ button: MouseButton, down: Bool) { note("\(down ? "down" : "up") \(button)") }
    func click(_ button: MouseButton) { note("click \(button)") }
    func scroll(by delta: CGVector) {
        scrolled.dx += delta.dx
        scrolled.dy += delta.dy
        note("scroll", other: false)
    }
    func startMomentum(velocity: CGVector) {
        momentum = velocity
        var v = velocity
        let interval = 1.0 / 60
        while hypot(v.dx, v.dy) >= 40 {
            v.dx *= 0.93
            v.dy *= 0.93
            scroll(by: CGVector(dx: v.dx * interval, dy: v.dy * interval))
        }
    }
    func stopMomentum() {}
    func zoom(by factor: CGFloat, around location: CGPoint) { note("zoom") }
    func pan(by delta: CGVector) { note("pan") }
    func resetZoom() { note("reset zoom") }
    func toggleKeyboard() { note("keyboard") }
    func haptic(_ style: TouchHaptic) { haptics.append(style) }
}

/// One finger: down at `down`, up at `up` (seconds), where it is at each moment in between.
struct FingerPath {
    var down: Double
    var up: Double
    var at: (Double) -> CGPoint
}

private final class Token {}

/// Plays fingers to an interpreter as UIKit would: one event per display frame (`hz`), each
/// with the touches that began, moved or ended in it. The location a finger lifts at is
/// where it was in its last frame (UIKit reports no new position with the lift).
///
/// The interpreter's timers (the hold, a tap's release) run on the same clock, between frames.
/// `area`: on the trackpad area (always trackpad) or on the desktop (`mode`). `cancelAt`: the
/// system cancels every touch then (a call coming in, the app going away).
func play(_ fingers: [FingerPath], hz: Double = 120, mode: PointerMode = .trackpad, area: Bool = true,
          zoomed: Bool = false, cancelAt: Double? = nil, settle: Double = 0) -> Recorder {
    let recorder = Recorder()
    recorder.mode = mode
    recorder.zoomed = zoomed
    let interpreter = TouchInterpreter()
    interpreter.delegate = recorder
    var clock = 0.0
    var timers: [(at: Double, work: DispatchWorkItem)] = []
    interpreter.schedule = { delay, work in timers.append((clock + delay, work)) }
    func runTimers(until time: Double) {
        while let next = timers.indices.filter({ timers[$0].at <= time + 1e-9 }).min(by: { timers[$0].at < timers[$1].at }) {
            let timer = timers.remove(at: next)
            clock = timer.at
            if !timer.work.isCancelled { timer.work.perform() }
        }
        clock = time
    }
    var cancelled = false
    let tokens = fingers.map { _ in Token() }
    let ids = tokens.map { ObjectIdentifier($0) }
    let frame = 1 / hz
    var down = Set<Int>()
    var lastLocation: [Int: CGPoint] = [:]
    var n = Int((fingers.map(\.down).min() ?? 0) / frame)
    let end = fingers.map(\.up).max() ?? 0
    while Double(n) * frame <= end + 2 * frame {
        let time = Double(n) * frame
        runTimers(until: time)
        if let cancelAt, !cancelled, time >= cancelAt - 1e-9 {
            cancelled = true
            recorder.note("cancel", other: false)
            interpreter.cancelled()
            down.removeAll()
            n += 1
            continue
        }
        if cancelled { n += 1; continue }
        var began: [TouchSample] = [], moved: [TouchSample] = [], ended: [TouchSample] = []
        var lifted: [Int] = []
        for (i, finger) in fingers.enumerated() {
            if !down.contains(i) && time >= finger.down - 1e-9 && time < finger.up - 1e-9 {
                down.insert(i)
                let location = finger.at(time)
                lastLocation[i] = location
                began.append(TouchSample(id: ids[i], location: location, desktop: area ? nil : recorder.desktopPoint(at: location), time: time))
            } else if down.contains(i) && time >= finger.up - 1e-9 {
                down.remove(i)
                lifted.append(i)
                ended.append(TouchSample(id: ids[i], location: lastLocation[i]!, desktop: area ? nil : recorder.desktopPoint(at: lastLocation[i]!), time: time))
            } else if down.contains(i) {
                let location = finger.at(time)
                if location != lastLocation[i] {
                    lastLocation[i] = location
                    moved.append(TouchSample(id: ids[i], location: location, desktop: area ? nil : recorder.desktopPoint(at: location), time: time))
                }
            }
        }
        if !began.isEmpty { interpreter.began(began, onTrackpadArea: area) }
        if !moved.isEmpty { interpreter.moved(moved) }
        for i in lifted { recorder.note("lift \(i)", other: false) }
        if !ended.isEmpty { interpreter.ended(ended) }
        n += 1
    }
    runTimers(until: end + 2 * frame + settle + 1)
    withExtendedLifetime(tokens) {}
    return recorder
}
