// SPDX-License-Identifier: GPL-3.0-or-later
//
//  AudioRecovery.swift
//  Artemis
//
//  When the session's audio engine is rebuilt, decided apart from AVFoundation so every case is
//  tested: what the user wants (a graph running) is kept apart from whether an engine exists, so
//  nothing that happens to the engine (a call, Siri, a failed rebuild, a media-services reset, a
//  storm of route changes) can leave the sound off for good while a session wants it.
//
//  - Configuration changes carry the generation of the engine that posted them: a stale one
//    (from an engine already replaced) is ignored, so queued duplicates rebuild once.
//  - Turning voice processing on reports a change just after the start: ignored for 1 s.
//  - During an interruption nothing is rebuilt; when it ends, the audio session is restored
//    (category, preferred input, active) and the graph rebuilt.
//  - A media-services reset invalidates the audio session: restored, then rebuilt.
//  - A failed rebuild is retried with back-off (1, 2, 4, 8 s, then every 8 s) while wanted.
//  - More than 5 rebuilds within 10 s: the next one waits for a retry instead of running now.
//

import Foundation

struct AudioRecovery {
    enum Action: Equatable {
        case none
        /// Build the engine again with the same graph.
        case rebuild
        /// Set the audio session up again (category, input, active), then rebuild.
        case restoreSessionAndRebuild
        /// Nothing now; call retryFired(token:) after this many seconds.
        case retry(after: TimeInterval, token: Int)
    }

    static let startupGrace: TimeInterval = 1
    static let burstWindow: TimeInterval = 10
    static let burstLimit = 5

    /// A session or test wants sound.
    private(set) var wanted = false
    /// An engine is running.
    private(set) var running = false
    private(set) var interrupted = false
    /// The running engine's generation (configuration changes carry it).
    private(set) var generation = 0
    /// The audio session must be set up again before the next build.
    private(set) var sessionInvalid = false
    private var lastStart = Date.distantPast
    private var rebuilds: [Date] = []
    private var failures = 0
    private var retryToken = 0

    /// A session or test starts (true) or everything stops (false).
    mutating func setWanted(_ wanted: Bool) {
        self.wanted = wanted
        if !wanted {
            running = false
            interrupted = false
            sessionInvalid = false
            rebuilds = []
            failures = 0
            retryToken += 1
        }
    }

    /// An engine started; returns its generation.
    mutating func started(at now: Date) -> Int {
        running = true
        failures = 0
        sessionInvalid = false
        lastStart = now
        generation += 1
        retryToken += 1
        return generation
    }

    /// The engine was stopped on purpose (before a rebuild, or at the end).
    mutating func stopped() {
        running = false
        generation += 1
    }

    /// Building or starting the engine failed.
    mutating func startFailed(at now: Date) -> Action {
        running = false
        guard wanted, !interrupted else { return .none }
        failures += 1
        return scheduleRetry(after: min(8, pow(2, Double(failures - 1))))
    }

    /// AVAudioEngineConfigurationChange from the engine of `engineGeneration`.
    mutating func configurationChanged(engineGeneration: Int, at now: Date) -> Action {
        guard wanted, engineGeneration == generation, running else { return .none }
        if interrupted { return .none }
        if now.timeIntervalSince(lastStart) < Self.startupGrace { return .none }
        rebuilds = rebuilds.filter { now.timeIntervalSince($0) < Self.burstWindow }
        guard rebuilds.count < Self.burstLimit else {
            // A storm: no rebuild now, but one later (never stuck off)
            running = false
            return scheduleRetry(after: Self.burstWindow / 2)
        }
        rebuilds.append(now)
        return .rebuild
    }

    mutating func interruptionBegan() {
        guard wanted else { return }
        interrupted = true
        // The system stopped the engine
        running = false
        retryToken += 1
    }

    /// The interruption ended (the system's resume hint isn't needed: the session wants sound).
    mutating func interruptionEnded() -> Action {
        guard wanted, interrupted else { return .none }
        interrupted = false
        return .restoreSessionAndRebuild
    }

    /// Media services were reset: every audio object, the session's setup included, is gone.
    mutating func mediaServicesReset() -> Action {
        guard wanted else { return .none }
        running = false
        sessionInvalid = true
        // A reset also ends any interruption
        interrupted = false
        return .restoreSessionAndRebuild
    }

    /// A route change (a headset came or went) while the sound is off after a failure: try now.
    mutating func routeChanged() -> Action {
        guard wanted, !running, !interrupted else { return .none }
        return sessionInvalid ? .restoreSessionAndRebuild : .rebuild
    }

    /// A retry's time came.
    mutating func retryFired(token: Int) -> Action {
        guard token == retryToken, wanted, !running, !interrupted else { return .none }
        return sessionInvalid ? .restoreSessionAndRebuild : .rebuild
    }

    private mutating func scheduleRetry(after delay: TimeInterval) -> Action {
        retryToken += 1
        return .retry(after: delay, token: retryToken)
    }
}
