//
//  PasteControl.swift
//  Artemis
//
//  The session's Paste button: iOS's own paste control (UIPasteControl), icon only. Its tap is
//  the permission, so iOS doesn't ask "Allow Paste": it hands the copied text over, and the
//  session puts it on the PC's clipboard and presses Ctrl+V there (DesktopViewController.paste).
//  Dimmed while nothing with text is copied. In the control bar and beside the key row's hide
//  button. iOS checks the control is drawn plainly (opaque, contrasting colours), so it has a
//  solid background of its own instead of glass.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class PasteControlView: UIView {
    private let target = PasteTarget()
    private let control: UIPasteControl

    /// The copied text, on the main queue.
    var onPaste: ((String) -> Void)? {
        get { target.onPaste }
        set { target.onPaste = newValue }
    }

    init(size: CGFloat, cornerRadius: CGFloat?) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        if let cornerRadius {
            configuration.cornerStyle = .fixed
            configuration.cornerRadius = cornerRadius
        } else {
            configuration.cornerStyle = .capsule
        }
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.9, alpha: 1) }
        control = UIPasteControl(configuration: configuration)
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        control.target = target
        control.accessibilityIdentifier = "paste"
        addSubview(control)
    }

    private let size: CGFloat

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Names it for the UI tests ("bar.paste", "key.paste").
    func identify(_ identifier: String) {
        control.accessibilityIdentifier = identifier
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 44) }

    override func layoutSubviews() {
        super.layoutSubviews()
        control.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }
}

/// Takes what the paste control pastes: plain text only.
private final class PasteTarget: UIResponder {
    var onPaste: ((String) -> Void)?

    override init() {
        super.init()
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier, UTType.utf8PlainText.identifier,
                                                                               UTType.text.identifier, UTType.url.identifier])
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: String.self) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
        _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
            guard let text, !text.isEmpty else { return }
            DispatchQueue.main.async { self?.onPaste?(text) }
        }
    }
}

/// The control bar's Paste.
struct PasteBarButton: UIViewRepresentable {
    let onPaste: (String) -> Void

    func makeUIView(context: Context) -> PasteControlView {
        let view = PasteControlView(size: 36, cornerRadius: nil)
        view.identify("bar.paste")
        return view
    }

    func updateUIView(_ view: PasteControlView, context: Context) {
        view.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteControlView, context: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }
}
