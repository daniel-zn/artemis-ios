//
//  DesktopInput.swift
//  Artemis
//
//  Where the desktop controls' input goes: the PC, through Moonlight's input calls
//  (MoonlightDesktopInput), or a list of events for the demo desktop and the UI tests
//  (RecordingDesktopInput).
//

import Foundation
import UIKit

enum MouseButton: CaseIterable {
    case left, right, middle

    var moonlight: Int32 {
        switch self {
        case .left: BUTTON_LEFT
        case .right: BUTTON_RIGHT
        case .middle: BUTTON_MIDDLE
        }
    }

    var name: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .middle: "middle"
        }
    }
}

/// The sticky modifier keys of the key row, with their Windows virtual-key codes.
enum Modifier: String, CaseIterable, Identifiable {
    case ctrl, alt, win, shift

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .ctrl: 0xA2 // VK_LCONTROL
        case .alt: 0xA4 // VK_LMENU
        case .win: 0x5B // VK_LWIN
        case .shift: 0xA0 // VK_LSHIFT
        }
    }

    var flag: UInt8 {
        switch self {
        case .ctrl: UInt8(MODIFIER_CTRL)
        case .alt: UInt8(MODIFIER_ALT)
        case .win: UInt8(MODIFIER_META)
        case .shift: UInt8(MODIFIER_SHIFT)
        }
    }

    var title: String {
        switch self {
        case .ctrl: "Ctrl"
        case .alt: "Alt"
        case .win: "Win"
        case .shift: "Shift"
        }
    }

    /// The order modifiers go down in (and come up in reverse).
    static let pressOrder: [Modifier] = [.ctrl, .shift, .alt, .win]
}

/// What the gestures and keys produce.
@objc(ArtemisDesktopInput)
protocol DesktopInput: AnyObject {
    /// The pointer to a position on the desktop, in the stream's pixels.
    func movePointer(x: Int, y: Int, width: Int, height: Int)
    func setButton(_ button: Int32, down: Bool)
    /// A press and release.
    func click(_ button: Int32)
    /// High-resolution scroll amounts (120 = one wheel notch): positive scrolls up / right.
    func scroll(vertical: Int, horizontal: Int)
    func setKey(_ keyCode: UInt16, down: Bool, modifiers: UInt8)
    /// A key pressed and released with these modifiers held around it.
    func keyStroke(_ keyCode: UInt16, modifiers: UInt8, nonNormalized: Bool)
    /// Unicode text the PC types as is.
    func text(_ text: String)
    /// The on-screen gamepad: an Xbox controller arrives on the PC, takes its states, and goes.
    func gamepadConnect()
    func gamepad(_ state: GamepadState)
    func gamepadDisconnect()
}

/// A gamepad's state as Moonlight sends it: button flags, triggers 0–255, sticks
/// −32768…32767 with up positive.
@objc(ArtemisGamepadState)
final class GamepadState: NSObject {
    let buttons: UInt32
    let leftTrigger: UInt8
    let rightTrigger: UInt8
    let leftX: Int16, leftY: Int16
    let rightX: Int16, rightY: Int16

    init(buttons: UInt32, leftTrigger: UInt8, rightTrigger: UInt8, leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16) {
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
    }
}

/// The PC, through moonlight-common-c. One serial queue keeps the events in order and
/// spaces a click's press and release, as upstream's touch handlers did.
@objc(MoonlightDesktopInput)
final class MoonlightDesktopInput: NSObject, DesktopInput {
    private let queue = DispatchQueue(label: "artemis.input", qos: .userInteractive)
    /// The session's controllers, which the on-screen gamepad joins (StreamFrameViewController).
    @objc weak var controllers: ControllerSupport?

    /// Ctrl+C or Ctrl+X: the shared clipboard fetches the PC's copy shortly after (StreamClipboard).
    private static func noteCopy(_ keyCode: UInt16, modifiers: UInt8) {
        guard modifiers & UInt8(MODIFIER_CTRL) != 0,
              keyCode == KeyCode.letter("c") || keyCode == KeyCode.letter("x") else { return }
        NotificationCenter.default.post(name: .artemisCopyKeySent, object: nil)
    }

    func movePointer(x: Int, y: Int, width: Int, height: Int) {
        queue.async {
            LiSendMousePositionEvent(Int16(clamping: x), Int16(clamping: y), Int16(clamping: width), Int16(clamping: height))
        }
    }

    func setButton(_ button: Int32, down: Bool) {
        queue.async {
            LiSendMouseButtonEvent(CChar(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), button)
        }
    }

    func click(_ button: Int32) {
        queue.async {
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_PRESS), button)
            usleep(30_000)
            LiSendMouseButtonEvent(CChar(BUTTON_ACTION_RELEASE), button)
        }
    }

    func scroll(vertical: Int, horizontal: Int) {
        queue.async {
            if vertical != 0 { LiSendHighResScrollEvent(Int16(clamping: vertical)) }
            if horizontal != 0 { LiSendHighResHScrollEvent(Int16(clamping: horizontal)) }
        }
    }

    func setKey(_ keyCode: UInt16, down: Bool, modifiers: UInt8) {
        if down { Self.noteCopy(keyCode, modifiers: modifiers) }
        queue.async {
            LiSendKeyboardEvent(Int16(bitPattern: keyCode), CChar(down ? KEY_ACTION_DOWN : KEY_ACTION_UP), CChar(bitPattern: modifiers))
        }
    }

    func keyStroke(_ keyCode: UInt16, modifiers: UInt8, nonNormalized: Bool) {
        Self.noteCopy(keyCode, modifiers: modifiers)
        queue.async {
            let held = Modifier.pressOrder.filter { modifiers & $0.flag != 0 }
            var flags: UInt8 = 0
            for modifier in held {
                flags |= modifier.flag
                LiSendKeyboardEvent(Int16(bitPattern: modifier.keyCode), CChar(KEY_ACTION_DOWN), CChar(bitPattern: flags))
            }
            let keyFlags = CChar(nonNormalized ? SS_KBE_FLAG_NON_NORMALIZED : 0)
            LiSendKeyboardEvent2(Int16(bitPattern: keyCode), CChar(KEY_ACTION_DOWN), CChar(bitPattern: flags), keyFlags)
            usleep(30_000)
            LiSendKeyboardEvent2(Int16(bitPattern: keyCode), CChar(KEY_ACTION_UP), CChar(bitPattern: flags), keyFlags)
            for modifier in held.reversed() {
                flags &= ~modifier.flag
                LiSendKeyboardEvent(Int16(bitPattern: modifier.keyCode), CChar(KEY_ACTION_UP), CChar(bitPattern: flags))
            }
        }
    }

    func text(_ text: String) {
        queue.async {
            var utf8 = Array(text.utf8)
            utf8.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                    _ = LiSendUtf8TextEvent(pointer, UInt32(buffer.count))
                }
            }
        }
    }

    // ControllerSupport numbers the gamepad among the connected controllers, under its lock
    func gamepadConnect() {
        controllers?.connectVirtualGamepad()
    }

    func gamepad(_ state: GamepadState) {
        controllers?.sendVirtualGamepadButtons(state.buttons, leftTrigger: state.leftTrigger, rightTrigger: state.rightTrigger,
                                               leftStickX: state.leftX, leftStickY: state.leftY,
                                               rightStickX: state.rightX, rightStickY: state.rightY)
    }

    func gamepadDisconnect() {
        controllers?.disconnectVirtualGamepad()
    }
}

/// The demo desktop's input: a list of events in a compact text form, shown to the UI
/// tests as the desktop's accessibility value.
final class RecordingDesktopInput: NSObject, DesktopInput {
    private(set) var events: [String] = []
    var onChange: (() -> Void)?

    private func record(_ event: String) {
        events.append(event)
        onChange?()
    }

    func movePointer(x: Int, y: Int, width: Int, height: Int) {
        record("move \(x) \(y)")
    }

    func setButton(_ button: Int32, down: Bool) {
        record("\(down ? "down" : "up") \(Self.name(button))")
    }

    func click(_ button: Int32) {
        setButton(button, down: true)
        setButton(button, down: false)
    }

    func scroll(vertical: Int, horizontal: Int) {
        record("scroll \(vertical) \(horizontal)")
    }

    func setKey(_ keyCode: UInt16, down: Bool, modifiers: UInt8) {
        record("\(down ? "keydown" : "keyup") \(Self.hex(keyCode))")
    }

    func keyStroke(_ keyCode: UInt16, modifiers: UInt8, nonNormalized: Bool) {
        let held = Modifier.pressOrder.filter { modifiers & $0.flag != 0 }.map { "+\($0.rawValue)" }
        record((["key \(Self.hex(keyCode))"] + held).joined(separator: " "))
    }

    func text(_ text: String) {
        record("text \(text)")
    }

    func gamepadConnect() {
        record("gamepad connect")
    }

    func gamepad(_ state: GamepadState) {
        record(String(format: "gamepad 0x%04X lt %d rt %d ls %d %d rs %d %d", state.buttons, state.leftTrigger, state.rightTrigger,
                      state.leftX, state.leftY, state.rightX, state.rightY))
    }

    func gamepadDisconnect() {
        record("gamepad disconnect")
    }

    /// Something else the demo wants the tests to see (a controller's state going to the PC).
    func note(_ event: String) {
        record(event)
    }

    private static func name(_ button: Int32) -> String {
        MouseButton.allCases.first { $0.moonlight == button }?.name ?? "\(button)"
    }

    private static func hex(_ code: UInt16) -> String {
        String(format: "0x%02X", code)
    }
}
