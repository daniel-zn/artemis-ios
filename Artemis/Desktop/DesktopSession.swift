//
//  DesktopSession.swift
//  Artemis
//
//  The connected screen's state that the control bar and the key row show, and the keys
//  and shortcuts they send.
//

import SwiftUI

@Observable
final class DesktopSession {
    enum ModifierState {
        case off
        /// Held for the next key or click, then released.
        case latched
        /// Held until tapped again.
        case locked
    }

    enum KeyPage {
        case main, function
    }

    var title: String
    var mode: PointerMode
    var zoomScale: CGFloat = 1
    var keyboardShown = false
    var barExpanded: Bool
    var isPortrait = false
    /// The on-screen controller is up (each session starts without it).
    var gamepadShown = false
    /// The microphone goes to the PC in this session (the bar shows its button), and is muted.
    var microphoneOn = false
    var microphoneMuted = false
    var keyPage = KeyPage.main
    var modifiers: [Modifier: ModifierState] = [:]

    /// Set by DesktopViewController.
    @ObservationIgnored var actions = Actions()

    struct Actions {
        var toggleKeyboard: () -> Void = {}
        var setMode: (PointerMode) -> Void = { _ in }
        var toggleGamepad: () -> Void = {}
        var toggleMicrophoneMute: () -> Void = {}
        var resetZoom: () -> Void = {}
        var shortcut: (Shortcut) -> Void = { _ in }
        var typeClipboard: () -> Void = {}
        var key: (UInt16) -> Void = { _ in }
        var disconnect: () -> Void = {}
        var moveBar: (CGSize) -> Void = { _ in }
        var endMoveBar: () -> Void = {}
        var setBarExpanded: (Bool) -> Void = { _ in }
    }

    init(title: String, mode: PointerMode, barExpanded: Bool) {
        self.title = title
        self.mode = mode
        self.barExpanded = barExpanded
    }

    var isZoomed: Bool { zoomScale > 1.01 }

    func state(of modifier: Modifier) -> ModifierState {
        modifiers[modifier] ?? .off
    }

    @ObservationIgnored private var lastModifierTap: [Modifier: Date] = [:]

    /// Tap: off → held for the next key → locked (a second tap soon after) → off.
    func tapModifier(_ modifier: Modifier) {
        let now = Date()
        let doubleTap = lastModifierTap[modifier].map { now.timeIntervalSince($0) < 0.4 } ?? false
        lastModifierTap[modifier] = now
        switch state(of: modifier) {
        case .off: modifiers[modifier] = .latched
        case .latched: modifiers[modifier] = doubleTap ? .locked : .off
        case .locked: modifiers[modifier] = .off
        }
    }

    /// The modifiers held right now, as Moonlight's flags.
    var activeModifierFlags: UInt8 {
        modifiers.filter { $0.value != .off }.keys.reduce(0) { $0 | $1.flag }
    }

    var activeModifiers: [Modifier] {
        Modifier.pressOrder.filter { state(of: $0) != .off }
    }

    /// After a key or click: the ones held for one key come up.
    func releaseLatchedModifiers() {
        for (modifier, state) in modifiers where state == .latched {
            modifiers[modifier] = .off
        }
    }
}

/// Windows virtual-key codes the key row and the shortcuts send.
enum KeyCode {
    static let backspace: UInt16 = 0x08
    static let tab: UInt16 = 0x09
    static let enter: UInt16 = 0x0D
    static let escape: UInt16 = 0x1B
    static let pageUp: UInt16 = 0x21
    static let pageDown: UInt16 = 0x22
    static let end: UInt16 = 0x23
    static let home: UInt16 = 0x24
    static let left: UInt16 = 0x25
    static let up: UInt16 = 0x26
    static let right: UInt16 = 0x27
    static let down: UInt16 = 0x28
    static let delete: UInt16 = 0x2E
    static let f1: UInt16 = 0x70

    static func letter(_ character: Character) -> UInt16 {
        UInt16(character.uppercased().unicodeScalars.first!.value)
    }
}

struct Shortcut: Identifiable {
    let title: String
    let symbol: String
    let keyCode: UInt16
    let modifiers: [Modifier]

    var id: String { title }

    var flags: UInt8 {
        modifiers.reduce(0) { $0 | $1.flag }
    }

    /// Edit commands, then Windows ones. Ctrl+Alt+Del and Win+L aren't offered: Windows
    /// ignores them when they come from injected input, which is how the host types.
    static let common: [Shortcut] = [
        Shortcut(title: "Copy", symbol: "doc.on.doc", keyCode: KeyCode.letter("c"), modifiers: [.ctrl]),
        Shortcut(title: "Paste", symbol: "doc.on.clipboard", keyCode: KeyCode.letter("v"), modifiers: [.ctrl]),
        Shortcut(title: "Undo", symbol: "arrow.uturn.backward", keyCode: KeyCode.letter("z"), modifiers: [.ctrl]),
        Shortcut(title: "Select All", symbol: "selection.pin.in.out", keyCode: KeyCode.letter("a"), modifiers: [.ctrl]),
    ]

    static let moreEditing: [Shortcut] = [
        Shortcut(title: "Cut", symbol: "scissors", keyCode: KeyCode.letter("x"), modifiers: [.ctrl]),
        Shortcut(title: "Redo", symbol: "arrow.uturn.forward", keyCode: KeyCode.letter("y"), modifiers: [.ctrl]),
        Shortcut(title: "Find", symbol: "magnifyingglass", keyCode: KeyCode.letter("f"), modifiers: [.ctrl]),
        Shortcut(title: "Save", symbol: "square.and.arrow.down", keyCode: KeyCode.letter("s"), modifiers: [.ctrl]),
    ]

    static let windows: [Shortcut] = [
        Shortcut(title: "Switch Apps", symbol: "rectangle.on.rectangle", keyCode: KeyCode.tab, modifiers: [.alt]),
        Shortcut(title: "Start", symbol: "square.grid.2x2", keyCode: Modifier.win.keyCode, modifiers: []),
        Shortcut(title: "Show Desktop", symbol: "menubar.dock.rectangle", keyCode: KeyCode.letter("d"), modifiers: [.win]),
        Shortcut(title: "File Explorer", symbol: "folder", keyCode: KeyCode.letter("e"), modifiers: [.win]),
        Shortcut(title: "Task Manager", symbol: "list.bullet.rectangle", keyCode: KeyCode.escape, modifiers: [.ctrl, .shift]),
        Shortcut(title: "Close Window", symbol: "xmark.rectangle", keyCode: 0x73, modifiers: [.alt]), // F4
        Shortcut(title: "Screenshot", symbol: "camera.viewfinder", keyCode: KeyCode.letter("s"), modifiers: [.win, .shift]),
    ]
}
