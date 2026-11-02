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
final class Recorder: TouchInterpreterDelegate {
    var scrolled = CGVector.zero
    var momentum: CGVector?
    var other: [String] = []

    func pointerMode(onTrackpadArea: Bool) -> PointerMode { .trackpad }
    var isZoomed: Bool { false }
    func movePointer(by delta: CGVector, interval: TimeInterval) { other.append("move") }
    func movePointer(to desktop: CGPoint) { other.append("move") }
    func desktopPoint(at location: CGPoint) -> CGPoint? { nil }
    func setButton(_ button: MouseButton, down: Bool) { other.append("button") }
    func click(_ button: MouseButton) { other.append("click") }
    func scroll(by delta: CGVector) {
        scrolled.dx += delta.dx
        scrolled.dy += delta.dy
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
    func zoom(by factor: CGFloat, around location: CGPoint) { other.append("zoom") }
    func pan(by delta: CGVector) { other.append("pan") }
    func resetZoom() {}
    func toggleKeyboard() { other.append("keyboard") }
    func haptic(_ style: TouchHaptic) {}
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
func play(_ fingers: [FingerPath], hz: Double = 120) -> Recorder {
    let recorder = Recorder()
    let interpreter = TouchInterpreter()
    interpreter.delegate = recorder
    let tokens = fingers.map { _ in Token() }
    let ids = tokens.map { ObjectIdentifier($0) }
    let frame = 1 / hz
    var down = Set<Int>()
    var lastLocation: [Int: CGPoint] = [:]
    var n = Int((fingers.map(\.down).min() ?? 0) / frame)
    let end = fingers.map(\.up).max() ?? 0
    while Double(n) * frame <= end + 2 * frame {
        let time = Double(n) * frame
        var began: [TouchSample] = [], moved: [TouchSample] = [], ended: [TouchSample] = []
        for (i, finger) in fingers.enumerated() {
            if !down.contains(i) && time >= finger.down - 1e-9 && time < finger.up - 1e-9 {
                down.insert(i)
                let location = finger.at(time)
                lastLocation[i] = location
                began.append(TouchSample(id: ids[i], location: location, desktop: nil, time: time))
            } else if down.contains(i) && time >= finger.up - 1e-9 {
                down.remove(i)
                ended.append(TouchSample(id: ids[i], location: lastLocation[i]!, desktop: nil, time: time))
            } else if down.contains(i) {
                let location = finger.at(time)
                if location != lastLocation[i] {
                    lastLocation[i] = location
                    moved.append(TouchSample(id: ids[i], location: location, desktop: nil, time: time))
                }
            }
        }
        if !began.isEmpty { interpreter.began(began, onTrackpadArea: true) }
        if !moved.isEmpty { interpreter.moved(moved) }
        if !ended.isEmpty { interpreter.ended(ended) }
        n += 1
    }
    withExtendedLifetime(tokens) {}
    return recorder
}
