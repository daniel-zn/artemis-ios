//
//  ClipboardSync.swift
//  Artemis
//
//  The shared clipboard (plain text) with an Apollo PC during a session, through Apollo's
//  /actions/clipboard?type=text (the one the Mac app and Artemis for Android use; it needs the
//  client's clipboard_read / clipboard_set permissions in Apollo and a running session).
//
//  iPhone → PC: only when the user pastes in the session (the shortcuts menu's Paste, UIKit's
//  paste, ⌘V, Ctrl+V): the text goes onto the PC's clipboard, then Ctrl+V pastes it there. Nothing reads
//  the pasteboard when the session starts or comes back, so iOS never asks "Allow Paste" for
//  that. PC → iPhone: every couple of seconds,
//  shortly after Ctrl+C or Ctrl+X goes to the PC, when the app leaves the foreground and when
//  the session ends. Requests run one at a time on a worker queue; everything else, the state
//  and the pasteboard, on the main queue. Foundation only: Scripts/clipboard-tests.sh builds it
//  for the Mac with stand-ins (StreamClipboard has the app's real ones).
//

import Foundation

/// Apollo's endpoint. Blocking; called on the worker queue. Status: the HTTP status, or
/// negative when there was no answer.
protocol ClipboardHostLink: AnyObject {
    func getClipboard(timeout: TimeInterval) -> (status: Int, body: Data?)
    func setClipboard(_ body: Data, timeout: TimeInterval) -> Int
}

/// The general pasteboard (main queue).
protocol LocalPasteboard: AnyObject {
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    func readString() -> String?
    func write(_ string: String)
}

/// The pasteboard's changeCount we last knew per PC, so a new session with the same PC
/// doesn't read the pasteboard again for a copy that's already there.
protocol ClipboardKnownCountStore: AnyObject {
    func knownCount(for hostID: String) -> Int?
    func setKnownCount(_ count: Int, for hostID: String)
}

final class ClipboardSync {
    typealias Result = ClipboardSyncState.Result
    typealias PasteStep = ClipboardSyncState.PasteStep

    private let hostID: String
    private let link: ClipboardHostLink
    private let pasteboard: LocalPasteboard
    private let store: ClipboardKnownCountStore
    private let pollInterval: TimeInterval
    private let copyDelay: TimeInterval
    private let timeout: TimeInterval
    private let worker = DispatchQueue(label: "artemis.clipboard", qos: .utility)
    private var state: ClipboardSyncState
    private var pollTimer: DispatchSourceTimer?
    /// A fetch waiting on the worker: more triggers meanwhile join it.
    private var fetchQueued = false
    private var ended = false

    var log: (String) -> Void = { _ in }

    init(hostID: String, link: ClipboardHostLink, pasteboard: LocalPasteboard, store: ClipboardKnownCountStore,
         pollInterval: TimeInterval = 2, copyDelay: TimeInterval = 0.3, timeout: TimeInterval = 2) {
        self.hostID = hostID
        self.link = link
        self.pasteboard = pasteboard
        self.store = store
        self.pollInterval = pollInterval
        self.copyDelay = copyDelay
        self.timeout = timeout
        state = ClipboardSyncState(localKnownCount: store.knownCount(for: hostID))
    }

    deinit {
        pollTimer?.cancel()
    }

    // MARK: Session events (main queue)

    /// The session is up: learn what the PC has, then keep watching. The pasteboard isn't read.
    func streamStarted() {
        fetch()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.fetch() }
        timer.resume()
        pollTimer = timer
    }

    /// Leaving the foreground: bring the PC's last copy over while it still answers.
    func resignedActive() {
        guard !ended else { return }
        fetch()
    }

    /// Ctrl+C or Ctrl+X went to the PC: its clipboard has the copy a moment later.
    func copyKeySent() {
        guard !ended else { return }
        fetch(after: copyDelay)
    }

    /// The session is ending: one more fetch (the PC answers only during a session), then
    /// `completion` on the main queue when it's done or after the time limit.
    func streamEnding(completion: @escaping () -> Void) {
        pollTimer?.cancel()
        pollTimer = nil
        var called = false
        let finish = { [weak self] in
            guard !called else { return }
            called = true
            self?.ended = true
            completion()
        }
        guard state.canFetch else {
            finish()
            return
        }
        fetch()
        // After everything already on the worker, and the main queue's handling of it
        worker.async {
            DispatchQueue.main.async { finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
    }

    // MARK: Paste (main queue)

    /// Pasted with this text, read just now (UIKit's paste): `completion`
    /// on the main queue with .ctrlV once it's on the PC's clipboard, or .type / .nothing.
    func paste(_ text: String, completion: @escaping (PasteStep) -> Void) {
        let step = state.paste(text, changeCount: pasteboard.changeCount)
        store.setKnownCount(pasteboard.changeCount, for: hostID)
        run(step, completion: completion)
    }

    /// Ctrl+V: what was copied here since we last knew goes onto the PC's clipboard first (the
    /// pasteboard is read only then); `completion` as for paste.
    func pasteKey(completion: @escaping (PasteStep) -> Void) {
        let board = pasteboard
        let step = state.pasteKey(changeCount: board.changeCount, hasStrings: board.hasStrings, read: board.readString)
        store.setKnownCount(state.localKnownCount ?? board.changeCount, for: hostID)
        run(step, completion: completion)
    }

    private func run(_ step: PasteStep, completion: @escaping (PasteStep) -> Void) {
        guard case .send(let text) = step, !ended else {
            if case .send(let text) = step { completion(.type(text)) } else { completion(step) }
            return
        }
        let body = Data(ClipboardSyncState.toWire(text).utf8)
        worker.async { [weak self, link, timeout] in
            let status = link.setClipboard(body, timeout: timeout)
            let result = ClipboardSyncState.result(status: status, body: nil)
            DispatchQueue.main.async {
                guard let self else { return completion(.type(text)) }
                self.log("Clipboard: pasted \(body.count) bytes onto the PC's clipboard: \(Self.describe(result, status: status))")
                completion(self.state.endPaste(text, result: result))
            }
        }
    }

    // MARK: Requests

    private func fetch(after delay: TimeInterval = 0) {
        guard state.canFetch, !fetchQueued, !ended else { return }
        fetchQueued = true
        let countAtRequest = pasteboard.changeCount
        worker.async { [weak self, link, timeout] in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            DispatchQueue.main.sync { self?.fetchQueued = false }
            let (status, body) = link.getClipboard(timeout: timeout)
            let result = ClipboardSyncState.result(status: status, body: body)
            let wire = body.map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async {
                self?.apply(result, status: status, wire: wire, countAtRequest: countAtRequest)
            }
        }
    }

    private func apply(_ result: Result, status: Int, wire: String?, countAtRequest: Int) {
        if result != .ok {
            log("Clipboard: fetch from the PC: \(Self.describe(result, status: status))")
        }
        guard let text = state.endFetch(result, wire: wire, changeCountAtRequest: countAtRequest,
                                        changeCountNow: pasteboard.changeCount) else { return }
        pasteboard.write(text)
        state.didWriteLocal(changeCount: pasteboard.changeCount)
        store.setKnownCount(pasteboard.changeCount, for: hostID)
        log("Clipboard: copied \(text.utf8.count) bytes from the PC")
    }

    private static func describe(_ result: Result, status: Int) -> String {
        switch result {
        case .ok: "ok"
        case .denied: "not permitted by the PC (Apollo's clipboard permissions for this device)"
        case .unsupported: "not supported by the PC"
        case .failed: status < 0 ? "no answer" : "failed (HTTP \(status))"
        }
    }
}
