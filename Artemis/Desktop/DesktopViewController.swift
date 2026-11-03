//
//  DesktopViewController.swift
//  Artemis
//
//  The connected screen's controls around the desktop (docs/TOUCH.md): the desktop view
//  (upstream's StreamView, or the demo picture) in a zoomable canvas, the touch gestures,
//  the control bar, the keyboard with its key row, the trackpad area when upright, and the
//  on-screen controller.
//  StreamFrameViewController keeps the connection; this sends the input.
//

import GameController
import SwiftUI
import UIKit

@objc(DesktopViewController)
final class DesktopViewController: UIViewController {
    /// Disconnect from the control bar.
    @objc var onDisconnect: (() -> Void)?
    /// Receives the desktop view's finger touches (StreamView hands them over).
    @objc private(set) lazy var touchHandler = DesktopTouchHandler(controller: self)
    /// A game controller as the mouse (hold Start / Menu); ControllerSupport hands it each controller's state.
    @objc let gamepadMouse = GamepadMouse(enabled: AppPreferences.gamepadMouse)

    let session: DesktopSession
    private let input: DesktopInput
    private let contentView: UIView
    private let streamSize: CGSize
    private var pointerSettings = PointerSettings.load()

    private let canvas = DesktopCanvasView()
    private let trackpadArea = TrackpadAreaView()
    /// The on-screen controller: in the trackpad's place upright, over the desktop in landscape.
    private let gamepad = OnScreenGamepadView()
    private let keyCapture = KeyCaptureView()
    /// Upright: resets the zoom, on the desktop's corner (landscape has it in the bar).
    private let fitButton = UIButton(configuration: .glass())
    /// "Controller mouse on / off", for a moment.
    private let toast = UILabel()
    private let toastBackground = UIView()
    private var toastHide: DispatchWorkItem?
    /// Notices shown this session (for the UI tests: a notice is up for 2.5 s only).
    private var toastCount = 0
    /// The bar, placed by SwiftUI in a hosting view that covers the screen and never moves (moving
    /// the hosting view left SwiftUI's accessibility frames where the bar had been: VoiceOver and
    /// Switch Control went for the old spot). Touches outside the bar pass through.
    private let barPlacement = BarPlacement()
    private lazy var barHost = UIHostingController(rootView: PlacedControlBar(session: session, placement: barPlacement))
    private let barLayer = BarPassThroughView()
    /// Measures the bar (hidden: it follows the same traits, like the text size).
    private lazy var barSizer = UIHostingController(rootView: ControlBar(session: session))
    /// Set while a change of the bar's content is laid out: the bar moves and resizes animated.
    /// The bar's move while relayoutBar lays it out (nil: it jumps there).
    private var barAnimation: Animation?
    private let interpreter = TouchInterpreter()
    /// The demo draws its own pointer; a real stream shows the PC's.
    private let localCursor: UIImageView?

    // Zoom: the content's scale and its centre's offset from the canvas's centre
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero

    /// Where the pointer is on the desktop (0–1).
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var scrollRemainder = CGVector.zero
    private var momentumVelocity = CGVector.zero
    private var momentumLink: CADisplayLink?
    private var lastMomentumTime: CFTimeInterval = 0
    private var buttonModifiers: [MouseButton: [Modifier]] = [:]

    /// The floating bar's centre, as a fraction of the screen (landscape).
    private var barCenter: CGPoint
    /// Its centre while the controller is over the desktop (nil: top centre, between the controls).
    private var gamepadBarCenter: CGPoint?
    private var barDragStart: CGPoint?

    /// Called when the demo's recorded input or the view's state changes (UI tests).
    var recordedEvents: (() -> [String])?

    @objc init(contentView: UIView, streamSize: CGSize, input: DesktopInput, title: String, localCursor: Bool) {
        self.contentView = contentView
        self.streamSize = streamSize.width > 0 && streamSize.height > 0 ? streamSize : CGSize(width: 1920, height: 1080)
        self.input = input
        let absolute = (DataManager().getSettings()?.absoluteTouchMode) ?? false
        let pointer = PointerSettings.load()
        session = DesktopSession(title: title, mode: absolute ? .direct : .trackpad, barExpanded: pointer.showControlBar)
        let saved = UserDefaults.standard.string(forKey: "ArtemisBarCenter").map(NSCoder.cgPoint(for:))
        barCenter = saved ?? CGPoint(x: 0.5, y: 0.92)
        // Empty: not moved (the UI tests start each session with it so)
        gamepadBarCenter = UserDefaults.standard.string(forKey: "ArtemisGamepadBarCenter2").flatMap { $0.isEmpty ? nil : NSCoder.cgPoint(for: $0) }
        self.localCursor = localCursor ? UIImageView(image: DesktopViewController.cursorImage) : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        interpreter.delegate = self
        // The app opts into controller UI navigation (GCSupportsControllerUserInteraction): during
        // a session every controller button goes to ControllerSupport alone, none to UIKit (which
        // could take Select / Options or B for its own navigation)
        let controllerEvents = GCEventInteraction()
        controllerEvents.handledEventTypes = .gamepad
        controllerEvents.receivesEventsInView = false
        view.addInteraction(controllerEvents)

        canvas.backgroundColor = .black
        canvas.clipsToBounds = true
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = "Remote desktop"
        canvas.accessibilityTraits = .allowsDirectInteraction
        canvas.accessibilityIdentifier = "desktop"
        canvas.touchHandler = touchHandler
        // Under the desktop: upright, the desktop moves over it as it fades out or in
        trackpadArea.touchHandler = touchHandler
        view.addSubview(trackpadArea)
        view.addSubview(canvas)
        canvas.addSubview(contentView)
        if let localCursor {
            localCursor.isUserInteractionEnabled = false
            contentView.addSubview(localCursor)
        }

        var fit = UIButton.Configuration.glass()
        fit.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        fit.baseForegroundColor = .label
        fitButton.configuration = fit
        fitButton.accessibilityLabel = "Reset Zoom"
        fitButton.accessibilityIdentifier = "bar.resetZoom"
        fitButton.addAction(UIAction { [weak self] _ in self?.resetZoomAnimated() }, for: .primaryActionTriggered)
        fitButton.isHidden = true
        view.addSubview(fitButton)

        gamepad.isHidden = true
        gamepad.accessibilityIdentifier = "gamepad"
        gamepad.model.onChange = { [weak self] held in
            self?.input.gamepad(held.gamepadState)
            self?.updateAccessibilityValue()
        }
        addChild(gamepad.host)
        view.addSubview(gamepad)
        gamepad.host.didMove(toParent: self)

        keyCapture.onText = { [weak self] in self?.typed($0) }
        keyCapture.onDelete = { [weak self] in self?.sendKey(KeyCode.backspace) }
        keyCapture.onHardwareKey = { [weak self] press, down in
            guard self?.input is MoonlightDesktopInput else { return false }
            return KeyboardSupport.sendKeyEvent(for: press, down: down)
        }
        keyCapture.accessory = makeKeyRow()
        view.addSubview(keyCapture)


        // Placed by hand inside the safe area; and no keyboard avoidance, which moved and shrank
        // the bar's content when the keyboard came up over it
        barSizer.view.isHidden = true
        barSizer.view.accessibilityElementsHidden = true
        barSizer.sizingOptions = [.intrinsicContentSize]
        barSizer.safeAreaRegions = []
        addChild(barSizer)
        view.addSubview(barSizer.view)
        barSizer.didMove(toParent: self)
        barHost.view.backgroundColor = .clear
        barHost.safeAreaRegions = []
        barLayer.placement = barPlacement
        barLayer.frame = view.bounds
        barLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(barHost)
        barHost.view.frame = barLayer.bounds
        barHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        barLayer.addSubview(barHost.view)
        view.addSubview(barLayer)
        barHost.didMove(toParent: self)

        session.actions = makeActions()

        gamepadMouse.output = self
        gamepadMouse.speed = pointerSettings.pointerSpeed
        toast.font = ArtemisTypography.headlineFont()
        toast.textColor = .white
        toast.textAlignment = .center
        toast.numberOfLines = 0
        toast.adjustsFontForContentSizeCategory = true
        toast.accessibilityIdentifier = "desktop.toast"
        toastBackground.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        toastBackground.layer.cornerRadius = 18
        toastBackground.layer.cornerCurve = .continuous
        toastBackground.alpha = 0
        toastBackground.isUserInteractionEnabled = false
        toastBackground.addSubview(toast)
        view.addSubview(toastBackground)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(microphoneChanged), name: .artemisMicrophoneChanged, object: nil)
        microphoneChanged()
        center.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidShowNotification, object: nil)
        updateAccessibilityValue()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Hardware keyboards type into the desktop view (upstream's StreamView handles them)
        if !keyCapture.isFirstResponder {
            contentView.becomeFirstResponder()
        }
        updateAccessibilityValue()
    }

    deinit {
        momentumLink?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let insets = view.safeAreaInsets
        // The keyboard and its key row lie over the desktop: nothing here moves or shrinks for them
        let portrait = bounds.height > bounds.width
        if session.isPortrait != portrait {
            session.isPortrait = portrait
        }
        let barSize = barSizer.sizeThatFits(in: CGSize(width: portrait ? bounds.width : bounds.width - insets.left - insets.right,
                                                      height: bounds.height))
        let padSize = AppPreferences.onScreenGamepadSize
        if portrait {
            // The desktop across the top, the trackpad (or the controller) under it, the bar at the
            // bottom. In direct mode without the controller there's no trackpad: the desktop sits
            // in the middle between the top and the bar
            let aspect = streamSize.width / streamSize.height
            let barY = bounds.maxY - max(insets.bottom, 12) - barSize.height
            let available = max(120, barY - insets.top - 16)
            let height = min(bounds.width / aspect, available)
            let centred = session.mode == .direct && !session.gamepadShown
            let top = centred ? insets.top + max(0, barY - insets.top - height) / 2 : insets.top
            canvas.frame = CGRect(x: 0, y: top, width: bounds.width, height: height)
            placeBar(CGRect(x: (bounds.width - barSize.width) / 2, y: barY, width: barSize.width, height: barSize.height))
            let areaTop = insets.top + height + 10
            let areaBottom = barY - 10
            let area = CGRect(x: 12, y: areaTop, width: bounds.width - 24, height: max(0, areaBottom - areaTop))
            // Faded rather than hidden, so it goes and comes with the desktop's move
            trackpadArea.isHidden = area.height < 60 || session.gamepadShown
            trackpadArea.alpha = centred ? 0 : 1
            trackpadArea.accessibilityElementsHidden = centred
            trackpadArea.frame = area
            gamepad.frame = area
            gamepad.isHidden = !session.gamepadShown || area.height < 60
            gamepad.layout(area: gamepad.bounds, overDesktop: false, scale: padSize, opacity: AppPreferences.onScreenGamepadOpacity)
        } else {
            // Full screen; the controller lies over it, inside the safe area
            canvas.frame = bounds
            trackpadArea.isHidden = true
            gamepad.frame = bounds
            gamepad.isHidden = !session.gamepadShown
            // Inside the safe area and over the desktop's picture (not out on the black bars beside
            // it), a thumb's margin from the sides (more where there's no notch) and clear of the
            // home indicator
            let picture = videoRect(in: bounds.size)
            let left = max(insets.left + 8, picture.minX + 8, 16)
            let right = max(insets.right + 8, bounds.width - picture.maxX + 8, 16)
            let top = max(insets.top, 10), bottom = max(insets.bottom, 10)
            let area = CGRect(x: left, y: top, width: bounds.width - left - right, height: bounds.height - top - bottom)
            gamepad.layout(area: area, overDesktop: true, scale: padSize, opacity: AppPreferences.onScreenGamepadOpacity)
            let wanted = session.gamepadShown
                ? gamepadBarCenter ?? PadLayout.barCenter(area: area, bounds: bounds.size, barSize: barSize, scale: padSize)
                : barCenter
            let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation
            let housing: CGRectEdge? = insets.left < 1 && insets.right < 1 ? nil
                : orientation == .landscapeRight ? .minXEdge : orientation == .landscapeLeft ? .maxXEdge : nil
            let center = Self.barCenter(CGPoint(x: wanted.x * bounds.width, y: wanted.y * bounds.height), barSize: barSize,
                                        bounds: bounds.size, insets: insets, housing: housing)
            placeBar(CGRect(x: center.x - barSize.width / 2, y: center.y - barSize.height / 2,
                            width: barSize.width, height: barSize.height))
        }
        layoutContent()
        fitButton.frame = CGRect(x: canvas.frame.maxX - 52, y: canvas.frame.minY + 8, width: 44, height: 44)
        view.bringSubviewToFront(fitButton)
        // The notice: padded text in a dark rounded box near the desktop's top
        let padding = CGSize(width: 22, height: 14)
        let maxText = max(100, min(canvas.frame.width - 32, 420) - padding.width * 2)
        // The full width, centred: the typeface measures a little narrower than it draws
        let text = toast.sizeThatFits(CGSize(width: maxText, height: .greatestFiniteMagnitude))
        let textSize = CGSize(width: maxText, height: ceil(text.height))
        toastBackground.bounds = CGRect(x: 0, y: 0, width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        toastBackground.center = CGPoint(x: canvas.frame.midX,
                                         y: max(canvas.frame.minY, view.safeAreaInsets.top) + 12 + toastBackground.bounds.height / 2)
        toast.frame = CGRect(origin: CGPoint(x: padding.width, y: padding.height), size: textSize)
        view.bringSubviewToFront(toastBackground)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout(); self.view.layoutIfNeeded() },
                            completion: { _ in
                                // Turned over, the camera's side changed: the bar's limits with it
                                self.view.setNeedsLayout()
                                self.view.layoutIfNeeded()
                                self.updateAccessibilityValue()
                            })
    }

    /// Where the bar goes (in the view's coordinates); animated while its content changes.
    private func placeBar(_ frame: CGRect) {
        guard barPlacement.frame != frame else { return }
        if let barAnimation, barPlacement.frame != .zero {
            withAnimation(barAnimation) { barPlacement.frame = frame }
        } else {
            barPlacement.frame = frame
        }
    }

    /// The floating bar's margin from the screen's edges (landscape): a capsule or the round
    /// folded bar this far in stays clear of the screen's rounded corners.
    static let barEdgeMargin: CGFloat = 12
    /// Half the height beside the camera (the Dynamic Island or the notch) that the bar keeps
    /// out of, from the middle of that side.
    static let housingHalfHeight: CGFloat = 124

    /// Where the floating bar's centre goes for a wanted one: anywhere on the screen up to its
    /// edges (less `barEdgeMargin`), except beside the camera (`housing`: the side it's on in
    /// landscape), where the bar stays inside the safe area.
    static func barCenter(_ wanted: CGPoint, barSize: CGSize, bounds: CGSize, insets: UIEdgeInsets, housing: CGRectEdge?) -> CGPoint {
        let half = CGSize(width: barSize.width / 2, height: barSize.height / 2)
        let minY = barEdgeMargin + half.height, maxY = bounds.height - barEdgeMargin - half.height
        let y = min(max(wanted.y, minY), max(minY, maxY))
        let besideHousing = abs(y - bounds.height / 2) < half.height + housingHalfHeight
        let left = housing == .minXEdge && besideHousing ? max(insets.left, barEdgeMargin) : barEdgeMargin
        let right = housing == .maxXEdge && besideHousing ? max(insets.right, barEdgeMargin) : barEdgeMargin
        let minX = left + half.width, maxX = bounds.width - right - half.width
        // Too wide to fit (never in practice): centred between the limits
        let x = minX <= maxX ? min(max(wanted.x, minX), maxX) : (minX + maxX) / 2
        return CGPoint(x: x, y: y)
    }

    /// A mouse moved the pointer (StreamView): the trackpad continues from there.
    @objc func pointerMovedExternally(to normalized: CGPoint) {
        pointer = CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopMomentum()
        // A drag's button never stays down on the PC
        interpreter.cancelled()
        gamepadMouse.stop()
        setGamepad(false)
    }

    /// The desktop picture's frame in this view, for the connection status over it.
    @objc var canvasFrame: CGRect {
        canvas.frame
    }

    // MARK: Zoom

    /// The desktop's rectangle in the content view (letterboxed to the stream's shape).
    private func videoRect(in size: CGSize) -> CGRect {
        let aspect = streamSize.width / streamSize.height
        var video = CGSize(width: size.width, height: size.width / aspect)
        if video.height > size.height {
            video = CGSize(width: size.height * aspect, height: size.height)
        }
        return CGRect(x: (size.width - video.width) / 2, y: (size.height - video.height) / 2, width: video.width, height: video.height)
    }

    private func layoutContent() {
        let size = canvas.bounds.size
        contentView.transform = .identity
        contentView.bounds = CGRect(origin: .zero, size: size)
        clampOffset()
        contentView.center = CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
        contentView.transform = CGAffineTransform(scaleX: scale, y: scale)
        if let localCursor {
            let video = videoRect(in: size)
            let width = max(14, video.width * 0.018)
            localCursor.frame = CGRect(x: video.minX + pointer.x * video.width, y: video.minY + pointer.y * video.height,
                                       width: width, height: width * 1.5)
        }
        fitButton.isHidden = !(session.isPortrait && scale > 1.01)
        if abs(session.zoomScale - scale) > 0.001 {
            let wasZoomed = session.isZoomed
            session.zoomScale = scale
            if wasZoomed != session.isZoomed { relayoutBar() }
        }
        updateAccessibilityValue()
    }

    private func clampOffset() {
        let size = canvas.bounds.size
        let video = videoRect(in: size)
        let maxX = max(0, (video.width * scale - size.width) / 2)
        let maxY = max(0, (video.height * scale - size.height) / 2)
        offset.x = min(max(offset.x, -maxX), maxX)
        offset.y = min(max(offset.y, -maxY), maxY)
    }

    private func canvasPoint(_ location: CGPoint) -> CGPoint {
        view.convert(location, to: canvas)
    }

    private func resetZoomAnimated() {
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.scale = 1
            self.offset = .zero
            self.layoutContent()
        }
    }

    /// Trackpad: keeps the pointer in view while zoomed.
    private func followPointer() {
        guard scale > 1.01 else { return }
        let size = canvas.bounds.size
        let video = videoRect(in: size)
        let inContent = CGPoint(x: video.minX + pointer.x * video.width - size.width / 2,
                                y: video.minY + pointer.y * video.height - size.height / 2)
        let onScreen = CGPoint(x: size.width / 2 + offset.x + inContent.x * scale, y: size.height / 2 + offset.y + inContent.y * scale)
        let margin: CGFloat = 40
        if onScreen.x < margin { offset.x += margin - onScreen.x }
        if onScreen.x > size.width - margin { offset.x -= onScreen.x - (size.width - margin) }
        if onScreen.y < margin { offset.y += margin - onScreen.y }
        if onScreen.y > size.height - margin { offset.y -= onScreen.y - (size.height - margin) }
    }

    // MARK: Pointer and buttons

    private func sendPointer() {
        let x = Int((pointer.x * streamSize.width).rounded())
        let y = Int((pointer.y * streamSize.height).rounded())
        input.movePointer(x: min(x, Int(streamSize.width) - 1), y: min(y, Int(streamSize.height) - 1),
                          width: Int(streamSize.width), height: Int(streamSize.height))
    }

    private func pressModifiers(_ modifiers: [Modifier]) {
        var flags: UInt8 = 0
        for modifier in modifiers {
            flags |= modifier.flag
            input.setKey(modifier.keyCode, down: true, modifiers: flags)
        }
    }

    private func releaseModifiers(_ modifiers: [Modifier]) {
        var flags = modifiers.reduce(UInt8(0)) { $0 | $1.flag }
        for modifier in modifiers.reversed() {
            flags &= ~modifier.flag
            input.setKey(modifier.keyCode, down: false, modifiers: flags)
        }
    }

    /// A button, with the key row's held modifiers around it (Ctrl+click).
    func setButton(_ button: MouseButton, down: Bool) {
        if down {
            let modifiers = session.activeModifiers
            buttonModifiers[button] = modifiers
            pressModifiers(modifiers)
            input.setButton(button.moonlight, down: true)
        } else {
            input.setButton(button.moonlight, down: false)
            releaseModifiers(buttonModifiers[button] ?? [])
            buttonModifiers[button] = nil
            session.releaseLatchedModifiers()
        }
        updateAccessibilityValue()
    }

    // MARK: Keys

    private func sendKey(_ keyCode: UInt16) {
        input.keyStroke(keyCode, modifiers: session.activeModifierFlags, nonNormalized: false)
    }

    /// Text from the iOS keyboard, with the key row's held modifiers.
    private func typed(_ text: String) {
        type(text, modifiers: session.activeModifierFlags)
        session.releaseLatchedModifiers()
        updateAccessibilityValue()
    }

    /// Characters as key strokes where a US layout has a key for them (Shift for capitals and
    /// shifted punctuation): Windows' sign-in screen, UAC and Ctrl+Alt+Del screens take only
    /// keys, not Unicode text. The rest (accents, emoji) goes as Unicode text.
    private func type(_ text: String, modifiers: UInt8) {
        var unicode = ""
        func flush() {
            if !unicode.isEmpty { input.text(unicode) }
            unicode = ""
        }
        for character in text {
            if character.isNewline {
                flush()
                input.keyStroke(KeyCode.enter, modifiers: modifiers, nonNormalized: false)
                continue
            }
            let units = Array(String(character).utf16)
            if units.count == 1 {
                let event = KeyboardSupport.translateKeyEvent(units[0], with: [])
                if event.keycode != 0 {
                    flush()
                    input.keyStroke(event.keycode, modifiers: modifiers | event.modifier, nonNormalized: true)
                    continue
                }
            }
            unicode.append(character)
        }
        flush()
    }

    private func setKeyboard(_ shown: Bool) {
        if shown {
            keyCapture.becomeFirstResponder()
        } else {
            keyCapture.resignFirstResponder()
            contentView.becomeFirstResponder()
        }
        session.keyboardShown = shown
        relayoutBar()
        updateAccessibilityValue()
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        let shown = keyCapture.isFirstResponder
        // Closed with the key row's hide button: hardware keyboards type into the desktop again
        if !shown && notification.name == UIResponder.keyboardDidHideNotification && view.window != nil && !contentView.isFirstResponder {
            contentView.becomeFirstResponder()
        }
        if session.keyboardShown != shown {
            session.keyboardShown = shown
            relayoutBar()
            updateAccessibilityValue()
        }
    }

    private func makeKeyRow() -> UIView {
        let row = KeyRowView(session: session)
        row.onHighlightChange = { [weak self] in self?.updateAccessibilityValue() }
        row.onHide = { [weak self] in self?.setKeyboard(false) }
        keyRow = row
        return row
    }

    private var keyRow: KeyRowView?

    // MARK: On-screen controller

    /// Shows the controller (the PC gets an Xbox controller, at rest) or hides it (everything
    /// comes up, then the controller goes away on the PC). Each session starts with it hidden.
    private func setGamepad(_ shown: Bool) {
        guard session.gamepadShown != shown else { return }
        if shown {
            session.gamepadShown = true
            input.gamepadConnect()
            input.gamepad(PadHeld.idle.gamepadState)
        } else {
            gamepad.releaseAll()
            session.gamepadShown = false
            input.gamepadDisconnect()
        }
        layoutAnimated()
        relayoutBar()
        updateAccessibilityValue()
    }

    /// Lays the screen out again, animated: upright, the desktop moves when the trackpad goes or
    /// comes back (direct mode, the controller).
    private func layoutAnimated() {
        view.setNeedsLayout()
        UIView.animate(springDuration: 0.4, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: Control bar

    /// Sizes the bar again after its content changed. SwiftUI updates the content on its next
    /// pass, so it's measured again then too.
    private func relayoutBar(animation: Animation = .snappy(duration: 0.25)) {
        let layout = { [weak self] in
            guard let self else { return }
            self.barSizer.view.invalidateIntrinsicContentSize()
            self.view.setNeedsLayout()
            self.barAnimation = animation
            self.view.layoutIfNeeded()
            self.barAnimation = nil
            self.updateAccessibilityValue()
        }
        layout()
        DispatchQueue.main.async(execute: layout)
    }

    private func makeActions() -> DesktopSession.Actions {
        var actions = DesktopSession.Actions()
        actions.toggleKeyboard = { [weak self] in
            guard let self else { return }
            self.setKeyboard(!self.session.keyboardShown)
        }
        actions.setMode = { [weak self] mode in
            self?.session.mode = mode
            self?.haptic(.light)
            self?.layoutAnimated()
            self?.relayoutBar()
            self?.updateAccessibilityValue()
        }
        actions.toggleGamepad = { [weak self] in
            guard let self else { return }
            self.setGamepad(!self.session.gamepadShown)
            self.haptic(.light)
        }
        actions.toggleMicrophoneMute = { [weak self] in
            SessionAudio.shared.muted.toggle()
            self?.haptic(.light)
        }
        actions.resetZoom = { [weak self] in self?.resetZoomAnimated() }
        actions.shortcut = { [weak self] shortcut in
            self?.input.keyStroke(shortcut.keyCode, modifiers: shortcut.flags, nonNormalized: false)
            self?.haptic(.light)
            self?.updateAccessibilityValue()
        }
        actions.typeClipboard = { [weak self] in
            // As keys too, so a copied password works on the sign-in screen
            if let text = UIPasteboard.general.string, !text.isEmpty {
                self?.type(text, modifiers: 0)
                self?.updateAccessibilityValue()
            }
        }
        actions.key = { [weak self] code in
            guard let self else { return }
            self.sendKey(code)
            self.session.releaseLatchedModifiers()
            self.updateAccessibilityValue()
        }
        actions.disconnect = { [weak self] in
            self?.stopMomentum()
            self?.interpreter.cancelled()
            self?.setGamepad(false)
            self?.setKeyboard(false)
            self?.onDisconnect?()
        }
        actions.moveBar = { [weak self] translation in
            guard let self else { return }
            let bounds = self.view.bounds
            let bar = self.barPlacement.frame
            let start = self.barDragStart ?? CGPoint(x: bar.midX / bounds.width, y: bar.midY / bounds.height)
            self.barDragStart = start
            let center = CGPoint(x: start.x + translation.width / bounds.width, y: start.y + translation.height / bounds.height)
            if self.session.gamepadShown { self.gamepadBarCenter = center } else { self.barCenter = center }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        actions.endMoveBar = { [weak self] in
            guard let self else { return }
            self.barDragStart = nil
            // Remember where it ended up (clamped inside the screen), with the controller up or not
            let bounds = self.view.bounds
            let bar = self.barPlacement.frame
            let center = CGPoint(x: bar.midX / bounds.width, y: bar.midY / bounds.height)
            if self.session.gamepadShown {
                self.gamepadBarCenter = center
                UserDefaults.standard.set(NSCoder.string(for: center), forKey: "ArtemisGamepadBarCenter2")
            } else {
                self.barCenter = center
                UserDefaults.standard.set(NSCoder.string(for: center), forKey: "ArtemisBarCenter")
            }
            self.updateAccessibilityValue()
        }
        actions.setBarExpanded = { [weak self] expanded in
            guard let self else { return }
            // The glass and the bar's place in one spring: the capsule shrinks into the round
            // button where it sits (inside the screen's edges) and grows back out of it
            withAnimation(ControlBar.foldAnimation) { self.session.barExpanded = expanded }
            self.relayoutBar(animation: ControlBar.foldAnimation)
            self.updateAccessibilityValue()
        }
        return actions
    }

    // MARK: UI tests

    /// The session's microphone started, stopped or was muted (SessionAudio).
    @objc private func microphoneChanged() {
        let audio = SessionAudio.shared
        guard session.microphoneOn != audio.isSending || session.microphoneMuted != audio.muted else { return }
        session.microphoneOn = audio.isSending
        session.microphoneMuted = audio.muted
        relayoutBar()
        updateAccessibilityValue()
    }

    func updateAccessibilityValue() {
        var lines = [String(format: "zoom %.2f · %@ · keyboard %@ · bar %@ · gamepad mouse %@", scale, session.mode.rawValue,
                            session.keyboardShown ? "on" : "off", session.barExpanded ? "open" : "folded",
                            gamepadMouse.isActive ? "on" : "off")]
        lines[0] += " · edges " + Self.describe(deferredEdges)
        lines[0] += " · on-screen controller " + (session.gamepadShown ? "shown" : "hidden")
        lines[0] += " · notices \(toastCount)"
        let order = view.subviews
        lines[0] += " · desktop over trackpad " + ((order.firstIndex(of: canvas) ?? 0) > (order.firstIndex(of: trackpadArea) ?? 0) ? "yes" : "no")
        let exclusive = view.interactions.contains { ($0 as? GCEventInteraction).map { $0.handledEventTypes.contains(.gamepad) && !$0.receivesEventsInView } ?? false }
        lines[0] += " · controller events " + (exclusive ? "game controller only" : "shared")
        let safe = view.safeAreaInsets
        lines[0] += String(format: " · safe %.1f %.1f %.1f %.1f", safe.top, safe.left, safe.bottom, safe.right)
        let picture = videoRect(in: view.bounds.size)
        lines[0] += String(format: " · picture %.1f %.1f %.1f %.1f", picture.minX, picture.minY, picture.width, picture.height)
        let bar = barPlacement.frame
        lines[0] += String(format: " · bar frame %.1f %.1f %.1f %.1f · screen %.1f %.1f", bar.minX, bar.minY, bar.width, bar.height,
                           view.bounds.width, view.bounds.height)
        let packets = SessionAudio.shared.packetStats
        lines[0] += " · microphone " + (session.microphoneOn ? (session.microphoneMuted ? "muted" : "on") : "off")
            + " · mic packets \(packets.encoded) of \(packets.samples) samples"
        if let keyRow {
            lines[0] += " · key highlights \(keyRow.highlightCount) · key down \(keyRow.highlightedKey ?? "none")"
            lines[0] += " · key growths \(keyRow.growths) · key strays \(keyRow.strays)"
        }
        if let events = recordedEvents?() {
            lines.append("events \(events.count)")
            lines.append(contentsOf: events.suffix(60))
        }
        canvas.accessibilityValue = lines.joined(separator: "\n")
    }

    // MARK: Status bar, orientation

    /// The edges iOS defers system gestures on right now: those of the controller it asks
    /// (the topmost presented one, then its children as they forward the question). A session
    /// defers all of them: a first swipe from an edge only shows the system's tab.
    var deferredEdges: UIRectEdge {
        var controller = view.window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        while let child = controller?.childForScreenEdgesDeferringSystemGestures {
            controller = child
        }
        return controller?.preferredScreenEdgesDeferringSystemGestures ?? []
    }

    private static func describe(_ edges: UIRectEdge) -> String {
        if edges == .all { return "all" }
        let names: [(UIRectEdge, String)] = [(.top, "top"), (.left, "left"), (.bottom, "bottom"), (.right, "right")]
        let list = names.filter { edges.contains($0.0) }.map(\.1)
        return list.isEmpty ? "none" : list.joined(separator: "+")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    /// A small arrow pointer for the demo desktop.
    static let cursorImage: UIImage = {
        let size = CGSize(width: 20, height: 30)
        return UIGraphicsImageRenderer(size: size).image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 1.5, y: 24))
            path.addLine(to: CGPoint(x: 7, y: 18.5))
            path.addLine(to: CGPoint(x: 11, y: 27.5))
            path.addLine(to: CGPoint(x: 14.5, y: 26))
            path.addLine(to: CGPoint(x: 10.5, y: 17.5))
            path.addLine(to: CGPoint(x: 18, y: 17.5))
            path.close()
            UIColor.white.setFill()
            path.fill()
            UIColor.black.setStroke()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.stroke()
        }
    }()
}

// MARK: - Gestures

extension DesktopViewController: TouchInterpreterDelegate {
    func pointerMode(onTrackpadArea: Bool) -> PointerMode {
        onTrackpadArea ? .trackpad : session.mode
    }

    var isZoomed: Bool { scale > 1.01 }

    func movePointer(by delta: CGVector, interval: TimeInterval) {
        // Acceleration: slow movements are precise, fast ones go far
        let speed = hypot(delta.dx, delta.dy) / max(interval, 1.0 / 240)
        let t = min(max((speed - 60) / 840, 0), 1)
        let gain = pointerSettings.pointerSpeed * (0.8 + 1.7 * t * t * (3 - 2 * t))
        // A finger's travel of 560 points crosses the desktop at the base speed; zoomed in, it's finer
        let reference: CGFloat = 560
        let aspect = streamSize.width / streamSize.height
        pointer.x = min(max(pointer.x + delta.dx * gain / (reference * scale), 0), 1)
        pointer.y = min(max(pointer.y + delta.dy * gain * aspect / (reference * scale), 0), 1)
        sendPointer()
        followPointer()
        layoutContent()
    }

    func movePointer(to desktop: CGPoint) {
        pointer = CGPoint(x: min(max(desktop.x, 0), 1), y: min(max(desktop.y, 0), 1))
        sendPointer()
        layoutContent()
    }

    func desktopPoint(at location: CGPoint) -> CGPoint? {
        let inCanvas = canvasPoint(location)
        guard canvas.bounds.contains(inCanvas) else { return nil }
        let inContent = contentView.convert(location, from: view)
        let video = videoRect(in: contentView.bounds.size)
        return CGPoint(x: min(max((inContent.x - video.minX) / video.width, 0), 1),
                       y: min(max((inContent.y - video.minY) / video.height, 0), 1))
    }

    func click(_ button: MouseButton) {
        let modifiers = session.activeModifiers
        pressModifiers(modifiers)
        input.click(button.moonlight)
        releaseModifiers(modifiers)
        session.releaseLatchedModifiers()
        updateAccessibilityValue()
    }

    func scroll(by delta: CGVector) {
        var delta = delta
        // Mostly vertical or mostly horizontal: keep to that axis
        if abs(delta.dx) < abs(delta.dy) * 0.5 { delta.dx = 0 }
        if abs(delta.dy) < abs(delta.dx) * 0.5 { delta.dy = 0 }
        // 120 is one wheel notch: one per ~24 points. Natural scrolling: the content follows the
        // fingers on the PC's screen. On the PC that's fingers down = wheel down (negative),
        // the opposite of the Mac trackpad convention this first followed: reported twice from a
        // real phone (2026-10-24, 2026-11-02), so the PC's screen is the reference, not the Mac.
        let direction: CGFloat = pointerSettings.naturalScrolling ? -1 : 1
        scrollRemainder.dy += delta.dy * 5 * direction
        scrollRemainder.dx += -delta.dx * 5 * direction
        let vertical = Int(scrollRemainder.dy)
        let horizontal = Int(scrollRemainder.dx)
        guard vertical != 0 || horizontal != 0 else { return }
        scrollRemainder.dy -= CGFloat(vertical)
        scrollRemainder.dx -= CGFloat(horizontal)
        input.scroll(vertical: vertical, horizontal: horizontal)
        updateAccessibilityValue()
    }

    func startMomentum(velocity: CGVector) {
        momentumVelocity = velocity
        lastMomentumTime = CACurrentMediaTime()
        if momentumLink == nil {
            // Through a weak proxy: a display link keeps its target alive
            let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.momentumStep))
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }
    }

    @objc fileprivate func momentumStep(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let interval = min(now - lastMomentumTime, 0.05)
        lastMomentumTime = now
        momentumVelocity.dx *= pow(0.93, interval * 60)
        momentumVelocity.dy *= pow(0.93, interval * 60)
        if hypot(momentumVelocity.dx, momentumVelocity.dy) < 40 {
            stopMomentum()
            return
        }
        scroll(by: CGVector(dx: momentumVelocity.dx * interval, dy: momentumVelocity.dy * interval))
    }

    func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
    }

    func zoom(by factor: CGFloat, around location: CGPoint) {
        let anchor = canvasPoint(location)
        let size = canvas.bounds.size
        let newScale = min(max(scale * factor, 1), 5)
        // Keep the desktop point under the fingers where it is
        let center = CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
        let inContent = CGPoint(x: (anchor.x - center.x) / scale, y: (anchor.y - center.y) / scale)
        let newCenter = CGPoint(x: anchor.x - inContent.x * newScale, y: anchor.y - inContent.y * newScale)
        scale = newScale
        offset = CGPoint(x: newCenter.x - size.width / 2, y: newCenter.y - size.height / 2)
        layoutContent()
    }

    func pan(by delta: CGVector) {
        offset.x += delta.dx
        offset.y += delta.dy
        layoutContent()
    }

    func resetZoom() {
        resetZoomAnimated()
    }

    func toggleKeyboard() {
        setKeyboard(!session.keyboardShown)
    }

    func haptic(_ style: TouchHaptic) {
        UIImpactFeedbackGenerator(style: style == .light ? .light : .medium).impactOccurred()
    }

    fileprivate func touches(_ touches: Set<UITouch>, phase: UITouch.Phase) {
        let onArea = touches.first.map { $0.view === trackpadArea || $0.view?.isDescendant(of: trackpadArea) == true } ?? false
        let samples = touches.filter { $0.type == .direct }.map { touch in
            let location = touch.location(in: view)
            return TouchSample(id: ObjectIdentifier(touch), location: location,
                               desktop: onArea ? nil : desktopPoint(at: location), time: touch.timestamp)
        }
        guard !samples.isEmpty else { return }
        switch phase {
        case .began: interpreter.began(samples, onTrackpadArea: onArea)
        case .moved: interpreter.moved(samples)
        case .ended: interpreter.ended(samples)
        default:
            stopMomentum()
            interpreter.cancelled()
        }
    }
}

/// Takes the finger touches of the desktop view and the trackpad area.
@objc(DesktopTouchHandler)
final class DesktopTouchHandler: UIResponder {
    private weak var controller: DesktopViewController?

    init(controller: DesktopViewController) {
        self.controller = controller
        super.init()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touches(touches, phase: .began)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touches(touches, phase: .moved)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touches(touches, phase: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touches(touches, phase: .cancelled)
    }
}

/// The canvas around the desktop view: touches on it (outside a zoomed-out desktop) count too.
final class DesktopCanvasView: UIView {
    weak var touchHandler: DesktopTouchHandler?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesCancelled(touches, with: event) }
}

/// Upright, under the desktop: a trackpad (its taps click; two fingers right-click).
final class TrackpadAreaView: UIView {
    weak var touchHandler: DesktopTouchHandler?
    private let hint = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "rectangle.and.hand.point.up.left"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 26
        layer.cornerCurve = .continuous
        isAccessibilityElement = false
        accessibilityIdentifier = "trackpad"

        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .light)
        hint.text = "Trackpad"
        hint.textColor = .tertiaryLabel
        hint.textAlignment = .center
        hint.adjustsFontForContentSizeCategory = false
        addSubview(icon)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        hint.font = Typography.uiFont(.footnote, sizeCategory: .large)
        icon.frame = CGRect(x: bounds.midX - 24, y: bounds.midY - 30, width: 48, height: 36)
        hint.frame = CGRect(x: 0, y: bounds.midY + 10, width: bounds.width, height: 22)
        icon.isHidden = bounds.height < 90
        hint.isHidden = icon.isHidden
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchHandler?.touchesCancelled(touches, with: event) }
}

/// Takes the iOS keyboard's typing (and a hardware keyboard's keys while it's up).
final class KeyCaptureView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onHardwareKey: ((UIPress, Bool) -> Bool)?
    var accessory: UIView?

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

    var hasText: Bool { true }
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onDelete?() }

    // Plain typing: no corrections, capitals or smart punctuation
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled = presses.map { onHardwareKey?($0, true) ?? false }.contains(true)
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled = presses.map { onHardwareKey?($0, false) ?? false }.contains(true)
        if !handled { super.pressesEnded(presses, with: event) }
    }

    // Leaving the app mid-press: the keys come up on the PC too
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled = presses.map { onHardwareKey?($0, false) ?? false }.contains(true)
        if !handled { super.pressesCancelled(presses, with: event) }
    }
}

/// Forwards the momentum display link to the controller without keeping it alive.
private final class WeakTarget: NSObject {
    weak var controller: DesktopViewController?

    init(_ controller: DesktopViewController) {
        self.controller = controller
    }

    @objc func momentumStep(_ link: CADisplayLink) {
        guard let controller else {
            link.invalidate()
            return
        }
        controller.momentumStep(link)
    }
}

// MARK: - Controller as the mouse

extension DesktopViewController: GamepadMouseOutput {
    func gamepadMouseMove(dx: CGFloat, dy: CGFloat) {
        pointer.x = min(max(pointer.x + dx / streamSize.width, 0), 1)
        pointer.y = min(max(pointer.y + dy / streamSize.height, 0), 1)
        sendPointer()
        followPointer()
        layoutContent()
    }

    func gamepadMouseButton(_ button: Int32, down: Bool) {
        if let known = MouseButton.allCases.first(where: { $0.moonlight == button }) {
            setButton(known, down: down)
        } else {
            input.setButton(button, down: down)
            updateAccessibilityValue()
        }
    }

    func gamepadMouseScroll(vertical: Int, horizontal: Int) {
        input.scroll(vertical: vertical, horizontal: horizontal)
        updateAccessibilityValue()
    }

    func gamepadMouseToggleKeyboard() {
        toggleKeyboard()
    }

    func gamepadMouseChanged(active: Bool) {
        haptic(.medium)
        showToast(active ? "Controller mouse on\nHold Start or Menu to turn it off" : "Controller mouse off")
        updateAccessibilityValue()
    }

    private func showToast(_ text: String) {
        toastHide?.cancel()
        toast.text = text
        view.setNeedsLayout()
        view.layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { self.toastBackground.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: text.replacingOccurrences(of: "\n", with: ". "))
        let hide = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.toastBackground.alpha = 0 }
        }
        toastHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
        toastCount += 1
        updateAccessibilityValue()
    }
}

/// Where the control bar goes, set by DesktopViewController.
@Observable
final class BarPlacement {
    var frame = CGRect.zero
}

/// The control bar at its place in a view that covers the screen.
struct PlacedControlBar: View {
    let session: DesktopSession
    let placement: BarPlacement

    var body: some View {
        ControlBar(session: session)
            .frame(width: placement.frame.width, height: placement.frame.height)
            .position(x: placement.frame.midX, y: placement.frame.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}

/// Holds the bar's screen-covering hosting view: only touches on the bar go to it.
final class BarPassThroughView: UIView {
    var placement: BarPlacement?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let placement, placement.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
