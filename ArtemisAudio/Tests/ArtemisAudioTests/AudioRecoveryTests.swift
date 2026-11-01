// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ArtemisAudio

/// The session's sound never stays off while a session wants it: interruptions, failed rebuilds,
/// media-services resets, stale and repeated configuration changes.
final class AudioRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A session whose engine is running (generation returned).
    private func running(_ r: inout AudioRecovery) -> Int {
        r.setWanted(true)
        return r.started(at: t0)
    }

    func testInterruptionThenFailedRebuildRecoversWhenItEnds() {
        // Review P1: a configuration change during an interruption rebuilt, the rebuild failed,
        // the engine was gone and the end of the interruption did nothing
        var r = AudioRecovery()
        let g = running(&r)
        r.interruptionBegan()
        XCTAssertEqual(r.configurationChanged(engineGeneration: g, at: at(5)), .none, "rebuilt during an interruption")
        XCTAssertEqual(r.startFailed(at: at(6)), .none, "a retry while interrupted")
        XCTAssertEqual(r.interruptionEnded(), .restoreSessionAndRebuild)
        // That rebuild fails too: retried, not given up
        guard case .retry(_, let token) = r.startFailed(at: at(7)) else { return XCTFail("no retry") }
        XCTAssertEqual(r.retryFired(token: token), .rebuild)
        _ = r.started(at: at(9))
        XCTAssertTrue(r.running)
    }

    func testInterruptionEndAlwaysRestoresTheSession() {
        var r = AudioRecovery()
        _ = running(&r)
        r.interruptionBegan()
        XCTAssertFalse(r.running)
        XCTAssertEqual(r.interruptionEnded(), .restoreSessionAndRebuild)
        XCTAssertEqual(r.interruptionEnded(), .none, "a second end")
    }

    func testMediaServicesResetRestoresTheSessionFirst() {
        // Review P1: a reset only rebuilt the engine, on a session that no longer had its setup
        var r = AudioRecovery()
        _ = running(&r)
        XCTAssertEqual(r.mediaServicesReset(), .restoreSessionAndRebuild)
        XCTAssertTrue(r.sessionInvalid)
        // Its rebuild fails: the retry restores the session too
        guard case .retry(_, let token) = r.startFailed(at: at(1)) else { return XCTFail("no retry") }
        XCTAssertEqual(r.retryFired(token: token), .restoreSessionAndRebuild)
        _ = r.started(at: at(2))
        XCTAssertFalse(r.sessionInvalid)
    }

    func testMediaServicesResetDuringAnInterruption() {
        var r = AudioRecovery()
        _ = running(&r)
        r.interruptionBegan()
        XCTAssertEqual(r.mediaServicesReset(), .restoreSessionAndRebuild)
        XCTAssertFalse(r.interrupted)
    }

    func testStaleConfigurationChangesAreIgnored() {
        // Review P2: queued notifications from a replaced engine each rebuilt again
        var r = AudioRecovery()
        let first = running(&r)
        XCTAssertEqual(r.configurationChanged(engineGeneration: first, at: at(2)), .rebuild)
        r.stopped()
        let second = r.started(at: at(2.1))
        XCTAssertNotEqual(first, second)
        // The same change, queued twice from the first engine
        XCTAssertEqual(r.configurationChanged(engineGeneration: first, at: at(3.5)), .none)
        XCTAssertEqual(r.configurationChanged(engineGeneration: first, at: at(3.6)), .none)
        XCTAssertEqual(r.configurationChanged(engineGeneration: second, at: at(3.7)), .rebuild)
    }

    func testVoiceProcessingsOwnChangeAtStartIsIgnored() {
        var r = AudioRecovery()
        let g = running(&r)
        XCTAssertEqual(r.configurationChanged(engineGeneration: g, at: at(0.3)), .none)
        XCTAssertEqual(r.configurationChanged(engineGeneration: g, at: at(1.5)), .rebuild)
    }

    func testAStormOfChangesWaitsButComesBack() {
        // Review P2: bounded, but with a way back
        var r = AudioRecovery()
        var g = running(&r)
        var now: TimeInterval = 2
        for _ in 0..<AudioRecovery.burstLimit {
            XCTAssertEqual(r.configurationChanged(engineGeneration: g, at: at(now)), .rebuild)
            r.stopped()
            g = r.started(at: at(now))
            now += 1.2
        }
        guard case .retry(let delay, let token) = r.configurationChanged(engineGeneration: g, at: at(now)) else {
            return XCTFail("the storm went on rebuilding")
        }
        XCTAssertGreaterThan(delay, 0)
        XCTAssertFalse(r.running)
        XCTAssertEqual(r.retryFired(token: token), .rebuild, "never stuck off")
    }

    func testFailuresBackOffAndKeepTrying() {
        var r = AudioRecovery()
        r.setWanted(true)
        var delays: [TimeInterval] = []
        for i in 0..<6 {
            guard case .retry(let delay, let token) = r.startFailed(at: at(Double(i))) else { return XCTFail("gave up") }
            delays.append(delay)
            XCTAssertEqual(r.retryFired(token: token), .rebuild)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 8, 8])
    }

    func testOldRetriesAndStoppedSessionsDoNothing() {
        var r = AudioRecovery()
        r.setWanted(true)
        guard case .retry(_, let old) = r.startFailed(at: t0) else { return XCTFail() }
        _ = r.started(at: at(0.5))
        XCTAssertEqual(r.retryFired(token: old), .none, "a retry after the engine came back")
        let g = r.generation
        r.setWanted(false)
        XCTAssertEqual(r.configurationChanged(engineGeneration: g, at: at(5)), .none)
        XCTAssertEqual(r.interruptionEnded(), .none)
        XCTAssertEqual(r.mediaServicesReset(), .none)
        XCTAssertEqual(r.startFailed(at: at(6)), .none)
    }

    func testRouteChangeRetriesAfterAFailureAtOnce() {
        var r = AudioRecovery()
        r.setWanted(true)
        _ = r.startFailed(at: t0)
        XCTAssertEqual(r.routeChanged(), .rebuild)
        _ = r.started(at: at(1))
        XCTAssertEqual(r.routeChanged(), .none, "running: the engine's own change handles it")
    }
}
