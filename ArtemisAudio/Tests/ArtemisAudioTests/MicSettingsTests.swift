// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ArtemisAudio

final class MicSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "ArtemisAudioTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOffByDefaultWithTheIPhoneMicrophone() {
        let settings = MicSettings.load(from: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.input, .iPhone)
    }

    func testChoicesAreKept() {
        var settings = MicSettings.load(from: defaults)
        settings.enabled = true
        settings.input = .bluetooth
        settings.save(to: defaults)
        XCTAssertEqual(MicSettings.load(from: defaults), MicSettings(enabled: true, input: .bluetooth))
        settings.input = .headset
        settings.enabled = false
        settings.save(to: defaults)
        XCTAssertEqual(MicSettings.load(from: defaults), MicSettings(enabled: false, input: .headset))
    }

    func testSettingsScreenKeysAreTheOnesRead() {
        // The settings screen binds @AppStorage to these keys directly
        defaults.set(true, forKey: MicSettings.Keys.enabled)
        defaults.set(MicInputChoice.headset.rawValue, forKey: MicSettings.Keys.input)
        XCTAssertEqual(MicSettings.load(from: defaults), MicSettings(enabled: true, input: .headset))
    }

    func testAnUnknownInputFallsBackToTheIPhone() {
        defaults.set("usb-thing", forKey: MicSettings.Keys.input)
        XCTAssertEqual(MicSettings.load(from: defaults).input, .iPhone)
    }

    func testLaunchArgumentTextIsRead() {
        // Launch arguments arrive as strings ("YES"); bool(forKey:) reads them
        defaults.set("YES", forKey: MicSettings.Keys.enabled)
        XCTAssertTrue(MicSettings.load(from: defaults).enabled)
    }

    func testOnlyBluetoothUsesTheCallLink() {
        XCTAssertTrue(MicInputChoice.bluetooth.usesBluetoothCallLink)
        XCTAssertFalse(MicInputChoice.iPhone.usesBluetoothCallLink)
        XCTAssertFalse(MicInputChoice.headset.usesBluetoothCallLink)
    }
}
