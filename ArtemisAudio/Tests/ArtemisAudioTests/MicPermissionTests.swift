// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ArtemisAudio

/// iOS asks for the microphone once, the first time it's needed; after a decision Artemis never
/// asks again (and never shows its own alert): denied only shows a line in Settings.
final class MicPermissionTests: XCTestCase {
    /// The system's permission: counts requests, answers when told to.
    final class FakeSystem: MicPermissionSource, @unchecked Sendable {
        var status: MicPermissionStatus
        var requests = 0
        var answer: Bool?
        private var pending: [(Bool) -> Void] = []

        init(_ status: MicPermissionStatus, answer: Bool? = nil) {
            self.status = status
            self.answer = answer
        }

        func request(_ done: @escaping @Sendable (Bool) -> Void) {
            requests += 1
            if let answer {
                status = answer ? .granted : .denied
                done(answer)
            } else {
                pending.append(done)
            }
        }

        func decide(_ granted: Bool) {
            status = granted ? .granted : .denied
            pending.forEach { $0(granted) }
            pending = []
        }
    }

    func testUndeterminedAsksOnceAndRemembers() {
        let system = FakeSystem(.undetermined, answer: true)
        let gate = MicPermissionGate(source: system)
        var results: [Bool] = []
        gate.ensureAccess { results.append($0) }
        gate.ensureAccess { results.append($0) }
        XCTAssertEqual(system.requests, 1)
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(gate.status, .granted)
        XCTAssertFalse(gate.showsDeniedLine(enabled: true))
    }

    func testCallsWhileTheSystemAsksShareTheOneQuestion() {
        let system = FakeSystem(.undetermined)
        let gate = MicPermissionGate(source: system)
        var results: [Bool] = []
        gate.ensureAccess { results.append($0) }
        gate.ensureAccess { results.append($0) }
        XCTAssertEqual(system.requests, 1, "a second question while the first is on screen")
        XCTAssertEqual(results, [])
        system.decide(false)
        XCTAssertEqual(results, [false, false])
    }

    func testDeniedNeverAsks() {
        let system = FakeSystem(.denied)
        let gate = MicPermissionGate(source: system)
        var results: [Bool] = []
        for _ in 0..<3 { gate.ensureAccess { results.append($0) } }
        XCTAssertEqual(system.requests, 0)
        XCTAssertEqual(results, [false, false, false])
        XCTAssertTrue(gate.showsDeniedLine(enabled: true))
        XCTAssertFalse(gate.showsDeniedLine(enabled: false), "the line belongs to a microphone that's on")
    }

    func testDeniedInTheSystemPromptThenNoMoreQuestions() {
        let system = FakeSystem(.undetermined, answer: false)
        let gate = MicPermissionGate(source: system)
        var results: [Bool] = []
        gate.ensureAccess { results.append($0) }
        gate.ensureAccess { results.append($0) }
        XCTAssertEqual(system.requests, 1)
        XCTAssertEqual(results, [false, false])
        XCTAssertTrue(gate.showsDeniedLine(enabled: true))
    }

    func testGrantedNeverAsks() {
        let system = FakeSystem(.granted)
        let gate = MicPermissionGate(source: system)
        var result: Bool?
        gate.ensureAccess { result = $0 }
        XCTAssertEqual(system.requests, 0)
        XCTAssertEqual(result, true)
    }

    func testAllowedLaterInSettingsIsSeen() {
        // Turned on in iOS Settings after a denial: the gate reads the system each time
        let system = FakeSystem(.denied)
        let gate = MicPermissionGate(source: system)
        XCTAssertTrue(gate.showsDeniedLine(enabled: true))
        system.status = .granted
        XCTAssertFalse(gate.showsDeniedLine(enabled: true))
        var result: Bool?
        gate.ensureAccess { result = $0 }
        XCTAssertEqual(result, true)
        XCTAssertEqual(system.requests, 0)
    }

    func testMayAskOnlyWhenUndetermined() {
        XCTAssertTrue(MicPermissionGate(source: FakeSystem(.undetermined)).wouldAsk)
        XCTAssertFalse(MicPermissionGate(source: FakeSystem(.denied)).wouldAsk)
        XCTAssertFalse(MicPermissionGate(source: FakeSystem(.granted)).wouldAsk)
    }
}
