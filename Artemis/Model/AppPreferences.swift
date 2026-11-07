//
//  AppPreferences.swift
//  Artemis
//
//  Settings the Mac app has that upstream's database doesn't, saved in UserDefaults (the
//  settings screen binds them with @AppStorage under the same keys).
//

import Foundation

enum AppPreferences {
    enum Keys {
        /// Host PC › Stop the app on the PC after a session.
        static let quitAppAfterSession = "ArtemisQuitAppAfterSession"
        /// Controllers › Mouse control with a controller (hold Start / Menu).
        static let gamepadMouse = "ArtemisGamepadMouse"
        /// Keyboard & Mouse › Swap left and right mouse buttons (a connected mouse; read by ControllerSupport).
        static let swapMouseButtons = "ArtemisSwapMouseButtons"
        /// Controllers › On-screen controller size (0.8 / 0.9 / 1 of the space it gets).
        static let onScreenGamepadSize = "ArtemisGamepadSize"
        /// Controllers › On-screen controller opacity over the desktop (0.3–1).
        static let onScreenGamepadOpacity = "ArtemisGamepadOpacity"
        /// Host PC › Share copied text with the host PC (Apollo's shared clipboard; on by default).
        static let shareClipboard = "ArtemisShareClipboard"
    }

    static var quitAppAfterSession: Bool {
        UserDefaults.standard.bool(forKey: Keys.quitAppAfterSession)
    }

    static var onScreenGamepadSize: Double {
        let value = UserDefaults.standard.double(forKey: Keys.onScreenGamepadSize)
        return value > 0 ? min(max(value, 0.6), 1) : PadLayout.defaultSize
    }

    static var onScreenGamepadOpacity: Double {
        let value = UserDefaults.standard.object(forKey: Keys.onScreenGamepadOpacity) == nil
            ? 0.75 : UserDefaults.standard.double(forKey: Keys.onScreenGamepadOpacity)
        return min(max(value, 0.3), 1)
    }

    static var shareClipboard: Bool {
        UserDefaults.standard.object(forKey: Keys.shareClipboard) == nil || UserDefaults.standard.bool(forKey: Keys.shareClipboard)
    }

    static var gamepadMouse: Bool {
        // bool(forKey:) also reads "YES" / "NO" from launch arguments
        UserDefaults.standard.object(forKey: Keys.gamepadMouse) == nil || UserDefaults.standard.bool(forKey: Keys.gamepadMouse)
    }
}
