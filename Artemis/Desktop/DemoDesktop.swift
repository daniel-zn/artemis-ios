//
//  DemoDesktop.swift
//  Artemis
//
//  The demo mode's connected screen (-ArtemisDemo YES): a drawn 1920×1080 desktop instead
//  of a stream, with the real controls, recording the input they produce for the UI tests
//  and screenshots.
//

import GameController
import QuartzCore
import UIKit

final class DemoDesktopViewController: UIViewController {
    private let appName: String
    private let onExit: () -> Void
    private let input = RecordingDesktopInput()
    private var desktop: DesktopViewController!

    init(appName: String, onExit: @escaping () -> Void) {
        self.appName = appName
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let picture = DemoDesktopView(image: Self.desktopImage)
        desktop = DesktopViewController(contentView: picture, streamSize: CGSize(width: 1920, height: 1080),
                                        input: input, title: appName, localCursor: true)
        picture.touchHandler = desktop.touchHandler
        desktop.recordedEvents = { [weak self] in self?.input.events ?? [] }
        input.onChange = { [weak self] in self?.desktop.updateAccessibilityValue() }
        desktop.onDisconnect = { [weak self] in
            guard let self else { return }
            self.controllerScript?.stop()
            let onExit = self.onExit
            self.presentingViewController?.dismiss(animated: true) { onExit() }
        }
        addChild(desktop)
        desktop.view.frame = view.bounds
        desktop.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(desktop.view)
        desktop.didMove(toParent: self)
    }

    private var ranGamepadScript = false
    private var controllerScript: DemoControllerScript?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        // The clipboard for Type Clipboard in the UI tests (-ArtemisDemoClipboard "<text>"): the test
        // runner, in the background, can't write it
        if let text = UserDefaults.standard.string(forKey: "ArtemisDemoClipboard") {
            UIPasteboard.general.string = text
        }
        // A connected controller for the UI tests (-ArtemisDemoController "<steps>"), see DemoControllerScript
        if controllerScript == nil, let script = UserDefaults.standard.string(forKey: "ArtemisDemoController") {
            controllerScript = DemoControllerScript(mouse: desktop.gamepadMouse, input: input)
            controllerScript?.run(script)
        }
        // A controller for the UI tests (-ArtemisDemoGamepad "<steps>"), see DemoGamepadScript
        guard !ranGamepadScript, let script = UserDefaults.standard.string(forKey: "ArtemisDemoGamepad") else { return }
        ranGamepadScript = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            DemoGamepadScript(mouse: self.desktop.gamepadMouse, input: self.input).run(script)
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var childForHomeIndicatorAutoHidden: UIViewController? { desktop }
    // As StreamFrameViewController: a first swipe from any edge only shows the system's tab
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    /// A Windows-like desktop: wallpaper, icons, an editor window and the taskbar.
    static let desktopImage: UIImage = {
        let size = CGSize(width: 1920, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.05, green: 0.18, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.28, green: 0.55, blue: 0.85, alpha: 1).cgColor,
                          UIColor(red: 0.85, green: 0.62, blue: 0.75, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1])!
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])

            func text(_ string: String, _ point: CGPoint, size: CGFloat, color: UIColor = .white, weight: UIFont.Weight = .regular) {
                (string as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            }

            // Desktop icons
            let icons = ["Recycle Bin", "This PC", "Projects", "Blender", "Steam"]
            for (index, name) in icons.enumerated() {
                let origin = CGPoint(x: 40, y: 40 + CGFloat(index) * 130)
                UIColor.white.withAlphaComponent(0.85).setFill()
                UIBezierPath(roundedRect: CGRect(x: origin.x + 18, y: origin.y, width: 64, height: 64), cornerRadius: 12).fill()
                text(name, CGPoint(x: origin.x, y: origin.y + 72), size: 18)
            }

            // A text editor window
            let window = CGRect(x: 420, y: 140, width: 1080, height: 660)
            cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 40, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor(white: 0.98, alpha: 1).setFill()
            UIBezierPath(roundedRect: window, cornerRadius: 10).fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(white: 0.93, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 52), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 10, height: 10)).fill()
            text("notes.txt – Notepad", CGPoint(x: window.minX + 20, y: window.minY + 14), size: 20, color: .darkGray)
            for (index, glyph) in ["–", "□", "✕"].enumerated() {
                text(glyph, CGPoint(x: window.maxX - 150 + CGFloat(index) * 50, y: window.minY + 12), size: 22, color: .darkGray)
            }
            let lines = [
                "Artemis demo desktop",
                "",
                "Trackpad: drag one finger to move the pointer, tap to click.",
                "Two fingers: tap to right-click, drag to scroll, pinch to zoom.",
                "Three fingers: tap for the keyboard.",
                "",
                "The quick brown fox jumps over the lazy dog. 0123456789",
            ]
            for (index, line) in lines.enumerated() {
                text(line, CGPoint(x: window.minX + 32, y: window.minY + 84 + CGFloat(index) * 40), size: 26,
                     color: UIColor(white: 0.15, alpha: 1), weight: index == 0 ? .semibold : .regular)
            }

            // Taskbar
            UIColor(white: 0.1, alpha: 0.88).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: size.height - 60, width: size.width, height: 60)).fill()
            for index in 0..<6 {
                let colorsBar: [UIColor] = [.systemBlue, .systemYellow, .systemGreen, .systemOrange, .systemPurple, .systemTeal]
                colorsBar[index].setFill()
                UIBezierPath(roundedRect: CGRect(x: 760 + CGFloat(index) * 66, y: size.height - 48, width: 36, height: 36), cornerRadius: 8).fill()
            }
            text("12:00", CGPoint(x: size.width - 110, y: size.height - 44), size: 22)
        }
    }()
}

/// The demo's desktop picture; hands its touches to the desktop controls, as StreamView does.
final class DemoDesktopView: UIImageView {
    weak var touchHandler: DesktopTouchHandler?

    override init(image: UIImage?) {
        super.init(image: image)
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true
        contentMode = .scaleAspectFit
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesCancelled(touches, with: event) }
}

/// Plays a controller into the gamepad mouse for the UI tests, on a clock of its own: the
/// states ControllerSupport would pass it, with the pointer moving at 60 ticks a second.
/// States that would go to the PC as a gamepad are recorded as "pad <buttons>".
///
/// Steps, separated by ";": `press a` (0.05 s), `hold start 0.8`, `left 1 0 0.25` (the left
/// stick at x 1, y 0 for 0.25 s, then centred), `right 0 1 0.25`, `wait 0.2`, `down start` /
/// `up start` (a button down or up, for combos).
/// Buttons: a b x y lb rb start back up down left right.
final class DemoGamepadScript {
    private let mouse: GamepadMouse
    private let input: RecordingDesktopInput
    private final class Clock {
        var time: TimeInterval
        init(time: TimeInterval) { self.time = time }
    }
    private var clock: Clock?
    private var time: TimeInterval = 1000
    private var buttons: UInt32 = 0
    private var left = (x: Int16(0), y: Int16(0))
    private var right = (x: Int16(0), y: Int16(0))

    private static let flags: [String: Int32] = [
        "a": A_FLAG, "b": B_FLAG, "x": X_FLAG, "y": Y_FLAG, "lb": LB_FLAG, "rb": RB_FLAG,
        "start": PLAY_FLAG, "back": BACK_FLAG, "up": UP_FLAG, "down": DOWN_FLAG, "left": LEFT_FLAG, "right": RIGHT_FLAG,
    ]

    init(mouse: GamepadMouse, input: RecordingDesktopInput) {
        self.mouse = mouse
        self.input = input
    }

    func run(_ script: String) {
        // This script's clock and ticks, and its events in order; back to the real ones after
        let clock = Clock(time: time)
        self.clock = clock
        mouse.drivesItself = false
        mouse.now = { clock.time }
        mouse.deliver = { $0() }
        defer {
            mouse.drivesItself = true
            mouse.now = { CACurrentMediaTime() }
            mouse.deliver = { DispatchQueue.main.async(execute: $0) }
        }
        for step in script.split(separator: ";") {
            let words = step.split(separator: " ").map(String.init)
            guard let verb = words.first else { continue }
            let number = { (index: Int) in words.count > index ? Double(words[index]) ?? 0 : 0 }
            switch verb {
            case "press", "hold":
                guard words.count > 1, let flag = Self.flags[words[1]] else { continue }
                buttons |= UInt32(flag)
                send()
                advance(verb == "press" ? 0.05 : number(2))
                buttons &= ~UInt32(flag)
                send()
            case "down", "up":
                guard words.count > 1, let flag = Self.flags[words[1]] else { continue }
                if verb == "down" { buttons |= UInt32(flag) } else { buttons &= ~UInt32(flag) }
                send()
            case "left", "right":
                let stick = (x: Self.axis(number(1)), y: Self.axis(number(2)))
                if verb == "left" { left = stick } else { right = stick }
                send()
                advance(number(3))
                if verb == "left" { left = (0, 0) } else { right = (0, 0) }
                send()
            case "wait":
                advance(number(1))
            default:
                continue
            }
        }
    }

    private static func axis(_ value: Double) -> Int16 {
        Int16(max(-1, min(1, value)) * 32766)
    }

    private func send() {
        let result = mouse.filterController(0, buttons: buttons, leftStickX: left.x, leftStickY: left.y,
                                            rightStickX: right.x, rightStickY: right.y)
        switch result {
        case .send: input.note(String(format: "pad 0x%04X", buttons))
        case .sendNeutral: input.note("pad 0x0000")
        default: break
        }
    }

    private func advance(_ seconds: TimeInterval) {
        let tick = 1.0 / 60
        var elapsed = 0.0
        while elapsed + tick / 2 < seconds {
            time += tick
            clock?.time = time
            elapsed += tick
            mouse.tick(tick)
        }
    }
}

/// A connected controller for the UI tests, end to end: a GCVirtualController that a script
/// presses, which ControllerSupport reads like any controller (its callbacks, its button mapping,
/// the gamepad mouse) and whose arrival and states go to the demo's record ("arrival <n> 0x…",
/// "pad 0x…") instead of to a PC. Mouse input from the gamepad mouse is recorded as usual.
///
/// Steps, separated by ";": `press options` (0.1 s), `hold menu 0.8`, `down a` / `up a`,
/// `left 1 0 0.3` (the left stick at x 1, y 0 for 0.3 s, then centred), `wait 0.2`.
/// Buttons: a b x y lb rb menu options l3 r3.
final class DemoControllerScript: NSObject, ControllerSupportDelegate {
    private let mouse: GamepadMouse
    private let input: RecordingDesktopInput
    private var virtual: GCVirtualController?
    private var support: ControllerSupport?

    private static let buttons: [String: String] = [
        "a": GCInputButtonA, "b": GCInputButtonB, "x": GCInputButtonX, "y": GCInputButtonY,
        "lb": GCInputLeftShoulder, "rb": GCInputRightShoulder, "menu": GCInputButtonMenu,
        "options": GCInputButtonOptions,
        "l3": GCInputLeftThumbstickButton, "r3": GCInputRightThumbstickButton,
    ]

    init(mouse: GamepadMouse, input: RecordingDesktopInput) {
        self.mouse = mouse
        self.input = input
    }

    func run(_ script: String) {
        ControllerSupport.demoSink = { [weak input] event in
            if Thread.isMainThread {
                input?.note(event)
            } else {
                DispatchQueue.main.async { input?.note(event) }
            }
        }
        // As a session does (StreamFrameViewController): the controllers, then the gamepad mouse
        guard let support = ControllerSupport(config: StreamConfiguration(), delegate: self) else { return }
        support.gamepadFilter = mouse
        self.support = support
        let configuration = GCVirtualController.Configuration()
        // The touch controller has no Home button, and no D-pad next to a left stick
        configuration.elements = Set(Self.buttons.values + [GCInputLeftThumbstick, GCInputRightThumbstick,
                                                            GCInputLeftTrigger, GCInputRightTrigger])
        configuration.isHidden = true
        let virtual = GCVirtualController(configuration: configuration)
        self.virtual = virtual
        virtual.connect { [weak self] error in
            if let error {
                DispatchQueue.main.async { self?.input.note("controller error \(error.localizedDescription)") }
                return
            }
            // ControllerSupport takes it on the connect notification; the script starts after
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.input.note("controller ready")
                self?.play(script.split(separator: ";").map { $0.split(separator: " ").map(String.init) })
            }
        }
    }

    func stop() {
        virtual?.disconnect()
        virtual = nil
        support?.cleanup()
        support = nil
        ControllerSupport.demoSink = nil
    }

    private func play(_ steps: [[String]]) {
        guard let words = steps.first, let virtual else {
            input.note("controller done")
            return
        }
        let rest = Array(steps.dropFirst())
        let number = { (index: Int) in words.count > index ? Double(words[index]) ?? 0 : 0 }
        let next = { (delay: TimeInterval) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.play(rest) }
        }
        let button = words.count > 1 ? Self.buttons[words[1]] : nil
        switch words.first {
        case "press", "hold":
            guard let button else { return next(0) }
            virtual.setValue(1, forButtonElement: button)
            DispatchQueue.main.asyncAfter(deadline: .now() + (words[0] == "press" ? 0.1 : number(2))) { [weak self] in
                self?.virtual?.setValue(0, forButtonElement: button)
                next(0.15)
            }
        case "down", "up":
            guard let button else { return next(0) }
            virtual.setValue(words[0] == "down" ? 1 : 0, forButtonElement: button)
            next(0.15)
        case "left", "right":
            let stick = words[0] == "left" ? GCInputLeftThumbstick : GCInputRightThumbstick
            virtual.setPosition(CGPoint(x: number(1), y: number(2)), forDirectionPadElement: stick)
            DispatchQueue.main.asyncAfter(deadline: .now() + number(3)) { [weak self] in
                self?.virtual?.setPosition(.zero, forDirectionPadElement: stick)
                next(0.15)
            }
        case "wait":
            next(number(1))
        default:
            next(0)
        }
    }

    // MARK: ControllerSupportDelegate

    func gamepadPresenceChanged() {}
    func mousePresenceChanged() {}
    func streamExitRequested() {
        input.note("exit requested")
    }
}
