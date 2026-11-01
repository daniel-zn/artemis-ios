//
//  KeyRow.swift
//  Artemis
//
//  The keys above the iOS keyboard (its input accessory): Esc, Tab, the sticky modifiers,
//  arrows and editing keys, and a page of function keys. Fn, the page switch, is the first key
//  and scrolls sideways with the others. A key lights up, grows and fires only on a real tap: a finger
//  that lands on a key and swipes the row along scrolls it instead (the scroll view delays and
//  cancels the key's touch, as UIKit's own scroll views do). The hide-keyboard button stays at
//  the right end on its own glass; the keys scroll on underneath it, fading out as they go, and
//  the row ends far enough to its left that the last key comes fully into view beside it.
//

import UIKit

final class KeyRowView: UIInputView {
    private let session: DesktopSession
    private let pageButton = KeyButton(identifier: "key.page")
    private let hideButton = KeyButton(identifier: "key.hide")
    private let scrollView = KeyScrollView()
    private var keys: [KeyButton] = []
    private var shownPage: DesktopSession.KeyPage?
    /// For the UI tests: how many times a key lit up, and the one lit now.
    private(set) var highlightCount = 0
    private(set) var highlightedKey: String?
    var onHighlightChange: (() -> Void)?
    /// For the UI tests (demo mode), sampled every frame: how many times a key grew (its press
    /// showing) and how many times something of a key was drawn outside it (a second title, or
    /// glass past its edges).
    private(set) var growths = 0
    private(set) var strays = 0
    private var sampler: CADisplayLink?
    private var grown: Set<String> = [], strayed: Set<String> = []
    /// The hide button's tap.
    var onHide: (() -> Void)?

    init(session: DesktopSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 54), inputViewStyle: .keyboard)
        allowsSelfSizing = false
        backgroundColor = .clear
        accessibilityIdentifier = "keyrow"

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = true
        // A touch on a key waits a moment to see whether it's a swipe (delaysContentTouches),
        // and a swipe takes it back from the key (touchesShouldCancel)
        scrollView.delaysContentTouches = true
        scrollView.canCancelContentTouches = true
        scrollView.clipsToBounds = true
        // The row places its keys clear of the safe area itself
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        hideButton.setKey(symbol: "keyboard.chevron.compact.down", accessibility: "Hide Keyboard")
        hideButton.addAction(UIAction { [weak self] _ in self?.onHide?() }, for: .primaryActionTriggered)
        addSubview(hideButton)

        scrollView.addSubview(pageButton)
        pageButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.session.keyPage = self.session.keyPage == .main ? .function : .main
        }, for: .primaryActionTriggered)
        watch(pageButton)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sampler?.invalidate()
        sampler = nil
        guard window != nil, DemoData.isEnabled else { return }
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        sampler = link
    }

    @objc private func sample() {
        for key in [pageButton] + keys {
            let id = key.accessibilityIdentifier ?? ""
            let sample = key.sampled()
            if sample.scale > 1.02 { if grown.insert(id).inserted { growths += 1; onHighlightChange?() } } else { grown.remove(id) }
            if sample.stray { if strayed.insert(id).inserted { strays += 1; onHighlightChange?() } } else { strayed.remove(id) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        let hideWidth = hideButton.intrinsicContentSize.width
        // Bounds and centre, not frames: a key is scaled up while it's pressed
        let hideFrame = CGRect(x: bounds.width - safeAreaInsets.right - 8 - hideWidth, y: (height - 38) / 2,
                               width: hideWidth, height: 38)
        hideButton.bounds.size = hideFrame.size
        hideButton.center = CGPoint(x: hideFrame.midX, y: hideFrame.midY)
        // The keys run the full width, under the hide button
        scrollView.frame = bounds
        // Fn, then the page's keys, side by side 6 pt apart
        var x: CGFloat = 8 + safeAreaInsets.left
        for key in [pageButton] + keys {
            let width = key.intrinsicContentSize.width
            key.bounds.size = CGSize(width: width, height: 38)
            key.center = CGPoint(x: x + width / 2, y: height / 2)
            x += width + 6
        }
        // Room at the end for the hide button, so the last key scrolls fully into view beside it
        scrollView.contentSize = CGSize(width: x + (bounds.width - hideFrame.minX), height: height)
        // The keys fade out from just before the button to its middle
        scrollView.fade = (hideFrame.minX - 10, hideFrame.midX)
    }

    // MARK: Keys

    /// Shows the session's page and modifier states; called again whenever they change.
    private func update() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func render() {
        let page = session.keyPage
        if page == .main {
            pageButton.setKey(title: "Fn", accessibility: "Function Keys")
        } else {
            pageButton.setKey(symbol: "chevron.left", accessibility: "Back to Keys")
        }
        if shownPage != page {
            shownPage = page
            for key in keys { key.removeFromSuperview() }
            keys = page == .main ? mainPage() : functionPage()
            for key in keys {
                scrollView.addSubview(key)
                watch(key)
            }
            scrollView.contentOffset = .zero
            setNeedsLayout()
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
        for key in keys {
            if let modifier = key.modifier {
                key.setState(session.state(of: modifier))
            }
        }
        setNeedsLayout()
    }

    private func mainPage() -> [KeyButton] {
        var keys = [
            key("Esc") { $0.actions.key(KeyCode.escape) },
            key("Tab") { $0.actions.key(KeyCode.tab) },
        ]
        for modifier in [Modifier.ctrl, .alt, .win, .shift] {
            let button = key(modifier.title) { $0.tapModifier(modifier) }
            button.modifier = modifier
            keys.append(button)
        }
        keys += [
            key(symbol: "arrow.left", "Left", "Left Arrow") { $0.actions.key(KeyCode.left) },
            key(symbol: "arrow.up", "Up", "Up Arrow") { $0.actions.key(KeyCode.up) },
            key(symbol: "arrow.down", "Down", "Down Arrow") { $0.actions.key(KeyCode.down) },
            key(symbol: "arrow.right", "Right", "Right Arrow") { $0.actions.key(KeyCode.right) },
            key("Del", accessibility: "Delete") { $0.actions.key(KeyCode.delete) },
            key("Home") { $0.actions.key(KeyCode.home) },
            key("End") { $0.actions.key(KeyCode.end) },
            key("PgUp", accessibility: "Page Up") { $0.actions.key(KeyCode.pageUp) },
            key("PgDn", accessibility: "Page Down") { $0.actions.key(KeyCode.pageDown) },
        ]
        return keys
    }

    private func functionPage() -> [KeyButton] {
        (1...12).map { number in
            key("F\(number)") { $0.actions.key(KeyCode.f1 + UInt16(number - 1)) }
        }
    }

    private func key(_ title: String, accessibility: String? = nil, action: @escaping (DesktopSession) -> Void) -> KeyButton {
        let button = KeyButton(identifier: "key.\(title)")
        button.setKey(title: title, accessibility: accessibility ?? title)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self.session)
        }, for: .primaryActionTriggered)
        return button
    }

    private func key(symbol: String, _ name: String, _ accessibility: String, action: @escaping (DesktopSession) -> Void) -> KeyButton {
        let button = KeyButton(identifier: "key.\(name)")
        button.setKey(symbol: symbol, accessibility: accessibility)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self.session)
        }, for: .primaryActionTriggered)
        return button
    }

    private func watch(_ button: KeyButton) {
        button.onHighlight = { [weak self, weak button] lit in
            guard let self, let button else { return }
            if lit {
                self.highlightCount += 1
                self.highlightedKey = button.accessibilityIdentifier
            } else if self.highlightedKey == button.accessibilityIdentifier {
                self.highlightedKey = nil
            }
            self.onHighlightChange?()
        }
    }
}

/// The row's scroll view: a swipe that starts on a key scrolls the row and cancels the key's
/// touch (UIScrollView keeps it for controls by default).
/// Its keys fade out over `fade` (x from, to, in the row), wherever it's scrolled.
private final class KeyScrollView: UIScrollView {
    private let fadeMask = CAGradientLayer()
    var fade: (from: CGFloat, to: CGFloat)? {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fadeMask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    /// Called as it scrolls too: the mask stays put over the visible part.
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        let width = max(bounds.width, 1)
        let fade = fade ?? (width, width)
        fadeMask.locations = [0, NSNumber(value: Double(fade.from / width)), NSNumber(value: Double(fade.to / width))]
        CATransaction.commit()
    }
}

/// One key: Liquid Glass, tinted while its modifier is held, with a lock while it's locked.
/// The glass isn't interactive: its own press effect reacts to any touch, a swipe of the row
/// too, and leaves a ghost of the title when tapped fast. The key grows as it lights up
/// instead, which the row's scroll view delays and cancels for a swipe.
final class KeyButton: UIButton {
    var modifier: Modifier?
    var onHighlight: ((Bool) -> Void)?
    private var modifierState = DesktopSession.ModifierState.off
    private var title: String?
    private var symbol: String?
    private let lock = UIImageView(image: UIImage(systemName: "lock.fill",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)))
    private let feedback = UISelectionFeedbackGenerator()
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    /// When it lit up: a quick tap still shows its press for a moment.
    private var pressed = Date.distantPast

    init(identifier: String) {
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        glass.isUserInteractionEnabled = false
        glass.cornerConfiguration = .corners(radius: .fixed(10))
        insertSubview(glass, at: 0)
        lock.tintColor = .white
        lock.isHidden = true
        addSubview(lock)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.restyle()
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: max(44, super.intrinsicContentSize.width), height: 38)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            onHighlight?(isHighlighted)
            let lit = isHighlighted
            if lit { pressed = .now }
            UIView.animate(springDuration: lit ? 0.25 : 0.35, bounce: lit ? 0 : 0.4, initialSpringVelocity: 0,
                           delay: lit ? 0 : max(0, 0.12 + pressed.timeIntervalSinceNow),
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = lit ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
            }
        }
    }

    func setKey(title: String, accessibility: String) {
        guard self.title != title || symbol != nil else { return }
        self.title = title
        symbol = nil
        accessibilityLabel = accessibility
        restyle()
    }

    func setKey(symbol: String, accessibility: String) {
        guard self.symbol != symbol else { return }
        self.symbol = symbol
        title = nil
        accessibilityLabel = accessibility
        restyle()
    }

    func setState(_ state: DesktopSession.ModifierState) {
        guard modifierState != state else { return }
        feedback.selectionChanged()
        modifierState = state
        accessibilityValue = state == .off ? nil : (state == .locked ? "Locked" : "Held")
        lock.isHidden = state != .locked
        restyle()
    }

    private func restyle() {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = modifierState == .off ? nil : .tintColor
        glass.effect = effect
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = modifierState == .off ? .label : .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
            configuration.title = nil
        } else if let title {
            configuration.image = nil
            // Up to xxLarge text: the row has one line of keys
            let size = traitCollection.preferredContentSizeCategory
            let font = Typography.uiFont(.subheadline, sizeCategory: size > .extraExtraLarge ? .extraExtraLarge : size)
            let kern = Typography.tracking(.subheadline, sizeCategory: size > .extraExtraLarge ? .extraExtraLarge : size)
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font, .kern: kern]))
        }
        self.configuration = configuration
        invalidateIntrinsicContentSize()
    }

    /// On screen now (presentation layers): how much it's scaled up, and whether anything of it
    /// is drawn outside it (a second title or icon, or glass past its edges).
    func sampled() -> (scale: CGFloat, stray: Bool) {
        guard let me = layer.presentation() else { return (1, false) }
        var labels = 0, stray = false
        var scale = me.affineTransform().a
        func visit(_ view: UIView) {
            for sub in view.subviews where !sub.isHidden && sub !== lock {
                guard let p = sub.layer.presentation(), p.opacity > 0.01 else { continue }
                let frame = p.convert(p.bounds, to: me)
                guard !frame.isEmpty else { continue }
                if sub is UILabel || sub is UIImageView { labels += 1 } else if frame.width > 10 {
                    scale = max(scale, me.affineTransform().a * frame.width / max(me.bounds.width, 1))
                }
                if !me.bounds.insetBy(dx: -1, dy: -1).contains(frame) { stray = true }
                visit(sub)
            }
        }
        visit(self)
        return (scale, stray || labels > 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        sendSubviewToBack(glass)
        lock.frame = CGRect(x: bounds.width - 14, y: 4, width: 10, height: 10)
        bringSubviewToFront(lock)
    }
}
