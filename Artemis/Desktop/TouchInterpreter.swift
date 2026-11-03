//
//  TouchInterpreter.swift
//  Artemis
//
//  Turns raw touches into the remote desktop's gestures (docs/TOUCH.md): pointer moves,
//  clicks, drags, scrolling, zooming and panning, the keyboard toggle. A gesture lasts from
//  the first finger down to the last finger up and is decided by the most fingers it had,
//  so lifting one finger of a scroll doesn't move the pointer. Trackpad: a finger resting while
//  another moves is a click and drag, held until the resting finger lifts.
//

import CoreGraphics
import Foundation

enum PointerMode: String {
    case trackpad, direct
}

/// What a touch is: where it is on the screen, and where on the desktop (0–1) when it's
/// over the desktop.
struct TouchSample {
    let id: ObjectIdentifier
    let location: CGPoint
    let desktop: CGPoint?
    let time: TimeInterval
}

/// A tap's feel (UIKit's impact styles; plain here so the interpreter builds and is tested
/// without UIKit: Scripts/touch-tests.sh).
enum TouchHaptic {
    case light, medium
}

protocol TouchInterpreterDelegate: AnyObject {
    /// The mode for a gesture: always trackpad on the trackpad area under the desktop.
    func pointerMode(onTrackpadArea: Bool) -> PointerMode
    var isZoomed: Bool { get }
    /// Trackpad: moves the pointer by a finger's movement on the screen.
    func movePointer(by delta: CGVector, interval: TimeInterval)
    /// Direct: moves the pointer to a point on the desktop (0–1).
    func movePointer(to desktop: CGPoint)
    /// The desktop point (0–1) under a screen point, if any.
    func desktopPoint(at location: CGPoint) -> CGPoint?
    func setButton(_ button: MouseButton, down: Bool)
    func click(_ button: MouseButton)
    func scroll(by delta: CGVector)
    func startMomentum(velocity: CGVector)
    func stopMomentum()
    func zoom(by factor: CGFloat, around location: CGPoint)
    func pan(by delta: CGVector)
    func resetZoom()
    func toggleKeyboard()
    func haptic(_ style: TouchHaptic)
}

final class TouchInterpreter {
    weak var delegate: TouchInterpreterDelegate?
    /// Runs a timer's work after a delay (the hold, a tap's release); the Mac tests play it on
    /// their own clock.
    var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Tuning
    static let slop: CGFloat = 8
    static let tapDuration: TimeInterval = 0.35
    static let longPressDelay: TimeInterval = 0.45
    static let tapReleaseDelay: TimeInterval = 0.2
    static let twoFingerDoubleTapWait: TimeInterval = 0.25
    /// A scroll's speed at the lift is measured over this long.
    static let releaseWindow: TimeInterval = 0.1
    /// Click and drag with a resting finger: it lands at least this long before the other
    /// finger (fingers landing together are a scroll or a pinch), moves at most `restSlop`
    /// while the other one goes `dragSlop`.
    static let restLead: TimeInterval = 0.1
    static let restSlop: CGFloat = 4
    static let dragSlop: CGFloat = 12

    private struct Finger {
        var start: CGPoint
        var startTime: TimeInterval
        var previous: CGPoint
        var last: CGPoint
        var lastTime: TimeInterval
        /// Since the move before.
        var interval: TimeInterval = 0
        var startDesktop: CGPoint?
        var desktop: CGPoint?
    }

    private enum Phase {
        case idle, one, two, three, ignored
    }

    private enum TwoFingerKind {
        /// drag: the first finger rests, the second moves the pointer with the left button down.
        case undecided, scroll, zoom, drag
    }

    private var fingers: [ObjectIdentifier: Finger] = [:]
    /// The order fingers went down in.
    private var order: [ObjectIdentifier] = []
    private var phase = Phase.idle
    private var peak = 0
    private var gestureStart: TimeInterval = 0
    private var mode = PointerMode.trackpad
    private var onTrackpadArea = false
    /// Fingers have started to lift: the rest of the gesture doesn't move anything.
    private var lifting = false

    // One finger
    private var moved = false
    /// The left button is held by this gesture (a drag, with one finger or with a resting one).
    private var dragging = false
    private var longPressFired = false
    private var longPressTimer: DispatchWorkItem?
    /// Trackpad: a tap's left button is down until this fires, so a touch that comes
    /// soon enough can turn it into a drag or a double click.
    private var pendingRelease: DispatchWorkItem?
    /// The left button is down from a tap (released by pendingRelease, or handed to the next touch).
    private var tapButtonDown = false
    private var tapThenTouch = false
    /// Direct: where the last tap lifted, so a double tap clicks the same spot.
    private var lastTapUp: (time: TimeInterval, desktop: CGPoint)?

    // Two fingers
    private var twoKind = TwoFingerKind.undecided
    private var twoStartCentroid = CGPoint.zero
    private var twoLastCentroid = CGPoint.zero
    private var twoStartSpread: CGFloat = 0
    private var twoLastSpread: CGFloat = 0
    private var twoMaxTravel: CGFloat = 0
    /// The scroll's recent centroids (the last `releaseWindow`), for its speed at the lift.
    private var scrollTrail: [(time: TimeInterval, centroid: CGPoint)] = []
    private var lastScrollTime: TimeInterval = 0
    private var pendingRightClick: DispatchWorkItem?
    /// Trackpad: the first finger rested until the second landed (`restLead` before), so this
    /// can be a click and drag; where it was then.
    private var restingFinger: CGPoint?
    /// The last two-finger gesture, for the demo desktop's state line (UI tests): its kind and
    /// how long the first finger was down before the second landed.
    private(set) var lastTwoFinger = "none"
    private var twoLead: TimeInterval = 0

    // Three fingers
    private var threeStartCentroid = CGPoint.zero
    private var threeLastCentroid = CGPoint.zero
    private var threeMoved = false

    // MARK: Touches

    func began(_ samples: [TouchSample], onTrackpadArea area: Bool) {
        guard let delegate else { return }
        let newGesture = phase == .idle
        for sample in samples where fingers[sample.id] == nil {
            fingers[sample.id] = Finger(start: sample.location, startTime: sample.time, previous: sample.location, last: sample.location,
                                        lastTime: sample.time, startDesktop: sample.desktop, desktop: sample.desktop)
            order.append(sample.id)
        }
        let time = samples.first?.time ?? 0
        if newGesture {
            delegate.stopMomentum()
            gestureStart = time
            peak = 0
            moved = false
            dragging = false
            longPressFired = false
            lifting = false
            onTrackpadArea = area
            mode = delegate.pointerMode(onTrackpadArea: area)
        }
        peak = max(peak, fingers.count)
        guard !lifting else { return }

        switch fingers.count {
        case 1 where newGesture:
            beginOne(time: time)
        case 2:
            // A drag keeps going with its one finger; other fingers don't count. A drag with a
            // resting finger: the finger landing again carries on moving the pointer
            guard !dragging else { return }
            beginTwo(time: time)
        case 3:
            guard !dragging else { return }
            beginThree()
        default:
            if fingers.count > 3 && !dragging {
                cancelTimers()
                phase = .ignored
            }
        }
    }

    func moved(_ samples: [TouchSample]) {
        for sample in samples {
            guard var finger = fingers[sample.id] else { continue }
            finger.previous = finger.last
            finger.last = sample.location
            finger.desktop = sample.desktop
            finger.interval = sample.time - finger.lastTime
            finger.lastTime = sample.time
            fingers[sample.id] = finger
            if phase == .one, sample.id == order.first {
                movedOne(finger, interval: finger.interval)
            }
        }
        guard !lifting else { return }
        let time = samples.first?.time ?? 0
        switch phase {
        case .two: movedTwo(time: time)
        case .three: movedThree()
        default: break
        }
    }

    func ended(_ samples: [TouchSample]) {
        // A touch that lifts the instant it landed, beside other fingers, never was: no finger
        // can, but XCTest's synthesizer adds one at the start for each finger that lands later
        if !samples.isEmpty, fingers.count > samples.count,
           samples.allSatisfy({ sample in fingers[sample.id].map { $0.startTime == sample.time && $0.start == $0.last } ?? false }) {
            for sample in samples { remove(sample.id) }
            peak = fingers.count
            if fingers.count == 1, phase == .two, twoKind == .undecided {
                // Back to the one finger it was, its hold timed from its landing
                phase = .one
                if mode == .direct || !tapThenTouch { scheduleLongPress() }
            }
            return
        }
        let primaryLifted = samples.contains { $0.id == order.first }
        for sample in samples {
            if var finger = fingers[sample.id] {
                finger.last = sample.location
                fingers[sample.id] = finger
            }
        }
        if fingers.count > samples.count {
            if phase == .two && twoKind == .drag && !primaryLifted {
                // The moving finger lifted, the resting one is still down: the button stays
                // down for the next finger to carry on
                for sample in samples { remove(sample.id) }
                return
            }
            if (phase == .one || (phase == .two && twoKind == .drag)) && primaryLifted {
                // The dragging (or resting) finger lifted and others are still down: the drag is over
                finish(time: samples.first?.time ?? 0)
                phase = .ignored
            }
            lifting = phase != .one
            for sample in samples { remove(sample.id) }
            return
        }
        finish(time: samples.first?.time ?? 0)
        for sample in samples { remove(sample.id) }
        fingers.removeAll()
        order.removeAll()
        phase = .idle
    }

    func cancelled() {
        cancelTimers()
        pendingRightClick?.cancel()
        pendingRightClick = nil
        if dragging {
            delegate?.setButton(.left, down: false)
            dragging = false
        }
        flushPendingRelease()
        fingers.removeAll()
        order.removeAll()
        phase = .idle
    }

    private func remove(_ id: ObjectIdentifier) {
        fingers[id] = nil
        order.removeAll { $0 == id }
    }

    // MARK: One finger

    private func beginOne(time: TimeInterval) {
        phase = .one
        tapThenTouch = false
        guard let delegate, let finger = order.first.flatMap({ fingers[$0] }) else { return }
        switch mode {
        case .trackpad:
            if tapButtonDown {
                // Touching again right after a tap: a drag or a double click. The tap's button
                // stays down until this touch decides
                pendingRelease?.cancel()
                pendingRelease = nil
                tapThenTouch = true
            } else {
                scheduleLongPress()
            }
        case .direct:
            if let desktop = finger.startDesktop {
                // Within a double tap's reach of the last tap, click the same spot
                if let last = lastTapUp, time - last.time < 0.3, hypot(desktop.x - last.desktop.x, desktop.y - last.desktop.y) < 0.03 {
                    fingers[order[0]]?.startDesktop = last.desktop
                } else {
                    delegate.movePointer(to: desktop)
                }
            }
            scheduleLongPress()
        }
    }

    private func movedOne(_ finger: Finger, interval: TimeInterval) {
        guard let delegate, !lifting || dragging else { return }
        if !moved && hypot(finger.last.x - finger.start.x, finger.last.y - finger.start.y) > Self.slop {
            moved = true
            flushPendingRightClick()
            longPressTimer?.cancel()
            longPressTimer = nil
        }
        guard moved else { return }
        switch mode {
        case .trackpad:
            if tapThenTouch && !dragging {
                // The tap's button is still down: keep it down and drag
                tapButtonDown = false
                dragging = true
                delegate.haptic(.light)
            } else if longPressFired && !dragging {
                delegate.setButton(.left, down: true)
                dragging = true
            }
            delegate.movePointer(by: CGVector(dx: finger.last.x - finger.previous.x, dy: finger.last.y - finger.previous.y),
                                 interval: interval)
        case .direct:
            guard !longPressFired else { return }
            if !dragging {
                delegate.setButton(.left, down: true)
                dragging = true
            }
            if let desktop = finger.desktop {
                delegate.movePointer(to: desktop)
            }
        }
    }

    private func scheduleLongPress() {
        longPressTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .one, !self.moved else { return }
            self.flushPendingRightClick()
            self.longPressFired = true
            self.delegate?.haptic(.medium)
            if self.mode == .direct {
                self.delegate?.click(.right)
            }
        }
        longPressTimer = work
        schedule(Self.longPressDelay, work)
    }

    private func finishOne(time: TimeInterval) {
        guard let delegate else { return }
        flushPendingRightClick()
        longPressTimer?.cancel()
        longPressTimer = nil
        let duration = time - gestureStart
        switch mode {
        case .trackpad:
            if dragging {
                delegate.setButton(.left, down: false)
            } else if tapThenTouch {
                // A second tap (a double click), or a touch held without moving
                flushPendingRelease()
                if !moved && duration < Self.tapDuration {
                    delegate.click(.left)
                    delegate.haptic(.light)
                }
            } else if longPressFired && !moved {
                delegate.click(.right)
            } else if !moved && duration < Self.tapDuration {
                delegate.setButton(.left, down: true)
                delegate.haptic(.light)
                tapButtonDown = true
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.tapButtonDown else { return }
                    self.pendingRelease = nil
                    self.tapButtonDown = false
                    self.delegate?.setButton(.left, down: false)
                }
                pendingRelease = work
                schedule(Self.tapReleaseDelay, work)
            }
        case .direct:
            if dragging {
                delegate.setButton(.left, down: false)
            } else if !longPressFired && !moved {
                delegate.click(.left)
                delegate.haptic(.light)
                if let desktop = order.first.flatMap({ fingers[$0]?.startDesktop }) {
                    lastTapUp = (time, desktop)
                }
            }
        }
        dragging = false
        tapThenTouch = false
    }

    /// A two-finger tap's right click that was waiting for a second tap: the next gesture is
    /// something else, so it happens now, before what that gesture does.
    private func flushPendingRightClick() {
        guard let pending = pendingRightClick else { return }
        pending.cancel()
        pendingRightClick = nil
        rightClick?()
        rightClick = nil
    }

    private var rightClick: (() -> Void)?

    private func flushPendingRelease() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard tapButtonDown else { return }
        tapButtonDown = false
        delegate?.setButton(.left, down: false)
    }

    // MARK: Two fingers

    private func twoFingers() -> (CGPoint, CGPoint)? {
        let ids = order.prefix(2)
        guard ids.count == 2, let a = fingers[ids.first!], let b = fingers[ids.last!] else { return nil }
        return (a.last, b.last)
    }

    private func beginTwo(time: TimeInterval) {
        // A second finger comes before the hold's right click (which happens only on the lift
        // of a finger held alone)
        longPressTimer?.cancel()
        longPressTimer = nil
        restingFinger = nil
        twoLead = order.first.flatMap { fingers[$0] }.map { time - $0.startTime } ?? 0
        if mode == .trackpad, !moved, let first = order.first.flatMap({ fingers[$0] }),
           time - first.startTime >= Self.restLead,
           hypot(first.last.x - first.start.x, first.last.y - first.start.y) <= Self.slop {
            restingFinger = first.last
        }
        if tapThenTouch {
            flushPendingRelease()
            tapThenTouch = false
        }
        phase = .two
        twoKind = .undecided
        twoMaxTravel = 0
        scrollTrail = []
        guard let (a, b) = twoFingers() else { return }
        twoStartCentroid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        twoLastCentroid = twoStartCentroid
        twoStartSpread = hypot(a.x - b.x, a.y - b.y)
        twoLastSpread = twoStartSpread
    }

    private func movedTwo(time: TimeInterval) {
        guard let delegate, let (a, b) = twoFingers() else { return }
        let centroid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let spread = hypot(a.x - b.x, a.y - b.y)
        for id in order.prefix(2) {
            if let finger = fingers[id] {
                twoMaxTravel = max(twoMaxTravel, hypot(finger.last.x - finger.start.x, finger.last.y - finger.start.y))
            }
        }
        if twoKind == .undecided, let rest = restingFinger, let mover = order.dropFirst().first.flatMap({ fingers[$0] }),
           hypot(a.x - rest.x, a.y - rest.y) <= Self.restSlop {
            // The first finger rests: the other one's first points decide nothing (not a
            // pinch, not a scroll); past them it's a click and drag
            guard hypot(mover.last.x - mover.start.x, mover.last.y - mover.start.y) > Self.dragSlop else { return }
            twoKind = .drag
            dragging = true
            delegate.setButton(.left, down: true)
            delegate.haptic(.light)
        }
        if twoKind == .undecided {
            let travel = hypot(centroid.x - twoStartCentroid.x, centroid.y - twoStartCentroid.y)
            let spreadChange = abs(spread - twoStartSpread)
            if spreadChange > 16 && spreadChange > travel * 0.8 {
                twoKind = .zoom
            } else if travel > 10 {
                twoKind = .scroll
                lastScrollTime = time
                scrollTrail = [(time, twoLastCentroid)]
            } else {
                return
            }
        }
        switch twoKind {
        case .scroll:
            let delta = CGVector(dx: centroid.x - twoLastCentroid.x, dy: centroid.y - twoLastCentroid.y)
            delegate.scroll(by: delta)
            lastScrollTime = time
            scrollTrail.append((time, centroid))
            // Keep one sample from before the window, so the window is always covered
            while scrollTrail.count > 2 && scrollTrail[1].time <= time - Self.releaseWindow {
                scrollTrail.removeFirst()
            }
        case .zoom:
            if twoLastSpread > 1 {
                delegate.zoom(by: spread / twoLastSpread, around: centroid)
            }
            delegate.pan(by: CGVector(dx: centroid.x - twoLastCentroid.x, dy: centroid.y - twoLastCentroid.y))
        case .drag:
            // The pointer follows the moving finger, as one finger moves it
            if let mover = order.dropFirst().first.flatMap({ fingers[$0] }), mover.last != mover.previous {
                delegate.movePointer(by: CGVector(dx: mover.last.x - mover.previous.x, dy: mover.last.y - mover.previous.y),
                                     interval: mover.interval)
            }
        case .undecided:
            break
        }
        twoLastCentroid = centroid
        twoLastSpread = spread
    }

    private func finishTwo(time: TimeInterval) {
        guard let delegate else { return }
        let duration = time - gestureStart
        lastTwoFinger = String(format: "%@ lead %.2f%@", "\(twoKind)", twoLead, restingFinger == nil ? "" : " resting")
        switch twoKind {
        case .undecided where peak == 2 && duration < Self.tapDuration && twoMaxTravel < Self.slop * 1.5:
            twoFingerTap(at: twoStartCentroid)
        case .drag:
            delegate.setButton(.left, down: false)
            dragging = false
        case .scroll:
            // Only if the fingers were still moving when they lifted, and the way they went
            if time - lastScrollTime < 0.08, let velocity = releaseVelocity(at: time), hypot(velocity.dx, velocity.dy) > 150 {
                delegate.startMomentum(velocity: velocity)
            }
        default:
            break
        }
    }

    /// How far the fingers went over the last `releaseWindow` before the lift, per second: a
    /// real finger's contact rolls back a few points as it comes off the glass, which as one
    /// frame's speed (120 a second) is a fast swipe the other way. Nothing when that leaves
    /// them going against the scroll they made.
    private func releaseVelocity(at time: TimeInterval) -> CGVector? {
        guard let last = scrollTrail.last,
              let first = scrollTrail.last(where: { $0.time <= time - Self.releaseWindow }) ?? scrollTrail.first,
              time - first.time > 0 else { return nil }
        let velocity = CGVector(dx: (last.centroid.x - first.centroid.x) / (time - first.time),
                                dy: (last.centroid.y - first.centroid.y) / (time - first.time))
        let travel = CGVector(dx: last.centroid.x - twoStartCentroid.x, dy: last.centroid.y - twoStartCentroid.y)
        guard velocity.dx * travel.dx + velocity.dy * travel.dy > 0 else { return nil }
        return velocity
    }

    private func twoFingerTap(at location: CGPoint) {
        guard let delegate else { return }
        if let pending = pendingRightClick {
            // A two-finger double tap: reset the zoom instead of right-clicking
            pending.cancel()
            pendingRightClick = nil
            rightClick = nil
            delegate.resetZoom()
            delegate.haptic(.medium)
            return
        }
        let click = { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            if self.mode == .direct, let desktop = delegate.desktopPoint(at: location) {
                delegate.movePointer(to: desktop)
            }
            delegate.click(.right)
            delegate.haptic(.medium)
        }
        if delegate.isZoomed {
            rightClick = click
            let work = DispatchWorkItem { [weak self] in
                self?.pendingRightClick = nil
                self?.rightClick = nil
                click()
            }
            pendingRightClick = work
            schedule(Self.twoFingerDoubleTapWait, work)
        } else {
            click()
        }
    }

    // MARK: Three fingers

    private func threeCentroid() -> CGPoint {
        let points = order.prefix(3).compactMap { fingers[$0]?.last }
        guard !points.isEmpty else { return .zero }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    private func beginThree() {
        longPressTimer?.cancel()
        longPressTimer = nil
        phase = .three
        threeMoved = false
        threeStartCentroid = threeCentroid()
        threeLastCentroid = threeStartCentroid
    }

    private func movedThree() {
        let centroid = threeCentroid()
        if !threeMoved && hypot(centroid.x - threeStartCentroid.x, centroid.y - threeStartCentroid.y) > 12 {
            threeMoved = true
        }
        if threeMoved {
            delegate?.pan(by: CGVector(dx: centroid.x - threeLastCentroid.x, dy: centroid.y - threeLastCentroid.y))
        }
        threeLastCentroid = centroid
    }

    // MARK: End of a gesture

    private func finish(time: TimeInterval) {
        switch phase {
        case .one: finishOne(time: time)
        case .two: finishTwo(time: time)
        case .three:
            if !threeMoved && peak == 3 && time - gestureStart < Self.tapDuration {
                delegate?.toggleKeyboard()
            }
        case .idle, .ignored:
            break
        }
    }

    private func cancelTimers() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }
}
