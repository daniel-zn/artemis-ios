//
//  ClipboardSyncState.swift
//  Artemis
//
//  The decisions of the shared clipboard (plain text) with an Apollo PC, without any I/O
//  (ClipboardSync does the requests and the pasteboard). As the Mac app's ClipboardSyncState,
//  with iOS's pasteboard in mind: reading it can bring up "Allow Paste" or a "pasted from"
//  notice, so it's read only when the user pastes in the session: the Paste control and UIKit's
//  paste hand over the text themselves (no question), and Ctrl+V reads it only when its
//  changeCount moved since we last knew it and it has text.
//
//  hostSeen is what the PC's clipboard was last known to hold (fetched, or sent by us): it's
//  never sent again and never written here, so nothing echoes, and the first fetch of a session
//  only learns it (what was on the PC before the session stays there). A paste the PC doesn't
//  take is typed instead; a refused permission (HTTP 401) quietly turns that direction off for
//  the session; a PC without the endpoint turns both off.
//

import Foundation

struct ClipboardSyncState {
    /// Bigger texts (UTF-8 bytes) are left alone both ways.
    static let maxBytes = 1024 * 1024

    enum Result: Equatable {
        case ok, denied, unsupported, failed
    }

    /// What a paste does next.
    enum PasteStep: Equatable {
        /// Onto the PC's clipboard first, then Ctrl+V (endPaste says which way it went).
        case send(String)
        /// The PC's clipboard has it (or nothing new was copied here): Ctrl+V alone.
        case ctrlV
        /// Not shared with this PC: typed instead.
        case type(String)
        case nothing
    }

    /// The PC's clipboard as last known (local line ends); nil until the first fetch or send.
    private(set) var hostSeen: String?
    /// The pasteboard's changeCount when we last read or wrote it; nil: never.
    private(set) var localKnownCount: Int?
    private var inFlight: String?
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

    // MARK: Paste

    /// Pasted in the session with this text (the Paste control's, or UIKit's paste), read just
    /// now at `changeCount`.
    mutating func paste(_ text: String, changeCount: Int) -> PasteStep {
        localKnownCount = changeCount
        guard !text.isEmpty, Self.fits(text) else { return .nothing }
        guard sendAllowed else { return .type(text) }
        if text == hostSeen { return .ctrlV }
        inFlight = text
        return .send(text)
    }

    /// Ctrl+V (a keyboard's, or the shortcuts menu's): the PC pastes its own clipboard, with
    /// what was copied here since we last knew on it first. `read` is called only when the
    /// pasteboard changed since then and has text, and never when sending isn't allowed.
    mutating func pasteKey(changeCount: Int, hasStrings: Bool, read: () -> String?) -> PasteStep {
        guard sendAllowed else { return .ctrlV }
        guard changeCount != localKnownCount else { return .ctrlV }
        guard hasStrings, let text = read(), !text.isEmpty else {
            localKnownCount = changeCount
            return .ctrlV
        }
        let step = paste(text, changeCount: changeCount)
        return step == .nothing ? .ctrlV : step
    }

    /// The PC's answer to a paste's send: Ctrl+V once the text is on its clipboard, otherwise
    /// typed (refused, no endpoint, no answer: what was pasted still arrives).
    mutating func endPaste(_ text: String, result: Result) -> PasteStep {
        if inFlight == text { inFlight = nil }
        switch result {
        case .ok: hostSeen = text; return .ctrlV
        case .denied: sendDenied = true
        case .unsupported: unsupported = true
        case .failed: break
        }
        return .type(text)
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
