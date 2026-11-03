//
//  PointerSettings.swift
//  Artemis
//
//  Settings › Touch & Pointer that upstream's database doesn't have (the default mode is
//  its absoluteTouchMode). Saved in UserDefaults.
//

import Foundation

struct PointerSettings: Equatable {
    /// Scales the trackpad's pointer movement (0.5–2.5).
    var pointerSpeed: Double
    /// Scroll direction › Natural: the content follows the fingers, as on iPhone and a Mac's
    /// trackpad (two fingers up scroll further down the page, two fingers left scroll right).
    /// Off is Reversed.
    var naturalScrolling: Bool
    /// A session starts with the control bar open (otherwise folded into a button).
    var showControlBar: Bool

    static let speedRange = 0.5...2.5

    static func load() -> PointerSettings {
        let defaults = UserDefaults.standard
        // bool(forKey:) / double(forKey:) also read a launch argument's "NO" or "1.5", which
        // `as? Bool` didn't (a test's -ArtemisNaturalScrolling NO was ignored)
        func value<T>(_ key: String, _ fallback: T, _ read: (String) -> T) -> T {
            defaults.object(forKey: key) == nil ? fallback : read(key)
        }
        return PointerSettings(
            pointerSpeed: value(Keys.speed, 1.0, defaults.double(forKey:)),
            naturalScrolling: value(Keys.natural, true, defaults.bool(forKey:)),
            showControlBar: value(Keys.showBar, true, defaults.bool(forKey:)))
    }

    /// Moves every install to Natural once (build 1279, and again when Natural's direction was
    /// flipped to match the PC's screen): a phone could have Reversed stored as a workaround.
    /// Marked done once stored, so a later choice of Reversed stays.
    static func adoptNaturalScrollingOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.naturalApplied) else { return }
        defaults.set(true, forKey: Keys.natural)
        defaults.set(true, forKey: Keys.naturalApplied)
    }

    /// Demo only: a phone with Reversed stored from before and not moved yet, to test the move.
    static func applyTestState() {
        let defaults = UserDefaults.standard
        guard DemoData.isEnabled && defaults.bool(forKey: "ArtemisTestReversedScrolling") else { return }
        defaults.set(false, forKey: Keys.natural)
        defaults.removeObject(forKey: Keys.naturalApplied)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(pointerSpeed, forKey: Keys.speed)
        defaults.set(naturalScrolling, forKey: Keys.natural)
        defaults.set(showControlBar, forKey: Keys.showBar)
    }

    private enum Keys {
        static let speed = "ArtemisPointerSpeed"
        static let natural = "ArtemisNaturalScrolling"
        static let naturalApplied = "ArtemisNaturalScrollingApplied2"
        static let showBar = "ArtemisShowControlBar"
    }
}
