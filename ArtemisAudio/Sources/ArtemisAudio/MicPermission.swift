// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MicPermission.swift
//  Artemis
//
//  The microphone permission, as the Mac app handles it: iOS asks once, the first time the
//  microphone is wanted (turning it on, testing it, or a session with it on when nobody has
//  decided yet). After a decision Artemis never asks again and shows no alert of its own: a
//  denial is one quiet line in Settings with Open Settings.
//

import AVFAudio

enum MicPermissionStatus {
    case undetermined, granted, denied
}

/// Where the permission lives (the system's, or a test's).
protocol MicPermissionSource: AnyObject, Sendable {
    var status: MicPermissionStatus { get }
    /// Shows the system's question; calls back with the answer.
    func request(_ done: @escaping @Sendable (Bool) -> Void)
}

/// The system's microphone permission.
final class SystemMicPermission: MicPermissionSource {
    static let shared = SystemMicPermission()

    var status: MicPermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    func request(_ done: @escaping @Sendable (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission(completionHandler: done)
    }
}

/// Main thread only.
final class MicPermissionGate {
    static let shared = MicPermissionGate(source: SystemMicPermission.shared)

    private let source: MicPermissionSource
    /// Callers waiting for the question on screen.
    private var waiting: [(Bool) -> Void]?

    init(source: MicPermissionSource) {
        self.source = source
    }

    /// Read from the system each time: the user can change it in iOS Settings at any moment.
    var status: MicPermissionStatus { source.status }

    /// Whether wanting the microphone now would show the system's question.
    var wouldAsk: Bool { status == .undetermined && waiting == nil }

    /// Calls back with whether the microphone may be used. Asks the system only when nobody has
    /// decided yet, and only once: calls while its question is up wait for that answer.
    func ensureAccess(_ done: @escaping (Bool) -> Void) {
        switch status {
        case .granted:
            done(true)
        case .denied:
            done(false)
        case .undetermined:
            if waiting != nil {
                waiting?.append(done)
                return
            }
            waiting = [done]
            source.request { [weak self] granted in
                let finish = {
                    guard let self else { return }
                    let callers = self.waiting ?? []
                    self.waiting = nil
                    callers.forEach { $0(granted) }
                }
                if Thread.isMainThread { finish() } else { DispatchQueue.main.async { finish() } }
            }
        }
    }

    /// The Settings line: the microphone is on but iOS doesn't allow it.
    func showsDeniedLine(enabled: Bool) -> Bool {
        enabled && status == .denied
    }
}
