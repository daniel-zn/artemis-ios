//
//  ClipboardSyncState.swift
//  Artemis
//
//  The decisions of the shared clipboard (plain text) with an Apollo PC, without any I/O
//  (ClipboardSync does the requests and the pasteboard). As the Mac app's ClipboardSyncState,
//  with iOS's pasteboard in mind: reading it can bring up "Allow Paste" or a "pasted from"
//  notice, so it's read only when its changeCount moved since we last knew it and it has text.
//
//  hostSeen is what the PC's clipboard was last known to hold (fetched, or sent by us): it's
//  never sent again and never written here, so nothing echoes, and the first fetch of a session
//  only learns it (what was on the PC before the session stays there). A failed send is kept to
//  try again unread; a refused permission (HTTP 401) quietly turns that direction off for the
//  session; a PC without the endpoint turns both off.
//

import Foundation

struct ClipboardSyncState {
    /// Bigger texts (UTF-8 bytes) are left alone both ways.
    static let maxBytes = 1024 * 1024

    enum Result: Equatable {
        case ok, denied, unsupported, failed
    }

    /// The PC's clipboard as last known (local line ends); nil until the first fetch or send.
    private(set) var hostSeen: String?
    /// The pasteboard's changeCount when we last read or wrote it; nil: never.
    private(set) var localKnownCount: Int?
    private var inFlight: String?
    /// Read but not yet on the PC (a send failed): goes at the next trigger without a new read.
    private var pending: String?
    private var sendDenied = false
    private var readDenied = false
    private var unsupported = false

    init(localKnownCount: Int?) {
        self.localKnownCount = localKnownCount
    }

    var sendAllowed: Bool { !sendDenied && !unsupported }
    var canFetch: Bool { !readDenied && !unsupported }

    static func fits(_ text: String) -> Bool {
        text.utf8.count <= maxBytes
    }

    // MARK: iPhone → PC

    /// The text to send now, if any (then it's in flight until endSend). `read` is called only
    /// when the pasteboard changed since we last knew it and has text.
    mutating func localToSend(changeCount: Int, hasStrings: Bool, read: () -> String?) -> String? {
        guard sendAllowed else { return nil }
        let text: String?
        if changeCount == localKnownCount {
            text = pending
        } else {
            localKnownCount = changeCount
            pending = nil
            text = hasStrings ? read() : nil
        }
        guard let text, !text.isEmpty, Self.fits(text), text != hostSeen, text != inFlight else {
            return nil
        }
        inFlight = text
        pending = nil
        return text
    }

    mutating func endSend(_ text: String, result: Result) {
        if inFlight == text { inFlight = nil }
        switch result {
        case .ok: hostSeen = text
        case .denied: sendDenied = true
        case .unsupported: unsupported = true
        case .failed: pending = text
        }
    }

    // MARK: PC → iPhone

    /// A fetch's answer: the text to write to the pasteboard, if any (then didWriteLocal).
    /// The changeCounts are the pasteboard's when the fetch was asked for and now: copied here
    /// meanwhile, the newer copy here wins.
    mutating func endFetch(_ result: Result, wire: String?, changeCountAtRequest: Int, changeCountNow: Int) -> String? {
        switch result {
        case .denied: readDenied = true; return nil
        case .unsupported: unsupported = true; return nil
        case .failed: return nil
        case .ok: break
        }
        let text = Self.fromWire(wire ?? "")
        let known = hostSeen
        hostSeen = text
        guard known != nil, text != known, !text.isEmpty, Self.fits(text), text != inFlight,
              changeCountNow == changeCountAtRequest else {
            return nil
        }
        return text
    }

    mutating func didWriteLocal(changeCount: Int) {
        localKnownCount = changeCount
        pending = nil
    }

    // MARK: Wire

    /// Line ends on the wire are Windows's (CRLF).
    static func toWire(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func fromWire(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// An answer as a result: 401 is a refused permission (clipboard_read / clipboard_set),
    /// 404 a PC without the endpoint, and so is Sunshine's "200 with an XML 404" for unknown
    /// paths; 403 (not streaming yet), 5xx and no answer are failures to try again.
    static func result(status: Int, body: Data?) -> Result {
        switch status {
        case 200:
            if let body, body.starts(with: Data("<?xml".utf8)) {
                let head = String(decoding: body.prefix(512), as: UTF8.self)
                if head.contains("<root"), head.contains("status_code=\""), !head.contains("status_code=\"200\"") {
                    return .unsupported
                }
            }
            return .ok
        case 401: return .denied
        case 404: return .unsupported
        default: return .failed
        }
    }
}
