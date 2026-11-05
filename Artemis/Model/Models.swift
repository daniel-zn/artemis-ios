//
//  Models.swift
//  Artemis
//
//  Value snapshots of the Obj-C TemporaryHost/TemporaryApp objects, rebuilt on the
//  main thread whenever discovery or a request changes them, so SwiftUI can diff them.
//

import Foundation

enum ComputerStatus: Hashable {
    case unknown, offline, online
}

struct Computer: Identifiable, Hashable {
    let id: String
    var name: String
    var status: ComputerStatus
    var isPaired: Bool
    var isWaking: Bool
    var canWake: Bool
    var runningGameName: String?
    var gameCount: Int
    var isNvidia: Bool

    /// The line under the name, worded like the Mac app's.
    var statusLine: String {
        if isWaking && status != .online {
            return "Waking up…"
        }
        switch status {
        case .unknown:
            return "Connecting…"
        case .offline:
            return canWake ? "Offline · Tap to wake" : "Offline"
        case .online:
            if !isPaired {
                return "Not paired · Tap to pair"
            }
            if let runningGameName {
                return "Online · \(runningGameName) active"
            }
            return "Online"
        }
    }
}

struct Game: Identifiable, Hashable {
    var id: String { "\(hostID)/\(appID)" }
    let hostID: String
    let appID: String
    var name: String
    var isHidden: Bool
    var isRunning: Bool
    /// Connects by itself when its PC is opened.
    var isDirectLaunch = false
}

enum Route: Hashable {
    case games(String)
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// Adds a Help button that opens the troubleshooting guide, like upstream's dialogs.
    var showsHelp = false
}

struct PairingInfo: Identifiable {
    var id: String { hostID }
    let hostID: String
    let hostName: String
    let pin: String
}

enum Links {
    static let sourceCode = URL(string: "https://github.com/daniel-zn/danielzn-moonlight-ios")!
    static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let troubleshooting = URL(string: "https://github.com/moonlight-stream/moonlight-docs/wiki/Troubleshooting")!
    static let setupGuide = URL(string: "https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide")!
    static let gameStreamEndOfService = URL(string: "https://github.com/moonlight-stream/moonlight-docs/wiki/NVIDIA-GameStream-End-Of-Service-Announcement-FAQ")!
}

/// Upstream's Log() is variadic C, which Swift can't call.
func logInfo(_ message: String) {
    NSLog("<INFO> %@", message)
}
